#!/bin/bash

set -e  # stop on first error

NOCONFIRM=false
while getopts "y" opt; do
	case $opt in
		y) NOCONFIRM=true ;;
		*) echo "Usage: $0 [-y]"; exit 1 ;;
	esac
done

if [ "$NOCONFIRM" = true ]; then
	AUR_HELPER_FLAG="--noconfirm"
else
	AUR_HELPER_FLAG=""
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

# display total space to be freed
get_size() {
    du -sb "$1" 2>/dev/null | cut -f1
}
convert_human() {
	numfmt --to=iec $1
}
SIZE_BEFORE=$(( \
	$(get_size /var/cache/pacman/pkg/download-*) + \
       	$(get_size ~/.cache) + \
	$(get_size ~/.local/share/Trash)  \
))
echo "Total directory space to be freed: $(convert_human $SIZE_BEFORE)"

# pacman cache
if confirm "Clean pacman cache"; then
	echo "==> Cleaning pacman cache..."
	paccache -rk3
fi

#uninstalled package cache
if confirm "Remove uninstalled package cache?"; then
	echo "==> Removing uninstalled package cache..."
	paccache -ruk0
fi

#orphaned packages
if confirm "Remove orphaned packages?"; then
	echo "==> Removing orphaned packages..."
	ORPHANS=$(pacman -Qtdq) || true
	if [ -n "$ORPHANS" ]; then
    		sudo pacman -Rns $ORPHANS
	else
    		echo "No orphans found."
	fi
fi

#aur helper cache
echo "==> Detecting aur helper..."
if command -v paru; then
	#paru
	if confirm "Clean paru cache?"; then
		echo "==> Cleaning paru cache..."
		paru -Sc $AUR_HELPER_FLAG
	fi
elif command -v yay; then
	#yay
	if confirm "Clean yay cache?"; then
		echo "==> Cleaning yay cache..."
		yay -Sc $AUR_HELPER_FLAG
	fi
else
	echo "No supported aur helpers found :("
fi

#temp pacman
if confirm "Remove leftover pacman files?"; then
	echo "==> Removing leftover pacman download temp dirs..."
	sudo rm -rf /var/cache/pacman/pkg/download-*
fi

#~/.cache
if confirm "Clean system cache?"; then
	echo "==> Cleaning system cache..." 
	rm -rf ~/.cache/*
fi

#trash
if confirm "Clean system trash?"; then
	echo "==> Cleaning system trash..."
	rm -rf ~/.local/share/Trash/files/*
	rm -rf ~/.local/share/Trash/info/*
fi
