#!/usr/bin/env bash
#
# setup_pi.sh — Standalone Raspberry Pi provisioning for a Pyronear engine.
#
# This REPLACES the `rpi-init.yml` Ansible play for the case where the Pyronear
# server infrastructure (OpenVPN / mediamtx / reverse-ssh) is NOT reachable.
#
# It installs ALL the system dependencies an engine needs, using FAKE
# credentials where a server would normally provide real ones. The steps that
# strictly require a remote Pyronear server are intentionally NOT performed
# (they only matter for the real fleet), but their packages ARE installed:
#
#   - OpenVPN  -> package installed, fake auth file written, NOT connected
#                 (the real client.conf is normally fetched from the VPN server)
#   - mediamtx -> stream registration is a server-side step, SKIPPED here
#   - reverse-ssh tunnel -> needs the bastion server, SKIPPED here
#
# Everything else (apt deps, Docker + compose, NetworkManager/Wi-Fi, Grafana
# Alloy, static IP) is installed so the engine can run locally.
#
# Run ON the Pi, as root. The (optional) first argument is the static IP to
# assign to this Pi — this is the IP you will later put in `ansible_host` /
# `static_ip_address` in the sister repo so `make deploy-one-engine` can reach it:
#   sudo ./setup_pi.sh                 # uses the default static IP 192.168.1.99
#   sudo ./setup_pi.sh 192.168.1.50    # set this Pi's static IP to 192.168.1.50
#
# Optional overrides (all have safe FAKE defaults):
#   WIFI_SSID, WIFI_PASSWORD          Wi-Fi connection (default: ExampleWifi; "" to skip)
#   STATIC_IP, STATIC_GW, STATIC_DNS  static IP (default: 192.168.1.99/.1; "" to skip)
#   STATIC_IFACE                      interface for the static IP (default: eth0)
#   OPENVPN_PASSWORD                  fake VPN password written to auth.txt
#   INSTALL_ALLOY                     "true"/"false" install Grafana Alloy (default: true)
#   PULL_ENGINE_IMAGE                 "true"/"false" pre-pull the engine image (default: false)
#   ENGINE_TAG                        docker tag to pre-pull (default: 1.0.12)
#   ENGINE_USER                       local user added to the docker group (default: pi)
#
# Examples:
#   sudo ./setup_pi.sh 192.168.1.50                 # set static IP 192.168.1.50
#   sudo ./setup_pi.sh                              # uses the example defaults
#   sudo STATIC_IP="" WIFI_SSID="" ./setup_pi.sh    # keep DHCP, no Wi-Fi profile
#
set -uo pipefail

# ---------------------------------------------------------------------------
# Positional argument: the static IP to assign to this Pi (optional).
#   ./setup_pi.sh 192.168.1.50   ->  same as  STATIC_IP=192.168.1.50 ./setup_pi.sh
# An explicit STATIC_IP env var still wins if both are given.
# ---------------------------------------------------------------------------
case "${1:-}" in
  -h|--help)
    grep -E '^#( |$)' "$0" | sed 's/^#\s\{0,1\}//'
    exit 0
    ;;
  ?*)
    STATIC_IP="${STATIC_IP:-$1}"
    ;;
esac

# ---------------------------------------------------------------------------
# Configuration (FAKE example defaults — override via environment variables)
#
# NOTE: STATIC_IP and WIFI_SSID now ship with EXAMPLE values (matching the
# example-station host_vars) so the script exercises every step. They only
# CREATE NetworkManager profiles — nothing is activated until the next reboot.
# To skip either step, pass an empty value, e.g.  STATIC_IP="" WIFI_SSID=""
# ---------------------------------------------------------------------------
WIFI_SSID="${WIFI_SSID:-ExampleWifi}"
WIFI_PASSWORD="${WIFI_PASSWORD:-example-wifi-password}"

# Static IP defaults match host_vars/example-station/vars.yml (the ".99" convention).
STATIC_IP="${STATIC_IP:-192.168.1.99}"
STATIC_GW="${STATIC_GW:-192.168.1.1}"
STATIC_DNS="${STATIC_DNS:-8.8.8.8}"
STATIC_IFACE="${STATIC_IFACE:-eth0}"
STATIC_PREFIX="${STATIC_PREFIX:-24}"

