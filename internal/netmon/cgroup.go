package netmon

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
)

var (
	containerScopePattern = regexp.MustCompile(`(?:^|/)(cri-containerd|crio|docker|libpod)-([0-9a-f]{12,64})\.scope(?:/|$)`)
	podSlicePattern       = regexp.MustCompile(`(?:^|/)kubepods[^/]*/kubepods[^/]*-pod([0-9a-fA-F_]+)\.slice(?:/|$)`)
	podCgroupPattern      = regexp.MustCompile(`(?:^|/)pod([0-9a-fA-F_-]{16,})(?:/|$)`)
	containerLogPattern   = regexp.MustCompile(`^(.+)_([^_]+)_(.+)-([0-9a-f]{12,64})\.log$`)
	containerIDPattern    = regexp.MustCompile(`^[0-9a-f]{12,64}$`)
)

type ContainerCgroup struct {
	Runtime     string
	ContainerID string
	PodUID      string
	RootPath    string
}

type ProcessOwner struct {
	ProcessID
	CgroupID uint64
	NetNS    uint64
	Workload Workload
}

type namespacedResolver struct {
	resolver *Resolver
	pids     map[ProcessID]ProcessOwner
}

type SystemResolver struct {
	byCgroup map[uint64][]namespacedResolver
	workload map[uint64]Workload
}

type Resolution struct {
	Process  *ProcessOwner
	Workload *Workload
	Reason   UnknownReason
}

type ResolverConfig struct {
	CgroupRoot    string
	ContainerLogs string
	PodLogs       string
	Metadata      *RuntimeMetadataCache
}

func DefaultResolverConfig() ResolverConfig {
	return ResolverConfig{
		CgroupRoot:    "/sys/fs/cgroup",
		ContainerLogs: "/var/log/containers",
		PodLogs:       "/var/log/pods",
	}
}

func ParseContainerCgroupInfo(path string) (ContainerCgroup, bool) {
	path = filepath.Clean(path)
	var result ContainerCgroup
	containerMatch := containerScopePattern.FindStringSubmatch(path)
	if len(containerMatch) == 3 {
		result.Runtime = map[string]string{"cri-containerd": "containerd", "crio": "cri-o", "docker": "docker", "libpod": "podman"}[containerMatch[1]]
		result.ContainerID = containerMatch[2]
	} else {
		parts := strings.Split(strings.Trim(path, "/"), "/")
		for index := 0; index+1 < len(parts); index++ {
			if (parts[index] == "docker" || parts[index] == "libpod") && containerIDPattern.MatchString(parts[index+1]) {
				result.Runtime = map[string]string{"docker": "docker", "libpod": "podman"}[parts[index]]
				result.ContainerID = parts[index+1]
				break
			}
		}
		if result.ContainerID == "" && strings.Contains(path, "kubepods") {
			for _, part := range parts {
				if containerIDPattern.MatchString(part) {
					result.Runtime, result.ContainerID = "cri", part
				}
			}
		}
		if result.ContainerID == "" {
			return ContainerCgroup{}, false
		}
	}
	result.RootPath = containerRootPath(path, result.ContainerID)
	podMatch := podSlicePattern.FindStringSubmatch(path)
	if len(podMatch) == 2 {
		result.PodUID = normalizePodUID(podMatch[1])
	} else if podMatch = podCgroupPattern.FindStringSubmatch(path); len(podMatch) == 2 {
		result.PodUID = normalizePodUID(podMatch[1])
	}
	return result, true
}

func ParseContainerCgroup(path string) (containerID, podUID string, ok bool) {
	info, ok := ParseContainerCgroupInfo(path)
	return info.ContainerID, info.PodUID, ok
}

func normalizePodUID(value string) string {
	return strings.ToLower(strings.ReplaceAll(value, "_", "-"))
}

