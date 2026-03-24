variable "vsphere_user"                 { type = string }
variable "vsphere_password"             { type = string; sensitive = true }
variable "vsphere_server"               { type = string }
variable "vsphere_allow_unverified_ssl" { type = bool; default = false }

variable "datacenter"         { type = string }
variable "cluster"            { type = string }
variable "datastore"          { type = string }
variable "vm_template"        { type = string; default = "ubuntu-22.04-template" }
variable "external_portgroup" { type = string; default = "PG-External" }
variable "internal_portgroup" { type = string; default = "PG-Internal-VLAN150" }

variable "vm_name"      { type = string; default = "ubuntu-hardened-01" }
variable "vm_cpus"      { type = number; default = 2 }
variable "vm_memory_mb" { type = number; default = 4096 }
variable "vm_disk_gb"   { type = number; default = 40 }

variable "external_ip"            { type = string }
variable "external_prefix_length" { type = number; default = 24 }
variable "external_gateway"       { type = string }
variable "internal_ip"            { type = string; default = "10.200.16.1" }
variable "internal_vlan_id"       { type = number; default = 150 }
variable "dns_servers"            { type = list(string); default = ["1.1.1.1", "8.8.8.8"] }

variable "vm_admin_user"  { type = string; default = "deploy" }
variable "ssh_public_key" { type = string }
