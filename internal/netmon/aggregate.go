package netmon

import (
	"bytes"
	"net/netip"
	"time"
)

type Window struct {
	CapturedRX uint64
	CapturedTX uint64
	UnknownRX  uint64
	UnknownTX  uint64
	Unknown    map[UnknownReason]*Traffic
	Packets    uint64
	Processes  map[ProcessID]*Traffic
}

func NewWindow() *Window {
	return &Window{Processes: make(map[ProcessID]*Traffic), Unknown: make(map[UnknownReason]*Traffic)}
}

func (w *Window) Account(p Packet, length int, localMAC []byte, localIPs map[netip.Addr]struct{}, resolver *Resolver) {
	if length < 0 {
		length = 0
	}
	size := uint64(length)
	w.Packets++
	tx := directionTX(p, localMAC, localIPs)
	if tx {
		w.CapturedTX += size
	} else {
		w.CapturedRX += size
	}
	if !p.HasPorts {
		w.addUnknown(tx, size, UnknownUnsupported)
		return
	}
	if resolver == nil {
		w.addUnknown(tx, size, UnknownUnmatched)
		return
	}
	flow := FlowKey{Protocol: p.Protocol}
	if tx {
		flow.Local, flow.Remote = p.Src, p.Dst
	} else {
		flow.Local, flow.Remote = p.Dst, p.Src
	}
	owner, reason := resolver.Resolve(flow)
	if reason != 0 {
		w.addUnknown(tx, size, reason)
		return
	}
	traffic := w.Processes[owner]
	if traffic == nil {
		traffic = &Traffic{}
		w.Processes[owner] = traffic
	}
	if tx {
		traffic.TXBytes += size
	} else {
		traffic.RXBytes += size
	}
}

func (w *Window) Observe(p Packet, length int, localMAC []byte, localIPs map[netip.Addr]struct{}) {
	if length < 0 {
		length = 0
	}
	size := uint64(length)
	w.Packets++
	if directionTX(p, localMAC, localIPs) {
		w.CapturedTX += size
	} else {
		w.CapturedRX += size
	}
}

func directionTX(p Packet, localMAC []byte, localIPs map[netip.Addr]struct{}) bool {
	if len(localMAC) == 6 {
		if bytes.Equal(p.SrcMAC[:], localMAC) {
			return true
		}
		if bytes.Equal(p.DstMAC[:], localMAC) {
			return false
		}
	}
	if p.IsIP {
		_, local := localIPs[p.Src.Addr().Unmap()]
		return local
	}
	return false
}

func (w *Window) addUnknown(tx bool, size uint64, reason UnknownReason) {
	if tx {
		w.UnknownTX += size
	} else {
		w.UnknownRX += size
	}
	traffic := w.Unknown[reason]
	if traffic == nil {
		traffic = &Traffic{}
		w.Unknown[reason] = traffic
	}
	if tx {
		traffic.TXBytes += size
	} else {
		traffic.RXBytes += size
	}
}

type ProcessRate struct {
	ProcessID
	RXKBS uint64
	TXKBS uint64
	Workload
}

type EntityRate struct {
	Workload
	RXKBS uint64
	TXKBS uint64
}

type Snapshot struct {
	Version          int
	UnixMilli        int64
	IntervalMS       int64
	Interface        string
	CapturedRXKBS    uint64
	CapturedTXKBS    uint64
	UnknownRXKBS     uint64
	UnknownTXKBS     uint64
	Packets          uint64
	Drops            uint64
	UnsupportedRXKBS uint64
	UnsupportedTXKBS uint64
	UnmatchedRXKBS   uint64
	UnmatchedTXKBS   uint64
	AmbiguousRXKBS   uint64
	AmbiguousTXKBS   uint64
	ExitedRXKBS      uint64
	ExitedTXKBS      uint64
	Processes        []ProcessRate
	Entities         []EntityRate
	Source           string
	Status           string
	Scope            string
	Reason           string
}

