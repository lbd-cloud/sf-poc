# Ubuntu Server — Automated Deployment & Hardening

Terraform + Ansible. Provisions a hardened Ubuntu 22.04 VM with two network interfaces, VLAN 150 segmentation, and CIS-aligned hardening. Runs locally on Arch Linux via KVM + OVS, and in production via VMware vSphere.

---

## Reasoning
 OVS provided the simplest and most well documented way of spinning this arch locally. Since this code is aimed as  PoC only, and i wanted to have a bit of fun with OVS ;) that was my choice.  KVM was choosen due to be lightweight and connectivity constraints during test. For demo purposes VirtualBox would also be a possibility.
 Hardening was done thinking about the general idea behind the test, which seems to be evaluating basic linux knowledge and verify how a simple isolation/segregation setup would be done for nodes running at managed datacenter.
 Code was structured to be clear, direct, and runnable from local machines. Still, some bugs may appear due to interface/network topology and local environment variations.


---
## Architecture

```
Internet
    │ (public IP)
    ▼
┌─────────────────────────────────────────┐
│           Ubuntu 22.04 VM               │
│  ens3 / eth0  — external interface      │  SSH :22, Nginx :80/:443
│  ens4.150     — internal VLAN 150       │  TCP :9000 ← 10.200.16.100 only
│               10.200.16.1/29            │
└─────────────────────────────────────────┘
         │
    OVS bridge br-vlan150
    Both ports: vlan_mode=trunk, trunks=[150]
    Only 802.1Q frames tagged VLAN 150 are forwarded
         │
    10.200.16.100 (ns-device / real device)
```

SSH and Nginx are bound to the external interface at the application level (`ListenAddress`, `listen <ip>:80`) and enforced again at the kernel level via UFW. Both controls must fail independently for a breach of interface segregation.

---

## Repository Structure

```
.
├── Makefile
├── scripts/
│   ├── setup-network.sh      # OVS bridge, VLAN 150 trunk ports, device namespace
│   └── teardown-network.sh
├── terraform/
│   ├── local/                # libvirt/KVM provider (Arch Linux)
│   └── vsphere/              # VMware vSphere provider (production)
└── ansible/
    ├── site.yml
    ├── inventory/
    │   ├── local.yml         # local KVM VM
    │   └── hosts.yml         # production 
    ├── group_vars/all.yml
    └── roles/
        ├── common/           # updates, NTP, packages, unattended-upgrades
        ├── networking/       # Netplan: ens4.150 VLAN sub-interface + host route
        ├── webserver/        # Nginx bound to external IP only
        ├── sshd/             # SSH bound to external IP, key auth only
        └── hardening/        # UFW, sysctl, fail2ban, auditd, module blacklist
```

---

## Host Dependencies (if running Arch Linux)

```bash
# KVM, libvirt, OVS
sudo pacman -S qemu-full libvirt virt-manager openvswitch dnsmasq cdrtools

# Enable services
sudo systemctl enable --now libvirtd ovs-vswitchd ovsdb-server

# Terraform (via mise, tfenv, or direct binary)
# https://developer.hashicorp.com/terraform/install

# Ansible
pip install ansible

# Ansible collections
make deps
```

### Host firewall (UFW)

UFW blocks forwarded packets by default, breaking libvirt NAT. Allow it:

```bash
sudo iptables -I FORWARD -i virbr0 -j ACCEPT
sudo iptables -I FORWARD -o virbr0 -j ACCEPT
```

To persist across reboots, add to `/etc/ufw/before.rules` before the `*filter` line:

```
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s 192.168.122.0/24 -j MASQUERADE
COMMIT
```

Set in `/etc/default/ufw`:
```
DEFAULT_FORWARD_POLICY=ACCEPT
```

Then: `sudo ufw reload`

---

## Local Testing (Arch Linux — KVM + OVS)

### Network topology

```
ns-device (veth-ns.150, VLAN 150 tagged)
    └── veth-host [OVS trunk, trunks=150]
            └── br-vlan150 (OVS bridge = vSwitch)
                    └── vnet1 [OVS trunk, trunks=150]
                            └── ens4 (VM raw interface)
                                    └── ens4.150 (VLAN sub-interface, 10.200.16.1/29)
```

Both OVS ports (`veth-host` and the VM tap) are configured as trunk ports with `trunks=[150]` — only 802.1Q frames tagged VLAN 150 are forwarded, matching the assignment requirement.

