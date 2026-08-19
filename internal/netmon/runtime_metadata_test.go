package netmon

import (
	"os"
	"path/filepath"
	"testing"

	runtimeapi "k8s.io/cri-api/pkg/apis/runtime/v1"
)

func TestWorkloadsFromCRI(t *testing.T) {
	pods := []*runtimeapi.PodSandbox{{Id: "sandbox", Metadata: &runtimeapi.PodSandboxMetadata{Name: "api-abc", Namespace: "prod"}}}
	containers := []*runtimeapi.Container{{Id: "abcdef123456", PodSandboxId: "sandbox", Metadata: &runtimeapi.ContainerMetadata{Name: "api"}}}
	items := workloadsFromCRI("containerd", containers, pods)
	if len(items) != 1 || items[0].Runtime != "containerd" || items[0].Scope != "pod" || items[0].Namespace != "prod" || items[0].Pod != "api-abc" || items[0].Container != "api" {
		t.Fatalf("unexpected CRI workload: %+v", items)
	}
}

func TestDockerAndOCIMetadataFallbacks(t *testing.T) {
	dockerRoot := t.TempDir()
	dockerID := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	if err := os.Mkdir(filepath.Join(dockerRoot, dockerID), 0o755); err != nil {
		t.Fatal(err)
	}
	dockerJSON := `{"ID":"` + dockerID + `","Name":"/web","Config":{"Labels":{"com.docker.compose.service":"frontend"}}}`
	if err := os.WriteFile(filepath.Join(dockerRoot, dockerID, "config.v2.json"), []byte(dockerJSON), 0o600); err != nil {
		t.Fatal(err)
	}
	docker := loadDockerMetadata(dockerRoot)
	if len(docker) != 1 || docker[0].Runtime != "docker" || docker[0].Scope != "container" || docker[0].Container != "frontend" {
		t.Fatalf("unexpected Docker metadata: %+v", docker)
	}

	ociRoot := t.TempDir()
	ociID := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	if err := os.MkdirAll(filepath.Join(ociRoot, ociID, "userdata"), 0o755); err != nil {
		t.Fatal(err)
	}
	ociJSON := `{"annotations":{"io.kubernetes.pod.name":"worker-1","io.kubernetes.pod.namespace":"jobs","io.kubernetes.container.name":"worker"}}`
	if err := os.WriteFile(filepath.Join(ociRoot, ociID, "userdata", "config.json"), []byte(ociJSON), 0o600); err != nil {
		t.Fatal(err)
	}
	oci := loadOCIMetadata(ociRoot)
	if len(oci) != 1 || oci[0].Runtime != "cri-o" || oci[0].Scope != "pod" || oci[0].Namespace != "jobs" || oci[0].Pod != "worker-1" || oci[0].Container != "worker" {
		t.Fatalf("unexpected OCI metadata: %+v", oci)
	}
}

func TestCatalogPrefixMustBeUnique(t *testing.T) {
	catalog := WorkloadCatalog{items: map[string]Workload{
		"abcdef111111": {ContainerID: "abcdef111111"},
		"abcdef222222": {ContainerID: "abcdef222222"},
	}}
	if _, ok := catalog.Lookup("abcdef"); ok {
		t.Fatal("ambiguous short container ID must not resolve")
	}
	if workload, ok := catalog.Lookup("abcdef111111ffff"); !ok || workload.ContainerID != "abcdef111111" {
		t.Fatalf("unique prefix did not resolve: %+v %v", workload, ok)
	}
}

func TestNormalizeRuntimeName(t *testing.T) {
	for input, want := range map[string]string{"cri-dockerd": "docker", "crio": "cri-o", "libpod": "podman", "custom-runtime": "custom-runtime"} {
		if got := normalizeRuntimeName(input); got != want {
			t.Errorf("normalizeRuntimeName(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestDefaultCRIEndpointsCoverCommonDistributions(t *testing.T) {
	t.Setenv("SMON_CRI_ENDPOINTS", "")
	config := DefaultRuntimeMetadataConfig()
	paths := make(map[string]bool)
	for _, endpoint := range config.CRIEndpoints {
		paths[endpoint.Path] = true
	}
	for _, path := range []string{"/run/containerd/containerd.sock", "/run/k3s/containerd/containerd.sock", "/run/rke2/containerd/containerd.sock", "/run/k0s/containerd.sock", "/var/snap/microk8s/common/run/containerd.sock", "/run/crio/crio.sock", "/run/cri-dockerd.sock"} {
		if !paths[path] {
			t.Errorf("default CRI endpoint %q is missing", path)
		}
	}
}
