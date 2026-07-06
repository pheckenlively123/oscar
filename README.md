# oscar

My grab bag repo — where things go when they have no other home.

Right now what lives here is `scripts/update-all-fedora.sh` and `scripts/update-all-ubuntu.sh`, sibling scripts that update my Fedora or Ubuntu box in one shot.

## update-all-fedora.sh / update-all-ubuntu.sh

Self-contained Bash scripts that run all of the distro's update mechanisms in sequence and print a single pass/fail summary at the end. Each updater is independent — if one fails, the rest still run. The two scripts share the same structure and helpers; only the distro-specific pieces differ.

They cover:

- **Flatpak** — updates both the per-user and system-wide installs, then prunes unused runtimes.
- **System packages** — Fedora: `dnf upgrade --refresh`; Ubuntu: `apt-get update` + `apt-get dist-upgrade`.
- **PackageKit (pkcon)** — refreshes PackageKit's cache so KDE Discover stops staging redundant offline updates after dnf/apt has already done the work.
- **snap** — refreshes Snap packages.
- **fwupd** — refreshes LVFS metadata and applies firmware updates (BIOS/UEFI, SSDs, docks, peripherals).
- **Reboot check** — at the end, reports whether updated core packages (kernel, libc, systemd, …) require a reboot. Fedora: `dnf needs-restarting -r`; Ubuntu: the `/run/reboot-required` marker (needs `update-notifier-common`, installed by default).

Any tool that isn't installed is simply skipped and noted in the summary.

## Requirements

- **Bash** (uses arrays, `[[ ]]`, here-strings — not POSIX `sh`).
- **The matching distro** — `update-all-fedora.sh` targets Fedora's dnf stack; `update-all-ubuntu.sh` targets Ubuntu's apt stack.
- **`sudo` / root** — the system package manager, pkcon, snap, and fwupd need root. Each script re-execs itself under `sudo` automatically; flatpak user-scope work drops back to the invoking user.
- **The updater tools you actually use** — `flatpak`, `dnf`/`apt-get`, `pkcon`, `snap`, `fwupdmgr`. None are mandatory; missing ones are skipped.

## Usage

```bash
./scripts/update-all-fedora.sh   # on Fedora
./scripts/update-all-ubuntu.sh   # on Ubuntu
```

Run it as your normal user — it elevates itself with `sudo` when needed. No arguments, no config.

Exit code is `0` if everything succeeded or was skipped, non-zero if any updater failed.

## Project structure

```
.
├── scripts/
│   ├── update-all-fedora.sh   # the whole tool (Fedora)
│   └── update-all-ubuntu.sh   # the whole tool (Ubuntu)
├── docs/
│   └── error-handling-guidelines.md
├── AGENTS.md           # onboarding for AI agents
├── CLAUDE.md
├── LICENSE             # GPL v2
└── README.md
```

## Further reading

- [`AGENTS.md`](AGENTS.md) — repo conventions and onboarding (for humans and AI agents alike).
- [`docs/error-handling-guidelines.md`](docs/error-handling-guidelines.md) — the `run_step` wrapper, `OK_CODES`, the `RESULTS` summary contract, and the privilege model. Required reading before touching the scripts.
