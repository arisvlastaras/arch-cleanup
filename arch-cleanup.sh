#!/bin/bash

set -e  # stop on first error

echo "==> Cleaning pacman cache (keep last 3)..."
paccache -rk3

echo "==> Removing uninstalled package cache..."
paccache -ruk0

echo "==> Removing orphaned packages..."
ORPHANS=$(pacman -Qtdq)
if [ -n "$ORPHANS" ]; then
    sudo pacman -Rns $ORPHANS
else
    echo "No orphans found."
fi

echo "==> Cleaning paru cache..."
paru -Sc --noconfirm

echo "==> Removing leftover pacman download temp dirs..."
sudo rm -rf /var/cache/pacman/pkg/download-*

echo "==> Cleaning system cache..." 
rm -rf ~/.cache/*

echo "==> Cleaning system trash..."
rm -rf ~/.local/share/Trash/files/*
rm -rf ~/.local/share/Trash/info/*
