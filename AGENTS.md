# AGENTS.md

Onboarding for AI agents (Claude, Cursor, CodeRabbit, etc.) working in the `oscar` repo.

## What this repo is

`oscar` is a personal "grab bag" repo (see `README.md`). Today it contains exactly one piece of real code: `scripts/update-all.sh`, a self-contained Fedora Linux system-maintenance script that updates flatpak, dnf, PackageKit (pkcon), snap, and firmware (fwupd), then checks whether a reboot is needed.

There is no build system, no package manifest, no external test framework, and no CI; the script does have a built-in selftest (see "Validating changes"). The "project" is a single Bash script plus its docs. Keep that shape: do not introduce a framework, config files, dependencies, or a directory structure unless a task genuinely requires it.

## Layout

- `scripts/update-all.sh` — the entire tool. All logic lives here.
- `docs/` — prose guidelines for working in the repo (see docs index below).
- `.coderabbit.yaml` — feeds `docs/*-guidelines.md` to CodeRabbit as code guidelines; renaming a guidelines doc silently detaches it from review tooling unless this pattern still matches.
- `README.md` — one-line project description.
- `LICENSE` — GPL v2.

## Docs index

Read the relevant guideline before changing matching code. These are authoritative; this file does not repeat them.

- `docs/error-handling-guidelines.md` — error handling, the `run_step` wrapper, `OK_CODES`, the `RESULTS` array and its load-bearing keyword prefixes, tool-presence (`have`) guards, the privilege/`as_user` model, output helpers, and the summary/exit-code contract. **Required reading before adding or modifying any updater.**

## Cross-cutting conventions

### Script shape and dependencies

- `#!/usr/bin/env bash` — Bash features (arrays, `[[ ]]`, `<<<` here-strings, `${VAR:-default}`) are expected and fine.
- The script is **self-contained and argument-less**: no flag parsing, no config file, no sourced helper libraries. Do not add external dependencies.
- `"$@"` is forwarded through the `sudo` re-exec. If you add argument handling, it must survive that re-exec — args are parsed *after* re-execution, as root.

### Structure and ordering

- The body is organized as **numbered, commented sections** (`# 1. Flatpak`, `# 2. dnf`, `# 2b. PackageKit`, etc.) divided by `# --- section title ---` rule comments.
- Order matters where there are data dependencies: PackageKit (`2b`) refreshes *after* dnf (`2`) because dnf changes the package set pkcon caches. Preserve such ordering and document it inline when you add a step.
- New updaters generally slot into this numbered list before the `# --- summary ---` section.

### Comment style — explain *why*, not *what*

This script is deliberately comment-heavy, and comments justify decisions rather than narrate code (e.g. the long PackageKit explanation, the dnf4-vs-dnf5 `--reboothint` note, why `set -e` is omitted). When a line exists to work around a tool quirk or non-obvious behavior, write the rationale next to it.

### Shell idioms used throughout

- **Graceful degradation:** probe calls use `... 2>/dev/null || true` so they never abort on absence.
- **Output via helpers, never bare `echo` for status:** use `info`/`ok`/`warn`/`fail`. Plain `printf`/`echo` is reserved for echoing captured tool output.
- **Capture-then-decide for chatty tools:** `out=$(cmd 2>&1); rc=$?` followed by `printf '%s\n' "$out"` and a `grep -qiE` on the text.
- **Local scoping:** functions declare `local`/`local -a` to avoid leaking state. The one intentional global is the `RESULTS` array.
- Quote expansions and guard possibly-unset ones with `${VAR:-}` (mandated by `set -u`).

## How to add a new updater

1. Pick the right place in the numbered section list and add a comment header.
2. Gate the whole block behind `if have <cmd>; then ... else ... fi`; in the `else` branch `warn` and append `SKIP <label> (not installed)` to `RESULTS`.
3. Inside the guard, prefer `run_step "<label>" -- <cmd> <args...>`.
4. If the tool returns a non-zero "nothing to do" code, prefix the call with `OK_CODES="<codes>"`.
5. If the tool reports status via stdout text rather than exit code, inline the capture-print-grep-append pattern instead.
6. If the command must run as the real user, wrap it in `as_user`.

(Steps 2–6 are governed in detail by `docs/error-handling-guidelines.md`; follow it exactly.)

## Common pitfalls

- **Don't add `set -e` or `set -o pipefail`.** Their absence is intentional.
- **The `RESULTS` keyword prefix is load-bearing.** The summary `case` parses `OK`/`SKIP`/`FAIL`; a typo silently breaks the exit code.
- **Nothing printed after the summary may change `overall`.** The script ends with `exit "$overall"`.
- **`OK_CODES` is single-use** — set it fresh on each call that needs it.
- **Don't double-elevate.** Code after the privilege check already runs as root.

## Validating changes

There is no external test framework, but the script has a built-in selftest. Before considering a change done:
- Run `UPDATE_ALL_SELFTEST=1 bash scripts/update-all.sh` — an assertion suite covering `run_step`, `OK_CODES` handling, the classifiers, `as_user`, and the flock primitive. It runs unprivileged and must report zero failures.
- Run `bash -n scripts/update-all.sh` (syntax check) and, if available, `shellcheck scripts/update-all.sh`.
- Verify every code path touching a tool appends exactly one `RESULTS` line with the correct keyword prefix.
- Do not actually run the updaters in an unintended environment — the script mutates the host system and requires root.
