package netmon

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	runtimeapi "k8s.io/cri-api/pkg/apis/runtime/v1"
)

const (
	labelPodName       = "io.kubernetes.pod.name"
	labelPodNamespace  = "io.kubernetes.pod.namespace"
	labelPodUID        = "io.kubernetes.pod.uid"
	labelContainerName = "io.kubernetes.container.name"
)

type CRIEndpoint struct {
	Path    string
	Runtime string
}

type RuntimeMetadataConfig struct {
	CRIEndpoints   []CRIEndpoint
	DockerRoot     string
	ContainersRoot string
	TTL            time.Duration
	Timeout        time.Duration
}

type RuntimeMetadataCache struct {
	mu      sync.Mutex
	config  RuntimeMetadataConfig
	expires time.Time
	catalog WorkloadCatalog
}

type WorkloadCatalog struct {
	items map[string]Workload
}

func DefaultRuntimeMetadataConfig() RuntimeMetadataConfig {
	paths := []string{
		"/run/containerd/containerd.sock",
		"/var/run/containerd/containerd.sock",
		"/run/k3s/containerd/containerd.sock",
		"/run/rke2/containerd/containerd.sock",
		"/run/k0s/containerd.sock",
		"/var/snap/microk8s/common/run/containerd.sock",
		"/run/crio/crio.sock",
		"/var/run/crio/crio.sock",
		"/run/cri-dockerd.sock",
		"/var/run/cri-dockerd.sock",
	}
	if configured := strings.TrimSpace(os.Getenv("SMON_CRI_ENDPOINTS")); configured != "" {
		paths = strings.Split(configured, ",")
	}
	endpoints := make([]CRIEndpoint, 0, len(paths))
	seen := make(map[string]struct{})
	for _, raw := range paths {
		path := strings.TrimSpace(strings.TrimPrefix(raw, "unix://"))
		if path == "" {
			continue
		}
		key := path
		if resolved, err := filepath.EvalSymlinks(path); err == nil {
			key = resolved
		}
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		endpoints = append(endpoints, CRIEndpoint{Path: path, Runtime: runtimeForEndpoint(path)})
	}
	return RuntimeMetadataConfig{
		CRIEndpoints: endpoints, DockerRoot: "/var/lib/docker/containers",
		ContainersRoot: "/var/lib/containers/storage/overlay-containers",
		TTL:            30 * time.Second, Timeout: 800 * time.Millisecond,
	}
}

func NewRuntimeMetadataCache(config RuntimeMetadataConfig) *RuntimeMetadataCache {
	if config.TTL <= 0 {
		config.TTL = 30 * time.Second
	}
	if config.Timeout <= 0 {
		config.Timeout = 800 * time.Millisecond
	}
	return &RuntimeMetadataCache{config: config}
}