func ParseContainerLogName(name string) (Workload, bool) {
	match := containerLogPattern.FindStringSubmatch(name)
	if len(match) != 5 {
		return Workload{}, false
	}
	return Workload{
		Scope:       "pod",
		Pod:         match[1],
		Namespace:   match[2],
		Container:   match[3],
		ContainerID: match[4],
		Attribution: "cgroup",
	}, true
}

func (p ProcFS) LoadSystemResolver(cfg ResolverConfig) (*SystemResolver, error) {
	if cfg.CgroupRoot == "" {
		cfg = DefaultResolverConfig()
	}
	logs := loadContainerLogs(cfg.ContainerLogs)
	pods := loadPodLogs(cfg.PodLogs)
	var catalog WorkloadCatalog
	if cfg.Metadata != nil {
		catalog = cfg.Metadata.Catalog()
	}
	dirs, err := os.ReadDir(p.Root)
	if err != nil {
		return nil, err
	}

	type netnsData struct {
		representative int
		owners         map[uint64][]ProcessID
		processes      map[ProcessID]ProcessOwner
		cgroups        map[uint64]struct{}
	}
	namespaces := make(map[uint64]*netnsData)
	workloads := make(map[uint64]Workload)
	var readErrs []error

	for _, dir := range dirs {
		pid, err := strconv.Atoi(dir.Name())
		if err != nil || !dir.IsDir() {
			continue
		}
		start, err := p.StartTime(pid)
		if err != nil {
			continue
		}
		netns, err := inodeOf(filepath.Join(p.Root, dir.Name(), "ns", "net"))
		if err != nil {
			continue
		}
		cgroupPath, err := readUnifiedCgroup(filepath.Join(p.Root, dir.Name(), "cgroup"))
		if err != nil {
			continue
		}
		cgroupID, err := inodeOf(filepath.Join(cfg.CgroupRoot, strings.TrimPrefix(cgroupPath, "/")))
		if err != nil {
			continue
		}
		workload := workloadForPath(cgroupID, cgroupPath, logs, pods, catalog)
		workloads[cgroupID] = workload
		process := ProcessID{PID: pid, StartTicks: start}
		owner := ProcessOwner{ProcessID: process, CgroupID: cgroupID, NetNS: netns, Workload: workload}
		data := namespaces[netns]
		if data == nil {
			data = &netnsData{representative: pid, owners: make(map[uint64][]ProcessID), processes: make(map[ProcessID]ProcessOwner), cgroups: make(map[uint64]struct{})}
			namespaces[netns] = data
		}
		if pid < data.representative {
			data.representative = pid
		}
		data.processes[process] = owner
		data.cgroups[cgroupID] = struct{}{}
		for _, inode := range p.socketInodes(pid) {
			data.owners[inode] = appendUniqueProcess(data.owners[inode], process)
		}
	}

	result := &SystemResolver{byCgroup: make(map[uint64][]namespacedResolver), workload: workloads}
	for _, data := range namespaces {
		entries, err := p.loadPIDSocketTables(data.representative)
		if err != nil {
			readErrs = append(readErrs, err)
		}
		resolver := NewResolver(entries, data.owners)
		nsr := namespacedResolver{resolver: resolver, pids: data.processes}
		for cgroupID := range data.cgroups {
			result.byCgroup[cgroupID] = append(result.byCgroup[cgroupID], nsr)
		}
	}
	if len(result.byCgroup) == 0 && len(readErrs) > 0 {
		return result, errors.Join(readErrs...)
	}
	return result, nil
}

