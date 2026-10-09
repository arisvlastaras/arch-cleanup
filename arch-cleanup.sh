#!/bin/bash

set -e  # stop on setup errors, cleanup steps record failures and carry on
shopt -s nullglob dotglob  # unmatched globs expand to nothing, * matches dotfiles

# ~/.cache entries kept at cache levels low and medium (shader caches are slow to rebuild)
KEEP_CACHES=(mesa_shader_cache mesa_shader_cache_db nvidia 'qtshadercache-*')
# at cache level low, only remove files not modified in this many days
CACHE_AGE=30

# colors when writing to a terminal, NO_COLOR turns them off (https://no-color.org)
C_RESET= C_BOLD= C_DIM= C_ACCENT= C_GREEN= C_YELLOW= C_ERR= C_HANDLE= C_BRISTLE=
C_CURSOR=$'\e[7m'  # reverse video highlight without colors
if [ -t 1 ] && [ -z "$NO_COLOR" ] && [ "$TERM" != dumb ]; then
	case $COLORTERM in
		truecolor|24bit) BLUE='2;23;147;209' ;;  # arch blue #1793d1
		*) BLUE='5;32' ;;  # closest 256-color match
	esac
	C_RESET=$'\e[0m'
	C_BOLD=$'\e[1m'
	C_DIM=$'\e[2m'
	C_ACCENT=$'\e[38;'$BLUE'm'
	C_GREEN=$'\e[32m'
	C_YELLOW=$'\e[33m'
	[ -t 2 ] && C_ERR=$'\e[1;31m'
	C_CURSOR=$'\e[1;97;48;'$BLUE'm'
	C_HANDLE=$'\e[38;5;137m'
	C_BRISTLE=$'\e[38;5;222m'
fi

# step header, pacman style
msg() {
	echo "$C_ACCENT$C_BOLD==>$C_RESET$C_BOLD $*$C_RESET"
}
error() {
	echo "${C_ERR}error:${C_ERR:+$C_RESET} $*" >&2
}

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
	*) error "Invalid cache level: $CACHE_LEVEL"; usage >&2; exit 1 ;;
esac

# safety checks
if [ "$EUID" -eq 0 ]; then
	error "Don't run as root, run as your normal user (sudo is used where needed)."
	exit 1
fi
if ! command -v paccache >/dev/null; then
	error "paccache not found, install it with: sudo pacman -S pacman-contrib"
	exit 1
fi
if [ -e /var/lib/pacman/db.lck ]; then
	error "pacman is running (/var/lib/pacman/db.lck exists), try again when it's done."
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
	read -rp "$C_ACCENT$C_BOLD::$C_RESET$C_BOLD $2$C_RESET [Y/n]: " answer
	if [ "$answer" = "n" ] || [ "$answer" = "N" ]; then
		return 1
	fi
	return 0
}

# run a command, or just print it in dry-run mode
run() {
	if [ "$DRYRUN" = true ]; then
		echo "    $C_YELLOW[dry-run]$C_RESET $*"
	else
		"$@"
	fi
}

# record a cleanup step that didn't complete, so the script carries on
FAILED=()
step_failed() {
	echo "    $C_ERR!!${C_ERR:+$C_RESET} $1 did not complete, continuing" >&2
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
		echo "    ${C_DIM}Nothing to remove.$C_RESET"
		return 0
	fi
	if [ "$DRYRUN" = true ]; then
		echo "    $C_YELLOW[dry-run]$C_RESET would remove $# item(s), $(convert_human "$(get_size "$@")")"
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

# every installed AUR helper gets its own step, the item key is its name
AUR_HELPERS=()
for helper in paru yay; do
	command -v "$helper" >/dev/null && AUR_HELPERS+=("$helper")
done

# checklist items, only the steps that apply to this system
ITEMS=(pacman uninstalled orphans)
ITEMS+=("${AUR_HELPERS[@]}")
command -v flatpak >/dev/null && ITEMS+=(flatpak)
ITEMS+=(pacman_tmp coredumps cache trash)

item_label() {
	case $1 in
		pacman) echo "Clean pacman cache (keep last 3)" ;;
		uninstalled) echo "Remove uninstalled package cache" ;;
		orphans) echo "Remove orphaned packages" ;;
		paru|yay) echo "Clean $1 cache" ;;
		flatpak) echo "Remove unused flatpak runtimes" ;;
		pacman_tmp) echo "Remove leftover pacman files" ;;
		coredumps) echo "Remove systemd coredumps" ;;
		cache) echo "Clean ~/.cache" ;;
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

