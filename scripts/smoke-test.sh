#!/usr/bin/env bash
# =============================================================================
# scripts/smoke-test.sh
# Quick post-deploy verification for the LOCAL (Vagrant) environment.
# Run after: make local-up
#
# Usage:  bash scripts/smoke-test.sh [external_ip] [internal_ip]
# =============================================================================
set -euo pipefail

EXTERNAL_IP="${1:-192.168.56.10}"
INTERNAL_IP="${2:-192.168.57.10}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_USER="${SSH_USER:-vagrant}"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=5"

PASS=0
FAIL=0

ok()   { echo "  ✓  $*"; ((PASS++)); }
fail() { echo "  ✗  $*"; ((FAIL++)); }
info() { echo ""; echo "── $* ──────────────────────────────────────────────────"; }

# ── HTTP reachability ─────────────────────────────────────────────────────────
info "Web server (Nginx)"

if curl -sf --max-time 5 "http://${EXTERNAL_IP}" -o /dev/null; then
  ok "Nginx responds on external IP (${EXTERNAL_IP}:80)"
else
  fail "Nginx NOT reachable on ${EXTERNAL_IP}:80"
fi

if ! curl -sf --max-time 5 "http://${INTERNAL_IP}" -o /dev/null 2>/dev/null; then
  ok "Nginx correctly NOT reachable on internal IP (${INTERNAL_IP}:80)"
else
  fail "Nginx is responding on internal IP ${INTERNAL_IP}:80 — should be blocked"
fi

# ── SSH reachability ──────────────────────────────────────────────────────────
info "SSH access"

if ssh $SSH_OPTS "${SSH_USER}@${EXTERNAL_IP}" "echo ok" &>/dev/null; then
  ok "SSH connects on external IP (${EXTERNAL_IP}:22)"
else
  fail "SSH NOT reachable on ${EXTERNAL_IP}:22"
fi

if ! ssh $SSH_OPTS -o BatchMode=yes "${SSH_USER}@${INTERNAL_IP}" "echo ok" &>/dev/null; then
  ok "SSH correctly NOT reachable on internal IP (${INTERNAL_IP}:22)"
else
  fail "SSH is reachable on internal IP ${INTERNAL_IP}:22 — should be blocked"
fi

# ── Remote checks via SSH ─────────────────────────────────────────────────────
info "Remote service verification"

run_remote() {
  ssh $SSH_OPTS "${SSH_USER}@${EXTERNAL_IP}" "$@" 2>/dev/null
}

# Nginx listen addresses
NGINX_LISTEN=$(run_remote "sudo ss -tlnp sport = :80 | grep nginx || true")
if echo "$NGINX_LISTEN" | grep -q "${EXTERNAL_IP}:80"; then
  ok "Nginx bound to external IP ${EXTERNAL_IP}:80"
else
  fail "Nginx listen address unexpected: $NGINX_LISTEN"
fi

# SSH listen addresses
SSH_LISTEN=$(run_remote "sudo ss -tlnp sport = :22")
if echo "$SSH_LISTEN" | grep -q "${EXTERNAL_IP}:22"; then
  ok "SSH bound to external IP ${EXTERNAL_IP}:22"
else
  fail "SSH listen address unexpected: $SSH_LISTEN"
fi
if echo "$SSH_LISTEN" | grep -q "0.0.0.0:22"; then
  fail "SSH is also listening on 0.0.0.0 — should be restricted to external IP"
else
  ok "SSH is NOT listening on 0.0.0.0 (correctly restricted)"
fi

# UFW status
UFW_STATUS=$(run_remote "sudo ufw status verbose")
if echo "$UFW_STATUS" | grep -q "Status: active"; then
  ok "UFW is active"
else
  fail "UFW is NOT active"
fi

# fail2ban
F2B_STATUS=$(run_remote "sudo fail2ban-client status sshd 2>/dev/null || true")
if echo "$F2B_STATUS" | grep -q "Jail list"; then
  ok "fail2ban SSH jail is running"
else
  fail "fail2ban SSH jail NOT found"
fi

# auditd
AUDITD=$(run_remote "sudo systemctl is-active auditd")
if [ "$AUDITD" = "active" ]; then
  ok "auditd is running"
else
  fail "auditd is NOT running (status: $AUDITD)"
fi

# Password authentication disabled
SSH_PASS_AUTH=$(run_remote "sudo sshd -T | grep -i passwordauthentication")
if echo "$SSH_PASS_AUTH" | grep -qi "no"; then
  ok "PasswordAuthentication is disabled in sshd"
else
  fail "PasswordAuthentication is NOT disabled: $SSH_PASS_AUTH"
fi

# ── Port 9000 firewall ────────────────────────────────────────────────────────
info "Port 9000 (internal service)"

# nc may not be installed; tolerate failure
if command -v nc &>/dev/null; then
  if nc -zw2 "${INTERNAL_IP}" 9000 &>/dev/null; then
    ok "TCP 9000 is reachable on internal IP (firewall allows it)"
  else
    # No service is running on 9000 — connection refused is still a firewall pass
    # A DROP would time out; a REJECT/refused means the packet got through UFW
    NC_ERR=$(nc -zw2 "${INTERNAL_IP}" 9000 2>&1 || true)
    if echo "$NC_ERR" | grep -qi "refused"; then
      ok "TCP 9000 on internal IP: UFW allows it (connection refused = no service, not blocked)"
    else
      fail "TCP 9000 on internal IP appears to be blocked or timing out: $NC_ERR"
    fi
  fi
  if nc -zw2 "${EXTERNAL_IP}" 9000 &>/dev/null; then
    fail "TCP 9000 is reachable on EXTERNAL IP — should be blocked"
  else
    ok "TCP 9000 correctly blocked on external IP ${EXTERNAL_IP}"
  fi
else
  echo "  -  nc not available on host — skipping port 9000 test"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════"
echo "  Results:  ${PASS} passed  |  ${FAIL} failed"
echo "═══════════════════════════════════════════════"
echo ""

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
