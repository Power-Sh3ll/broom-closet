#!/usr/bin/env bash
# Undo install-client.sh.
#
# Removes the `closet` command and the client it points at. Tailscale is left
# alone unless you ask for it, since other things may depend on it.
set -euo pipefail

BINDIR="$HOME/.local/bin"
LIBDIR="$HOME/.local/share/broom-closet"
SECRET="$HOME/.closet-secret"
ASSUME_YES=0
REMOVE_TAILSCALE=0

usage() {
	cat <<'USAGE'
usage: uninstall-client.sh [options]

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

say "The 'closet' command"
if [ -f "$BINDIR/closet" ]; then
	rm -f "$BINDIR/closet"
	info "removed $BINDIR/closet"
else
	info "not installed — nothing to do"
fi

say "Client files"
if [ -d "$LIBDIR" ]; then
	rm -rf "$LIBDIR"
	info "removed $LIBDIR"
else
	info "nothing at $LIBDIR"
fi

say "Saved passphrase"
if [ -f "$SECRET" ]; then
	if confirm "delete $SECRET?"; then
		rm -f "$SECRET"
		info "deleted"
	else
		info "kept at $SECRET"
	fi
else
	info "no passphrase file — nothing to do"
fi

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
	elif command -v apt-get >/dev/null; then
		sudo apt-get remove -y tailscale || true
	elif command -v dnf >/dev/null; then
		sudo dnf remove -y tailscale || true
	else
		info "remove the package with your package manager"
	fi
	info "removed. Also delete this machine from the admin console:"
	info "  https://login.tailscale.com/admin/machines"
else
	info "kept"
fi

say "Done"
info "PATH lines you added to ~/.bashrc or ~/.zshrc are left alone."
