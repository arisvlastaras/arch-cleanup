#!/bin/bash

set -e  # stop on setup errors, cleanup steps record failures and carry on
shopt -s nullglob dotglob  # unmatched globs expand to nothing, * matches dotfiles

# ~/.cache entries kept at cache levels low and medium (shader caches are slow to rebuild)
KEEP_CACHES=(mesa_shader_cache mesa_shader_cache_db nvidia 'qtshadercache-*')
# at cache level low, only remove files not modified in this many days
CACHE_AGE=30

usage() {
	echo "Usage: $0 [-y] [-n] [-c LEVEL] [-h]"
	echo "  -y        don't ask, run every step without the checklist"
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

# checklist in a terminal, plain Y/n prompts otherwise (e.g. piped input)
if [ "$NOCONFIRM" = false ] && [ -t 0 ] && [ -t 1 ]; then
	USE_TUI=true
else
	USE_TUI=false
fi

#confirm function
# usage: confirm KEY PROMPT, KEY is the step's checklist item
confirm() {
	#checklist selection
	if [ "$USE_TUI" = true ]; then
		[ "${SELECTED[$1]}" = 1 ]
		return
	fi

	#flag check
	if [ "$NOCONFIRM" = true ]; then
		return 0
	fi

	#prompt
	read -rp "$2 [Y/n]: " answer
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

if command -v paru >/dev/null; then
	AUR_HELPER=paru
elif command -v yay >/dev/null; then
	AUR_HELPER=yay
else
	AUR_HELPER=
fi

# checklist items, only the steps that apply to this system
ITEMS=(pacman uninstalled orphans)
[ -n "$AUR_HELPER" ] && ITEMS+=(aur)
command -v flatpak >/dev/null && ITEMS+=(flatpak)
ITEMS+=(pacman_tmp coredumps cache trash)

item_label() {
	case $1 in
		pacman) echo "Clean pacman cache (keep last 3)" ;;
		uninstalled) echo "Remove uninstalled package cache" ;;
		orphans) echo "Remove orphaned packages" ;;
		aur) echo "Clean $AUR_HELPER cache" ;;
		flatpak) echo "Remove unused flatpak runtimes" ;;
		pacman_tmp) echo "Remove leftover pacman files" ;;
		coredumps) echo "Remove systemd coredumps" ;;
		cache) echo "Clean ~/.cache (level: $CACHE_LEVEL)" ;;
		trash) echo "Clean system trash" ;;
	esac
}

# everything is ticked to start with, like answering Y to every prompt
declare -A SELECTED
for key in "${ITEMS[@]}"; do
	SELECTED[$key]=1
done

