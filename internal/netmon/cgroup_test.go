package netmon

import (
	"net/netip"
	"testing"
)

func TestParseContainerMetadata(t *testing.T) {
	path := "/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-poda2bd0797_83f1_42a2_8457_1396a9240283.slice/cri-containerd-b958e6f3d242deadbeef.scope"
	containerID, podUID, ok := ParseContainerCgroup(path)
	if !ok || containerID != "b958e6f3d242deadbeef" || podUID != "a2bd0797-83f1-42a2-8457-1396a9240283" {
		t.Fatalf("unexpected cgroup metadata: id=%q pod=%q ok=%v", containerID, podUID, ok)
	}
	workload, ok := ParseContainerLogName("scene-hub-service-54dbcb7cb8-6wkpr_moying-business_scene-hub-service-b958e6f3d242deadbeef.log")
	if !ok || workload.Namespace != "moying-business" || workload.Pod != "scene-hub-service-54dbcb7cb8-6wkpr" || workload.Container != "scene-hub-service" {
		t.Fatalf("unexpected log metadata: %+v ok=%v", workload, ok)
	}
}

func TestSystemResolverUsesPIDOrContainerAggregate(t *testing.T) {
	flow := FlowKey{Protocol: ProtocolTCP, Local: netip.MustParseAddrPort("10.42.0.8:8080"), Remote: netip.MustParseAddrPort("10.42.0.1:50000")}
	process := ProcessID{PID: 123, StartTicks: 456}
	workload := Workload{Scope: "pod", CgroupID: 88, Namespace: "ns", Pod: "pod", Container: "app", ContainerID: "abcdef123456"}
	owner := ProcessOwner{ProcessID: process, CgroupID: 88, NetNS: 77, Workload: workload}
	resolver := &SystemResolver{
		byCgroup: map[uint64][]namespacedResolver{88: {{resolver: NewResolver([]SocketEntry{{Flow: flow, Inode: 9}}, map[uint64][]ProcessID{9: {process}}), pids: map[ProcessID]ProcessOwner{process: owner}}}},
		workload: map[uint64]Workload{88: workload},
	}
	resolution := resolver.Resolve(CgroupFlow{CgroupID: 88, Flow: flow})
	if resolution.Process == nil || resolution.Process.PID != 123 || resolution.Workload != nil {
		t.Fatalf("wanted unique PID, got %+v", resolution)
	}

	shared := NewResolver([]SocketEntry{{Flow: flow, Inode: 9}}, map[uint64][]ProcessID{9: {process, {PID: 124, StartTicks: 457}}})
	resolver.byCgroup[88][0].resolver = shared
	resolution = resolver.Resolve(CgroupFlow{CgroupID: 88, Flow: flow})
	if resolution.Process != nil || resolution.Workload == nil || resolution.Workload.Pod != "pod" || resolution.Reason != UnknownAmbiguous {
		t.Fatalf("shared socket must use container aggregate: %+v", resolution)
	}

	resolution = resolver.Resolve(CgroupFlow{CgroupID: 88, Flow: FlowKey{Protocol: ProtocolUDP, Local: netip.MustParseAddrPort("10.42.0.8:9999"), Remote: netip.MustParseAddrPort("10.42.0.1:53")}})
	if resolution.Workload == nil || resolution.Reason != UnknownUnmatched {
		t.Fatalf("short flow must use container aggregate: %+v", resolution)
	}
}

func TestSystemResolverNeverGuessesHostPIDAcrossNamespaces(t *testing.T) {
	flow := FlowKey{Protocol: ProtocolTCP, Local: netip.MustParseAddrPort("127.0.0.1:8080"), Remote: netip.MustParseAddrPort("127.0.0.1:40000")}
	first := ProcessID{PID: 1, StartTicks: 1}
	second := ProcessID{PID: 2, StartTicks: 2}
	resolver := &SystemResolver{byCgroup: map[uint64][]namespacedResolver{1: {
		{resolver: NewResolver([]SocketEntry{{Flow: flow, Inode: 1}}, map[uint64][]ProcessID{1: {first}}), pids: map[ProcessID]ProcessOwner{first: {ProcessID: first, CgroupID: 1}}},
		{resolver: NewResolver([]SocketEntry{{Flow: flow, Inode: 2}}, map[uint64][]ProcessID{2: {second}}), pids: map[ProcessID]ProcessOwner{second: {ProcessID: second, CgroupID: 1}}},
	}}}
	resolution := resolver.Resolve(CgroupFlow{CgroupID: 1, Flow: flow})
	if resolution.Process != nil || resolution.Workload != nil || resolution.Reason != UnknownAmbiguous {
		t.Fatalf("cross-netns ambiguity must remain unknown: %+v", resolution)
	}
}
