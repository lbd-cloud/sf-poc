ANSIBLE_DIR = ansible
TF_LOCAL    = terraform/local
TF_VSPHERE  = terraform/vsphere
INV_LOCAL   = inventory/local.yml
INV_PROD    = inventory/hosts.yml
VM_NAME     = ubuntu-hardened
VM_EXT_IP   = 192.168.122.10
VM_INT_IP   = 10.200.16.1
DEVICE_IP   = 10.200.16.100
DEVICE_NS   = ns-device

.PHONY: help deps \
        net-up net-down \
        local-up local-apply local-destroy \
        ansible-local ansible-prod \
        prod-plan prod-apply prod-destroy \
        reset soft-reset \
        test test-vlan test-firewall test-services test-hardening

help:
	@echo ""
	@echo "  SETUP"
	@echo "    deps              Install Ansible Galaxy collections"
	@echo "    net-up            Create OVS bridge, VLAN 150 ports, device namespace"
	@echo "    net-down          Tear down OVS bridge and device namespace"
	@echo ""
	@echo "  PROVISIONING"
	@echo "    local-up          net-up + terraform apply"
	@echo "    local-apply       terraform apply only (network must be up)"
	@echo "    local-destroy     terraform destroy + net-down"
	@echo "    ansible-local     Run Ansible against local VM"
	@echo "    ansible-prod      Run Ansible against production VM"
	@echo ""
	@echo "  RESET"
	@echo "    reset             Destroy everything including base image and state"
	@echo "    soft-reset        Destroy VM and state but keep base image"
	@echo ""
	@echo "  PRODUCTION"
	@echo "    prod-plan         terraform plan (vSphere)"
	@echo "    prod-apply        terraform apply (vSphere)"
	@echo "    prod-destroy      terraform destroy (vSphere)"
	@echo ""
	@echo "  TESTS"
	@echo "    test              Run all tests (requires ansible-local to have run)"
	@echo "    test-vlan         VLAN 150 tagging and isolation"
	@echo "    test-firewall     UFW interface rules and port 9000"
	@echo "    test-services     SSH and Nginx interface binding"
	@echo "    test-hardening    Hardening controls"
	@echo ""

deps:
	ansible-galaxy collection install -r $(ANSIBLE_DIR)/requirements.yml --upgrade

net-up:
	sudo bash scripts/setup-network.sh

net-down:
	sudo bash scripts/teardown-network.sh

local-apply:
	cd $(TF_LOCAL) && terraform init && terraform apply -auto-approve
	@echo "Waiting 30s for VM to fully boot and apply cloud-init..."
	@sleep 30
local-up: net-up local-apply

local-destroy:
	cd $(TF_LOCAL) && terraform destroy -auto-approve
	$(MAKE) net-down

ansible-local:
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml -i $(INV_LOCAL)

ansible-prod:
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml -i $(INV_PROD)

reset:
	sudo virsh destroy $(VM_NAME) 2>/dev/null || true
	sudo virsh undefine $(VM_NAME) 2>/dev/null || true
	sudo virsh vol-delete $(VM_NAME).qcow2 --pool default 2>/dev/null || true
	sudo virsh vol-delete $(VM_NAME)-init.iso --pool default 2>/dev/null || true
	sudo virsh vol-delete ubuntu-22.04-base.img --pool default 2>/dev/null || true
	rm -f $(TF_LOCAL)/terraform.tfstate $(TF_LOCAL)/terraform.tfstate.backup
	$(MAKE) net-down 2>/dev/null || true
	@echo "Full reset done. Run: make net-up && make local-apply"

soft-reset:
	sudo virsh destroy $(VM_NAME) 2>/dev/null || true
	sudo virsh undefine $(VM_NAME) 2>/dev/null || true
	sudo virsh vol-delete $(VM_NAME).qcow2 --pool default 2>/dev/null || true
	sudo virsh vol-delete $(VM_NAME)-init.iso --pool default 2>/dev/null || true
	rm -f $(TF_LOCAL)/terraform.tfstate $(TF_LOCAL)/terraform.tfstate.backup
	$(MAKE) net-down 2>/dev/null || true
	@echo "Soft reset done. Base image preserved. Run: make net-up && make local-apply"

prod-plan:
	cd $(TF_VSPHERE) && terraform init && terraform plan

