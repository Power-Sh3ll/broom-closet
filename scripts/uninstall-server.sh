#!/usr/bin/env bash
# Undo install-server.sh.
#
# By default this removes only what belongs to the chat room and leaves
# Tailscale alone, since you may be using it for other things. Each
# destructive step asks first unless --yes is given.
set -euo pipefail

SECRET="${CLOSET_SECRET_FILE:-$HOME/.closet-secret}"
UNIT=/etc/systemd/system/broom-closet.service
ASSUME_YES=0
REMOVE_TAILSCALE=0

usage() {
	cat <<'USAGE'
usage: uninstall-server.sh [options]

  --tailscale   also log out, disable, and uninstall Tailscale
  --yes         do not ask for confirmation
  -h, --help    this text
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
		--tailscale) REMOVE_TAILSCALE=1 ;;
		--yes|-y) ASSUME_YES=1 ;;
		-h|--help) usage; exit 0 ;;
		*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }

confirm() {
	[ "$ASSUME_YES" -eq 1 ] && return 0
	printf '    %s [y/N] ' "$1"
	read -r reply </dev/tty || return 1
	case "$reply" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# --- 1. the service --------------------------------------------------------
say "systemd unit"
if [ -f "$UNIT" ]; then
	info "stopping and removing $UNIT (needs sudo)"
	sudo systemctl disable --now broom-closet 2>/dev/null || true
	sudo rm -f "$UNIT"
	sudo systemctl daemon-reload
	info "removed"
else
	info "no unit installed — nothing to do"
fi

# Catch a server started by hand, too.
if pgrep -af 'broom-closet/server\.py' >/dev/null 2>&1; then
	if confirm "a server is still running by hand; stop it?"; then
		pkill -f 'broom-closet/server\.py' || true
		info "stopped"
	fi
fi

# --- 2. firewall ----------------------------------------------------------
say "firewalld"
if systemctl is-active --quiet firewalld; then
	# The 7777 rule from --no-tailscale mode was runtime-only, but clear it anyway.
	sudo firewall-cmd --remove-port=7777/tcp 2>/dev/null || true
	sudo firewall-cmd --zone=trusted --remove-interface=tailscale0 2>/dev/null || true
	sudo firewall-cmd --permanent --zone=trusted --remove-interface=tailscale0 2>/dev/null || true
	info "removed the rules this project added"
else
	info "firewalld not active — nothing to do"
fi

# --- 3. the passphrase ----------------------------------------------------
say "Shared passphrase"
if [ -f "$SECRET" ]; then
	if confirm "delete $SECRET? friends using it will be locked out"; then
		rm -f "$SECRET"
		info "deleted"
	else
		info "kept at $SECRET"
	fi
else
	info "no passphrase file — nothing to do"
fi

# --- 4. tailscale (opt-in) ------------------------------------------------
say "Tailscale"
if [ "$REMOVE_TAILSCALE" -eq 0 ]; then
	info "left installed — pass --tailscale to remove it"
elif ! command -v tailscale >/dev/null; then
	info "not installed — nothing to do"
elif confirm "log out and uninstall Tailscale? other things may rely on it"; then
	sudo tailscale down 2>/dev/null || true
	sudo tailscale logout 2>/dev/null || true
	sudo systemctl disable --now tailscaled 2>/dev/null || true
	if command -v pacman >/dev/null; then
		sudo pacman -Rns --noconfirm tailscale || true
	else
		info "remove the package with your package manager"
	fi
	info "removed. Also delete this machine from the Tailscale admin console:"
	info "  https://login.tailscale.com/admin/machines"
else
	info "kept"
fi

say "Done"
info "The repo itself is untouched; delete the directory to finish cleaning up."
