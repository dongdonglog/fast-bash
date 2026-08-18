package netmon

import (
	"encoding/binary"
	"net/netip"
)

const (
	etherTypeIPv4     = 0x0800
	etherTypeIPv6     = 0x86dd
	etherTypeVLAN     = 0x8100
	etherTypeQinQ     = 0x88a8
	etherTypeVLAN9100 = 0x9100
)

// ParsePacket extracts only the tuple needed for attribution. It deliberately
// avoids allocating gopacket layers in the capture hot path.
func ParsePacket(data []byte) Packet {
	var p Packet
	if len(data) < 14 {
		return p
	}
	copy(p.DstMAC[:], data[:6])
	copy(p.SrcMAC[:], data[6:12])
	etherType := binary.BigEndian.Uint16(data[12:14])
	offset := 14
	for etherType == etherTypeVLAN || etherType == etherTypeQinQ || etherType == etherTypeVLAN9100 {
		if len(data) < offset+4 {
			return p
		}
		etherType = binary.BigEndian.Uint16(data[offset+2 : offset+4])
		offset += 4
	}

	switch etherType {
	case etherTypeIPv4:
		return parseIPv4(data, offset, p)
	case etherTypeIPv6:
		return parseIPv6(data, offset, p)
	default:
		return p
	}
}

func parseIPv4(data []byte, offset int, p Packet) Packet {
	if len(data) < offset+20 || data[offset]>>4 != 4 {
		return p
	}
	ihl := int(data[offset]&0x0f) * 4
	if ihl < 20 || len(data) < offset+ihl {
		return p
	}
	p.IsIP = true
	p.Src = netip.AddrPortFrom(netip.AddrFrom4([4]byte(data[offset+12:offset+16])), 0)
	p.Dst = netip.AddrPortFrom(netip.AddrFrom4([4]byte(data[offset+16:offset+20])), 0)
	fragment := binary.BigEndian.Uint16(data[offset+6 : offset+8])
	if fragment&0x1fff != 0 {
		return p
	}
	return parsePorts(data, offset+ihl, Protocol(data[offset+9]), p)
}

func parseIPv6(data []byte, offset int, p Packet) Packet {
	if len(data) < offset+40 || data[offset]>>4 != 6 {
		return p
	}
	p.IsIP = true
	p.Src = netip.AddrPortFrom(netip.AddrFrom16([16]byte(data[offset+8:offset+24])).Unmap(), 0)
	p.Dst = netip.AddrPortFrom(netip.AddrFrom16([16]byte(data[offset+24:offset+40])).Unmap(), 0)
	next := data[offset+6]
	offset += 40
	for i := 0; i < 8; i++ {
		switch next {
		case 0, 43, 60: // hop-by-hop, routing, destination options
			if len(data) < offset+2 {
				return p
			}
			next, offset = data[offset], offset+(int(data[offset+1])+1)*8
		case 44: // fragment
			if len(data) < offset+8 {
				return p
			}
			if binary.BigEndian.Uint16(data[offset+2:offset+4])&0xfff8 != 0 {
				return p
			}
			next, offset = data[offset], offset+8
		case 51: // authentication header
			if len(data) < offset+2 {
				return p
			}
			next, offset = data[offset], offset+(int(data[offset+1])+2)*4
		default:
			return parsePorts(data, offset, Protocol(next), p)
		}
		if offset > len(data) {
			return p
		}
	}
	return p
}

func parsePorts(data []byte, offset int, protocol Protocol, p Packet) Packet {
	if protocol != ProtocolTCP && protocol != ProtocolUDP {
		return p
	}
	if len(data) < offset+4 {
		return p
	}
	p.Protocol = protocol
	p.Src = netip.AddrPortFrom(p.Src.Addr(), binary.BigEndian.Uint16(data[offset:offset+2]))
	p.Dst = netip.AddrPortFrom(p.Dst.Addr(), binary.BigEndian.Uint16(data[offset+2:offset+4]))
	p.HasPorts = true
	return p
}