prod-apply:
	cd $(TF_VSPHERE) && terraform init && terraform apply -auto-approve

prod-destroy:
	cd $(TF_VSPHERE) && terraform destroy -auto-approve

test:
	@echo "NOTE: Ansible must have run before tests (make ansible-local)"
	$(MAKE) test-vlan test-firewall test-services test-hardening

test-vlan:
	@echo "\n── VLAN tagging ────────────────────────────────────────────────────────"
	@echo "[host] OVS port vlan_mode and trunks (both must show trunk / [150]):"
	@sudo ovs-vsctl list port veth-host | grep -E "vlan_mode|trunks"
	@TAP=$$(sudo virsh domiflist $(VM_NAME) | awk '/vlan150/{print $$1}'); \
	  sudo ovs-vsctl list port $$TAP | grep -E "vlan_mode|trunks"
	@echo "[host] Untagged ping via veth-ns (no VLAN tag) — must fail:"
	@sudo ip netns exec $(DEVICE_NS) ping -c2 -W1 -I veth-ns $(VM_INT_IP) 2>&1 | tail -2
	@echo "[host] Tagged ping via veth-ns.150 (VLAN 150) — must succeed:"
	@sudo ip netns exec $(DEVICE_NS) ping -c2 -W2 -I veth-ns.150 $(VM_INT_IP) 2>&1 | tail -2

test-firewall:
	@echo "\n── Firewall rules ──────────────────────────────────────────────────────"
	@echo "[host] Port 9000 from device via internal interface — must succeed:"
	@sudo ip netns exec $(DEVICE_NS) nc -zvw2 -s $(DEVICE_IP) $(VM_INT_IP) 9000 2>&1; true
	@echo "[host] SSH from device via internal interface — must fail:"
	@sudo ip netns exec $(DEVICE_NS) nc -zvw2 $(VM_INT_IP) 22 2>&1 || true
	@echo "[host] HTTP from device via internal interface — must fail:"
	@sudo ip netns exec $(DEVICE_NS) nc -zvw2 $(VM_INT_IP) 80 2>&1 || true
	@echo "[host] HTTP on external interface — must succeed:"
	@curl -s -o /dev/null -w "HTTP %{http_code}\n" http://$(VM_EXT_IP)

test-services:
	@echo "\n── Service interface binding ────────────────────────────────────────────"
	@echo "[guest] SSH listen address (must show $(VM_EXT_IP):22 only):"
	@ssh -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no deploy@$(VM_EXT_IP) \
	  "sudo ss -tlnp sport = :22"
	@echo "[guest] Nginx listen address (must show $(VM_EXT_IP):80 only):"
	@ssh -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no deploy@$(VM_EXT_IP) \
	  "sudo ss -tlnp sport = :80"
	@echo "[guest] ens4 has no IP (only ens4.150 does):"
	@ssh -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no deploy@$(VM_EXT_IP) \
	  "ip addr show ens4 | grep 'inet ' || echo 'OK: no IP on ens4'"
	@echo "[guest] ens4.150 has $(VM_INT_IP)/29:"
	@ssh -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no deploy@$(VM_EXT_IP) \
	  "ip addr show ens4.150 | grep inet"

test-hardening:
	@echo "\n── Hardening controls ──────────────────────────────────────────────────"
	@ssh -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no deploy@$(VM_EXT_IP) " \
	  echo '[guest] UFW status:'; sudo ufw status verbose | head -5; \
	  echo '[guest] fail2ban SSH jail:'; sudo fail2ban-client status sshd | grep 'Jail\|Currently'; \
	  echo '[guest] auditd active:'; sudo systemctl is-active auditd; \
	  echo '[guest] unattended-upgrades active:'; sudo systemctl is-active unattended-upgrades; \
	  echo '[guest] PasswordAuthentication (must be no):'; sudo sshd -T | grep passwordauthentication; \
	  echo '[guest] PermitRootLogin (must be no):'; sudo sshd -T | grep permitrootlogin; \
	  echo '[guest] ASLR (must be 2):'; sysctl kernel.randomize_va_space; \
	  echo '[guest] IP forwarding (must be 0):'; sysctl net.ipv4.ip_forward; \
	  echo '[guest] SYN cookies (must be 1):'; sysctl net.ipv4.tcp_syncookies; \
	"