# glyphs need a UTF-8 locale, plain ASCII otherwise
case ${LC_ALL:-${LC_CTYPE:-$LANG}} in
	*[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*)
		TICK=✓
		SEP=' · '
		DUST_SPECKS=(. · ˙ ,)
		PILE='.·˙'
		;;
	*)
		TICK=x
		SEP=' - '
		DUST_SPECKS=(. , "'" '`')
		PILE=".,'"
		;;
esac

# arch logo, with the title and the tools it cleans next to it
LOGO=(
	'      /\'
	'     /  \'
	'    /\   \'
	'   /      \'
	'  /   ,,   \'
	' /   |  |  -\'
	"/_-''    ''-_\\"
)
SUBTITLE=pacman
for helper in "${AUR_HELPERS[@]}"; do
	SUBTITLE+=$SEP$helper
done
command -v flatpak >/dev/null && SUBTITLE+=${SEP}flatpak
SUBTITLE+=${SEP}cache${SEP}trash
HEADER=('' "${C_BOLD}arch-cleanup$C_RESET" "$C_DIM$SUBTITLE$C_RESET")
[ "$DRYRUN" = true ] && HEADER+=("${C_YELLOW}dry run, nothing will be removed$C_RESET")

# the broom's 4 rows and the gauge row sit under the logo and a blank line,
# animation ticks redraw only these
BROOM_ROW=$(( ${#LOGO[@]} + 2 ))
TICK_TIME=0.08

# upright broom swinging while it walks along a track the width of the
# checklist, sweeping the dust on the floor row
BROOM_W=54
BROOM_PAUSE=15  # ticks of clean track before the next sweep
# swing frames, left, center and right: the handle's column offset from
# BROOM_X and its glyph for each of the 3 handle rows, then where the 3-wide
# bristles start and what they look like
F_OFF=(-1 -2 -3  0 0 0  1 2 3)
F_CH=('/' '/' '/'  '|' '|' '|'  '\' '\' '\')
F_HEAD=(-5 -1 3)
F_BRISTLES=('///' '/|\' '\\\')
SWING=(0 0 1 1 2 2 1 1)  # frame order, each frame held for 2 ticks
new_dust() {
	local i
	DUST=
	for (( i = 0; i < BROOM_W; i++ )); do
		if (( RANDOM % 6 == 0 )); then
			DUST+=${DUST_SPECKS[RANDOM % ${#DUST_SPECKS[@]}]}
		else
			DUST+=' '
		fi
	done
	BROOM_X=-6  # broom column, starts off the left edge
	SWING_I=0
	SWEPT=0
}
broom_step() {
	local f head i
	SWING_I=$(( (SWING_I + 1) % ${#SWING[@]} ))
	if (( SWING_I % 2 == 0 )); then
		BROOM_X=$(( BROOM_X + 1 ))
	fi
	if (( BROOM_X > BROOM_W + 5 + BROOM_PAUSE )); then
		new_dust
		return
	fi
	# the bristles clear the dust they pass over
	f=${SWING[SWING_I]}
	head=$(( BROOM_X + F_HEAD[f] ))
	for (( i = head; i < head + 3; i++ )); do
		if (( i >= 0 && i < BROOM_W )) && [ "${DUST:i:1}" != ' ' ]; then
			DUST=${DUST:0:i}' '${DUST:i+1}
			SWEPT=$(( SWEPT + 1 ))
		fi
	done
}
# sets BROOM_LINES, each swing flicks a puff of the swept dust out the
# side of the bristles it swings to
broom_lines() {
	local f=${SWING[SWING_I]} r col i j ch color prev= out= puff=0
	BROOM_LINES=()
	for r in 0 1 2; do
		col=$(( BROOM_X + F_OFF[f * 3 + r] ))
		if (( col >= 0 && col < BROOM_W )); then
			printf -v "BROOM_LINES[$r]" ' %*s%s' "$col" '' "$C_HANDLE${F_CH[f * 3 + r]}$C_RESET"
		else
			BROOM_LINES[r]=
		fi
	done
	(( f != 1 )) && puff=$(( SWEPT < ${#PILE} ? SWEPT : ${#PILE} ))
	for (( i = 0; i < BROOM_W; i++ )); do
		j=$(( i - BROOM_X - F_HEAD[f] ))
		if (( j >= 0 && j < 3 )); then
			ch=${F_BRISTLES[f]:j:1} color=$C_BRISTLE
		elif (( f == 0 && j < 0 && j >= -puff )); then
			ch=${PILE:(-j-1):1} color=$C_DIM
		elif (( f == 2 && j >= 3 && j < 3 + puff )); then
			ch=${PILE:j-3:1} color=$C_DIM
		else
			ch=${DUST:i:1} color=$C_DIM
		fi
		if [ "$color" != "$prev" ]; then
			out+=$C_RESET$color
			prev=$color
		fi
		out+=$ch
	done
	BROOM_LINES[3]=" $out$C_RESET"
}
new_dust

# gauge of the selected bytes out of everything the checklist can free,
# GAUGE_PCT eases towards GAUGE_TARGET, both in percent
GAUGE_W=20
GAUGE_PCT=0
GAUGE_TARGET=0
update_gauge() {
	local key total=0 selected
	selected=$(selected_size)
	for key in "${ITEMS[@]}"; do
		total=$(( total + ${SIZES[$key]:-0} ))
	done
	if (( total > 0 )); then
		GAUGE_TARGET=$(( (selected * 100 + total / 2) / total ))
	else
		GAUGE_TARGET=0
	fi
	GAUGE_TEXT="$(convert_human "$selected") of $(convert_human "$total")"
}
gauge_step() {
	local diff=$(( GAUGE_TARGET - GAUGE_PCT )) step
	step=$(( diff / 3 ))
	(( step == 0 && diff > 0 )) && step=1
	(( step == 0 && diff < 0 )) && step=-1
	GAUGE_PCT=$(( GAUGE_PCT + step ))
}
# sets GAUGE_LINE, [=======>.....]  35% with no arrow head when empty or full
gauge_line() {
	local cells=$(( GAUGE_PCT * GAUGE_W / 100 )) bar empty pct  # full only at 100%
	printf -v bar '%*s' "$cells" ''
	bar=${bar// /=}
	(( cells > 0 && cells < GAUGE_W )) && bar=${bar%=}'>'
	printf -v empty '%*s' "$(( GAUGE_W - cells ))" ''
	empty=${empty// /.}
	printf -v pct '%3d%%' "$GAUGE_PCT"
	GAUGE_LINE=" $C_DIM[$C_RESET$C_ACCENT$C_BOLD$bar$C_RESET$C_DIM$empty]$C_RESET $C_ACCENT$C_BOLD$pct$C_RESET  $C_BOLD$GAUGE_TEXT$C_RESET selected$C_DIM, plus package caches$C_RESET"
}

# cache level slider, [=====|-----] medium with the knob at CACHE_LEVEL,
# sets SLIDER_PLAIN and SLIDER (colored)
SLIDER_W=11
slider() {
	local i pos fill empty
	for i in "${!CACHE_LEVELS[@]}"; do
		[ "${CACHE_LEVELS[i]}" = "$CACHE_LEVEL" ] && break
	done
	pos=$(( i * (SLIDER_W - 1) / (${#CACHE_LEVELS[@]} - 1) ))
	printf -v fill '%*s' "$pos" ''
	fill=${fill// /=}
	printf -v empty '%*s' "$(( SLIDER_W - 1 - pos ))" ''
	empty=${empty// /-}
	SLIDER_PLAIN="[$fill|$empty] $CACHE_LEVEL"
	SLIDER="$C_DIM[$C_RESET$C_ACCENT$C_BOLD$fill$C_RESET$C_BOLD|$C_RESET$C_DIM$empty]$C_RESET $C_BOLD$CACHE_LEVEL$C_RESET"
}

# append a line to FRAME, \e[K clears what's left of the previous frame's line
frame_line() {
	FRAME+=$1$'\e[K\n'
}

# usage: draw_row ROW TICKED LABEL [SIZE [STYLED]]
# STYLED is LABEL with colors, used on ticked rows outside the cursor
# the padding counts characters, printf's width would count bytes
draw_row() {
	local label=$3 styled=${5:-$3} pad size
	printf -v pad '%*s' "$(( 42 - ${#label} ))" ''
	printf -v size '%7s' "$4"
	if [ "$1" -eq "$CURSOR" ]; then
		local mark=' '
		[ "$2" = 1 ] && mark=$TICK
		frame_line "$C_CURSOR [$mark] $label$pad $size "$'\e[0m'
	elif [ "$2" = 1 ]; then
		frame_line " $C_DIM[$C_RESET$C_GREEN$C_BOLD$TICK$C_RESET$C_DIM]$C_RESET $styled$pad $C_YELLOW$size$C_RESET "
	else
		frame_line " $C_DIM[ ] $label$pad $size$C_RESET "
	fi
}

# key hints, usage: hints KEY DESC [KEY DESC...]
hints() {
	local line=
	while [ $# -gt 0 ]; do
		line+=" $C_ACCENT$C_BOLD$1$C_RESET $C_DIM$2$C_RESET "
		shift 2
	done
	frame_line "$line"
}

# the frame is built in FRAME and written in one go over the old one,
# clearing the screen first would make it flicker
draw_menu() {
	local i key size line label styled
	update_gauge
	FRAME=$'\e[H'
	for i in "${!LOGO[@]}"; do
		printf -v line ' %-14s' "${LOGO[i]}"
		frame_line "$C_ACCENT$C_BOLD$line$C_RESET   ${HEADER[i]}"
	done
	frame_line ''
	broom_lines
	for line in "${BROOM_LINES[@]}"; do
		frame_line "$line"
	done
	gauge_line
	frame_line "$GAUGE_LINE"
	frame_line ''
	for i in "${!ITEMS[@]}"; do
		key=${ITEMS[i]}
		size=
		[ -n "${SIZES[$key]}" ] && size=$(convert_human "${SIZES[$key]}")
		label=$(item_label "$key") styled=
		if [ "$key" = cache ]; then
			slider
			styled="$label  $SLIDER"
			label+="  $SLIDER_PLAIN"
		fi
		draw_row "$i" "${SELECTED[$key]}" "$label" "$size" "$styled"
	done
	frame_line ''
	draw_row "$NOCONFIRM_ROW" "$([ "$NOCONFIRM" = true ] && echo 1)" "No-confirm (package managers won't ask)"
	frame_line ''
	hints up/down move space tick a all/none left/right 'cache level'
	hints enter run q quit
	printf '%s\e[J' "$FRAME"  # \e[J clears anything below the frame
}

# animation tick, rewrites only the broom and gauge rows
draw_anim() {
	local line out=
	broom_lines
	gauge_line
	for line in "${BROOM_LINES[@]}" "$GAUGE_LINE"; do
		out+=$line$'\e[K\n'
	done
	printf '\e[%d;1H%s' "$BROOM_ROW" "${out%$'\n'}"
}

tui_restore() {
	printf '\e[?25h\e[?1049l'  # show cursor, leave alternate screen
}

menu_abort() {
	tui_restore
	trap - EXIT WINCH
	echo "Aborted, nothing was removed."
	exit 0
}

run_menu() {
	local key rest i all status redraw=true
	CURSOR=0
	trap tui_restore EXIT
	trap 'redraw=true' WINCH  # terminal resized
	printf '\e[?1049h\e[?25l'  # alternate screen, hide cursor
	while true; do
		if [ "$redraw" = true ]; then
			draw_menu
			redraw=false
		fi
		# wait for a key, or time out and draw the next animation frame
		status=0
		IFS= read -rsn1 -t "$TICK_TIME" key || status=$?
		if [ "$status" -gt 128 ]; then
			broom_step
			gauge_step
			draw_anim
			continue
		elif [ "$status" -ne 0 ]; then
			menu_abort  # input closed
		fi
		redraw=true
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
			q|Q) menu_abort ;;
		esac
	done
	tui_restore
	trap - EXIT WINCH
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

msg "Total directory space to be freed: $C_YELLOW$(convert_human "$(selected_size)")"

# ask for the sudo password once upfront
if [ "$DRYRUN" = false ]; then
	sudo -v
fi

# get total size of system
SIZE_BEFORE=$(df --output=used -B1 / | tail -1)

# pacman cache
if confirm pacman "Clean pacman cache?"; then
	msg "Cleaning pacman cache..."
	if [ "$DRYRUN" = true ]; then
		paccache -dk3 || step_failed "pacman cache"
	else
		paccache -rk3 || step_failed "pacman cache"
	fi
fi

#uninstalled package cache
if confirm uninstalled "Remove uninstalled package cache?"; then
	msg "Removing uninstalled package cache..."
	if [ "$DRYRUN" = true ]; then
		paccache -duk0 || step_failed "uninstalled package cache"
	else
		paccache -ruk0 || step_failed "uninstalled package cache"
	fi
fi

#orphaned packages
if confirm orphans "Remove orphaned packages?"; then
	msg "Removing orphaned packages..."
	mapfile -t ORPHANS < <(pacman -Qtdq)
	if [ ${#ORPHANS[@]} -gt 0 ]; then
		run sudo pacman -Rns "${NOCONFIRM_FLAG[@]}" "${ORPHANS[@]}" || step_failed "orphaned packages"
	else
		echo "    ${C_DIM}No orphans found.$C_RESET"
	fi
fi

#aur helper cache (-a: AUR only, the pacman cache is handled by paccache above)
for helper in "${AUR_HELPERS[@]}"; do
	if confirm "$helper" "Clean $helper cache?"; then
		msg "Cleaning $helper cache..."
		run "$helper" -Sca "${NOCONFIRM_FLAG[@]}" || step_failed "$helper cache"
	fi
done
if [ ${#AUR_HELPERS[@]} -eq 0 ] && [ "$USE_TUI" = false ]; then
	echo "No supported aur helpers found :("
fi

#flatpak
if command -v flatpak >/dev/null; then
	if confirm flatpak "Remove unused flatpak runtimes?"; then
		msg "Removing unused flatpak runtimes..."
		run flatpak uninstall --unused "${FLATPAK_FLAG[@]}" || step_failed "flatpak"
	fi
fi

#temp pacman
if confirm pacman_tmp "Remove leftover pacman files?"; then
	msg "Removing leftover pacman download temp dirs..."
	remove --sudo /var/cache/pacman/pkg/download-* || step_failed "leftover pacman files"
fi

#coredumps
if confirm coredumps "Remove systemd coredumps?"; then
	msg "Removing systemd coredumps..."
	remove --sudo /var/lib/systemd/coredump/* || step_failed "coredumps"
fi

#~/.cache
if confirm cache "Clean system cache (level: $CACHE_LEVEL)?"; then
	msg "Cleaning system cache (level: $CACHE_LEVEL)..."
	case $CACHE_LEVEL in
		low)
			if [ "$DRYRUN" = true ]; then
				echo "    $C_YELLOW[dry-run]$C_RESET would remove $(find_old_cache -printf '.' | wc -c) file(s) older than $CACHE_AGE days, $(convert_human "$(cache_size)")"
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
	msg "Cleaning system trash (${#TRASH_DIRS[@]} location(s))..."
	remove "${TRASH_CONTENTS[@]}" || step_failed "system trash"
fi

# readout size
if [ "$DRYRUN" = true ]; then
	msg "${C_YELLOW}Dry run, nothing was removed."
else
	SIZE_AFTER=$(df --output=used -B1 / | tail -1)
	SIZE_FREED=$(( SIZE_BEFORE - SIZE_AFTER ))
	msg "Total space freed: $C_GREEN$(convert_human "$SIZE_FREED")"
fi

# failed steps summary
if [ ${#FAILED[@]} -gt 0 ]; then
	echo "$C_ERR==> Steps that did not complete:${C_ERR:+$C_RESET}" >&2
	printf '    %s\n' "${FAILED[@]}" >&2
	exit 1
fi
