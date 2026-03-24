#!/usr/bin/env bash
set -euo pipefail

OVS_BRIDGE="br-vlan150"
DEVICE_NS="ns-device"
VETH_HOST="veth-host"

virsh net-destroy vlan150-internal 2>/dev/null || true
virsh net-undefine vlan150-internal 2>/dev/null || true

ip netns del "$DEVICE_NS" 2>/dev/null || true

ovs-vsctl del-port "$OVS_BRIDGE" "$VETH_HOST" 2>/dev/null || true
ovs-vsctl del-br "$OVS_BRIDGE" 2>/dev/null || true

echo "Network teardown complete"
