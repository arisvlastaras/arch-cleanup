#!/bin/bash

set -e  # stop on first error
shopt -s nullglob dotglob  # unmatched globs expand to nothing, * matches dotfiles

usage() {
	echo "Usage: $0 [-y] [-n] [-h]"
	echo "  -y  don't ask for confirmation"
	echo "  -n  dry run, show what would be removed without removing it"
	echo "  -h  show this help"
}

NOCONFIRM=false
DRYRUN=false
while getopts "ynh" opt; do
	case $opt in
		y) NOCONFIRM=true ;;
		n) DRYRUN=true ;;
		h) usage; exit 0 ;;
		*) usage >&2; exit 1 ;;
	esac
done

if [ "$NOCONFIRM" = true ]; then
	NOCONFIRM_FLAG=(--noconfirm)
	FLATPAK_FLAG=(-y)
else
	NOCONFIRM_FLAG=()
	FLATPAK_FLAG=()
fi

#confirm function
confirm() {
	#flag check
	if [ "$NOCONFIRM" = true ]; then
		return 0
	fi

	#prompt
	read -p "$1 [Y/n]: " answer
	if [ "$answer" = "n" ] || [ "$answer" = "N" ]; then
		return 1
	fi
	return 0
}

# run a command, or just print it in dry-run mode
run() {
	if [ "$DRYRUN" = true ]; then
		echo "    [dry-run] $*"
	else
		"$@"
	fi
}

# display directory space to be freed
get_size() {
	if [ $# -eq 0 ]; then
		echo 0
		return
	fi
	du -scb "$@" 2>/dev/null | tail -1 | cut -f1
}
convert_human() {
	numfmt --to=iec -- "$1"
}

# remove paths, or just report their size in dry-run mode
# usage: remove [--sudo] paths...
remove() {
	local sudo_cmd=()
	if [ "$1" = "--sudo" ]; then
		sudo_cmd=(sudo)
		shift
	fi
	if [ $# -eq 0 ]; then
		echo "    Nothing to remove."
		return 0
	fi
	if [ "$DRYRUN" = true ]; then
		echo "    [dry-run] would remove $# item(s), $(convert_human "$(get_size "$@")")"
	else
		"${sudo_cmd[@]}" rm -rf -- "$@"
	fi
}

# trash dirs: home trash + .Trash-$UID / .Trash/$UID on mounted drives
TRASH_DIRS=(~/.local/share/Trash)
while IFS= read -r mnt; do
	mnt=$(printf '%b' "$mnt")  # findmnt escapes spaces as \x20
	for dir in "$mnt/.Trash-$UID" "$mnt/.Trash/$UID"; do
		[ -d "$dir" ] && TRASH_DIRS+=("$dir")
	done
done < <(findmnt -rno TARGET)

TRASH_CONTENTS=()
for dir in "${TRASH_DIRS[@]}"; do
	TRASH_CONTENTS+=("$dir"/files/* "$dir"/info/* "$dir"/expunged/*)
done

DIRSIZE=$(get_size \
	/var/cache/pacman/pkg/download-* \
	~/.cache \
	"${TRASH_CONTENTS[@]}" \
	/var/lib/systemd/coredump/* \
)
echo "Total directory space to be freed: $(convert_human "$DIRSIZE")"

# get total size of system
SIZE_BEFORE=$(df --output=used -B1 / | tail -1)

# pacman cache
if confirm "Clean pacman cache?"; then
	echo "==> Cleaning pacman cache..."
	if [ "$DRYRUN" = true ]; then
		paccache -dk3
	else
		paccache -rk3
	fi
fi

#uninstalled package cache
if confirm "Remove uninstalled package cache?"; then
	echo "==> Removing uninstalled package cache..."
	if [ "$DRYRUN" = true ]; then
		paccache -duk0
	else
		paccache -ruk0
	fi
fi

#orphaned packages
if confirm "Remove orphaned packages?"; then
	echo "==> Removing orphaned packages..."
	ORPHANS=$(pacman -Qtdq) || true
	if [ -n "$ORPHANS" ]; then
		run sudo pacman -Rns "${NOCONFIRM_FLAG[@]}" $ORPHANS
	else
		echo "No orphans found."
	fi
fi

#aur helper cache
echo "==> Detecting aur helper..."
if command -v paru >/dev/null; then
	#paru
	if confirm "Clean paru cache?"; then
		echo "==> Cleaning paru cache..."
		run paru -Sc "${NOCONFIRM_FLAG[@]}"
	fi
elif command -v yay >/dev/null; then
	#yay
	if confirm "Clean yay cache?"; then
		echo "==> Cleaning yay cache..."
		run yay -Sc "${NOCONFIRM_FLAG[@]}"
	fi
else
	echo "No supported aur helpers found :("
fi

#flatpak
if command -v flatpak >/dev/null; then
	if confirm "Remove unused flatpak runtimes?"; then
		echo "==> Removing unused flatpak runtimes..."
		run flatpak uninstall --unused "${FLATPAK_FLAG[@]}"
	fi
fi

#temp pacman
if confirm "Remove leftover pacman files?"; then
	echo "==> Removing leftover pacman download temp dirs..."
	remove --sudo /var/cache/pacman/pkg/download-*
fi

#coredumps
if confirm "Remove systemd coredumps?"; then
	echo "==> Removing systemd coredumps..."
	remove --sudo /var/lib/systemd/coredump/*
fi

#~/.cache
if confirm "Clean system cache?"; then
	echo "==> Cleaning system cache..."
	remove ~/.cache/*
fi

#trash
if confirm "Clean system trash?"; then
	echo "==> Cleaning system trash (${#TRASH_DIRS[@]} location(s))..."
	remove "${TRASH_CONTENTS[@]}"
fi

# readout size
if [ "$DRYRUN" = true ]; then
	echo "==> Dry run, nothing was removed."
	exit 0
fi
SIZE_AFTER=$(df --output=used -B1 / | tail -1)
SIZE_FREED=$(( SIZE_BEFORE - SIZE_AFTER ))
echo "==> Total space freed: $(convert_human "$SIZE_FREED")"
