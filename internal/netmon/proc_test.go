package netmon

import (
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseSocketTablesIPv4AndIPv6(t *testing.T) {
	header := "sl local_address rem_address st tx_queue tr tm->when retrnsmt uid timeout inode\n"
	v4 := header + "0: 0100007F:1F90 0200000A:C350 01 0 0 0 1000 0 4242\n"
	entries, err := ParseSocketTable(strings.NewReader(v4), ProtocolTCP, false)
	if err != nil || len(entries) != 1 {
		t.Fatalf("parse IPv4: entries=%v err=%v", entries, err)
	}
	if entries[0].Flow.Local != netip.MustParseAddrPort("127.0.0.1:8080") || entries[0].Flow.Remote != netip.MustParseAddrPort("10.0.0.2:50000") {
		t.Fatalf("unexpected IPv4 flow: %+v", entries[0].Flow)
	}

	v6 := header + "0: 00000000000000000000000001000000:0035 00000000000000000000000002000000:C350 01 0 0 0 1000 0 99\n"
	entries, err = ParseSocketTable(strings.NewReader(v6), ProtocolUDP, true)
	if err != nil || len(entries) != 1 {
		t.Fatalf("parse IPv6: entries=%v err=%v", entries, err)
	}
	if entries[0].Flow.Local != netip.MustParseAddrPort("[::1]:53") || entries[0].Flow.Remote != netip.MustParseAddrPort("[::2]:50000") {
		t.Fatalf("unexpected IPv6 flow: %+v", entries[0].Flow)
	}
}

func TestProcResolverMapsInodeToPIDAndStartTime(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "net"), 0o755); err != nil {
		t.Fatal(err)
	}
	header := "sl local_address rem_address st tx_queue tr tm->when retrnsmt uid timeout inode\n"
	tcp := header + "0: 0100007F:1F90 0200000A:C350 01 0 0 0 1000 0 4242\n"
	for _, table := range []string{"tcp", "tcp6", "udp", "udp6"} {
		content := header
		if table == "tcp" {
			content = tcp
		}
		if err := os.WriteFile(filepath.Join(root, "net", table), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	makeFakeProcess(t, root, 123, 98765, 4242)

	resolver, err := (ProcFS{Root: root}).LoadResolver()
	if err != nil {
		t.Fatal(err)
	}
	owner, reason := resolver.Resolve(FlowKey{
		Protocol: ProtocolTCP,
		Local:    netip.MustParseAddrPort("127.0.0.1:8080"),
		Remote:   netip.MustParseAddrPort("10.0.0.2:50000"),
	})
	if reason != 0 || owner != (ProcessID{PID: 123, StartTicks: 98765}) {
		t.Fatalf("unexpected owner: %+v reason=%v", owner, reason)
	}
}

func TestSharedSocketAndReusePortAreUnknown(t *testing.T) {
	flow := FlowKey{Protocol: ProtocolUDP, Local: netip.MustParseAddrPort("0.0.0.0:9000"), Remote: netip.MustParseAddrPort("0.0.0.0:0")}
	owners := map[uint64][]ProcessID{
		1: {{PID: 10, StartTicks: 1}, {PID: 11, StartTicks: 2}},
		2: {{PID: 12, StartTicks: 3}},
	}
	resolver := NewResolver([]SocketEntry{{Flow: flow, Inode: 1}}, owners)
	packetFlow := FlowKey{Protocol: ProtocolUDP, Local: netip.MustParseAddrPort("192.0.2.1:9000"), Remote: netip.MustParseAddrPort("198.51.100.2:1234")}
	if owner, reason := resolver.Resolve(packetFlow); reason != UnknownAmbiguous {
		t.Fatalf("shared socket reason=%v owner=%+v", reason, owner)
	}

	resolver = NewResolver([]SocketEntry{{Flow: flow, Inode: 1}, {Flow: flow, Inode: 2}}, owners)
	if owner, reason := resolver.Resolve(packetFlow); reason != UnknownAmbiguous {
		t.Fatalf("reuseport tuple reason=%v owner=%+v", reason, owner)
	}

	exact := SocketEntry{Flow: packetFlow, Inode: 1}
	exact2 := SocketEntry{Flow: packetFlow, Inode: 2}
	wildcardOwner := ProcessID{PID: 99, StartTicks: 9}
	owners[3] = []ProcessID{wildcardOwner}
	resolver = NewResolver([]SocketEntry{exact, exact2, {Flow: flow, Inode: 3}}, owners)
	if owner, reason := resolver.Resolve(packetFlow); reason != UnknownAmbiguous {
		t.Fatalf("ambiguous exact tuple reason=%v owner=%+v", reason, owner)
	}
}

func TestResolverReportsUnmatched(t *testing.T) {
	r := NewResolver(nil, nil)
	_, reason := r.Resolve(FlowKey{Protocol: ProtocolTCP, Local: netip.MustParseAddrPort("192.0.2.1:1"), Remote: netip.MustParseAddrPort("198.51.100.1:2")})
	if reason != UnknownUnmatched {
		t.Fatalf("reason=%v", reason)
	}
}

func makeFakeProcess(t *testing.T, root string, pid int, start, inode uint64) {
	t.Helper()
	pdir := filepath.Join(root, fmt.Sprint(pid))
	if err := os.MkdirAll(filepath.Join(pdir, "fd"), 0o755); err != nil {
		t.Fatal(err)
	}
	fields := []string{"S"}
	for i := 0; i < 18; i++ {
		fields = append(fields, "0")
	}
	fields = append(fields, fmt.Sprint(start))
	stat := fmt.Sprintf("%d (process name) %s\n", pid, strings.Join(fields, " "))
	if err := os.WriteFile(filepath.Join(pdir, "stat"), []byte(stat), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(fmt.Sprintf("socket:[%d]", inode), filepath.Join(pdir, "fd", "3")); err != nil {
		t.Fatal(err)
	}
}
