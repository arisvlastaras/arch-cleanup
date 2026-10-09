#!/bin/bash

set -e  # stop on setup errors, cleanup steps record failures and carry on
shopt -s nullglob dotglob  # unmatched globs expand to nothing, * matches dotfiles

# ~/.cache entries kept at cache levels low and medium (shader caches are slow to rebuild)
KEEP_CACHES=(mesa_shader_cache mesa_shader_cache_db nvidia 'qtshadercache-*')
# at cache level low, only remove files not modified in this many days
CACHE_AGE=30

usage() {
	echo "Usage: $0 [-y] [-n] [-c LEVEL] [-h]"
	echo "  -y        don't ask for confirmation"
	echo "  -n        dry run, show what would be removed without removing it"
	echo "  -c LEVEL  how much of ~/.cache to remove:"
	echo "              low     files older than $CACHE_AGE days, keep shader caches"
	echo "              medium  everything except shader caches (default)"
	echo "              high    everything"
	echo "  -h        show this help"
}

NOCONFIRM=false
DRYRUN=false
CACHE_LEVEL=medium
while getopts "ync:h" opt; do
	case $opt in
		y) NOCONFIRM=true ;;
		n) DRYRUN=true ;;
		c) CACHE_LEVEL=$OPTARG ;;
		h) usage; exit 0 ;;
		*) usage >&2; exit 1 ;;
	esac
done

case $CACHE_LEVEL in
	low|medium|high) ;;
	*) echo "Invalid cache level: $CACHE_LEVEL" >&2; usage >&2; exit 1 ;;
esac

# safety checks
if [ "$EUID" -eq 0 ]; then
	echo "Don't run as root, run as your normal user (sudo is used where needed)." >&2
	exit 1
fi
if ! command -v paccache >/dev/null; then
	echo "paccache not found, install it with: sudo pacman -S pacman-contrib" >&2
	exit 1
fi
if [ -e /var/lib/pacman/db.lck ]; then
	echo "pacman is running (/var/lib/pacman/db.lck exists), try again when it's done." >&2
	echo "If no pacman is running, remove the stale lock with: sudo rm /var/lib/pacman/db.lck" >&2
	exit 1
fi

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
	read -rp "$1 [Y/n]: " answer
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

# record a cleanup step that didn't complete, so the script carries on
FAILED=()
step_failed() {
	echo "    !! $1 did not complete, continuing" >&2
	FAILED+=("$1")
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

# ~/.cache entries outside KEEP_CACHES
cache_entries() {
	local entry name keep
	for entry in ~/.cache/*; do
		name=${entry##*/}
		for keep in "${KEEP_CACHES[@]}"; do
			# shellcheck disable=SC2053  # unquoted on purpose, KEEP_CACHES can hold globs
			[[ $name == $keep ]] && continue 2
		done
		echo "$entry"
	done
}

