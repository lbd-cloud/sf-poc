# Ubuntu Server — Automated Deployment & Hardening

Terraform + Ansible. Two environments: local (KVM + OVS) and production (vSphere).

---

## Architecture

```
Internet
    │ (public IP)
    ▼
┌─────────────────────────────┐
│       Ubuntu 22.04 VM       │
│  eth0  — external           │  SSH :22, Nginx :80/:443
│  eth1.150 — internal VLAN   │  TCP :9000 ← 10.200.16.100 only
│             10.200.16.1/29  │
└─────────────────────────────┘
         │
    OVS trunk (VLAN 150)          ← local
    vSwitch port group VLAN 150   ← vSphere
         │
    10.200.16.100  (device)
```

SSH and Nginx are bound to the external interface at the application level (`ListenAddress`, `listen <ip>:80`) and enforced again at the firewall level (UFW). Both must fail independently for a breach of interface segregation.

---

## Repository Structure

```
.
├── Makefile
├── scripts/
│   ├── setup-network.sh      # OVS bridge + device namespace (local only)
│   └── teardown-network.sh
├── terraform/
│   ├── local/                # libvirt/KVM provider
│   └── vsphere/              # VMware vSphere provider
└── ansible/
    ├── site.yml
    ├── inventory/
    │   ├── local.yml         # local KVM VM
    │   └── hosts.yml         # production (gitignored — copy from hosts.yml template inside)
    ├── group_vars/all.yml
    └── roles/
        ├── common/           # updates, NTP, packages
        ├── networking/       # Netplan VLAN sub-interface eth1.150
        ├── webserver/        # Nginx on external IP only
        ├── sshd/             # SSH on external IP only, key auth only
        └── hardening/        # UFW, sysctl, fail2ban, auditd, module blacklist
```

---

## Prerequisites

**Arch Linux (local):**
```bash
sudo pacman -S qemu-full libvirt virt-manager openvswitch dnsmasq
sudo systemctl enable --now libvirtd ovs-vswitchd ovsdb-server
```

**Ansible collections:**
```bash
make deps
```

**Terraform:**
- Local: [`dmacvicar/libvirt`](https://github.com/dmacvicar/terraform-provider-libvirt) provider
- Production: HashiCorp `vsphere` provider

---

## Local Testing

Simulates the full topology on Arch Linux:
- OVS bridge with a VLAN 150 trunk port → VM `eth1` receives 802.1Q-tagged frames
- Network namespace `ns-device` with IP `10.200.16.100` → simulates the internal device
- Terraform provisions the KVM VM via libvirt with two NICs

### 1. Create the network

```bash
make net-up
```

Creates:
- OVS bridge `br-vlan150`
- `veth-host` added to OVS as an access port on VLAN 150
- Namespace `ns-device` with `10.200.16.100/29` — the simulated device

### 2. Provision the VM

```bash
make local-apply
```

Downloads Ubuntu 22.04 cloud image on first run (~600 MB). Creates the VM with:
- `eth0` on libvirt NAT (DHCP, internet access, Ansible entry point)
- `eth1` on the OVS-backed libvirt network (receives VLAN 150 tagged frames)

Get the VM's external IP:
```bash
terraform -chdir=terraform/local output external_ip
```

Update `ansible/inventory/local.yml` with that IP.

### 3. Run Ansible

```bash
make ansible-local
```

Ansible configures `eth1.150` via Netplan (identical to production), binds Nginx and SSH to the external IP, and applies all hardening.

### 4. Verify

```bash
# Web server reachable on external interface
curl http://$(terraform -chdir=terraform/local output -raw external_ip)

# SSH reachable on external interface only
ssh deploy@$(terraform -chdir=terraform/local output -raw external_ip)

# Device at 10.200.16.100 can reach port 9000
sudo ip netns exec ns-device nc -zv 10.200.16.1 9000

# Device cannot reach SSH or Nginx
sudo ip netns exec ns-device nc -zv 10.200.16.1 22    # must fail
sudo ip netns exec ns-device nc -zv 10.200.16.1 80    # must fail
```

### 5. Teardown

```bash
make local-destroy
```

---

## Production (vSphere)

### 1. Configure Terraform

```bash
cp terraform/vsphere/terraform.tfvars.example terraform/vsphere/terraform.tfvars
# Fill in vCenter credentials, IPs, portgroups
```

The vSwitch port group for the internal NIC must already be configured with VLAN ID 150 in trunk mode.

### 2. Provision

```bash
make prod-plan
make prod-apply
```

### 3. Configure inventory

```bash
cp ansible/inventory/local.yml ansible/inventory/hosts.yml
# Set ansible_host, external_ip, external_gateway to the values from terraform output
```

### 4. Run Ansible

```bash
make ansible-prod
```

---

## Hardening Summary

| Area | Controls |
|---|---|
| Interface segregation | `ListenAddress` / `listen <ip>:80` (application) + UFW (kernel) |
| SSH access | Key auth only, root disabled, external interface only, fail2ban |
| Firewall | UFW default-deny; port 9000 open only from `10.200.16.100` on `eth1.150` |
| Kernel | sysctl: no forwarding, SYN cookies, ASLR, ptrace restriction, rp_filter |
| Audit | auditd: identity files, privilege escalation, network config, module loads |
| Patching | unattended-upgrades (security stream) |
| Attack surface | Unused packages and kernel modules removed/blacklisted |
