//go:build linux

package netmon

import (
	"bytes"
	_ "embed"
	"errors"
	"fmt"
	"net/netip"
	"runtime"

	"github.com/cilium/ebpf"
	"github.com/cilium/ebpf/link"
	"github.com/cilium/ebpf/rlimit"
)

//go:embed bpf/netmon_bpfel.o
var netmonBPFObject []byte

type bpfFlowKey struct {
	CgroupID   uint64
	Family     uint8
	Protocol   uint8
	Direction  uint8
	Pad        uint8
	SourcePort uint16
	DestPort   uint16
	SourceIP   [16]byte
	DestIP     [16]byte
}

type EBPFCollector struct {
	collection *ebpf.Collection
	flows      *ebpf.Map
	ingress    link.Link
	egress     link.Link
	previous   map[bpfFlowKey]uint64
}

func OpenEBPFCollector(cgroupRoot string) (*EBPFCollector, error) {
	if cgroupRoot == "" {
		cgroupRoot = "/sys/fs/cgroup"
	}
	_ = rlimit.RemoveMemlock()
	spec, err := ebpf.LoadCollectionSpecFromReader(bytes.NewReader(netmonBPFObject))
	if err != nil {
		return nil, fmt.Errorf("read embedded BPF object: %w", err)
	}
	collection, err := ebpf.NewCollection(spec)
	if err != nil {
		return nil, fmt.Errorf("load BPF programs: %w", err)
	}
	collector := &EBPFCollector{
		collection: collection,
		flows:      collection.Maps["flows"],
		previous:   make(map[bpfFlowKey]uint64),
	}
	if collector.flows == nil || collection.Programs["count_ingress"] == nil || collection.Programs["count_egress"] == nil {
		collector.Close()
		return nil, errors.New("embedded BPF object is missing programs or maps")
	}
	collector.ingress, err = link.AttachCgroup(link.CgroupOptions{
		Path: cgroupRoot, Attach: ebpf.AttachCGroupInetIngress, Program: collection.Programs["count_ingress"],
	})
	if err != nil {
		collector.Close()
		return nil, fmt.Errorf("attach cgroup ingress: %w", err)
	}
	collector.egress, err = link.AttachCgroup(link.CgroupOptions{
		Path: cgroupRoot, Attach: ebpf.AttachCGroupInetEgress, Program: collection.Programs["count_egress"],
	})
	if err != nil {
		collector.Close()
		return nil, fmt.Errorf("attach cgroup egress: %w", err)
	}
	return collector, nil
}

func (c *EBPFCollector) ReadDeltas() ([]CgroupFlow, error) {
	// Hash maps are updated by the cgroup programs while they are being
	// iterated. cilium/ebpf reports ErrIterationAborted when a concurrent
	// update prevents a complete walk. Retry first; if traffic is continuous,
	// keep the partial walk and let the caller publish a partial eBPF snapshot
	// instead of throwing away all container attribution.
	const maxAttempts = 3
	var lastErr error
	for attempt := 0; attempt < maxAttempts; attempt++ {
		result, current, err := c.readDeltasOnce()
		if err == nil {
			c.previous = current
			return result, nil
		}
		if !errors.Is(err, ebpf.ErrIterationAborted) {
			return nil, err
		}
		lastErr = err
		runtime.Gosched()
	}

	// A final partial walk is still useful. Updating the baselines for keys
	// that were observed prevents them from being counted twice next cycle;
	// keys not observed remain at their prior baseline and will be caught up
	// by a later complete walk.
	result, current, err := c.readDeltasOnce()
	if err == nil {
		c.previous = current
		return result, nil
	}
	if errors.Is(err, ebpf.ErrIterationAborted) {
		for key, value := range current {
			c.previous[key] = value
		}
		return result, lastErr
	}
	return nil, err
}

func (c *EBPFCollector) readDeltasOnce() ([]CgroupFlow, map[bpfFlowKey]uint64, error) {
	iterator := c.flows.Iterate()
	current := make(map[bpfFlowKey]uint64)
	var key bpfFlowKey
	var value uint64
	var result []CgroupFlow
	for iterator.Next(&key, &value) {
		current[key] = value
		previous := c.previous[key]
		if value == previous {
			continue
		}
		flow, ok := flowFromBPFKey(key)
		if !ok {
			continue
		}
		// LRU eviction can recreate a key with a smaller counter. Treat it as
		// a fresh counter rather than waiting for it to exceed the old value.
		if value < previous {
			previous = 0
		}
		flow.Bytes = value - previous
		result = append(result, flow)
	}
	return result, current, iterator.Err()
}

func (c *EBPFCollector) Close() {
	if c == nil {
		return
	}
	if c.ingress != nil {
		_ = c.ingress.Close()
	}
	if c.egress != nil {
		_ = c.egress.Close()
	}
	if c.collection != nil {
		c.collection.Close()
	}
}

func flowFromBPFKey(key bpfFlowKey) (CgroupFlow, bool) {
	var source, dest netip.Addr
	switch key.Family {
	case 2:
		source = netip.AddrFrom4([4]byte(key.SourceIP[:4])).Unmap()
		dest = netip.AddrFrom4([4]byte(key.DestIP[:4])).Unmap()
	case 10:
		source = netip.AddrFrom16(key.SourceIP).Unmap()
		dest = netip.AddrFrom16(key.DestIP).Unmap()
	default:
		return CgroupFlow{}, false
	}
	protocol := Protocol(key.Protocol)
	sourcePort := netip.AddrPortFrom(source, key.SourcePort)
	destPort := netip.AddrPortFrom(dest, key.DestPort)
	flow := CgroupFlow{CgroupID: key.CgroupID, Direction: Direction(key.Direction)}
	flow.Flow.Protocol = protocol
	if flow.Direction == DirectionEgress {
		flow.Flow.Local, flow.Flow.Remote = sourcePort, destPort
	} else {
		flow.Flow.Local, flow.Flow.Remote = destPort, sourcePort
	}
	return flow, true
}
