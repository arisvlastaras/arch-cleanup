# arch-cleanup

A simple cleanup script for Arch-based systems

## What it does

- Clears old pacman package cache (keeps last 3)
- Removes uninstalled package cache
- Removes orphaned packages
- Cleans paru/yay AUR cache
- Removes unused flatpak runtimes (if flatpak is installed)
- Deletes leftover pacman temp directories
- Removes systemd coredumps
- Cleans system cache with adjustable aggressiveness (see `-c`)
- Cleans system trash (including trash on mounted drives)
- Calculates size to be freed before committing
- Dry-run mode to preview what would be removed

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
arch-cleanup       # interactive
arch-cleanup -y    # noconfirm
arch-cleanup -n    # dry run, nothing is removed
arch-cleanup -n -y # dry run without prompts
arch-cleanup -c high # remove all of ~/.cache
arch-cleanup -h    # help
```

### Cache levels (`-c`)

| Level | Removes from `~/.cache` |
|---|---|
| `low` (default) | files not modified in 30 days, shader caches kept |
| `medium` | everything except shader caches |
| `high` | everything |

The kept shader caches and the 30 day cutoff are set by `KEEP_CACHES` and `CACHE_AGE` at the top of the script.

### Safety checks

The script refuses to run as root, exits if `paccache` is missing, and exits if pacman is currently running (`/var/lib/pacman/db.lck` exists). It asks for the sudo password once at the start.
