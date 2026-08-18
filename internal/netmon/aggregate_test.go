package netmon

import (
	"net/netip"
	"testing"
	"time"
)

type fakeStarts map[int]uint64

func (f fakeStarts) StartTime(pid int) (uint64, error) { return f[pid], nil }

func TestWindowAccountsBothDirections(t *testing.T) {
	local := netip.MustParseAddr("192.0.2.10")
	remote := netip.MustParseAddr("198.51.100.20")
	process := ProcessID{PID: 7, StartTicks: 77}
	owners := map[uint64][]ProcessID{100: {process}}
	entries := []SocketEntry{{
		Flow: FlowKey{
			Protocol: ProtocolTCP,
			Local:    netip.AddrPortFrom(local, 12345),
			Remote:   netip.AddrPortFrom(remote, 443),
		},
		Inode: 100,
	}}
	resolver := NewResolver(entries, owners)
	w := NewWindow()
	mac := []byte{1, 2, 3, 4, 5, 6}
	w.Account(Packet{Protocol: ProtocolTCP, Src: netip.AddrPortFrom(local, 12345), Dst: netip.AddrPortFrom(remote, 443), SrcMAC: [6]byte{1, 2, 3, 4, 5, 6}, IsIP: true, HasPorts: true}, 1024, mac, nil, resolver)
	w.Account(Packet{Protocol: ProtocolTCP, Src: netip.AddrPortFrom(remote, 443), Dst: netip.AddrPortFrom(local, 12345), DstMAC: [6]byte{1, 2, 3, 4, 5, 6}, IsIP: true, HasPorts: true}, 2048, mac, nil, resolver)
	s := w.Snapshot(time.Unix(1, 0), time.Second, "eth0", 0, fakeStarts{7: 77})
	if len(s.Processes) != 1 || s.Processes[0].TXKBS != 1 || s.Processes[0].RXKBS != 2 {
		t.Fatalf("unexpected process rates: %+v", s.Processes)
	}
	if s.CapturedTXKBS != 1 || s.CapturedRXKBS != 2 || s.UnknownTXKBS != 0 || s.UnknownRXKBS != 0 {
		t.Fatalf("unexpected totals: %+v", s)
	}
}

func TestPIDReuseMovesTrafficToUnknown(t *testing.T) {
	w := NewWindow()
	w.CapturedRX = 4096
	w.Processes[ProcessID{PID: 8, StartTicks: 100}] = &Traffic{RXBytes: 4096}
	s := w.Snapshot(time.Unix(1, 0), time.Second, "eth0", 0, fakeStarts{8: 101})
	if len(s.Processes) != 0 || s.UnknownRXKBS != 4 || s.ExitedRXKBS != 4 {
		t.Fatalf("reused PID should be unknown: %+v", s)
	}
}

func TestUnknownReasonsAreAccounted(t *testing.T) {
	w := NewWindow()
	mac := []byte{1, 2, 3, 4, 5, 6}
	w.Account(Packet{SrcMAC: [6]byte{1, 2, 3, 4, 5, 6}}, 1024, mac, nil, nil)
	flow := FlowKey{Protocol: ProtocolTCP, Local: netip.MustParseAddrPort("192.0.2.1:1"), Remote: netip.MustParseAddrPort("198.51.100.1:2")}
	w.Account(Packet{Protocol: ProtocolTCP, Src: flow.Local, Dst: flow.Remote, SrcMAC: [6]byte{1, 2, 3, 4, 5, 6}, IsIP: true, HasPorts: true}, 2048, mac, nil, NewResolver(nil, nil))
	shared := NewResolver([]SocketEntry{{Flow: flow, Inode: 1}}, map[uint64][]ProcessID{1: {{PID: 1}, {PID: 2}}})
	w.Account(Packet{Protocol: ProtocolTCP, Src: flow.Local, Dst: flow.Remote, SrcMAC: [6]byte{1, 2, 3, 4, 5, 6}, IsIP: true, HasPorts: true}, 3072, mac, nil, shared)
	s := w.Snapshot(time.Unix(1, 0), time.Second, "eth0", 0, fakeStarts{})
	if s.UnsupportedTXKBS != 1 || s.UnmatchedTXKBS != 2 || s.AmbiguousTXKBS != 3 || s.UnknownTXKBS != 6 {
		t.Fatalf("unexpected reason rates: %+v", s)
	}
}
