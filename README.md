# arch-cleanup

A simple cleanup script for Arch-based systems

## What it does

- Clears old pacman package cache (keeps last 3)
- Removes uninstalled package cache
- Removes orphaned packages
- Cleans paru AUR cache
- Deletes leftover pacman temp directories
- Shows ~/.cache usage

## Usage

```bash
git clone https://github.com/yourusername/arch-cleanup.git
cd arch-cleanup
chmod +x arch-cleanup.sh
./arch-cleanup.sh
```

## Requirements

- `pacman-contrib` (for `paccache`)
