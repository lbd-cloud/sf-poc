# Ubuntu Server — Automated Deployment & Hardening
> Terraform + Ansible | VMware vSphere | VLAN-segmented networking | CIS-aligned hardening

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture & Design Decisions](#2-architecture--design-decisions)
3. [Repository Structure](#3-repository-structure)
4. [Prerequisites](#4-prerequisites)
5. [Quick Start](#5-quick-start)
6. [Terraform — Infrastructure Provisioning](#6-terraform--infrastructure-provisioning)
7. [Ansible — Configuration & Hardening](#7-ansible--configuration--hardening)
8. [Security Intentions](#8-security-intentions)
9. [Networking Details](#9-networking-details)
10. [Known Limitations & Trade-offs](#10-known-limitations--trade-offs)

---

## 1. Overview

This repository automates the full lifecycle of a hardened Ubuntu 22.04 LTS server:

| Phase | Tool | What it does |
|---|---|---|
| Provisioning | Terraform | Spins up a VM on vSphere with two NICs — external (internet-facing) and internal (VLAN 150) |
| Configuration | Ansible | Installs Nginx (web server) and OpenSSH, both bound exclusively to the external interface |
| Hardening | Ansible | Applies firewall rules, SSH lockdown, kernel parameter tuning, and service minimisation |

The driving principle is **least privilege at every layer**: the VM exposes only what is explicitly required, on exactly the interface it belongs to.

---

## 2. Architecture & Design Decisions

```
Internet
    │
    │  (any public IP)
    ▼
┌─────────────────────────────────┐
│           Ubuntu 22.04 VM       │
│                                 │
│  eth0 ── External Interface     │  ← Nginx :80/:443, SSH :22
│  eth1 ── Internal Interface     │  ← VLAN 150 tag, TCP :9000 only
│           10.200.16.x/29        │
└─────────────────────────────────┘
    │
    │  vSwitch (VLAN 150, tagged)
    │
    ▼
 Device @ 10.200.16.100/29
```

### Why vSphere?
The requirement mentions **vswitches** and **VLAN-tagged ports** — these are VMware vSphere primitives. Terraform's `vsphere` provider maps directly to these concepts (Port Groups, DVS, VLAN IDs), making it the natural choice.

### Why two separate Port Groups?
- The **external Port Group** carries untagged traffic (VLAN 0 / access mode) — the VM gets a routable public IP.
- The **internal Port Group** is set to VLAN 150 (trunk/tagged mode on the vSwitch side, the guest OS sees an 802.1Q-tagged interface). This isolates internal traffic without requiring a physical NIC per segment.

### Why Nginx instead of Apache?
Nginx has a smaller memory footprint, a simpler `listen` directive syntax for binding to a specific IP, and is more idiomatic for a modern hardened server. The `listen <external_ip>:80` directive ensures the daemon never accidentally responds on the internal interface.

### Why bind SSH to the external interface only?
The internal subnet (`10.200.16.0/29`) has only 6 usable host addresses. Exposing SSH there would widen the attack surface to any device that reaches the internal VLAN — defeating the purpose of segmentation. Management access is centralised on the external interface and further restricted by `AllowUsers` and key-based auth only.

---

## 3. Repository Structure

```
.
├── terraform/
│   ├── provider.tf          # vSphere provider + version pins
│   ├── variables.tf         # All inputs (datacenter, cluster, IPs, credentials)
│   ├── main.tf              # VM resource, two NICs, clone from template
│   ├── outputs.tf           # External IP, internal IP
│   └── terraform.tfvars.example  # Copy → terraform.tfvars and fill in
│
├── ansible/
│   ├── ansible.cfg          # Inventory path, remote user, private key
│   ├── inventory/
│   │   └── hosts.yml        # Dynamic or static inventory (external IP from TF output)
│   ├── group_vars/
│   │   └── all.yml          # Global variables (external_ip, internal_ip, vlan_id…)
│   ├── roles/
│   │   ├── common/          # OS updates, locale, NTP, minimal package set
│   │   ├── networking/      # Netplan config — VLAN sub-interface on eth1
│   │   ├── webserver/       # Nginx install + virtualhost bound to external IP
│   │   ├── sshd/            # SSH hardening (keys only, no root, bound to external IP)
│   │   └── hardening/       # UFW rules, sysctl, auditd, fail2ban, unattended-upgrades
│   └── site.yml             # Master playbook — runs all roles in order
│
├── .gitignore               # Excludes *.tfvars, *.pem, inventory secrets
└── README.md
```

---

## 4. Prerequisites

### Local machine
| Tool | Minimum version |
|---|---|
| Terraform | 1.7+ |
| Ansible | 2.15+ |
| Python | 3.10+ (for Ansible) |
| `community.general` collection | `ansible-galaxy collection install community.general` |

### vSphere environment
- vCenter Server (or standalone ESXi with vSphere provider support)
- An Ubuntu 22.04 VM template already uploaded to a datastore
- Two Port Groups configured on a vSwitch:
  - `PG-External` — VLAN 0 (or access port), routable uplink
  - `PG-Internal-VLAN150` — VLAN 150, connected to the internal segment where `10.200.16.100` lives
- A service account with **VirtualMachine.Provision** and **Network.Assign** privileges

### Credentials
Copy `terraform/terraform.tfvars.example` → `terraform/terraform.tfvars` and fill in:

```hcl
vsphere_user       = "svc-terraform@vsphere.local"
vsphere_password   = "changeme"
vsphere_server     = "vcenter.example.com"
external_ip        = "203.0.113.10"   # your chosen public IP
external_gateway   = "203.0.113.1"
```

> **Never commit `terraform.tfvars` — it is in `.gitignore`.**

---

## 5. Quick Start

```bash
# 1. Clone
git clone https://github.com/lbd-cloud/sf-poc.git
cd ubuntu-hardening

# 2. Terraform — provision the VM
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars
terraform init
terraform plan
terraform apply

# 3. Capture the external IP into Ansible inventory
terraform output -raw external_ip   # note this value

# 4. Ansible — configure and harden
cd ../ansible
# edit inventory/hosts.yml — set ansible_host to the external IP above
ansible-galaxy collection install community.general
ansible-playbook site.yml

# 5. Verify
curl http://<external_ip>           # should return Nginx default page
ssh deploy@<external_ip>            # key-based login only
```

End-to-end time: ~8 minutes (VM clone ~5 min, Ansible ~3 min).

---

## 6. Terraform — Infrastructure Provisioning

### What it creates
1. **VM** — cloned from the Ubuntu 22.04 template, 2 vCPU / 4 GB RAM (configurable).
2. **NIC 0 (eth0)** — attached to `PG-External`, assigned the chosen public IP via cloud-init / Netplan customisation.
3. **NIC 1 (eth1)** — attached to `PG-Internal-VLAN150`. The vSwitch port is already configured for VLAN 150; the guest OS will receive tagged frames and needs a VLAN sub-interface (`eth1.150`) — handled by the Ansible `networking` role.

### Key variables

| Variable | Description |
|---|---|
| `vm_template` | Name of the Ubuntu 22.04 template in vSphere |
| `datacenter` | vSphere Datacenter name |
| `cluster` | Compute cluster or host |
| `datastore` | Datastore for the VM disk |
| `external_portgroup` | Port Group name for the external NIC |
| `internal_portgroup` | Port Group name for the internal NIC (VLAN 150) |
| `external_ip` | Public IP address to assign |
| `internal_ip` | IP within `10.200.16.0/29` to assign to the VM |

### State management
For a production scenario, the `terraform` block in `provider.tf` includes a commented-out `backend "s3"` block. For this assignment, local state is used for simplicity.

---

## 7. Ansible — Configuration & Hardening

Roles are applied in this order by `site.yml`:

### `common`
- Full `apt upgrade`
- Sets timezone, NTP (chrony), and hostname
- Removes unnecessary packages: `telnet`, `rsh-*`, `nis`, `talk`
- Installs baseline tools: `curl`, `ca-certificates`, `unzip`

### `networking`
- Writes a Netplan configuration:
  - `eth0` — static IP (external), default gateway
  - `eth1.150` — VLAN sub-interface with VLAN ID 150, static IP from `10.200.16.0/29`
- Applies the config with `netplan apply`
- This satisfies the requirement: the vSwitch sends tagged frames on VLAN 150; the guest creates a sub-interface that strips the tag and presents it as `eth1.150`

### `webserver`
- Installs `nginx`
- Deploys a virtualhost that contains **`listen <external_ip>:80`** — Nginx will not bind to the internal interface
- Optionally configures a self-signed TLS certificate for port 443 (commented section)
- Starts and enables the service

### `sshd`
- Rewrites `/etc/ssh/sshd_config` with:
  - `ListenAddress <external_ip>` — SSH daemon only listens on the external interface
  - `PasswordAuthentication no`
  - `PermitRootLogin no`
  - `AllowUsers deploy` (dedicated non-root user)
  - `MaxAuthTries 3`
  - Strong `KexAlgorithms`, `Ciphers`, and `MACs`

### `hardening`
- **UFW firewall**:
  - Default: deny inbound, allow outbound
  - Allow TCP 22 and 80/443 on `eth0` (external)
  - Allow TCP 9000 from `10.200.16.100` on `eth1.150` (internal only)
  - All other inbound traffic dropped
- **sysctl** hardening (`/etc/sysctl.d/99-hardening.conf`):
  - Disable IP forwarding and source routing
  - Enable TCP SYN cookies
  - Restrict `dmesg` access (`kernel.dmesg_restrict`)
  - Disable ICMP redirects
- **fail2ban** — SSH jail enabled, 5 retries, 1-hour ban
- **auditd** — basic rules for privileged command execution and `/etc/passwd` changes
- **unattended-upgrades** — security patches applied automatically

---

## 8. Security Intentions

| Goal | Implementation |
|---|---|
| Interface segregation | Nginx and SSH bind only to the external IP; UFW enforces this at the kernel level too |
| Internal service isolation | Port 9000 is open **only** from `10.200.16.100`; no broad internal allow rule |
| No password auth | SSH key-only; passwords disabled globally |
| Reduced attack surface | Unnecessary services and packages removed in `common` role |
| Brute-force protection | fail2ban on SSH |
| Kernel hardening | sysctl parameters follow CIS Ubuntu 22.04 Benchmark (Level 1) |
| Audit trail | auditd records sensitive system calls |
| Patch cadence | unattended-upgrades for security stream |

The layered approach means that even if UFW were misconfigured, the application-level `listen` directives would still prevent services from responding on the wrong interface.

---

## 9. Networking Details

### Subnet `10.200.16.0/29`
```
Network:    10.200.16.0
Broadcast:  10.200.16.7
Usable:     10.200.16.1 – 10.200.16.6  (6 hosts)
Device:     10.200.16.100  ← this is outside the /29 range*
```

> ⚠️ **Note**: `10.200.16.100` is technically outside the `/29` subnet (`10.200.16.0–10.200.16.7`). The practical assumption is that the device at `.100` is reachable over the vSwitch/VLAN regardless of strict subnet membership — i.e., Layer 2 adjacency is guaranteed by the shared VLAN, and the firewall rule is host-specific (`from 10.200.16.100`). The VM's internal IP is assigned from within the `/29` (e.g., `10.200.16.1`).

### VLAN tagging flow
```
VM (eth1.150) ──[802.1Q tag=150]──▶ vSwitch trunk port ──▶ PG-Internal-VLAN150
                                                                    │
                                                             VLAN 150 segment
                                                                    │
                                                         10.200.16.100 (device)
```

The vSwitch port group is configured with VLAN ID 150 in "VLAN trunk" mode — it passes tagged frames. The VM's `eth1.150` sub-interface handles the tagging transparently from the application layer.

---

## 10. Known Limitations & Trade-offs

| Item | Note |
|---|---|
| vSphere dependency | The Terraform code targets vSphere. Adapting to AWS/GCP/Azure would require replacing the provider and removing VLAN sub-interface logic (cloud providers handle VLAN segmentation differently) |
| Template requirement | A pre-baked Ubuntu 22.04 template with `cloud-init` support must exist in vSphere. Building the template itself (e.g., with Packer) is out of scope |
| TLS certificate | A self-signed cert is generated for HTTPS. Production deployments should use Let's Encrypt via `certbot` |
| Port 9000 service | The assignment requires TCP 9000 to be reachable; the service listening on it is assumed to be deployed separately. The firewall rule and network path are fully prepared |
| Single-region | No HA or redundancy — this is a single VM as specified |
