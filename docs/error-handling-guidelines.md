# Error Handling Guidelines

These rules govern error handling in `scripts/update-all.sh` and any updater added to it. They encode conventions specific to this repo; follow them exactly.

## Core philosophy: `set -u`, never `set -e`

The script uses `set -u` (unset variables are errors) but **deliberately omits `set -e`**. Do not add `set -e` or `set -o pipefail`. The whole point is that one updater failing must never abort the others — every updater runs to completion and outcomes are collected. If a command's failure should be fatal, handle it explicitly (see the `sudo` re-exec, which `exit 1`s by hand).

Because `set -u` is active, always guard possibly-unset expansions with `${VAR:-}` (e.g. `${OK_CODES:-}`, `${1:-}`, `${SUDO_USER:-$USER}`).

## `run_step` — the standard updater wrapper

Run every updater command through `run_step`, not directly. It prints the `==> Updating <label>...` banner, runs the command, classifies the exit code, prints `[ OK ]`/`[FAIL]`, and appends a line to `RESULTS`.

```bash
run_step "snap" -- snap refresh
```

Rules:
- First arg is a human-readable `label`; it appears in output and in the summary.
- The literal `--` separator is optional but conventional — it visually divides the label from the command and is stripped if present.
- Everything after is the command + args, run via `"$@"` (no `eval`, no quoting tricks). Pass real argv, not a string.
- `run_step` returns the command's real `rc` on failure, `0` on success — but the script never branches on that return value; outcome flows through `RESULTS` instead.

## `OK_CODES` — tolerating non-zero "success" exits

Some tools signal "nothing to do" / "already current" with a non-zero exit that is not a real failure. Pass these as extra success codes via the `OK_CODES` environment-style prefix on the same line:

```bash
OK_CODES=2 run_step "fwupd (refresh)" -- fwupdmgr refresh --force
OK_CODES=2 run_step "fwupd (update)"  -- fwupdmgr update --assume-yes
```

- `OK_CODES` is a space-separated list of additional codes treated as success (`0` is always included).
- It is **single-use**: `run_step` reads it, then resets it to empty so it never leaks into the next call. Set it fresh on each call that needs it; never rely on it persisting.

## When a tool reports status via output text, not exit code

`run_step` only inspects exit codes. For tools whose exit code is unreliable and which announce "no updates" in their stdout/stderr (PackageKit's `pkcon update`, dnf's `needs-restarting`), **do not use `run_step`**. Instead inline the pattern: capture output, print it, and decide with `grep`:

```bash
info "Updating PackageKit (pending packages, if any)..."
pk_out=$(pkcon update -y -p 2>&1); pk_rc=$?
printf '%s\n' "$pk_out"
if [[ $pk_rc -eq 0 ]] || grep -qiE 'no (updates|packages)|nothing to do' <<<"$pk_out"; then
    ok "PackageKit update completed."
    RESULTS+=("OK   PackageKit (update)")
else
    fail "PackageKit update failed (exit ${pk_rc})."
    RESULTS+=("FAIL PackageKit (update, exit ${pk_rc})")
fi
```

When inlining, you are responsible for printing the banner, echoing captured output, and appending to `RESULTS` yourself — match `run_step`'s format.

## The `RESULTS` array — the single source of truth for outcomes

Every code path that touches a tool must append exactly one line to `RESULTS`. `run_step` does this automatically; inline blocks and skip branches must do it manually.

Line format — the **leading keyword is load-bearing** because the summary parses it:
- `OK   <label>` — success
- `FAIL <label> (exit <rc>)` — failure
- `SKIP <label> (not installed)` — tool absent

```bash
RESULTS+=("SKIP snap (not installed)")
```

## Tool-presence guards

Gate every updater behind `have <cmd>` (a wrapper over `command -v`). The `else` branch must `warn` and append a `SKIP` line so missing tools show up in the summary rather than vanishing:

```bash
if have snap; then
    run_step "snap" -- snap refresh
else
    warn "snap not found; skipping snap update."
    RESULTS+=("SKIP snap (not installed)")
fi
```

## Final summary and exit code

The summary loop walks `RESULTS` and sets `overall=1` if any line is neither `OK*` nor `SKIP*` (i.e. a `FAIL`). The script ends with `exit "$overall"`.

Consequences to preserve:
- `SKIP` does **not** fail the run — a missing tool is acceptable, a present-but-broken tool is not.
- Only `FAIL` lines flip the exit code. Keep the keyword prefixes consistent or the exit code and `case` matching break.
- Anything you print after the summary (e.g. the reboot hint) must not change `overall`; it is informational only.

## Output helpers

Use `info`/`ok`/`warn`/`fail` for all user-facing messages — avoid raw `echo`/`printf` for status. They apply consistent coloring/markers. Color variables come from `tput ... 2>/dev/null || true`, so they degrade to empty strings on dumb terminals; never assume color is present.

## Privilege model

The script re-execs itself under `sudo` (`exec sudo --preserve-env=SUDO_USER bash "$0" "$@"`) when not root, because dnf/snap/fwupd need root. `INVOKING_USER` is captured **before** elevation so user-scope work can drop back down via `as_user`. When adding a command that must run as the real user (e.g. `flatpak --user`), wrap it in `as_user`; everything else runs as root after the re-exec — do not add redundant `sudo` calls.
