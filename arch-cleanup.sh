#!/bin/bash

set -e  # stop on first error

# pacman cache
read -p "Clean pacman cache? [Y/n]: " answer
if [ "$answer" = "n" ] || [ "$answer" = "N" ]; then
	echo "Skipping..."
else
	echo "==> Cleaning pacman cache..." 
	paccache -rk3
fi

#uninstalled package cache
echo "==> Removing uninstalled package cache..."
paccache -ruk0

#orphaned packages
read -p "Remove orphaned packages? [Y/n]: " answer
if [ "$answer" = "n" ] || [ "$answer" = "N" ]; then
	echo "Skipping..."
else
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
	read -p "Clean paru cache? [Y/n]: " answer
	if [ "$answer" = "n" ] || [ "$answer" = "N" ]; then
		echo "Skipping..."
	else
		echo "==> Cleaning paru cache..."
		paru -Sc
	fi
elif command -v yay; then
	read -p "Clean yay cache? [Y/n]: " answer
	if [ "$answer" = "n" ] || [ "$answer" = "N" ]; then
		echo "Skipping..."
	else
		echo "==> Cleaning yay cache..."
		yay -Sc
	fi
else
	echo "No supported aur helpers found :("
fi

#temp pacman
read -p "Remove leftover pacman files? [Y/n]: " answer
if [ "$answer" = "n" ] || [ "$answer" = "N" ]; then
	echo "Skipping..."
else
	echo "==> Removing leftover pacman download temp dirs..."
	sudo rm -rf /var/cache/pacman/pkg/download-*
fi

#~/.cache
read -p "Remove leftover pacman files? [Y/n]: " answer
if [ "$answer" = "n" ] || [ "$answer" = "N" ]; then
	echo "Skipping..."
else
	echo "==> Cleaning system cache..." 
	rm -rf ~/.cache/*
fi

#trash
read -p "Clean trash? [Y/n]: " answer
if [ "$answer" = "n" ] || [ "$answer" = "N" ]; then
	echo "Skipping..."
else
	echo "==> Cleaning system trash..."
	rm -rf ~/.local/share/Trash/files/*
	rm -rf ~/.local/share/Trash/info/*
fi