The device at `10.200.16.100` uses a VLAN sub-interface (`veth-ns.150`) inside a network namespace, so it sends and receives tagged frames explicitly.

### Note on 10.200.16.100 subnet

`10.200.16.100` is outside the `/29` subnet (`10.200.16.0–10.200.16.7`). The Netplan config includes a host route (`10.200.16.100/32 on-link via ens4.150`) so the VM replies go back through the correct interface instead of the default gateway.

### Step 1 — Create the network

```bash
make net-up
```

Creates OVS bridge `br-vlan150`, both trunk ports, device namespace `ns-device` with `veth-ns.150` at `10.200.16.100/29`, and the libvirt network backed by OVS.

### Step 2 — Provision the VM

```bash
make local-apply
```

Downloads Ubuntu 22.04 cloud image on first run (~600 MB). Creates the VM via Terraform with:
- `ens3` on libvirt NAT (`192.168.122.10`, static) — external interface
- `ens4` on OVS-backed libvirt network — receives VLAN 150 tagged frames

### Step 3 — Configure and harden

```bash
# Accept the new host key
ssh-keyscan -H 192.168.122.10 >> ~/.ssh/known_hosts
make ansible-local
```

### Step 4 — Run tests

```bash
make test
```

Or individually:

```bash
make test-vlan        # VLAN tagging and isolation
make test-firewall    # UFW interface rules and port 9000
make test-services    # SSH and Nginx interface binding
make test-hardening   # fail2ban, auditd, sysctl, password auth
```

### Reset options

```bash
# Keep base image (~600 MB, i know its not much but my connection was really bad last days), destroy VM and recreate from scratch
make soft-reset
make net-up
make local-apply
ssh-keyscan -H 192.168.122.10 >> ~/.ssh/known_hosts
make ansible-local
make test

# Full reset including base image (next apply re-downloads so tf can find it locally)
make reset
make net-up
make local-apply
ssh-keyscan -H 192.168.122.10 >> ~/.ssh/known_hosts
make ansible-local
make test

---

## Production Deployment (Here vSphere was supposed)

### Step 1 — Configure Terraform

```bash
cp terraform/vsphere/terraform.tfvars.example terraform/vsphere/terraform.tfvars
# Fill in vCenter credentials, IPs, port groups
```

The internal port group (`PG-Internal-VLAN150`) must already be configured as a VLAN 150 trunk port on the vSwitch.

### Step 2 — Provision

```bash
make prod-plan
make prod-apply
```

### Step 3 — Configure inventory and run Ansible

```bash
cp ansible/inventory/local.yml ansible/inventory/hosts.yml
# Set ansible_host, external_ip, external_gateway to values from terraform output
ssh-keyscan -H <external_ip> >> ~/.ssh/known_hosts
make ansible-prod
```

---

## Hardening Summary

| Area | Controls |
|---|---|
| Interface segregation | `ListenAddress` / `listen <ip>:80` (application) + UFW per-interface rules (kernel) |
| VLAN enforcement | Both OVS ports trunk-only VLAN 150 — untagged and wrong-VLAN frames dropped |
| SSH | Key auth only, root disabled, external interface only, idle timeout 5 min |
| Firewall | UFW default-deny; port 9000 open only from `10.200.16.100` on `ens4.150` |
| Brute force | fail2ban: 5 attempts / 10 min → 1-hour ban |
| Kernel | sysctl: no IP forwarding, SYN cookies, ASLR=2, ptrace restriction, rp_filter |
| Audit | auditd: identity files, privilege escalation, network config, kernel module loads |
| Patching | unattended-upgrades (security stream) |
| Attack surface | Unused packages removed, kernel modules blacklisted |

---

## Getting a Public IP (Was not viable at test env)

**Locally:** the VM uses `192.168.122.10` which was how it was tested locally for dev purposes only (libvirt NAT) — reachable from host machine only.

**vSphere:** set `external_ip` in `terraform.tfvars` to a routable address from datacenter pool. Terraform assigns it directly to the VM's external NIC via the customize block.

**Any VPS/cloud provider:** replace `terraform/vsphere/` with the provider of choice. The Ansible roles are untouched — `external_ip` flows into `ListenAddress` and `listen <ip>:80` regardless of where it comes from.
