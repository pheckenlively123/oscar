# oscar

My grab bag repo — where things go when they have no other home.

Right now there's exactly one thing living here: `scripts/update-all.sh`, a script that updates my Fedora box in one shot.

## update-all.sh

A self-contained Bash script that runs all of Fedora's update mechanisms in sequence and prints a single pass/fail summary at the end. Each updater is independent — if one fails, the rest still run.

It covers:

- **Flatpak** — updates both the per-user and system-wide installs, then prunes unused runtimes.
- **dnf** — upgrades system RPM packages (`dnf upgrade --refresh`).
- **PackageKit (pkcon)** — refreshes PackageKit's cache so KDE Discover stops staging redundant offline updates after dnf has already done the work.
- **snap** — refreshes Snap packages.
- **fwupd** — refreshes LVFS metadata and applies firmware updates (BIOS/UEFI, SSDs, docks, peripherals).
- **Reboot check** — at the end, reports whether updated core packages (kernel, glibc, systemd, …) require a reboot.

Any tool that isn't installed is simply skipped and noted in the summary.

## Requirements

- **Bash** (uses arrays, `[[ ]]`, here-strings — not POSIX `sh`).
- **A Fedora / systemd Linux system** — this targets `dnf` and Fedora's update stack.
- **`sudo` / root** — dnf, pkcon, snap, and fwupd need root. The script re-execs itself under `sudo` automatically; flatpak user-scope work drops back to the invoking user.
- **The updater tools you actually use** — `flatpak`, `dnf`, `pkcon`, `snap`, `fwupdmgr`. None are mandatory; missing ones are skipped.

## Usage

```bash
./scripts/update-all.sh
```

Run it as your normal user — it elevates itself with `sudo` when needed. No arguments, no config.

Exit code is `0` if everything succeeded or was skipped, non-zero if any updater failed.

## Project structure

```
.
├── scripts/
│   └── update-all.sh   # the whole tool
├── docs/
│   └── error-handling-guidelines.md
├── AGENTS.md           # onboarding for AI agents
├── CLAUDE.md
├── LICENSE             # GPL v2
└── README.md
```

## Further reading

- [`AGENTS.md`](AGENTS.md) — repo conventions and onboarding (for humans and AI agents alike).
- [`docs/error-handling-guidelines.md`](docs/error-handling-guidelines.md) — the `run_step` wrapper, `OK_CODES`, the `RESULTS` summary contract, and the privilege model. Required reading before touching the script.
