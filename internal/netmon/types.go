package netmon

import "net/netip"

type Protocol uint8

const (
	ProtocolTCP Protocol = 6
	ProtocolUDP Protocol = 17
)

type FlowKey struct {
	Protocol Protocol
	Local    netip.AddrPort
	Remote   netip.AddrPort
}

// UnknownReason records why a captured frame cannot safely be assigned to a
// host-network-namespace process. Attribution intentionally never guesses.
type UnknownReason uint8

const (
	UnknownUnsupported UnknownReason = iota
	UnknownUnmatched
	UnknownAmbiguous
	UnknownExited
)

type ProcessID struct {
	PID        int
	StartTicks uint64
}

type Workload struct {
	Scope       string
	Runtime     string
	CgroupID    uint64
	CgroupPath  string
	Namespace   string
	Pod         string
	Container   string
	ContainerID string
	Attribution string
}

func (w Workload) IsContainer() bool {
	return w.ContainerID != "" || w.Pod != "" || w.Container != ""
}

type SocketEntry struct {
	Flow  FlowKey
	Inode uint64
}

type Packet struct {
	Protocol Protocol
	Src      netip.AddrPort
	Dst      netip.AddrPort
	SrcMAC   [6]byte
	DstMAC   [6]byte
	IsIP     bool
	HasPorts bool
}

type Traffic struct {
	RXBytes uint64
	TXBytes uint64
}

type Direction uint8

const (
	DirectionIngress Direction = iota
	DirectionEgress
)

type CgroupFlow struct {
	CgroupID uint64
	Direction
	Flow  FlowKey
	Bytes uint64
}
