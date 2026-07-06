# Error Handling Guidelines

These rules govern error handling in `scripts/update-all-fedora.sh` and `scripts/update-all-ubuntu.sh`, and any updater added to them. They encode conventions specific to this repo; follow them exactly. Examples below quote the Fedora script; the Ubuntu script follows the same contract (with `apt` in place of `dnf`, and `classify_reboot_marker` — the `/run/reboot-required` three-way classifier — in place of `classify_reboot_result`).

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
- A `label` is required. A call with an empty/missing label (unreachable from any current call site, but guarded defensively under `set -u`) degrades through `fail` + a distinct `RESULTS` line, `FAIL run_step (no label)` — note this does not follow the `FAIL <label> (exit <rc>)` shape used elsewhere, since there is no label to interpolate.

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
# LC_ALL=C and LANGUAGE= are both required to force English output. LANG=C alone
# does not override LC_ALL or LANGUAGE; GLib (used by pkcon) checks those first.
# Without this, grep patterns fail on non-English systems.
pk_out=$(LC_ALL=C LANGUAGE='' pkcon update -y -p 2>&1); pk_rc=$?
printf '%s\n' "$pk_out"
case "$(pk_classify_result "$pk_rc" "$pk_out")" in
    ok)
        ok "PackageKit update completed."
        RESULTS+=("OK   PackageKit (update)")
        ;;
    timeout)
        ok "PackageKit update: D-Bus timeout (ignored — see pk_classify_result for why)."
        RESULTS+=("OK   PackageKit (update) (D-Bus timeout, ignored)")
        ;;
    *)
        fail "PackageKit update failed (exit ${pk_rc})."
        RESULTS+=("FAIL PackageKit (update) (exit ${pk_rc})")
        ;;
esac
```

When a tool's outcome has more than a simple ok/fail split — e.g. pkcon's "ok" / "known D-Bus-timeout quirk, treat as ok" / "genuine fail" — extract the classification into a small, pure `echo`-based function (`pk_classify_result`, alongside its `PK_NOTHING_TO_DO_PATTERN`, defined near `run_step`) instead of inlining the `grep` chain at each call site. This gives the selftest a single function to call directly with synthetic `rc`/`out` pairs, so the match pattern and the branching logic around it stay covered by one source of truth instead of a hand-copied duplicate that can silently drift.

The dnf `needs-restarting -r` reboot check (see the reboot-hint section near the end of the script) follows the same pattern via `classify_reboot_result <rc> <output>`: its 5-way split (missing plugin / no reboot / reboot required / ambiguous / unknown exit) is a pure function defined next to `pk_classify_result`, covered by its own selftest assertions for all 5 branches, rather than living only in the live call site's `if`/`elif` chain.

Similarly, `pk_note_for <dnf_failed> <pk_refresh_failed>` (defined alongside `pk_classify_result`) builds the annotation suffix appended to the PackageKit (update) `RESULTS`/output line when an upstream step (the dnf upgrade or the PackageKit cache refresh) failed, so an apparent OK from step 2b isn't mistaken for a fully-verified post-upgrade sync. It is extracted the same way and for the same reason — the selftest covers all 4 `dnf_failed`/`pk_refresh_failed` flag combinations directly instead of only through the inline call site.

The current pattern (`PK_NOTHING_TO_DO_PATTERN` in the script — that definition, not this list, is authoritative) matches these pkcon "nothing to do" messages, each anchored to a whole line (`^...$`) to avoid matching error strings that contain the phrase as a substring:
- `^nothing to update$` — no pending packages in cache
- `^no updates available$` — cache shows nothing pending
- `^nothing to do$` — generic "already current"
- `^no packages require updating( to newer versions)?\.?$` — pkcon + DNF5 backend (Fedora 41+): exits 5 despite having nothing to install. The optional trailing text is verified against a real Fedora 44 transcript ("No packages require updating to newer versions."); the earlier bare-phrase anchor turned this routine outcome into a false FAIL in production. Do not narrow it back.

All four alternatives are anchored, not just `nothing to do` — an unanchored substring match on any of them would reintroduce the same false-OK risk (a genuine error message that happens to contain one of these phrases would otherwise be misclassified as success). The other three alternatives are unverified against real transcripts; if one ever shows leading/trailing text in the wild, widen it the same way the fourth was.

Avoid bare `'no (updates|packages)'` — it also matches error fragments, causing false OKs. `'updated 0 packages'` is likewise omitted — it can appear in failure output too.

A separate `timeout` outcome (pkcon + DNF5 backend, Fedora 41+: the daemon finishes the transaction but the D-Bus client times out waiting for the completion signal, exiting 1 with "Command failed: Timeout was reached") is also classified as OK, since it's a cosmetic D-Bus race rather than a real failure — but reported with its own `(D-Bus timeout, ignored)` suffix in `RESULTS` so it's distinguishable from a plain success. This classification requires BOTH `rc == 1` AND the fuller, specific message text (`"Command failed: Timeout was reached"`, not just `"timeout was reached"`) — the bare substring is also libcurl's stock text for `CURLE_OPERATION_TIMEDOUT`, so matching it alone (regardless of exit code) could misclassify a genuine network/repo timeout as this benign D-Bus race.

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

All helpers — including `fail` and `alert` — write to **stdout** by design: this is an interactive-terminal tool, and the exit code (not the output stream) is the machine-readable failure signal. Do not refactor them to write to stderr.

## Privilege model

The script re-execs itself under `sudo` (`exec sudo bash "$SELF" "$@"`, where `SELF` is the `realpath`-resolved script path) when not root, because dnf/pkcon/snap/fwupd need root. `INVOKING_USER` is captured **before** elevation so user-scope work can drop back down via `as_user`. When adding a command that must run as the real user (e.g. `flatpak --user`), wrap it in `as_user`; everything else runs as root after the re-exec — do not add redundant `sudo` calls.
