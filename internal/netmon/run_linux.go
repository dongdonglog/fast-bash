//go:build linux

package netmon

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"time"

	"github.com/gopacket/gopacket/afpacket"
)

type Config struct {
	Interface     string
	Interval      time.Duration
	Output        string
	Once          bool
	ProcRoot      string
	CgroupRoot    string
	ContainerLogs string
	PodLogs       string
}

func Run(ctx context.Context, cfg Config) error {
	iface, err := net.InterfaceByName(cfg.Interface)
	if err != nil {
		return fmt.Errorf("interface %q: %w", cfg.Interface, err)
	}
	localIPs := make(map[netip.Addr]struct{})
	addrs, err := iface.Addrs()
	if err != nil {
		return fmt.Errorf("interface addresses: %w", err)
	}
	for _, raw := range addrs {
		prefix, err := netip.ParsePrefix(raw.String())
		if err == nil {
			localIPs[prefix.Addr().Unmap()] = struct{}{}
		}
	}
	proc := ProcFS{Root: cfg.ProcRoot}
	resolver, _ := proc.LoadResolver()
	resolverConfig := DefaultResolverConfig()
	if cfg.CgroupRoot != "" {
		resolverConfig.CgroupRoot = cfg.CgroupRoot
	}
	if cfg.ContainerLogs != "" {
		resolverConfig.ContainerLogs = cfg.ContainerLogs
	}
	if cfg.PodLogs != "" {
		resolverConfig.PodLogs = cfg.PodLogs
	}
	handle, err := afpacket.NewTPacket(
		afpacket.OptInterface(cfg.Interface),
		afpacket.OptFrameSize(4096),
		afpacket.OptBlockSize(1<<20),
		afpacket.OptNumBlocks(16),
		afpacket.OptBlockTimeout(64*time.Millisecond),
		afpacket.OptPollTimeout(100*time.Millisecond),
		afpacket.OptTPacketVersion(afpacket.TPacketVersion3),
	)
	if err != nil {
		return fmt.Errorf("open AF_PACKET (run smon as root): %w", err)
	}
	defer handle.Close()
	bpfCollector, bpfErr := OpenEBPFCollector(resolverConfig.CgroupRoot)
	if bpfCollector != nil {
		defer bpfCollector.Close()
	}
	bpfFallbackReason := ""
	if bpfErr != nil {
		bpfFallbackReason = fmt.Sprintf("eBPF 不可用，已回退 AF_PACKET: %v", bpfErr)
	}

	window := NewWindow()
	started := time.Now()
	deadline := started.Add(cfg.Interval)
	var previousDrops uint64

	for {
		select {
		case <-ctx.Done():
			return nil
		default:
		}

		data, info, readErr := handle.ZeroCopyReadPacketData()
		if readErr == nil {
			length := info.Length
			if length <= 0 {
				length = len(data)
			}
			packet := ParsePacket(data)
			if bpfCollector != nil {
				window.Observe(packet, length, iface.HardwareAddr, localIPs)
			} else {
				window.Account(packet, length, iface.HardwareAddr, localIPs, resolver)
			}
		} else if !errors.Is(readErr, afpacket.ErrTimeout) {
			return fmt.Errorf("capture: %w", readErr)
		}

		now := time.Now()
		if now.Before(deadline) {
			continue
		}
		_, statsV3, statsErr := handle.SocketStats()
		var drops uint64
		if statsErr == nil {
			totalDrops := uint64(statsV3.Drops())
			if totalDrops >= previousDrops {
				drops = totalDrops - previousDrops
			}
			previousDrops = totalDrops
		}
		var snapshot Snapshot
		if bpfCollector != nil {
			flows, readBPFErr := bpfCollector.ReadDeltas()
			systemResolver, resolverErr := proc.LoadSystemResolver(resolverConfig)
			if readBPFErr == nil && systemResolver != nil {
				snapshot = SnapshotCgroupFlows(now, now.Sub(started), cfg.Interface, drops, window, systemResolver, flows, proc)
				if resolverErr != nil {
					snapshot.Status = "partial"
					snapshot.Reason = fmt.Sprintf("部分 network namespace 无法读取: %v", resolverErr)
				}
			} else {
				reason := readBPFErr
				if reason == nil {
					reason = resolverErr
				}
				bpfCollector.Close()
				bpfCollector = nil
				bpfFallbackReason = fmt.Sprintf("eBPF 采集异常，已回退 AF_PACKET: %v", reason)
				snapshot = window.Snapshot(now, now.Sub(started), cfg.Interface, drops, proc)
			}
		} else {
			snapshot = window.Snapshot(now, now.Sub(started), cfg.Interface, drops, proc)
		}
		if snapshot.Version < 3 {
			snapshot.Version = 3
			snapshot.Source = "af_packet_fallback"
			snapshot.Status = "partial"
			snapshot.Scope = "host_network_namespace"
			snapshot.Reason = bpfFallbackReason
		}
		if err := WriteSnapshot(cfg.Output, snapshot); err != nil {
			return fmt.Errorf("write snapshot: %w", err)
		}
		if cfg.Once {
			return nil
		}
		resolver, _ = proc.LoadResolver()
		window = NewWindow()
		started = now
		deadline = now.Add(cfg.Interval)
	}
}
