package netmon

import (
	"encoding/binary"
	"net/netip"
	"testing"
)

func TestParseIPv4TCP(t *testing.T) {
	frame := ethernetFrame(etherTypeIPv4, ipv4Packet(ProtocolTCP, [4]byte{10, 0, 0, 1}, [4]byte{10, 0, 0, 2}, 1234, 443))
	p := ParsePacket(frame)
	if !p.HasPorts || p.Protocol != ProtocolTCP {
		t.Fatalf("unexpected parse: %+v", p)
	}
	if p.Src != netip.MustParseAddrPort("10.0.0.1:1234") || p.Dst != netip.MustParseAddrPort("10.0.0.2:443") {
		t.Fatalf("unexpected tuple: %s -> %s", p.Src, p.Dst)
	}
}

func TestParseVLANIPv4UDP(t *testing.T) {
	payload := ipv4Packet(ProtocolUDP, [4]byte{192, 0, 2, 1}, [4]byte{198, 51, 100, 2}, 5353, 9999)
	frame := make([]byte, 18+len(payload))
	copy(frame[0:6], []byte{0, 1, 2, 3, 4, 5})
	copy(frame[6:12], []byte{6, 7, 8, 9, 10, 11})
	binary.BigEndian.PutUint16(frame[12:14], etherTypeVLAN)
	binary.BigEndian.PutUint16(frame[14:16], 42)
	binary.BigEndian.PutUint16(frame[16:18], etherTypeIPv4)
	copy(frame[18:], payload)
	p := ParsePacket(frame)
	if !p.HasPorts || p.Protocol != ProtocolUDP || p.Src.Port() != 5353 || p.Dst.Port() != 9999 {
		t.Fatalf("unexpected VLAN parse: %+v", p)
	}
}

func TestParseIPv6UDPWithHopByHop(t *testing.T) {
	src := netip.MustParseAddr("2001:db8::1").As16()
	dst := netip.MustParseAddr("2001:db8::2").As16()
	ip := make([]byte, 40+8+8)
	ip[0] = 0x60
	ip[6] = 0 // hop-by-hop
	copy(ip[8:24], src[:])
	copy(ip[24:40], dst[:])
	ip[40] = byte(ProtocolUDP)
	ip[41] = 0
	binary.BigEndian.PutUint16(ip[48:50], 53)
	binary.BigEndian.PutUint16(ip[50:52], 44444)
	p := ParsePacket(ethernetFrame(etherTypeIPv6, ip))
	if !p.HasPorts || p.Protocol != ProtocolUDP {
		t.Fatalf("unexpected IPv6 parse: %+v", p)
	}
	if p.Src != netip.MustParseAddrPort("[2001:db8::1]:53") || p.Dst != netip.MustParseAddrPort("[2001:db8::2]:44444") {
		t.Fatalf("unexpected tuple: %s -> %s", p.Src, p.Dst)
	}
}

func TestNonInitialFragmentHasNoPorts(t *testing.T) {
	ip := ipv4Packet(ProtocolTCP, [4]byte{10, 0, 0, 1}, [4]byte{10, 0, 0, 2}, 1, 2)
	binary.BigEndian.PutUint16(ip[6:8], 1)
	p := ParsePacket(ethernetFrame(etherTypeIPv4, ip))
	if !p.IsIP || p.HasPorts {
		t.Fatalf("fragment should be IP but unattributable: %+v", p)
	}
}

func ethernetFrame(etherType uint16, payload []byte) []byte {
	frame := make([]byte, 14+len(payload))
	copy(frame[0:6], []byte{0, 1, 2, 3, 4, 5})
	copy(frame[6:12], []byte{6, 7, 8, 9, 10, 11})
	binary.BigEndian.PutUint16(frame[12:14], etherType)
	copy(frame[14:], payload)
	return frame
}

func ipv4Packet(protocol Protocol, src, dst [4]byte, srcPort, dstPort uint16) []byte {
	ip := make([]byte, 24)
	ip[0] = 0x45
	ip[9] = byte(protocol)
	copy(ip[12:16], src[:])
	copy(ip[16:20], dst[:])
	binary.BigEndian.PutUint16(ip[20:22], srcPort)
	binary.BigEndian.PutUint16(ip[22:24], dstPort)
	return ip
}
