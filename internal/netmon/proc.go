package netmon

import (
	"bufio"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

type ProcFS struct {
	Root string
}

type Resolver struct {
	flows  map[FlowKey][]uint64
	owners map[uint64][]ProcessID
}

func (p ProcFS) LoadResolver() (*Resolver, error) {
	var entries []SocketEntry
	var readErrs []error
	for _, table := range []struct {
		name     string
		protocol Protocol
		ipv6     bool
	}{
		{"tcp", ProtocolTCP, false},
		{"tcp6", ProtocolTCP, true},
		{"udp", ProtocolUDP, false},
		{"udp6", ProtocolUDP, true},
	} {
		path := filepath.Join(p.Root, "net", table.name)
		f, err := os.Open(path)
		if err != nil {
			if !errors.Is(err, os.ErrNotExist) {
				readErrs = append(readErrs, fmt.Errorf("%s: %w", path, err))
			}
			continue
		}
		parsed, err := ParseSocketTable(f, table.protocol, table.ipv6)
		_ = f.Close()
		if err != nil {
			readErrs = append(readErrs, fmt.Errorf("%s: %w", path, err))
			continue
		}
		entries = append(entries, parsed...)
	}
	owners, err := p.scanOwners()
	if err != nil {
		readErrs = append(readErrs, err)
	}
	if len(entries) == 0 && len(readErrs) > 0 {
		return NewResolver(nil, owners), errors.Join(readErrs...)
	}
	return NewResolver(entries, owners), nil
}

func ParseSocketTable(r io.Reader, protocol Protocol, ipv6 bool) ([]SocketEntry, error) {
	scanner := bufio.NewScanner(r)
	var entries []SocketEntry
	first := true
	for scanner.Scan() {
		if first {
			first = false
			continue
		}
		fields := strings.Fields(scanner.Text())
		if len(fields) < 10 {
			continue
		}
		local, err := parseProcAddrPort(fields[1], ipv6)
		if err != nil {
			continue
		}
		remote, err := parseProcAddrPort(fields[2], ipv6)
		if err != nil {
			continue
		}
		inode, err := strconv.ParseUint(fields[9], 10, 64)
		if err != nil || inode == 0 {
			continue
		}
		entries = append(entries, SocketEntry{
			Flow:  FlowKey{Protocol: protocol, Local: local, Remote: remote},
			Inode: inode,
		})
	}
	return entries, scanner.Err()
}

func parseProcAddrPort(value string, ipv6 bool) (netip.AddrPort, error) {
	parts := strings.Split(value, ":")
	if len(parts) != 2 {
		return netip.AddrPort{}, fmt.Errorf("invalid address %q", value)
	}
	raw, err := hex.DecodeString(parts[0])
	if err != nil {
		return netip.AddrPort{}, err
	}
	port, err := strconv.ParseUint(parts[1], 16, 16)
	if err != nil {
		return netip.AddrPort{}, err
	}
	var addr netip.Addr
	if ipv6 {
		if len(raw) != 16 {
			return netip.AddrPort{}, fmt.Errorf("invalid IPv6 address length")
		}
		for i := 0; i < 16; i += 4 {
			raw[i], raw[i+3] = raw[i+3], raw[i]
			raw[i+1], raw[i+2] = raw[i+2], raw[i+1]
		}
		addr = netip.AddrFrom16([16]byte(raw)).Unmap()
	} else {
		if len(raw) != 4 {
			return netip.AddrPort{}, fmt.Errorf("invalid IPv4 address length")
		}
		addr = netip.AddrFrom4([4]byte{raw[3], raw[2], raw[1], raw[0]})
	}
	return netip.AddrPortFrom(addr, uint16(port)), nil
}

func NewResolver(entries []SocketEntry, owners map[uint64][]ProcessID) *Resolver {
	r := &Resolver{flows: make(map[FlowKey][]uint64), owners: owners}
	for _, entry := range entries {
		inodes := r.flows[entry.Flow]
		found := false
		for _, inode := range inodes {
			if inode == entry.Inode {
				found = true
				break
			}
		}
		if !found {
			r.flows[entry.Flow] = append(inodes, entry.Inode)
		}
	}
	return r
}

func (r *Resolver) Resolve(flow FlowKey) (ProcessID, UnknownReason) {
	if _, exists := r.flows[flow]; exists {
		return r.resolveExact(flow)
	}
	if flow.Protocol != ProtocolUDP {
		return ProcessID{}, UnknownUnmatched
	}

	localZeros := unspecifiedAddresses(flow.Local.Addr())
	remoteZeros := unspecifiedAddresses(flow.Remote.Addr())
	var candidates []FlowKey
	for _, remote := range remoteZeros {
		candidates = append(candidates, FlowKey{
			Protocol: flow.Protocol,
			Local:    flow.Local,
			Remote:   netip.AddrPortFrom(remote, 0),
		})
	}
	for _, local := range localZeros {
		candidates = append(candidates, FlowKey{
			Protocol: flow.Protocol,
			Local:    netip.AddrPortFrom(local, flow.Local.Port()),
			Remote:   flow.Remote,
		})
		for _, remote := range remoteZeros {
			candidates = append(candidates, FlowKey{
				Protocol: flow.Protocol,
				Local:    netip.AddrPortFrom(local, flow.Local.Port()),
				Remote:   netip.AddrPortFrom(remote, 0),
			})
		}
	}
	for _, candidate := range candidates {
		if _, exists := r.flows[candidate]; exists {
			return r.resolveExact(candidate)
		}
	}
	return ProcessID{}, UnknownUnmatched
}

func (r *Resolver) resolveExact(flow FlowKey) (ProcessID, UnknownReason) {
	inodes, exists := r.flows[flow]
	if !exists {
		return ProcessID{}, UnknownUnmatched
	}
	if len(inodes) != 1 {
		return ProcessID{}, UnknownAmbiguous
	}
	owners := r.owners[inodes[0]]
	if len(owners) == 0 {
		return ProcessID{}, UnknownUnmatched
	}
	if len(owners) != 1 {
		return ProcessID{}, UnknownAmbiguous
	}
	return owners[0], 0
}

func unspecifiedAddresses(addr netip.Addr) []netip.Addr {
	if addr.Is4() {
		return []netip.Addr{netip.IPv4Unspecified(), netip.IPv6Unspecified()}
	}
	return []netip.Addr{netip.IPv6Unspecified()}
}

func (p ProcFS) scanOwners() (map[uint64][]ProcessID, error) {
	dirs, err := os.ReadDir(p.Root)
	if err != nil {
		return nil, err
	}
	owners := make(map[uint64][]ProcessID)
	for _, dir := range dirs {
		pid, err := strconv.Atoi(dir.Name())
		if err != nil || !dir.IsDir() {
			continue
		}
		start, err := p.StartTime(pid)
		if err != nil {
			continue
		}
		fds, err := os.ReadDir(filepath.Join(p.Root, dir.Name(), "fd"))
		if err != nil {
			continue
		}
		seen := make(map[uint64]struct{})
		for _, fd := range fds {
			target, err := os.Readlink(filepath.Join(p.Root, dir.Name(), "fd", fd.Name()))
			if err != nil || !strings.HasPrefix(target, "socket:[") || !strings.HasSuffix(target, "]") {
				continue
			}
			inode, err := strconv.ParseUint(strings.TrimSuffix(strings.TrimPrefix(target, "socket:["), "]"), 10, 64)
			if err != nil {
				continue
			}
			if _, exists := seen[inode]; exists {
				continue
			}
			seen[inode] = struct{}{}
			owners[inode] = append(owners[inode], ProcessID{PID: pid, StartTicks: start})
		}
	}
	for inode := range owners {
		sort.Slice(owners[inode], func(i, j int) bool { return owners[inode][i].PID < owners[inode][j].PID })
	}
	return owners, nil
}

func (p ProcFS) StartTime(pid int) (uint64, error) {
	b, err := os.ReadFile(filepath.Join(p.Root, strconv.Itoa(pid), "stat"))
	if err != nil {
		return 0, err
	}
	end := strings.LastIndexByte(string(b), ')')
	if end < 0 || end+2 >= len(b) {
		return 0, errors.New("malformed stat")
	}
	fields := strings.Fields(string(b[end+2:]))
	// fields starts at proc stat field 3; starttime is field 22.
	if len(fields) <= 19 {
		return 0, errors.New("stat missing starttime")
	}
	return strconv.ParseUint(fields[19], 10, 64)
}