func (c *RuntimeMetadataCache) Catalog() WorkloadCatalog {
	if c == nil {
		return WorkloadCatalog{}
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if time.Now().Before(c.expires) && c.catalog.items != nil {
		return c.catalog
	}
	items := make(map[string]Workload)
	results := make(chan []Workload, len(c.config.CRIEndpoints))
	var wait sync.WaitGroup
	for _, endpoint := range c.config.CRIEndpoints {
		wait.Add(1)
		go func(endpoint CRIEndpoint) {
			defer wait.Done()
			results <- loadCRIEndpoint(endpoint, c.config.Timeout)
		}(endpoint)
	}
	wait.Wait()
	close(results)
	for workloads := range results {
		for _, workload := range workloads {
			mergeCatalogItem(items, workload)
		}
	}
	for _, root := range runtimeMetadataRoots(c.config.DockerRoot, ".local/share/docker/containers") {
		for _, workload := range loadDockerMetadata(root) {
			mergeCatalogItem(items, workload)
		}
	}
	for _, root := range runtimeMetadataRoots(c.config.ContainersRoot, ".local/share/containers/storage/overlay-containers") {
		for _, workload := range loadOCIMetadata(root) {
			mergeCatalogItem(items, workload)
		}
	}
	c.catalog = WorkloadCatalog{items: items}
	c.expires = time.Now().Add(c.config.TTL)
	return c.catalog
}

func runtimeMetadataRoots(primary, rootlessSuffix string) []string {
	if primary == "" {
		return nil
	}
	result := []string{primary}
	if primary != "/var/lib/docker/containers" && primary != "/var/lib/containers/storage/overlay-containers" {
		return result
	}
	patterns := []string{filepath.Join("/home", "*", rootlessSuffix), filepath.Join("/root", rootlessSuffix)}
	seen := map[string]struct{}{primary: {}}
	for _, pattern := range patterns {
		matches, _ := filepath.Glob(pattern)
		for _, match := range matches {
			if _, ok := seen[match]; ok {
				continue
			}
			seen[match] = struct{}{}
			result = append(result, match)
		}
	}
	return result
}

func (c WorkloadCatalog) Lookup(containerID string) (Workload, bool) {
	if containerID == "" || len(c.items) == 0 {
		return Workload{}, false
	}
	if workload, ok := c.items[containerID]; ok {
		return workload, true
	}
	var match Workload
	found := false
	for id, workload := range c.items {
		if strings.HasPrefix(id, containerID) || strings.HasPrefix(containerID, id) {
			if found && match.ContainerID != workload.ContainerID {
				return Workload{}, false
			}
			match, found = workload, true
		}
	}
	return match, found
}

func mergeCatalogItem(items map[string]Workload, workload Workload) {
	if workload.ContainerID == "" {
		return
	}
	current := items[workload.ContainerID]
	mergeWorkload(&current, workload)
	if current.Scope == "" {
		current.Scope = "container"
	}
	current.Attribution = "cgroup"
	items[workload.ContainerID] = current
}

func runtimeForEndpoint(path string) string {
	lower := strings.ToLower(path)
	switch {
	case strings.Contains(lower, "cri-dockerd") || strings.Contains(lower, "docker"):
		return "docker"
	case strings.Contains(lower, "crio") || strings.Contains(lower, "cri-o"):
		return "cri-o"
	case strings.Contains(lower, "containerd"):
		return "containerd"
	default:
		return "cri"
	}
}

func loadCRIEndpoint(endpoint CRIEndpoint, timeout time.Duration) []Workload {
	info, err := os.Stat(endpoint.Path)
	if err != nil || info.Mode()&os.ModeSocket == 0 {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	connection, err := grpc.NewClient("unix://"+endpoint.Path, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return nil
	}
	defer connection.Close()
	client := runtimeapi.NewRuntimeServiceClient(connection)
	containersResponse, containersErr := client.ListContainers(ctx, &runtimeapi.ListContainersRequest{})
	if containersErr != nil {
		return nil
	}
	podsResponse, podsErr := client.ListPodSandbox(ctx, &runtimeapi.ListPodSandboxRequest{})
	runtimeName := endpoint.Runtime
	if version, versionErr := client.Version(ctx, &runtimeapi.VersionRequest{Version: "0.1.0"}); versionErr == nil && version.RuntimeName != "" {
		runtimeName = normalizeRuntimeName(version.RuntimeName)
	}
	var pods []*runtimeapi.PodSandbox
	if podsErr == nil {
		pods = podsResponse.Items
	}
	return workloadsFromCRI(runtimeName, containersResponse.Containers, pods)
}

func normalizeRuntimeName(name string) string {
	switch strings.ToLower(strings.TrimSpace(name)) {
	case "cri-dockerd", "dockerd", "docker":
		return "docker"
	case "crio", "cri-o":
		return "cri-o"
	case "libpod", "podman":
		return "podman"
	default:
		return strings.ToLower(strings.TrimSpace(name))
	}
}

func workloadsFromCRI(runtime string, containers []*runtimeapi.Container, pods []*runtimeapi.PodSandbox) []Workload {
	podByID := make(map[string]Workload)
	for _, pod := range pods {
		if pod == nil {
			continue
		}
		workload := workloadFromLabels(runtime, pod.Labels)
		if metadata := pod.Metadata; metadata != nil {
			if workload.Pod == "" {
				workload.Pod = metadata.Name
			}
			if workload.Namespace == "" {
				workload.Namespace = metadata.Namespace
			}
		}
		podByID[pod.Id] = workload
	}
	result := make([]Workload, 0, len(containers))
	for _, container := range containers {
		if container == nil || container.Id == "" {
			continue
		}
		workload := workloadFromLabels(runtime, container.Labels)
		workload.ContainerID = container.Id
		if pod, ok := podByID[container.PodSandboxId]; ok {
			mergeWorkload(&workload, pod)
			workload.ContainerID = container.Id
		}
		if container.Metadata != nil && workload.Container == "" {
			workload.Container = container.Metadata.Name
		}
		if workload.Pod != "" || workload.Namespace != "" {
			workload.Scope = "pod"
		} else {
			workload.Scope = "container"
		}
		result = append(result, workload)
	}
	return result
}

func workloadFromLabels(runtime string, labels map[string]string) Workload {
	workload := Workload{Runtime: runtime, Namespace: labels[labelPodNamespace], Pod: labels[labelPodName], Container: labels[labelContainerName]}
	if workload.Pod != "" || workload.Namespace != "" || labels[labelPodUID] != "" {
		workload.Scope = "pod"
	} else {
		workload.Scope = "container"
	}
	return workload
}

func loadDockerMetadata(root string) []Workload {
	entries, _ := os.ReadDir(root)
	result := make([]Workload, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() || !containerIDPattern.MatchString(entry.Name()) {
			continue
		}
		content, err := os.ReadFile(filepath.Join(root, entry.Name(), "config.v2.json"))
		if err != nil {
			continue
		}
		var config struct {
			ID     string `json:"ID"`
			Name   string `json:"Name"`
			Config struct {
				Labels map[string]string `json:"Labels"`
			} `json:"Config"`
		}
		if json.Unmarshal(content, &config) != nil {
			continue
		}
		id := config.ID
		if id == "" {
			id = entry.Name()
		}
		workload := workloadFromLabels("docker", config.Config.Labels)
		workload.ContainerID = id
		if workload.Container == "" {
			workload.Container = firstNonEmpty(config.Config.Labels["com.docker.compose.service"], strings.TrimPrefix(config.Name, "/"))
		}
		result = append(result, workload)
	}
	return result
}

func loadOCIMetadata(root string) []Workload {
	entries, _ := os.ReadDir(root)
	result := make([]Workload, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() || !containerIDPattern.MatchString(entry.Name()) {
			continue
		}
		content, err := os.ReadFile(filepath.Join(root, entry.Name(), "userdata", "config.json"))
		if err != nil {
			continue
		}
		var config struct {
			Annotations map[string]string `json:"annotations"`
		}
		if json.Unmarshal(content, &config) != nil {
			continue
		}
		annotations := config.Annotations
		runtime := "podman"
		if annotations[labelPodName] != "" || annotations[labelPodNamespace] != "" || annotations["io.kubernetes.cri-o.ContainerName"] != "" {
			runtime = "cri-o"
		}
		workload := workloadFromLabels(runtime, annotations)
		workload.ContainerID = entry.Name()
		workload.Container = firstNonEmpty(workload.Container, annotations["io.kubernetes.cri-o.ContainerName"], annotations["io.containers.name"], annotations["name"])
		result = append(result, workload)
	}
	return result
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}
