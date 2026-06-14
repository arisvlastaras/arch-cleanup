# arch-cleanup

A simple cleanup script for Arch-based systems

## What it does

- Clears old pacman package cache (keeps last 3)
- Removes uninstalled package cache
- Removes orphaned packages
- Cleans paru/yay AUR cache
- Deletes leftover pacman temp directories
- Cleans system cache and system trash
- Calculates size to be freed before committing

## Requirements

- `pacman-contrib` (for `paccache`)
```bash
sudo pacman -S pacman-contrib
```

## Installation

- Clone and run directly:
```bash
git clone https://github.com/arisvlastaras/arch-cleanup.git
cd arch-cleanup
chmod +x arch-cleanup.sh
./arch-cleanup.sh
```
- Or copy to `/usr/local/bin/` for global access:
```bash
git clone https://github.com/arisvlastaras/arch-cleanup.git
cd arch-cleanup
sudo cp arch-cleanup.sh /usr/local/bin/arch-cleanup
sudo chmod +x /usr/local/bin/arch-cleanup
```

## Usage
```bash
arch-cleanup    # interactive
arch-cleanup -y # noconfirm
```
