variable "vm_name" {
  type    = string
  default = "ubuntu-hardened"
}

variable "vm_cpus" {
  type    = number
  default = 2
}

variable "vm_memory_mb" {
  type    = number
  default = 2048
}

variable "vm_disk_gb" {
  type    = number
  default = 20
}

variable "ubuntu_image_path" {
  type    = string
  default = "/var/lib/libvirt/images/ubuntu-22.04-base.img"
}

# Static IP assigned to eth1 inside the VLAN 150 segment
variable "vm_internal_ip" {
  type    = string
  default = "10.200.16.1"
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

variable "internal_vlan_id" {
  type    = number
  default = 150
}

variable "vm_external_ip" {
  type    = string
  default = "192.168.122.10"
}

variable "vm_external_gw" {
  type    = string
  default = "192.168.122.1"
}