type StartTimeReader interface {
	StartTime(pid int) (uint64, error)
}

type attributedTraffic struct {
	owner   ProcessOwner
	traffic Traffic
}

type entityTraffic struct {
	workload Workload
	traffic  Traffic
}

func SnapshotCgroupFlows(now time.Time, elapsed time.Duration, iface string, drops uint64, capture *Window, resolver *SystemResolver, flows []CgroupFlow, starts StartTimeReader) Snapshot {
	if elapsed <= 0 {
		elapsed = time.Second
	}
	processes := make(map[ProcessID]*attributedTraffic)
	entities := make(map[uint64]*entityTraffic)
	unknown := make(map[UnknownReason]*Traffic)
	var knownRX, knownTX uint64
	for _, sample := range flows {
		resolution := resolver.Resolve(sample)
		if resolution.Process != nil {
			item := processes[resolution.Process.ProcessID]
			if item == nil {
				item = &attributedTraffic{owner: *resolution.Process}
				processes[resolution.Process.ProcessID] = item
			}
			addDirection(&item.traffic, sample.Direction, sample.Bytes)
			continue
		}
		if resolution.Workload != nil {
			item := entities[sample.CgroupID]
			if item == nil {
				item = &entityTraffic{workload: *resolution.Workload}
				entities[sample.CgroupID] = item
			}
			addDirection(&item.traffic, sample.Direction, sample.Bytes)
			continue
		}
		item := unknown[resolution.Reason]
		if item == nil {
			item = &Traffic{}
			unknown[resolution.Reason] = item
		}
		addDirection(item, sample.Direction, sample.Bytes)
	}

	snapshot := Snapshot{
		Version: 3, UnixMilli: now.UnixMilli(), IntervalMS: elapsed.Milliseconds(), Interface: iface,
		Packets: capture.Packets, Drops: drops, Source: "ebpf_cgroup", Status: "ok", Scope: "host_and_containers",
	}
	for id, item := range processes {
		start, err := starts.StartTime(id.PID)
		if err != nil || start != id.StartTicks {
			traffic := unknown[UnknownExited]
			if traffic == nil {
				traffic = &Traffic{}
				unknown[UnknownExited] = traffic
			}
			traffic.RXBytes += item.traffic.RXBytes
			traffic.TXBytes += item.traffic.TXBytes
			continue
		}
		knownRX += item.traffic.RXBytes
		knownTX += item.traffic.TXBytes
		workload := item.owner.Workload
		if workload.Scope == "" {
			workload.Scope = "host"
		}
		snapshot.Processes = append(snapshot.Processes, ProcessRate{ProcessID: id, RXKBS: bytesPerSecondKB(item.traffic.RXBytes, elapsed), TXKBS: bytesPerSecondKB(item.traffic.TXBytes, elapsed), Workload: workload})
	}
	for _, item := range entities {
		knownRX += item.traffic.RXBytes
		knownTX += item.traffic.TXBytes
		rxRate, txRate := bytesPerSecondKB(item.traffic.RXBytes, elapsed), bytesPerSecondKB(item.traffic.TXBytes, elapsed)
		if rxRate+txRate > 0 {
			snapshot.Entities = append(snapshot.Entities, EntityRate{Workload: item.workload, RXKBS: rxRate, TXKBS: txRate})
		}
	}
	var explicitRX, explicitTX uint64
	for reason, traffic := range unknown {
		explicitRX += traffic.RXBytes
		explicitTX += traffic.TXBytes
		snapshot.addUnknownRate(reason, traffic, elapsed)
	}
	bpfRX, bpfTX := knownRX+explicitRX, knownTX+explicitTX
	if capture.CapturedRX > bpfRX {
		residual := &Traffic{RXBytes: capture.CapturedRX - knownRX - explicitRX}
		unknown[UnknownUnmatched] = residual
		snapshot.addUnknownRate(UnknownUnmatched, residual, elapsed)
		explicitRX += residual.RXBytes
	}
	if capture.CapturedTX > bpfTX {
		residual := &Traffic{TXBytes: capture.CapturedTX - knownTX - explicitTX}
		snapshot.addUnknownRate(UnknownUnmatched, residual, elapsed)
		explicitTX += residual.TXBytes
	}
	snapshot.UnknownRXKBS = bytesPerSecondKB(explicitRX, elapsed)
	snapshot.UnknownTXKBS = bytesPerSecondKB(explicitTX, elapsed)
	totalRX, totalTX := capture.CapturedRX, capture.CapturedTX
	if bpfRX > totalRX {
		totalRX = bpfRX
	}
	if bpfTX > totalTX {
		totalTX = bpfTX
	}
	snapshot.CapturedRXKBS = bytesPerSecondKB(totalRX, elapsed)
	snapshot.CapturedTXKBS = bytesPerSecondKB(totalTX, elapsed)
	return snapshot
}

