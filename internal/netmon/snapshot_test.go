package netmon

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWriteSnapshotIsVersionedAndPrivate(t *testing.T) {
	path := filepath.Join(t.TempDir(), "net.tsv")
	err := WriteSnapshot(path, Snapshot{
		Version: 2, UnixMilli: 123, IntervalMS: 1000, Interface: "eth0",
		CapturedRXKBS: 10, CapturedTXKBS: 20, UnknownRXKBS: 1, UnknownTXKBS: 2,
		Packets: 99, Drops: 3,
		Processes: []ProcessRate{{ProcessID: ProcessID{PID: 5, StartTicks: 50}, RXKBS: 4, TXKBS: 6}},
	})
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %o, want 600", info.Mode().Perm())
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	text := string(b)
	if !strings.Contains(text, "M\t2\t123\t1000\teth0\t10\t20\t1\t2\t99\t3\t0\t0\t0\t0\t0\t0\t0\t0\n") || !strings.Contains(text, "P\t5\t50\t4\t6\n") {
		t.Fatalf("unexpected snapshot:\n%s", text)
	}
}

func TestWriteSnapshotV3IncludesWorkloads(t *testing.T) {
	path := filepath.Join(t.TempDir(), "net.tsv")
	err := WriteSnapshot(path, Snapshot{
		Version: 3, UnixMilli: 123, IntervalMS: 1000, Interface: "eth0", Source: "ebpf_cgroup", Status: "ok", Scope: "host_and_containers",
		Processes: []ProcessRate{{ProcessID: ProcessID{PID: 5, StartTicks: 50}, RXKBS: 4, TXKBS: 6, Workload: Workload{Scope: "pod", Namespace: "ns", Pod: "pod", Container: "app", ContainerID: "abc", Attribution: "socket"}}},
		Entities:  []EntityRate{{Workload: Workload{CgroupID: 99, Namespace: "ns", Pod: "pod", Container: "app", ContainerID: "abc", Attribution: "cgroup"}, RXKBS: 7, TXKBS: 8}},
	})
	if err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	text := string(content)
	if !strings.Contains(text, "\tebpf_cgroup\tok\thost_and_containers\t-\n") ||
		!strings.Contains(text, "P\t5\t50\t4\t6\tpod\tns\tpod\tapp\tabc\tsocket\n") ||
		!strings.Contains(text, "C\t99\tns\tpod\tapp\tabc\t7\t8\tcgroup\n") {
		t.Fatalf("unexpected v3 snapshot:\n%s", text)
	}
}

func TestWriteSnapshotV4IncludesRuntimeAndMetadataWorkloads(t *testing.T) {
	path := filepath.Join(t.TempDir(), "net.tsv")
	err := WriteSnapshot(path, Snapshot{
		Version: 4, UnixMilli: 123, IntervalMS: 1000, Interface: "eth0", Source: "ebpf_cgroup", Status: "ok", Scope: "host_and_containers",
		Processes: []ProcessRate{{ProcessID: ProcessID{PID: 5, StartTicks: 50}, RXKBS: 4, TXKBS: 6, Workload: Workload{Scope: "pod", Runtime: "cri-o", Namespace: "ns", Pod: "pod", Container: "app", ContainerID: "abc", Attribution: "socket"}}},
		Entities:  []EntityRate{{Workload: Workload{CgroupID: 99, Scope: "container", Runtime: "docker", Container: "api", ContainerID: "def", Attribution: "cgroup"}, RXKBS: 7, TXKBS: 8}},
		Workloads: []Workload{{CgroupID: 99, Scope: "container", Runtime: "docker", Container: "api", ContainerID: "def", CgroupPath: "/system.slice/docker-def.scope", Attribution: "cgroup"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	text := string(content)
	for _, want := range []string{
		"P\t5\t50\t4\t6\tpod\tcri-o\tns\tpod\tapp\tabc\tsocket\n",
		"C\t99\tcontainer\tdocker\t-\t-\tapi\tdef\t7\t8\tcgroup\n",
		"W\t99\tcontainer\tdocker\t-\t-\tapi\tdef\t/system.slice/docker-def.scope\tcgroup\n",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("v4 snapshot missing %q:\n%s", want, text)
		}
	}
}
