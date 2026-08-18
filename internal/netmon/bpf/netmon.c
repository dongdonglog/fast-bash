// SPDX-License-Identifier: MIT
#include <linux/bpf.h>
#include <linux/in.h>
#include <linux/in6.h>
#include <linux/ip.h>
#include <linux/ipv6.h>
#include <linux/types.h>
#include <bpf/bpf_endian.h>
#include <bpf/bpf_helpers.h>

enum direction {
	DIR_INGRESS = 0,
	DIR_EGRESS = 1,
};

#define SMON_AF_INET 2
#define SMON_AF_INET6 10

struct flow_key {
	__u64 cgroup_id;
	__u8 family;
	__u8 protocol;
	__u8 direction;
	__u8 pad;
	__u16 source_port;
	__u16 dest_port;
	__u32 source_ip[4];
	__u32 dest_ip[4];
};

struct {
	__uint(type, BPF_MAP_TYPE_LRU_HASH);
	__uint(max_entries, 65536);
	__type(key, struct flow_key);
	__type(value, __u64);
} flows SEC(".maps");

static __always_inline int count_packet(struct __sk_buff *skb, __u8 direction)
{
	struct flow_key key = {};
	__u8 version = 0;
	__u8 protocol = 0;
	__u16 ports[2] = {};
	__u64 initial;
	__u64 *value;
	__u32 offset;

	if (bpf_skb_load_bytes(skb, 0, &version, sizeof(version)) < 0)
		return 1;
	version >>= 4;
	key.direction = direction;
	key.cgroup_id = bpf_skb_cgroup_id(skb);

	if (version == 4) {
		__u8 ihl = 0;
		__u16 frag = 0;

		key.family = SMON_AF_INET;
		if (bpf_skb_load_bytes(skb, 0, &ihl, sizeof(ihl)) < 0 ||
		    bpf_skb_load_bytes(skb, 9, &protocol, sizeof(protocol)) < 0 ||
		    bpf_skb_load_bytes(skb, 6, &frag, sizeof(frag)) < 0 ||
		    bpf_skb_load_bytes(skb, 12, key.source_ip, 4) < 0 ||
		    bpf_skb_load_bytes(skb, 16, key.dest_ip, 4) < 0)
			return 1;
		offset = (ihl & 0x0f) * 4;
		// Non-initial fragments cannot be matched to a socket tuple.
		if (frag & __bpf_constant_htons(0x1fff))
			protocol = 0;
	} else if (version == 6) {
		key.family = SMON_AF_INET6;
		if (bpf_skb_load_bytes(skb, 6, &protocol, sizeof(protocol)) < 0 ||
		    bpf_skb_load_bytes(skb, 8, key.source_ip, 16) < 0 ||
		    bpf_skb_load_bytes(skb, 24, key.dest_ip, 16) < 0)
			return 1;
		offset = sizeof(struct ipv6hdr);
	} else {
		return 1;
	}

	key.protocol = protocol;
	if ((protocol == IPPROTO_TCP || protocol == IPPROTO_UDP) &&
	    bpf_skb_load_bytes(skb, offset, ports, sizeof(ports)) == 0) {
		key.source_port = bpf_ntohs(ports[0]);
		key.dest_port = bpf_ntohs(ports[1]);
	}

	value = bpf_map_lookup_elem(&flows, &key);
	if (value) {
		__sync_fetch_and_add(value, skb->len);
		return 1;
	}
	initial = skb->len;
	bpf_map_update_elem(&flows, &key, &initial, BPF_ANY);
	return 1;
}

SEC("cgroup_skb/ingress")
int count_ingress(struct __sk_buff *skb)
{
	return count_packet(skb, DIR_INGRESS);
}

SEC("cgroup_skb/egress")
int count_egress(struct __sk_buff *skb)
{
	return count_packet(skb, DIR_EGRESS);
}

char LICENSE[] SEC("license") = "Dual BSD/GPL";