OPENVPN_PASSWORD="${OPENVPN_PASSWORD:-example-openvpn-password}"

INSTALL_ALLOY="${INSTALL_ALLOY:-true}"
PULL_ENGINE_IMAGE="${PULL_ENGINE_IMAGE:-false}"
ENGINE_TAG="${ENGINE_TAG:-1.0.12}"
ENGINE_USER="${ENGINE_USER:-pi}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
WARNINGS=()

log()  { printf '%s\n' "${BLUE}==>${NC} $*"; }
ok()   { printf '%s\n' "${GREEN} ok ${NC} $*"; }
warn() { printf '%s\n' "${YELLOW}warn${NC} $*"; WARNINGS+=("$*"); }
die()  { printf '%s\n' "${RED}FATAL${NC} $*" >&2; exit 1; }

# Run a step that must succeed for the engine to work.
require() {
  local desc="$1"; shift
  log "$desc"
  if "$@"; then ok "$desc"; else die "$desc — failed. See output above."; fi
}

# Run a step that is allowed to fail (server-dependent / optional). Never aborts.
optional() {
  local desc="$1"; shift
  log "$desc"
  if "$@"; then ok "$desc"; else warn "$desc — skipped/failed (non-fatal)."; fi
}

[[ $EUID -eq 0 ]] || die "Run as root: sudo $0"

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# 1. Base system packages  (role: common + wifi)
# ---------------------------------------------------------------------------
apt_base() {
  apt-get update -y || return 1
  apt-get upgrade -y || return 1
  apt-get install -y --no-install-recommends \
    git curl ca-certificates gnupg lsb-release \
    network-manager openvpn || return 1
  apt-get autoremove -y || true
}
require "Install base packages (git, curl, network-manager, openvpn)" apt_base

# ---------------------------------------------------------------------------
# 2. Docker + Docker Compose plugin  (role: docker / geerlingguy.docker)
# ---------------------------------------------------------------------------
install_docker() {
  if command -v docker >/dev/null 2>&1; then
    return 0
  fi
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh || return 1
  sh /tmp/get-docker.sh || return 1
  rm -f /tmp/get-docker.sh
}
require "Install Docker + Compose plugin" install_docker

optional "Enable & start docker service"      systemctl enable --now docker
optional "Add user '${ENGINE_USER}' to docker group" usermod -aG docker "${ENGINE_USER}"

# ---------------------------------------------------------------------------
# 3. Wi-Fi connection  (role: wifi) — only if WIFI_SSID provided
# ---------------------------------------------------------------------------
configure_wifi() {
  if nmcli -t -f NAME con show | grep -qF "${WIFI_SSID}"; then
    nmcli con mod "${WIFI_SSID}" \
      wifi-sec.psk "${WIFI_PASSWORD}" \
      connection.autoconnect-priority 10 \
      connection.autoconnect-retries 0
  else
    nmcli con add type wifi ifname wlan0 con-name "${WIFI_SSID}" \
      ssid "${WIFI_SSID}" wifi-sec.key-mgmt wpa-psk \
      wifi-sec.psk "${WIFI_PASSWORD}" connection.autoconnect yes \
      connection.autoconnect-priority 10 \
      connection.autoconnect-retries 0
  fi
}
if [[ -n "${WIFI_SSID}" ]]; then
  optional "Configure Wi-Fi connection '${WIFI_SSID}'" configure_wifi
else
  log "Wi-Fi: WIFI_SSID empty — skipping (Pi assumed on ethernet)."
fi

