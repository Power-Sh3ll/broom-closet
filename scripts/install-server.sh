#!/usr/bin/env bash
# Set up the broom closet server on this machine.
#
# Installs nothing you cannot remove with uninstall-server.sh. Every step
# announces itself and is safe to re-run.
set -euo pipefail

SECRET="${CLOSET_SECRET_FILE:-$HOME/.closet-secret}"
UNIT=/etc/systemd/system/broom-closet.service
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WANT_TAILSCALE=1
WANT_SERVICE=0

usage() {
	cat <<'USAGE'
usage: install-server.sh [options]

  --no-tailscale   skip the VPN; only do this if every client is on your LAN
  --service        also install a systemd unit so the room survives reboots
  -h, --help       this text
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
		--no-tailscale) WANT_TAILSCALE=0 ;;
		--service) WANT_SERVICE=1 ;;
		-h|--help) usage; exit 0 ;;
		*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m    ! %s\033[0m\n' "$*"; }

# --- 1. python -------------------------------------------------------------
say "Checking Python"
if ! command -v python3 >/dev/null; then
	echo "python3 is not installed. Install it first, then re-run:" >&2
	echo "  sudo pacman -S python     # Arch" >&2
	echo "  sudo apt install python3  # Debian/Ubuntu" >&2
	exit 1
fi
python3 - <<'PY' || exit 1
import sys
if sys.version_info < (3, 9):
    sys.exit(f"python 3.9+ required, found {sys.version.split()[0]}")
print(f"    python {sys.version.split()[0]} — ok")
PY

# --- 2. shared passphrase --------------------------------------------------
say "Shared passphrase"
if [ -s "$SECRET" ]; then
	info "already present at $SECRET — keeping it"
else
	install -m 600 /dev/null "$SECRET"
	python3 -c "import secrets; print(secrets.token_urlsafe(24), end='')" > "$SECRET"
	chmod 600 "$SECRET"
	info "generated a random passphrase at $SECRET (mode 600)"
fi
info "friends will need this exact string:"
printf '\n      '; cat "$SECRET"; printf '\n'

# --- 3. tailscale ----------------------------------------------------------
if [ "$WANT_TAILSCALE" -eq 1 ]; then
	say "Tailscale"
	if command -v tailscale >/dev/null; then
		info "already installed"
	elif command -v pacman >/dev/null; then
		info "installing via pacman (needs sudo)"
		sudo pacman -S --needed --noconfirm tailscale
	else
		warn "no pacman here. Install Tailscale manually, then re-run:"
		warn "  curl -fsSL https://tailscale.com/install.sh | sh"
		warn "Review that script before piping it to a shell."
		exit 1
	fi

	if ! systemctl is-active --quiet tailscaled; then
		info "enabling tailscaled (needs sudo)"
		sudo systemctl enable --now tailscaled
	else
		info "tailscaled already running"
	fi

	if ! tailscale status >/dev/null 2>&1; then
		warn "not logged in yet. Run this yourself — it opens a browser:"
		warn "  sudo tailscale up"
		warn "Then re-run this script to finish."
		exit 1
	fi
	info "logged in as: $(tailscale status --json 2>/dev/null \
		| python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null \
		|| echo 'unknown')"

	# firewalld would otherwise drop tailnet traffic into the public zone
	if systemctl is-active --quiet firewalld; then
		if sudo firewall-cmd --zone=trusted --query-interface=tailscale0 >/dev/null 2>&1; then
			info "firewalld: tailscale0 already trusted"
		else
			info "firewalld: trusting tailscale0 (needs sudo)"
			sudo firewall-cmd --zone=trusted --add-interface=tailscale0
			sudo firewall-cmd --permanent --zone=trusted --add-interface=tailscale0
		fi
	fi
else
	say "Skipping Tailscale"
	warn "LAN-only mode: you must open the port yourself and clients must be"
	warn "able to route to this machine. See README for VirtualBox forwarding."
	if systemctl is-active --quiet firewalld; then
		info "firewalld: opening 7777/tcp for this boot only (needs sudo)"
		sudo firewall-cmd --add-port=7777/tcp
	fi
fi

# --- 4. optional systemd unit ---------------------------------------------
if [ "$WANT_SERVICE" -eq 1 ]; then
	say "systemd unit"
	if [ "$WANT_TAILSCALE" -eq 1 ]; then
		BIND='--host "$(tailscale ip -4 | head -1)"'
		AFTER="network-online.target tailscaled.service"
	else
		BIND='--host 0.0.0.0'
		AFTER="network-online.target"
	fi
	sudo tee "$UNIT" >/dev/null <<UNITEOF
[Unit]
Description=broom closet chat
After=$AFTER
Wants=$AFTER

[Service]
# The bind address is resolved at start time, not install time.
ExecStart=/bin/sh -c 'exec $REPO/server.py $BIND --secret-file $SECRET'
Restart=always
RestartSec=2
User=$USER

[Install]
WantedBy=multi-user.target
UNITEOF
	sudo systemctl daemon-reload
	sudo systemctl enable --now broom-closet
	info "installed $UNIT and started it"
	info "logs: journalctl -u broom-closet -f"
fi

# --- done ------------------------------------------------------------------
say "Done"
if [ "$WANT_TAILSCALE" -eq 1 ]; then
	TSIP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
	info "Clients connect to: ${TSIP:-<your tailscale ip>}"
	if [ "$WANT_SERVICE" -eq 0 ]; then
		info "Start the room with:"
		info "  $REPO/server.py --host ${TSIP:-\$(tailscale ip -4)} --secret-file $SECRET"
	fi
else
	info "Start the room with:"
	info "  $REPO/server.py --host 0.0.0.0 --secret-file $SECRET"
fi