# bytes freed per item, where it can be known upfront
declare -A SIZES CACHE_SIZES
SIZES[pacman_tmp]=$(get_size /var/cache/pacman/pkg/download-*)
SIZES[coredumps]=$(get_size /var/lib/systemd/coredump/*)
SIZES[trash]=$(get_size "${TRASH_CONTENTS[@]}")
# ~/.cache size at CACHE_LEVEL, each level is measured once
update_cache_size() {
	if [ -z "${CACHE_SIZES[$CACHE_LEVEL]}" ]; then
		CACHE_SIZES[$CACHE_LEVEL]=$(cache_size)
	fi
	SIZES[cache]=${CACHE_SIZES[$CACHE_LEVEL]}
}
update_cache_size

# bytes freed by the ticked items
selected_size() {
	local key total=0
	for key in "${ITEMS[@]}"; do
		[ "${SELECTED[$key]}" = 1 ] && total=$(( total + ${SIZES[$key]:-0} ))
	done
	echo "$total"
}

# checklist ui, arrow keys or j/k to move, space to tick, enter to run
# rows are the ITEMS, then the no-confirm option
CACHE_LEVELS=(low medium high)
NOCONFIRM_ROW=${#ITEMS[@]}
ROWS=$(( ${#ITEMS[@]} + 1 ))

# append a line to FRAME, \e[K clears what's left of the previous frame's line
frame_line() {
	FRAME+=$1$'\e[K\n'
}

# usage: draw_row ROW TICKED LABEL [SIZE]
draw_row() {
	local mark=' ' line
	[ "$2" = 1 ] && mark=x
	printf -v line ' [%s] %-42s %7s ' "$mark" "$3" "$4"
	if [ "$1" -eq "$CURSOR" ]; then
		frame_line $'\e[7m'"$line"$'\e[0m'
	else
		frame_line "$line"
	fi
}

# the frame is built in FRAME and written in one go over the old one,
# clearing the screen first would make it flicker
draw_menu() {
	local i key size
	FRAME=$'\e[H'
	if [ "$DRYRUN" = true ]; then
		frame_line 'arch-cleanup (dry run, nothing will be removed)'
	else
		frame_line 'arch-cleanup'
	fi
	frame_line ''
	for i in "${!ITEMS[@]}"; do
		key=${ITEMS[i]}
		size=
		[ -n "${SIZES[$key]}" ] && size=$(convert_human "${SIZES[$key]}")
		draw_row "$i" "${SELECTED[$key]}" "$(item_label "$key")" "$size"
	done
	frame_line ''
	draw_row "$NOCONFIRM_ROW" "$([ "$NOCONFIRM" = true ] && echo 1)" "No-confirm (package managers won't ask)"
	frame_line ''
	frame_line " Selected: $(convert_human "$(selected_size)"), plus package caches"
	frame_line ''
	frame_line ' up/down move  space tick  a all/none  left/right cache level'
	frame_line ' enter run  q quit'
	printf '%s\e[J' "$FRAME"  # \e[J clears anything below the frame
}

tui_restore() {
	printf '\e[?25h\e[?1049l'  # show cursor, leave alternate screen
}

run_menu() {
	local key rest i all
	CURSOR=0
	trap tui_restore EXIT
	printf '\e[?1049h\e[?25l'  # alternate screen, hide cursor
	while true; do
		draw_menu
		IFS= read -rsn1 key
		if [ "$key" = $'\e' ]; then
			IFS= read -rsn2 -t 0.05 rest || true
			key+=$rest
		fi
		case $key in
			$'\e[A'|k) CURSOR=$(( (CURSOR + ROWS - 1) % ROWS )) ;;
			$'\e[B'|j) CURSOR=$(( (CURSOR + 1) % ROWS )) ;;
			' ')
				if [ "$CURSOR" -eq "$NOCONFIRM_ROW" ]; then
					[ "$NOCONFIRM" = true ] && NOCONFIRM=false || NOCONFIRM=true
				else
					key=${ITEMS[CURSOR]}
					SELECTED[$key]=$(( 1 - ${SELECTED[$key]} ))
				fi
				;;
			a)
				# untick all if everything is ticked, otherwise tick all
				all=0
				for i in "${ITEMS[@]}"; do
					[ "${SELECTED[$i]}" = 1 ] || all=1
				done
				for i in "${ITEMS[@]}"; do
					SELECTED[$i]=$all
				done
				;;
			$'\e[C'|$'\e[D'|l|h)
				for i in "${!CACHE_LEVELS[@]}"; do
					[ "${CACHE_LEVELS[i]}" = "$CACHE_LEVEL" ] && break
				done
				case $key in
					$'\e[C'|l) i=$(( i < 2 ? i + 1 : 2 )) ;;
					*) i=$(( i > 0 ? i - 1 : 0 )) ;;
				esac
				CACHE_LEVEL=${CACHE_LEVELS[i]}
				update_cache_size
				;;
			'') break ;;  # enter
			q|Q) tui_restore; trap - EXIT; echo "Aborted, nothing was removed."; exit 0 ;;
		esac
	done
	tui_restore
	trap - EXIT
}

if [ "$USE_TUI" = true ]; then
	run_menu
	ANY_SELECTED=false
	for key in "${ITEMS[@]}"; do
		[ "${SELECTED[$key]}" = 1 ] && ANY_SELECTED=true
	done
	if [ "$ANY_SELECTED" = false ]; then
		echo "Nothing selected."
		exit 0
	fi
fi

if [ "$NOCONFIRM" = true ]; then
	NOCONFIRM_FLAG=(--noconfirm)
	FLATPAK_FLAG=(-y)
else
	NOCONFIRM_FLAG=()
	FLATPAK_FLAG=()
fi

echo "Total directory space to be freed: $(convert_human "$(selected_size)")"

# ask for the sudo password once upfront
if [ "$DRYRUN" = false ]; then
	sudo -v
fi

# get total size of system
SIZE_BEFORE=$(df --output=used -B1 / | tail -1)

# pacman cache
if confirm pacman "Clean pacman cache?"; then
	echo "==> Cleaning pacman cache..."
	if [ "$DRYRUN" = true ]; then
		paccache -dk3 || step_failed "pacman cache"
	else
		paccache -rk3 || step_failed "pacman cache"
	fi
fi

#uninstalled package cache
if confirm uninstalled "Remove uninstalled package cache?"; then
	echo "==> Removing uninstalled package cache..."
	if [ "$DRYRUN" = true ]; then
		paccache -duk0 || step_failed "uninstalled package cache"
	else
		paccache -ruk0 || step_failed "uninstalled package cache"
	fi
fi

#orphaned packages
if confirm orphans "Remove orphaned packages?"; then
	echo "==> Removing orphaned packages..."
	mapfile -t ORPHANS < <(pacman -Qtdq)
	if [ ${#ORPHANS[@]} -gt 0 ]; then
		run sudo pacman -Rns "${NOCONFIRM_FLAG[@]}" "${ORPHANS[@]}" || step_failed "orphaned packages"
	else
		echo "No orphans found."
	fi
fi

#aur helper cache (-a: AUR only, the pacman cache is handled by paccache above)
if [ -n "$AUR_HELPER" ]; then
	if confirm aur "Clean $AUR_HELPER cache?"; then
		echo "==> Cleaning $AUR_HELPER cache..."
		run "$AUR_HELPER" -Sca "${NOCONFIRM_FLAG[@]}" || step_failed "$AUR_HELPER cache"
	fi
elif [ "$USE_TUI" = false ]; then
	echo "No supported aur helpers found :("
fi

#flatpak
if command -v flatpak >/dev/null; then
	if confirm flatpak "Remove unused flatpak runtimes?"; then
		echo "==> Removing unused flatpak runtimes..."
		run flatpak uninstall --unused "${FLATPAK_FLAG[@]}" || step_failed "flatpak"
	fi
fi

#temp pacman
if confirm pacman_tmp "Remove leftover pacman files?"; then
	echo "==> Removing leftover pacman download temp dirs..."
	remove --sudo /var/cache/pacman/pkg/download-* || step_failed "leftover pacman files"
fi

#coredumps
if confirm coredumps "Remove systemd coredumps?"; then
	echo "==> Removing systemd coredumps..."
	remove --sudo /var/lib/systemd/coredump/* || step_failed "coredumps"
fi

#~/.cache
if confirm cache "Clean system cache (level: $CACHE_LEVEL)?"; then
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
if confirm trash "Clean system trash?"; then
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