# find files older than CACHE_AGE days in ~/.cache entries outside KEEP_CACHES,
# extra args are the find action (-printf, -delete, ...)
# mtime is used because atime is not updated on noatime mounts
find_old_cache() {
	local entries
	mapfile -t entries < <(cache_entries)
	[ ${#entries[@]} -eq 0 ] && return 0
	find "${entries[@]}" -type f -mtime +"$CACHE_AGE" "$@"
}

# bytes ~/.cache cleaning would free at CACHE_LEVEL
cache_size() {
	local entries
	case $CACHE_LEVEL in
		low) find_old_cache -printf '%s\n' | awk '{ s += $1 } END { print s + 0 }' ;;
		medium) mapfile -t entries < <(cache_entries); get_size "${entries[@]}" ;;
		high) get_size ~/.cache/* ;;
	esac
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

DIRSIZE=$(( \
	$(get_size \
		/var/cache/pacman/pkg/download-* \
		"${TRASH_CONTENTS[@]}" \
		/var/lib/systemd/coredump/*) + \
	$(cache_size) \
))
echo "Total directory space to be freed: $(convert_human "$DIRSIZE")"

# ask for the sudo password once upfront
if [ "$DRYRUN" = false ]; then
	sudo -v
fi

# get total size of system
SIZE_BEFORE=$(df --output=used -B1 / | tail -1)

# pacman cache
if confirm "Clean pacman cache?"; then
	echo "==> Cleaning pacman cache..."
	if [ "$DRYRUN" = true ]; then
		paccache -dk3 || step_failed "pacman cache"
	else
		paccache -rk3 || step_failed "pacman cache"
	fi
fi

#uninstalled package cache
if confirm "Remove uninstalled package cache?"; then
	echo "==> Removing uninstalled package cache..."
	if [ "$DRYRUN" = true ]; then
		paccache -duk0 || step_failed "uninstalled package cache"
	else
		paccache -ruk0 || step_failed "uninstalled package cache"
	fi
fi

#orphaned packages
if confirm "Remove orphaned packages?"; then
	echo "==> Removing orphaned packages..."
	mapfile -t ORPHANS < <(pacman -Qtdq)
	if [ ${#ORPHANS[@]} -gt 0 ]; then
		run sudo pacman -Rns "${NOCONFIRM_FLAG[@]}" "${ORPHANS[@]}" || step_failed "orphaned packages"
	else
		echo "No orphans found."
	fi
fi

#aur helper cache (-a: AUR only, the pacman cache is handled by paccache above)
echo "==> Detecting aur helper..."
if command -v paru >/dev/null; then
	#paru
	if confirm "Clean paru cache?"; then
		echo "==> Cleaning paru cache..."
		run paru -Sca "${NOCONFIRM_FLAG[@]}" || step_failed "paru cache"
	fi
elif command -v yay >/dev/null; then
	#yay
	if confirm "Clean yay cache?"; then
		echo "==> Cleaning yay cache..."
		run yay -Sca "${NOCONFIRM_FLAG[@]}" || step_failed "yay cache"
	fi
else
	echo "No supported aur helpers found :("
fi

#flatpak
if command -v flatpak >/dev/null; then
	if confirm "Remove unused flatpak runtimes?"; then
		echo "==> Removing unused flatpak runtimes..."
		run flatpak uninstall --unused "${FLATPAK_FLAG[@]}" || step_failed "flatpak"
	fi
fi

#temp pacman
if confirm "Remove leftover pacman files?"; then
	echo "==> Removing leftover pacman download temp dirs..."
	remove --sudo /var/cache/pacman/pkg/download-* || step_failed "leftover pacman files"
fi

#coredumps
if confirm "Remove systemd coredumps?"; then
	echo "==> Removing systemd coredumps..."
	remove --sudo /var/lib/systemd/coredump/* || step_failed "coredumps"
fi

#~/.cache
if confirm "Clean system cache (level: $CACHE_LEVEL)?"; then
	echo "==> Cleaning system cache (level: $CACHE_LEVEL)..."
	case $CACHE_LEVEL in
		low)
			if [ "$DRYRUN" = true ]; then
				echo "    [dry-run] would remove $(find_old_cache -printf '.' | wc -c) file(s) older than $CACHE_AGE days, $(convert_human "$(cache_size)")"
			else
				find_old_cache -delete || step_failed "system cache"
			fi
			;;
		medium)
			mapfile -t CACHE_ENTRIES < <(cache_entries)
			remove "${CACHE_ENTRIES[@]}" || step_failed "system cache"
			;;
		high)
			remove ~/.cache/* || step_failed "system cache"
			;;
	esac
fi

#trash
if confirm "Clean system trash?"; then
	echo "==> Cleaning system trash (${#TRASH_DIRS[@]} location(s))..."
	remove "${TRASH_CONTENTS[@]}" || step_failed "system trash"
fi

# readout size
if [ "$DRYRUN" = true ]; then
	echo "==> Dry run, nothing was removed."
else
	SIZE_AFTER=$(df --output=used -B1 / | tail -1)
	SIZE_FREED=$(( SIZE_BEFORE - SIZE_AFTER ))
	echo "==> Total space freed: $(convert_human "$SIZE_FREED")"
fi

# failed steps summary
if [ ${#FAILED[@]} -gt 0 ]; then
	echo "==> Steps that did not complete:" >&2
	printf '    %s\n' "${FAILED[@]}" >&2
	exit 1
fi
