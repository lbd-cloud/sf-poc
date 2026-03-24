data "vsphere_datacenter"       "dc"       { name = var.datacenter }
data "vsphere_compute_cluster" "cluster"  { name = var.cluster;             datacenter_id = data.vsphere_datacenter.dc.id }
data "vsphere_datastore"       "ds"       { name = var.datastore;           datacenter_id = data.vsphere_datacenter.dc.id }
data "vsphere_network"         "external" { name = var.external_portgroup;  datacenter_id = data.vsphere_datacenter.dc.id }
data "vsphere_network"         "internal" { name = var.internal_portgroup;  datacenter_id = data.vsphere_datacenter.dc.id }
data "vsphere_virtual_machine" "template" { name = var.vm_template;         datacenter_id = data.vsphere_datacenter.dc.id }

locals {
  cloud_init_userdata = <<-EOT
    #cloud-config
    hostname: ${var.vm_name}
    manage_etc_hosts: true
    users:
      - name: ${var.vm_admin_user}
        groups: sudo
        shell: /bin/bash
        sudo: "ALL=(ALL) NOPASSWD:ALL"
        lock_passwd: true
        ssh_authorized_keys:
          - ${var.ssh_public_key}
    ssh_pwauth: false
    disable_root: true
    packages: [python3, python3-apt]
    runcmd:
      - systemctl enable ssh
      - systemctl start ssh
  EOT
}

resource "vsphere_virtual_machine" "vm" {
  name             = var.vm_name
  resource_pool_id = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id     = data.vsphere_datastore.ds.id
  num_cpus         = var.vm_cpus
  memory           = var.vm_memory_mb
  guest_id         = data.vsphere_virtual_machine.template.guest_id

  clone {
    template_uuid = data.vsphere_virtual_machine.template.id
    customize {
      linux_options { host_name = var.vm_name; domain = "local" }
      # eth0 — external, internet-facing
      network_interface { ipv4_address = var.external_ip; ipv4_netmask = var.external_prefix_length }
      # eth1 — internal; vSwitch port group is VLAN 150 trunk
      # Ansible configures eth1.150 sub-interface via Netplan
      network_interface { ipv4_address = var.internal_ip; ipv4_netmask = 29 }
      ipv4_gateway    = var.external_gateway
      dns_server_list = var.dns_servers
    }
  }

  disk {
    label            = "disk0"
    size             = var.vm_disk_gb
    thin_provisioned = true
  }

  network_interface {
    network_id   = data.vsphere_network.external.id
    adapter_type = data.vsphere_virtual_machine.template.network_interface_types[0]
  }

  network_interface {
    network_id   = data.vsphere_network.internal.id
    adapter_type = data.vsphere_virtual_machine.template.network_interface_types[0]
  }

  extra_config = {
    "guestinfo.userdata"          = base64encode(local.cloud_init_userdata)
    "guestinfo.userdata.encoding" = "base64"
  }

  wait_for_guest_net_timeout = 300
  wait_for_guest_ip_timeout  = 300
}
