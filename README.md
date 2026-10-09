# arch-cleanup

A simple cleanup script for Arch-based systems

## What it does

- Clears old pacman package cache (keeps last 3)
- Removes uninstalled package cache
- Removes orphaned packages
- Cleans paru/yay AUR cache (AUR only, the pacman cache is handled by `paccache`)
- Removes unused flatpak runtimes (if flatpak is installed)
- Deletes leftover pacman temp directories
- Removes systemd coredumps
- Cleans system cache with adjustable aggressiveness (see `-c`)
- Cleans system trash (including trash on mounted drives)
- Checklist to pick which steps to run, with the size each one frees
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
arch-cleanup       # interactive checklist
arch-cleanup -y    # noconfirm, run every step
arch-cleanup -n    # dry run, nothing is removed
arch-cleanup -n -y # dry run without prompts
arch-cleanup -c high # remove all of ~/.cache
arch-cleanup -h    # help
```

### Checklist

Run in a terminal without `-y`, the script opens a checklist of the steps that apply to your system (the AUR and flatpak steps only show up if paru/yay or flatpak is installed). Everything starts ticked. Below the steps is a no-confirm option, unticked by default, which stops pacman, the AUR helper and flatpak from asking for confirmation (the same as `-y` for the ticked steps).

| Key | Action |
|---|---|
| `↑`/`↓` or `k`/`j` | move |
| `space` | tick/untick |
| `a` | tick/untick all |
| `←`/`→` or `h`/`l` | change the `~/.cache` level |
| `enter` | run the ticked steps |
| `q` | quit without removing anything |

Steps with a known size show it next to them, and the total for the ticked steps is shown below the list. The package cache steps (`paccache`, orphans, AUR, flatpak) aren't included in that total. When input isn't a terminal (e.g. piped), the script falls back to Y/n prompts.

### Cache levels (`-c`)

| Level | Removes from `~/.cache` |
|---|---|
| `low` | files not modified in 30 days, shader caches kept |
| `medium` (default) | everything except shader caches |
| `high` | everything |

The kept shader caches and the 30 day cutoff are set by `KEEP_CACHES` and `CACHE_AGE` at the top of the script.

### Safety checks

The script refuses to run as root, exits if `paccache` is missing, and exits if pacman is currently running (`/var/lib/pacman/db.lck` exists). It asks for the sudo password once at the start.

If a cleanup step fails, the script carries on with the rest, lists the failed steps at the end and exits with status 1.
