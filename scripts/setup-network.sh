#!/usr/bin/env bash
# Run as root before terraform apply.
# Creates:
#   - OVS bridge br-vlan150
#   - veth pair: veth-host (OVS trunk port, trunks=150) <-> veth-ns (inside ns-device)
#   - Network namespace ns-device with IP 10.200.16.100/29
#   - libvirt network vlan150-internal backed by br-vlan150
#
# The VM tap interface is added to OVS by libvirt at VM start.
# Terraform then sets that tap as a trunk port (VLAN 150) via null_resource.
set -euo pipefail

# Dependencies
command -v mkisofs &>/dev/null || { echo "ERROR: sudo pacman -S cdrtools"; exit 1; }
command -v virsh &>/dev/null || { echo "ERROR: sudo pacman -S libvirt"; exit 1; }
command -v ovs-vsctl &>/dev/null || { echo "ERROR: sudo pacman -S openvswitch"; exit 1; }

# Ubuntu 22.04 cloud image
IMAGE="/var/lib/libvirt/images/ubuntu-22.04-base.img"
if [ ! -f "$IMAGE" ]; then
  echo "Downloading Ubuntu 22.04 cloud image (600 MB)..."
  curl -L -o "$IMAGE" https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
fi

# Default libvirt NAT network
if ! virsh net-info default 2>/dev/null | grep -q "Active:.*yes"; then
  virsh net-start default 2>/dev/null || true
fi
virsh net-autostart default 2>/dev/null || true

# Default libvirt storage pool
if ! virsh pool-info default &>/dev/null; then
  virsh pool-define-as default dir --target /var/lib/libvirt/images
  virsh pool-build default
  virsh pool-start default
  virsh pool-autostart default
fi

OVS_BRIDGE="br-vlan150"
VLAN_ID=150
DEVICE_NS="ns-device"
VETH_HOST="veth-host"
VETH_NS="veth-ns"
DEVICE_IP="10.200.16.100/32"
NET_XML="/tmp/vlan150-net.xml"

# OVS bridge
ovs-vsctl br-exists "$OVS_BRIDGE" || ovs-vsctl add-br "$OVS_BRIDGE"
ip link set "$OVS_BRIDGE" up

# veth pair — veth-host in OVS as trunk port, trunks=150
# Both the device port and the VM port only accept VLAN 150 tagged frames
if ! ip link show "$VETH_HOST" &>/dev/null; then
  ip link add "$VETH_HOST" type veth peer name "$VETH_NS"
  ip link set "$VETH_HOST" up
  ovs-vsctl add-port "$OVS_BRIDGE" "$VETH_HOST"
  ovs-vsctl set port "$VETH_HOST" vlan_mode=trunk trunks="$VLAN_ID"
  ovs-vsctl clear port "$VETH_HOST" tag
fi

# Device namespace — simulates 10.200.16.100
# Uses a VLAN sub-interface (veth-ns.150) so it sends/receives 802.1Q tagged frames
# matching the requirement: port only accepts VLAN 150 tagged packets
if ! ip netns list | grep -q "^$DEVICE_NS"; then
  ip netns add "$DEVICE_NS"
  ip link set "$VETH_NS" netns "$DEVICE_NS"
  ip netns exec "$DEVICE_NS" ip link set lo up
  ip netns exec "$DEVICE_NS" ip link set "$VETH_NS" up
  ip netns exec "$DEVICE_NS" ip link add link "$VETH_NS" name "${VETH_NS}.${VLAN_ID}" type vlan id "$VLAN_ID"
  ip netns exec "$DEVICE_NS" ip link set "${VETH_NS}.${VLAN_ID}" up
  ip netns exec "$DEVICE_NS" ip addr add "$DEVICE_IP" dev "${VETH_NS}.${VLAN_ID}"
  ip netns exec "$DEVICE_NS" ip route add 10.200.16.0/29 dev "${VETH_NS}.${VLAN_ID}"
fi

# libvirt network backed by OVS bridge — passthrough, no NAT/DHCP
cat > "$NET_XML" <<EOF
<network>
  <name>vlan150-internal</name>
  <forward mode="bridge"/>
  <bridge name="${OVS_BRIDGE}"/>
  <virtualport type="openvswitch"/>
</network>
EOF

if ! virsh net-info vlan150-internal &>/dev/null; then
  virsh net-define "$NET_XML"
  virsh net-start vlan150-internal
  virsh net-autostart vlan150-internal
fi

echo "Network ready."
echo "  OVS bridge : $OVS_BRIDGE"
echo "  Device NS  : $DEVICE_NS  (10.200.16.100/29)"
echo ""
echo "Next: make local-apply"
echo "After VM is up: sudo ip netns exec $DEVICE_NS nc -zv 10.200.16.1 9000"
