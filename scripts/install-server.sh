#!/usr/bin/env bash
# Set up the broom closet server on this machine.
#
# Installs nothing you cannot remove with uninstall-server.sh. Every step
# announces itself and is safe to re-run. If something fails, the error
# reporter below says which line and which command, so re-run with --trace
# for the full story.
set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
	echo "run this with bash, not sh:  bash $0" >&2
	exit 2
fi

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
  --trace          print every command as it runs (for debugging)
  -h, --help       this text
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
		--no-tailscale) WANT_TAILSCALE=0 ;;
		--service) WANT_SERVICE=1 ;;
		--trace) set -x ;;
		-h|--help) usage; exit 0 ;;
		*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m    ! %s\033[0m\n' "$*"; }

# Intentional exits go through this so they are not reported as crashes.
bail() { trap - ERR; exit "${1:-1}"; }

on_error() {
	local code=$? line="$1" cmd="$2"
	trap - ERR
	printf '\n\033[31m!! install failed\033[0m\n' >&2
	printf '   line:    %s\n' "$line" >&2
	printf '   command: %s\n' "$cmd" >&2
	printf '   exit:    %s\n' "$code" >&2
	printf '\n   Nothing was left half-configured that uninstall-server.sh\n' >&2
	printf '   cannot clean up. For a full trace:\n' >&2
	printf '     bash %s --trace %s\n' "$0" "${ORIG_ARGS:-}" >&2
	exit "$code"
}
ORIG_ARGS="$*"
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# --- 0. sudo ---------------------------------------------------------------
# Get the password prompt over with once, up front, where it is obviously a
# password prompt rather than a mystery hang in the middle of a package install.
need_sudo=0
[ "$WANT_TAILSCALE" -eq 1 ] && need_sudo=1
[ "$WANT_SERVICE" -eq 1 ] && need_sudo=1
systemctl is-active --quiet firewalld && need_sudo=1 || true

if [ "$need_sudo" -eq 1 ]; then
	say "Administrator access"
	if sudo -n true 2>/dev/null; then
		info "already authorized"
	else
		info "some steps need sudo (installing Tailscale, firewall, systemd)"
		info "you will be asked for your password once, now"
		if ! sudo -v; then
			warn "could not authenticate with sudo."
			warn "Re-run and enter your password, or use --no-tailscale to skip"
			warn "the steps that need it."
			bail 1
		fi
	fi
fi

# --- 1. python -------------------------------------------------------------
say "Checking Python"
if ! command -v python3 >/dev/null; then
	warn "python3 is not installed. Install it, then re-run:"
	warn "  sudo pacman -S python     # Arch"
	warn "  sudo apt install python3  # Debian/Ubuntu"
	bail 1
fi
if ! python3 - <<'PY'
import sys
if sys.version_info < (3, 9):
    sys.exit(f"python 3.9+ required, found {sys.version.split()[0]}")
print(f"    python {sys.version.split()[0]} — ok")
PY
then
	warn "your python3 is too old; install a newer one and re-run"
	bail 1
fi

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
		info "installing via pacman"
		if ! sudo pacman -S --needed --noconfirm tailscale; then
			warn "pacman could not install tailscale."
			warn "A stale package database is the usual cause. Refresh with a"
			warn "FULL upgrade, then re-run this script:"
			warn "    sudo pacman -Syu"
			warn "Do not use 'pacman -Sy tailscale' — partial upgrades break Arch."
			bail 1
		fi
	elif command -v apt-get >/dev/null || command -v dnf >/dev/null; then
		warn "Tailscale is not in your default repos. Install it with:"
		warn "    curl -fsSL https://tailscale.com/install.sh | sh"
		warn "Review that script before piping it to a shell, then re-run this one."
		bail 1
	else
		warn "unrecognized package manager. Install Tailscale manually:"
		warn "    https://tailscale.com/download"
		bail 1
	fi

	if systemctl is-active --quiet tailscaled; then
		info "tailscaled already running"
	else
		info "enabling tailscaled"
		if ! sudo systemctl enable --now tailscaled; then
			warn "tailscaled would not start. Look at why with:"
			warn "    systemctl status tailscaled"
			warn "    journalctl -u tailscaled -n 50"
			bail 1
		fi
	fi

	if ! tailscale status >/dev/null 2>&1; then
		say "Action needed"
		info "Tailscale is installed but not logged in. Run this yourself —"
		info "it prints a URL you open in a browser:"
		info ""
		info "    sudo tailscale up"
		info ""
		info "Then re-run this script to finish. Nothing is broken; this step"
		info "just cannot be automated."
		bail 0
	fi

	WHO="$(tailscale status --json 2>/dev/null \
		| python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null \
		|| true)"
	info "logged in as: ${WHO:-unknown}"

	# firewalld would otherwise drop tailnet traffic into the public zone
	if systemctl is-active --quiet firewalld; then
		if sudo firewall-cmd --zone=trusted --query-interface=tailscale0 >/dev/null 2>&1; then
			info "firewalld: tailscale0 already trusted"
		else
			info "firewalld: trusting tailscale0"
			sudo firewall-cmd --zone=trusted --add-interface=tailscale0 \
				|| warn "could not trust tailscale0 for this boot; clients may be blocked"
			sudo firewall-cmd --permanent --zone=trusted --add-interface=tailscale0 \
				|| warn "could not persist the firewalld rule across reboots"
		fi
	fi
else
	say "Skipping Tailscale"
	warn "LAN-only mode: clients must be able to route to this machine."
	warn "If this host is a VirtualBox NAT guest, see the README — you need a"
	warn "port-forwarding rule on the VirtualBox host as well."
	if systemctl is-active --quiet firewalld; then
		info "firewalld: opening 7777/tcp for this boot only"
		sudo firewall-cmd --add-port=7777/tcp \
			|| warn "could not open 7777/tcp; clients will not get through"
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
	RUNAS="${USER:-$(id -un)}"
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
User=$RUNAS

[Install]
WantedBy=multi-user.target
UNITEOF
	sudo systemctl daemon-reload
	if sudo systemctl enable --now broom-closet; then
		info "installed $UNIT and started it"
		info "logs: journalctl -u broom-closet -f"
	else
		warn "the unit was written but would not start. Check:"
		warn "    systemctl status broom-closet"
		warn "    journalctl -u broom-closet -n 50"
		bail 1
	fi
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
