#!/usr/bin/env bash
# Shared constants + helpers for the custos-network Phase 1 scripts.
# Sourced by scripts/install.sh and scripts/health-check.sh — not executed directly.
#
# Only constants the scripts actually consume live here. Radio/IP details (SSID, channel,
# addresses) are owned by the config files in drone/ and ground/; when those are templated
# into an Ansible role (the next step) the values move to host_vars.

# shellcheck disable=SC2034  # consumed by the scripts that source this file
IFACE="wlan0"
DRONE_IP="192.168.4.1"     # used by health-check to know self/peer
GROUND_IP="192.168.4.2"
COUNTRY="TW"               # used by health-check to verify the reg domain

# --- Logging ---
log()  { printf '[custos-net] %s\n' "$*"; }
warn() { printf '[custos-net] WARN: %s\n' "$*" >&2; }
die()  { printf '[custos-net] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"
}

# link_into_etc <abs-src> <abs-dest> — idempotent symlink of a repo file into the system.
link_into_etc() {
  local src="$1" dest="$2"
  [ -e "$src" ] || die "missing source: $src"
  mkdir -p "$(dirname "$dest")"
  ln -sfn "$src" "$dest"
  log "linked $dest -> $src"
}