func addDirection(traffic *Traffic, direction Direction, bytes uint64) {
	if direction == DirectionEgress {
		traffic.TXBytes += bytes
	} else {
		traffic.RXBytes += bytes
	}
}

func (w *Window) Snapshot(now time.Time, elapsed time.Duration, iface string, drops uint64, starts StartTimeReader) Snapshot {
	if elapsed <= 0 {
		elapsed = time.Second
	}
	s := Snapshot{
		Version:       2,
		UnixMilli:     now.UnixMilli(),
		IntervalMS:    elapsed.Milliseconds(),
		Interface:     iface,
		CapturedRXKBS: bytesPerSecondKB(w.CapturedRX, elapsed),
		CapturedTXKBS: bytesPerSecondKB(w.CapturedTX, elapsed),
		UnknownRXKBS:  bytesPerSecondKB(w.UnknownRX, elapsed),
		UnknownTXKBS:  bytesPerSecondKB(w.UnknownTX, elapsed),
		Packets:       w.Packets,
		Drops:         drops,
	}
	for reason, traffic := range w.Unknown {
		s.addUnknownRate(reason, traffic, elapsed)
	}
	for process, traffic := range w.Processes {
		start, err := starts.StartTime(process.PID)
		if err != nil || start != process.StartTicks {
			s.UnknownRXKBS += bytesPerSecondKB(traffic.RXBytes, elapsed)
			s.UnknownTXKBS += bytesPerSecondKB(traffic.TXBytes, elapsed)
			s.addUnknownRate(UnknownExited, traffic, elapsed)
			continue
		}
		s.Processes = append(s.Processes, ProcessRate{
			ProcessID: process,
			RXKBS:     bytesPerSecondKB(traffic.RXBytes, elapsed),
			TXKBS:     bytesPerSecondKB(traffic.TXBytes, elapsed),
		})
	}
	return s
}

func (s *Snapshot) addUnknownRate(reason UnknownReason, traffic *Traffic, elapsed time.Duration) {
	rx, tx := bytesPerSecondKB(traffic.RXBytes, elapsed), bytesPerSecondKB(traffic.TXBytes, elapsed)
	switch reason {
	case UnknownUnsupported:
		s.UnsupportedRXKBS += rx
		s.UnsupportedTXKBS += tx
	case UnknownUnmatched:
		s.UnmatchedRXKBS += rx
		s.UnmatchedTXKBS += tx
	case UnknownAmbiguous:
		s.AmbiguousRXKBS += rx
		s.AmbiguousTXKBS += tx
	case UnknownExited:
		s.ExitedRXKBS += rx
		s.ExitedTXKBS += tx
	}
}

func bytesPerSecondKB(value uint64, elapsed time.Duration) uint64 {
	return uint64(float64(value) / elapsed.Seconds() / 1024)
}
