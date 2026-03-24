locals {
  ssh_pub_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
}

# Ubuntu 22.04 cloud image — fetched once into the default libvirt pool
resource "libvirt_volume" "ubuntu_base" {
  name   = "ubuntu-22.04-base.img"
  pool   = "default"
  source = var.ubuntu_image_path
  format = "qcow2"
}

# Thin clone expanded to the desired disk size
resource "libvirt_volume" "vm_disk" {
  name           = "${var.vm_name}.qcow2"
  pool           = "default"
  base_volume_id = libvirt_volume.ubuntu_base.id
  size           = var.vm_disk_gb * 1073741824
  format         = "qcow2"
}

# cloud-init iso — user + key injection, static IP on eth1
resource "libvirt_cloudinit_disk" "init" {
  name = "${var.vm_name}-init.iso"
  pool = "default"

  user_data = <<-EOT
    #cloud-config
    hostname: ${var.vm_name}
    manage_etc_hosts: true
    users:
      - name: deploy
        groups: sudo
        shell: /bin/bash
        sudo: "ALL=(ALL) NOPASSWD:ALL"
        lock_passwd: true
        ssh_authorized_keys:
          - ${local.ssh_pub_key}
    ssh_pwauth: false
    disable_root: true
    packages: [python3, python3-apt]
    runcmd:
      - systemctl enable ssh
      - systemctl start ssh
  EOT

  network_config = <<-EOT
    version: 2
    ethernets:
      ens3:
        dhcp4: false
        addresses: ["${var.vm_external_ip}/24"]
        routes:
          - to: default
            via: ${var.vm_external_gw}
        nameservers:
          addresses: [8.8.8.8, 1.1.1.1]
      ens4:
        dhcp4: false
    vlans:
      ens4.${var.internal_vlan_id}:
        id: ${var.internal_vlan_id}
        link: ens4
        dhcp4: false
        addresses: ["${var.vm_internal_ip}/29"]
  EOT
}

resource "libvirt_domain" "vm" {
  name      = var.vm_name
  memory    = var.vm_memory_mb
  vcpu      = var.vm_cpus
  cloudinit = libvirt_cloudinit_disk.init.id

  # eth0 — libvirt default NAT; internet access + Ansible SSH entry point
  network_interface {
    network_name   = "default"
    wait_for_lease = false
  }

  # eth1 — OVS-backed libvirt network
  # setup-network.sh creates the libvirt network pointing at br-vlan150.
  # After the VM starts, the null_resource below sets this tap as trunk
  # on VLAN 150 so the VM receives 802.1Q-tagged frames on ens4.
  network_interface {
    network_name = "vlan150-internal"
  }

  disk {
    volume_id = libvirt_volume.vm_disk.id
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }
}

# After the VM starts, libvirt adds a tap interface to the OVS bridge.
# By default libvirt sets it as an access port — we switch it to trunk
# passing VLAN 150 so the VM receives tagged frames on eth1.
resource "null_resource" "ovs_trunk_port" {
  depends_on = [libvirt_domain.vm]

  provisioner "local-exec" {
    command = <<-SH
      sleep 5
      TAP=$(virsh domiflist ${var.vm_name} | awk '/vlan150/{print $1}')
      if [ -z "$TAP" ]; then
        echo "ERROR: could not find tap interface for ${var.vm_name} on vlan150-internal"
        exit 1
      fi
      ovs-vsctl set port "$TAP" vlan_mode=trunk trunks=150
      echo "OVS port $TAP set to trunk VLAN 150"
      # Patch domain XML to set trustGuestRxFilters=yes on the internal NIC.
      # This tells the virtio driver to pass 802.1Q tagged frames to the guest
      # without requiring promiscuous mode on the tap interface.
      XMLFILE=$(mktemp /tmp/vm-XXXXXX.xml)
      virsh dumpxml ${var.vm_name} | \
        sed 's|\(<source bridge=.br-vlan150./>\)|\1\n      <driver name="vhost" trustGuestRxFilters="yes"/>|' \
        > "$XMLFILE"
      virsh define "$XMLFILE" && echo "trustGuestRxFilters set for next boot"
      rm -f "$XMLFILE"
      # Also set promisc on current tap for this session (takes effect immediately)
      ip link set "$TAP" promisc on
    SH
    interpreter = ["sudo", "bash", "-c"]
  }
}