func (r *SystemResolver) Resolve(sample CgroupFlow) Resolution {
	if sample.Flow.Protocol != ProtocolTCP && sample.Flow.Protocol != ProtocolUDP {
		return Resolution{Reason: UnknownUnsupported}
	}
	var candidates []ProcessOwner
	reason := UnknownUnmatched
	for _, nsr := range r.byCgroup[sample.CgroupID] {
		process, current := nsr.resolver.Resolve(sample.Flow)
		if current == 0 {
			if owner, ok := nsr.pids[process]; ok && owner.CgroupID == sample.CgroupID {
				candidates = appendUniqueOwner(candidates, owner)
			}
			continue
		}
		if current == UnknownAmbiguous {
			reason = UnknownAmbiguous
		}
	}
	if len(candidates) == 1 {
		owner := candidates[0]
		owner.Workload.Attribution = "socket"
		return Resolution{Process: &owner}
	}
	if len(candidates) > 1 {
		reason = UnknownAmbiguous
	}
	if workload, ok := r.workload[sample.CgroupID]; ok && workload.IsContainer() {
		workload.Attribution = "cgroup"
		return Resolution{Workload: &workload, Reason: reason}
	}
	return Resolution{Reason: reason}
}

func (r *SystemResolver) Workloads() []Workload {
	if r == nil {
		return nil
	}
	containers := make(map[uint64]Workload)
	for id, workload := range r.workload {
		if workload.IsContainer() {
			containers[id] = workload
		}
	}
	return sortedWorkloads(containers)
}

func (p ProcFS) loadPIDSocketTables(pid int) ([]SocketEntry, error) {
	var entries []SocketEntry
	var errs []error
	for _, table := range []struct {
		name     string
		protocol Protocol
		ipv6     bool
	}{{"tcp", ProtocolTCP, false}, {"tcp6", ProtocolTCP, true}, {"udp", ProtocolUDP, false}, {"udp6", ProtocolUDP, true}} {
		path := filepath.Join(p.Root, strconv.Itoa(pid), "net", table.name)
		file, err := os.Open(path)
		if err != nil {
			if !errors.Is(err, os.ErrNotExist) {
				errs = append(errs, fmt.Errorf("%s: %w", path, err))
			}
			continue
		}
		parsed, parseErr := ParseSocketTable(file, table.protocol, table.ipv6)
		_ = file.Close()
		if parseErr != nil {
			errs = append(errs, parseErr)
			continue
		}
		entries = append(entries, parsed...)
	}
	return entries, errors.Join(errs...)
}

func (p ProcFS) socketInodes(pid int) []uint64 {
	fds, err := os.ReadDir(filepath.Join(p.Root, strconv.Itoa(pid), "fd"))
	if err != nil {
		return nil
	}
	seen := make(map[uint64]struct{})
	var result []uint64
	for _, fd := range fds {
		target, err := os.Readlink(filepath.Join(p.Root, strconv.Itoa(pid), "fd", fd.Name()))
		if err != nil || !strings.HasPrefix(target, "socket:[") || !strings.HasSuffix(target, "]") {
			continue
		}
		inode, err := strconv.ParseUint(strings.TrimSuffix(strings.TrimPrefix(target, "socket:["), "]"), 10, 64)
		if err != nil {
			continue
		}
		if _, ok := seen[inode]; ok {
			continue
		}
		seen[inode] = struct{}{}
		result = append(result, inode)
	}
	return result
}

func readUnifiedCgroup(path string) (string, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	for _, line := range strings.Split(string(content), "\n") {
		if strings.HasPrefix(line, "0::") {
			value := strings.TrimPrefix(line, "0::")
			if value == "" {
				value = "/"
			}
			return filepath.Clean(value), nil
		}
	}
	return "", errors.New("unified cgroup entry not found")
}

func inodeOf(path string) (uint64, error) {
	info, err := os.Stat(path)
	if err != nil {
		return 0, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, errors.New("stat inode unavailable")
	}
	return stat.Ino, nil
}

func loadContainerLogs(root string) []Workload {
	entries, _ := os.ReadDir(root)
	var result []Workload
	for _, entry := range entries {
		if workload, ok := ParseContainerLogName(entry.Name()); ok {
			result = append(result, workload)
		}
	}
	return result
}

func loadPodLogs(root string) map[string]Workload {
	result := make(map[string]Workload)
	entries, _ := os.ReadDir(root)
	for _, entry := range entries {
		parts := strings.Split(entry.Name(), "_")
		if len(parts) < 3 {
			continue
		}
		uid := strings.ToLower(parts[len(parts)-1])
		result[uid] = Workload{Scope: "pod", Namespace: parts[0], Pod: strings.Join(parts[1:len(parts)-1], "_")}
	}
	return result
}