# ---------------------------------------------------------------------------
# 4. OpenVPN — install the package + fake auth, but DO NOT connect.
#    (The real /etc/openvpn/client.conf is fetched from the VPN server during
#     the normal fleet init; here the server is unreachable, so we only make
#     sure the dependency is present.)
# ---------------------------------------------------------------------------
setup_openvpn_fake() {
  install -d -m 0755 /etc/openvpn
  printf '%s' "${OPENVPN_PASSWORD}" > /etc/openvpn/auth.txt
  chmod 600 /etc/openvpn/auth.txt
  cat > /etc/openvpn/client.conf.example <<'EOF'
# PLACEHOLDER — no real VPN connection on a standalone Pi.
# On the real fleet, /etc/openvpn/client.conf is generated from the VPN server
# (pyronear.openvpn role, get_conf.yml) and references askpass /etc/openvpn/auth.txt
EOF
}
optional "Install OpenVPN (package + fake auth, not connected)" setup_openvpn_fake

# ---------------------------------------------------------------------------
# 5. Grafana Alloy monitoring agent (role: grafana.grafana.alloy) — optional.
#    Installs fine offline; it simply won't ship metrics without valid creds.
# ---------------------------------------------------------------------------
install_alloy() {
  if command -v alloy >/dev/null 2>&1; then return 0; fi
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg || return 1
  echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    > /etc/apt/sources.list.d/grafana.list
  apt-get update -y || return 1
  apt-get install -y alloy || return 1
}
if [[ "${INSTALL_ALLOY}" == "true" ]]; then
  optional "Install Grafana Alloy" install_alloy
else
  log "Alloy: INSTALL_ALLOY=false — skipping."
fi

# ---------------------------------------------------------------------------
# 6. Static IP  (role: static_ip) — only if STATIC_IP provided
# ---------------------------------------------------------------------------
configure_static_ip() {
  [[ -n "${STATIC_GW}" ]] || { warn "STATIC_GW empty — cannot set static IP."; return 1; }
  nmcli con delete "${STATIC_IFACE}-static" 2>/dev/null || true
  nmcli con add type ethernet ifname "${STATIC_IFACE}" con-name "${STATIC_IFACE}-static" \
    ipv4.addresses "${STATIC_IP}/${STATIC_PREFIX}" \
    ipv4.gateway "${STATIC_GW}" \
    ipv4.dns "${STATIC_DNS}" \
    ipv4.method manual \
    connection.autoconnect yes \
    connection.autoconnect-priority 100
}
if [[ -n "${STATIC_IP}" ]]; then
  optional "Configure static IP ${STATIC_IP}/${STATIC_PREFIX} on ${STATIC_IFACE}" configure_static_ip
  warn "Static IP set: reboot the Pi for it to take effect (it will come back on ${STATIC_IP})."
else
  log "Static IP: STATIC_IP empty — skipping (keeping DHCP)."
fi

# ---------------------------------------------------------------------------
# 7. (Optional) pre-pull the engine image so the deploy is faster / cached.
#    Pulling needs internet + Docker Hub, NOT a Pyronear server.
# ---------------------------------------------------------------------------
pull_engine() {
  docker pull "pyronear/pyro-engine:${ENGINE_TAG}" || return 1
  docker pull "pyronear/pyro-camera-api:${ENGINE_TAG}" || return 1
}
if [[ "${PULL_ENGINE_IMAGE}" == "true" ]]; then
  optional "Pre-pull engine images (tag ${ENGINE_TAG})" pull_engine
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
log "Setup finished."
echo "  Docker:   $(command -v docker >/dev/null 2>&1 && docker --version || echo 'NOT installed')"
echo "  Compose:  $(docker compose version 2>/dev/null || echo 'NOT available')"
echo "  OpenVPN:  $(command -v openvpn >/dev/null 2>&1 && echo 'installed (not connected — fake)' || echo 'NOT installed')"
echo "  Alloy:    $(command -v alloy >/dev/null 2>&1 && echo 'installed' || echo 'not installed')"
echo
if (( ${#WARNINGS[@]} )); then
  printf '%s\n' "${YELLOW}Warnings (non-fatal):${NC}"
  for w in "${WARNINGS[@]}"; do echo "  - $w"; done
  echo
fi
cat <<EOF
Next step — deploy/update the engine app itself with Ansible from the control
machine (needs a reachable alert API for camera tokens):

  make install-engines-filtered    # LIMIT=example-station

The VPN / mediamtx / reverse-ssh server steps were intentionally skipped: this
Pi has all dependencies installed and can run the engine standalone.
EOF
