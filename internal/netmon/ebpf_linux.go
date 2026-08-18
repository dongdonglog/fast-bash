//go:build linux

package netmon

import (
	"bytes"
	_ "embed"
	"errors"
	"fmt"
	"net/netip"

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
	iterator := c.flows.Iterate()
	current := make(map[bpfFlowKey]uint64)
	var key bpfFlowKey
	var value uint64
	var result []CgroupFlow
	for iterator.Next(&key, &value) {
		current[key] = value
		previous := c.previous[key]
		if value <= previous {
			continue
		}
		flow, ok := flowFromBPFKey(key)
		if !ok {
			continue
		}
		flow.Bytes = value - previous
		result = append(result, flow)
	}
	if err := iterator.Err(); err != nil {
		return nil, err
	}
	c.previous = current
	return result, nil
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