func workloadForPath(id uint64, path string, logs []Workload, pods map[string]Workload, catalog WorkloadCatalog) Workload {
	result := Workload{Scope: "host", CgroupID: id, CgroupPath: path, Attribution: "socket"}
	info, ok := ParseContainerCgroupInfo(path)
	if !ok {
		candidate := containerIDFromCatalogPath(path, catalog)
		metadata, exists := catalog.Lookup(candidate)
		if !exists {
			return result
		}
		info = ContainerCgroup{Runtime: metadata.Runtime, ContainerID: candidate, RootPath: containerRootPath(path, candidate)}
	}
	result.Scope = "container"
	result.Runtime = info.Runtime
	result.ContainerID = info.ContainerID
	if info.RootPath != "" {
		result.CgroupPath = info.RootPath
	}
	result.Attribution = "cgroup"
	if info.PodUID != "" {
		result.Scope = "pod"
	}
	if metadata, exists := catalog.Lookup(info.ContainerID); exists {
		mergeWorkload(&result, metadata)
	}
	if pod, exists := pods[info.PodUID]; exists {
		result.Namespace, result.Pod = pod.Namespace, pod.Pod
		result.Scope = "pod"
	}
	for _, log := range logs {
		if strings.HasPrefix(info.ContainerID, log.ContainerID) || strings.HasPrefix(log.ContainerID, info.ContainerID) {
			result.Namespace, result.Pod, result.Container = log.Namespace, log.Pod, log.Container
			result.Scope = "pod"
			break
		}
	}
	return result
}

func containerIDFromCatalogPath(path string, catalog WorkloadCatalog) string {
	for _, part := range strings.Split(strings.Trim(filepath.Clean(path), "/"), "/") {
		candidate := strings.TrimSuffix(part, ".scope")
		for _, prefix := range []string{"cri-containerd-", "containerd-", "crio-", "docker-", "libpod-"} {
			candidate = strings.TrimPrefix(candidate, prefix)
		}
		if containerIDPattern.MatchString(candidate) {
			if _, ok := catalog.Lookup(candidate); ok {
				return candidate
			}
		}
	}
	return ""
}

func containerRootPath(path, containerID string) string {
	parts := strings.Split(strings.Trim(filepath.Clean(path), "/"), "/")
	for index, part := range parts {
		if part == containerID || strings.Contains(part, containerID) {
			return "/" + strings.Join(parts[:index+1], "/")
		}
	}
	return filepath.Clean(path)
}

func mergeWorkload(target *Workload, source Workload) {
	if source.Scope == "pod" || (source.Scope != "" && target.Scope != "pod") {
		target.Scope = source.Scope
	}
	if source.Runtime != "" && source.Runtime != "cri" {
		target.Runtime = source.Runtime
	}
	if source.Namespace != "" {
		target.Namespace = source.Namespace
	}
	if source.Pod != "" {
		target.Pod = source.Pod
	}
	if source.Container != "" {
		target.Container = source.Container
	}
	if source.ContainerID != "" {
		target.ContainerID = source.ContainerID
	}
}

func appendUniqueProcess(items []ProcessID, process ProcessID) []ProcessID {
	for _, item := range items {
		if item == process {
			return items
		}
	}
	return append(items, process)
}

func appendUniqueOwner(items []ProcessOwner, owner ProcessOwner) []ProcessOwner {
	for _, item := range items {
		if item.ProcessID == owner.ProcessID {
			return items
		}
	}
	return append(items, owner)
}

func sortedWorkloads(values map[uint64]Workload) []Workload {
	result := make([]Workload, 0, len(values))
	for _, value := range values {
		result = append(result, value)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].CgroupID < result[j].CgroupID })
	return result
}
