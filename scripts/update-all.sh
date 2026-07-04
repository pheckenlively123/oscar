#!/usr/bin/env bash
#
# update-all.sh — update flatpak, dnf (system), snap, and firmware (fwupd).
#
# Each updater runs independently; a failure in one does not stop the others.
# A summary of successes/failures is printed at the end.
#
# Scope notes:
#   * Flatpak is updated for BOTH the per-user and system-wide installations.
#     The user-scope update runs as the invoking user, not as root.
#   * dnf, snap, and fwupd require root and run under sudo.

set -u  # treat unset variables as errors; we intentionally do NOT use -e
        # because we want to keep going after a failed updater.

# Pin PATH to a known-safe value so all tool lookups are predictable when
# running as root regardless of the invoking user's PATH. All tools used by
# this script (dnf, flatpak, pkcon, fwupdmgr, snap, flock, id, realpath,
# tput, grep, bash) live in /usr/sbin or /usr/bin on Fedora.
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# --- pretty output helpers -------------------------------------------------
bold=$(tput bold 2>/dev/null || true)
red=$(tput setaf 1 2>/dev/null || true)
green=$(tput setaf 2 2>/dev/null || true)
yellow=$(tput setaf 3 2>/dev/null || true)
reset=$(tput sgr0 2>/dev/null || true)

info()  { printf '%s==>%s %s\n' "$bold" "$reset" "$*"; }
ok()    { printf '%s[ OK ]%s %s\n' "$green" "$reset" "$*"; }
warn()  { printf '%s[WARN]%s %s\n' "$yellow" "$reset" "$*"; }
fail()  { printf '%s[FAIL]%s %s\n' "$red" "$reset" "$*"; }
alert() { printf '%s%s[ALRT]%s %s\n' "$bold" "$yellow" "$reset" "$*"; }

# Track results for the final summary.
declare -a RESULTS=()
OK_CODES=""  # prevent caller-exported OK_CODES from contaminating the first run_step call

# have <command> — true if a command exists on PATH.
have() { command -v "$1" >/dev/null 2>&1; }

# run_step <label> -- <command...>
# Runs a command, records the outcome, and reports it.
# Optionally accept extra "success" exit codes (e.g. fwupd's "nothing to do")
# by setting OK_CODES to a space-separated list before calling.
#
# OK_CODES convention: set it on the same line as the call (e.g. OK_CODES=2 run_step ...).
# run_step reads it and immediately resets it to "" so it never leaks to the next call.
# Do NOT call run_step from inside $() or a pipe: OK_CODES="" runs in the subshell and
# does not propagate back, leaving a stale value that silently widens success-exit-codes.
# OK_CODES must contain only space-separated numeric values (e.g. "2" or "2 3").
run_step() {
    local label=$1
    local code
    shift
    [[ "${1:-}" == "--" ]] && shift

    local -a ok_codes
    read -ra ok_codes <<< "0 ${OK_CODES:-}"
    OK_CODES=""  # reset for the next call

    for code in "${ok_codes[@]}"; do
        [[ "$code" =~ ^[0-9]+$ ]] || {
            fail "run_step: invalid OK_CODES value '${code}' (not a non-negative integer)."
            RESULTS+=("FAIL ${label} (invalid OK_CODES)")
            return 1
        }
    done

    if [[ $# -eq 0 ]]; then
        # Defensive assertion — all call sites pass a command; this branch should not be reached.
        fail "run_step: '${label}' — no command specified."
        RESULTS+=("FAIL ${label} (no command provided to run_step)")
        return 1
    fi

    info "Updating ${label}..."
    "$@"
    local rc=$?

    for code in "${ok_codes[@]}"; do
        if [[ $rc -eq $code ]]; then
            ok "${label} update completed."
            RESULTS+=("OK   ${label}")
            return 0
        fi
    done

    fail "${label} update failed (exit code ${rc})."
    RESULTS+=("FAIL ${label} (exit ${rc})")
    return "$rc"
}

# --- pkcon "nothing to do" classification -----------------------------------
# Single source of truth for the live PackageKit step (2b) AND the selftest,
# so the two can never hand-drift out of sync (one edited without the other).
#
# Pattern deliberately narrow: bare "no packages"/"no updates" and "updated 0
# packages" are excluded because they also appear inside pkcon's failure/error
# output, which would cause false OKs. "^nothing to do$" is anchored for the
# same reason.
readonly PK_NOTHING_TO_DO_PATTERN='nothing to update|no updates available|^nothing to do$|no packages require updating'

# pk_classify_result <rc> <output> — classify a `pkcon update` outcome from its
# exit code and captured stdout/stderr text. Echoes exactly one of:
#   ok      — succeeded, or nothing was pending (matches PK_NOTHING_TO_DO_PATTERN)
#   timeout — pkcon + DNF5 backend (Fedora 41+): the daemon finishes the
#             transaction but the D-Bus client times out waiting for the
#             completion signal and exits 1 with "Command failed: Timeout was
#             reached". Cosmetic D-Bus race, not a real failure.
#   fail    — genuine failure
pk_classify_result() {
    local rc=$1 out=$2
    if [[ $rc -eq 0 ]] || grep -qiE "$PK_NOTHING_TO_DO_PATTERN" <<<"$out"; then
        echo "ok"
    elif grep -qi 'timeout was reached' <<<"$out"; then
        echo "timeout"
    else
        echo "fail"
    fi
}

# --- identify the invoking (non-root) user ---------------------------------
# Captured BEFORE we elevate, so we can run user-scope flatpak as them.
INVOKING_USER="${SUDO_USER:-${USER:-root}}"
id -u "$INVOKING_USER" &>/dev/null
_invoking_user_rc=$?
if [[ $_invoking_user_rc -eq 127 ]]; then
    # 127 = `id` itself was not found/executable — the check failed, we don't
    # actually know whether the user is invalid. Say so rather than claiming
    # the user is bad.
    fail "Cannot verify invoking user '${INVOKING_USER}': 'id' command not found or failed to execute."
    exit 1
elif [[ $_invoking_user_rc -ne 0 ]]; then
    fail "Invoking user '${INVOKING_USER}' (from \${SUDO_USER:-\${USER}}) is not a valid system user; aborting."
    exit 1
fi
unset _invoking_user_rc
CURRENT_USER="$(id -un)" \
    || { fail "Cannot determine current user via id -un; aborting."; exit 1; }
# CURRENT_USER is always "root" after the privilege re-exec

# as_user <command...> — run a command as the invoking user.
# Falls back to running directly if we're already that user.
#
# Note: if INVOKING_USER is "root" (direct root execution without sudo),
# user-scope operations run as root — known limitation; see the warning
# emitted after the privilege check for details.
as_user() {
    # The second condition ($CURRENT_USER == $INVOKING_USER) is dead code after the
    # privilege re-exec (CURRENT_USER is always "root" then), but kept as a defensive
    # fallback for non-re-exec contexts such as UPDATE_ALL_SELFTEST=1 mode.
    if [[ "$INVOKING_USER" == "root" || "$CURRENT_USER" == "$INVOKING_USER" ]]; then
        "$@"
    else
        # -n: fail fast instead of blocking on a password prompt. An atypical
        # sudoers policy or non-tty context could otherwise hang here rather
        # than falling through to run_step's normal FAIL/RESULTS path.
        sudo -n -Hu "$INVOKING_USER" "$@"
    fi
}

# --- selftest (UPDATE_ALL_SELFTEST=1) --------------------------------------
# Exercises core logic without root. Usage:
#   UPDATE_ALL_SELFTEST=1 bash scripts/update-all.sh
# Lock-path parameterization can also be tested independently:
#   UPDATE_ALL_LOCK_FILE=/tmp/update-all-test.lock bash scripts/update-all.sh
if [[ "${UPDATE_ALL_SELFTEST:-}" == "1" ]]; then
    _st_pass=0 _st_fail=0

    _assert() {
        local desc="$1" want="$2" got="$3"
        if [[ "$got" == "$want" ]]; then
            ok  "SELFTEST PASS: ${desc}"
            _st_pass=$(( _st_pass + 1 ))
        else
            fail "SELFTEST FAIL: ${desc}"
            fail "  expected: '${want}'"
            fail "  got:      '${got}'"
            _st_fail=$(( _st_fail + 1 ))
        fi
    }

    info "Running selftests..."

    # L15: have() finds real commands and rejects nonexistent ones
    _assert "have finds a real command (bash)" "yes" "$(have bash && echo yes || echo no)"
    _assert "have rejects a nonexistent command" "no" \
        "$(have this-command-does-not-exist-xyz123 && echo yes || echo no)"

    # L14: a pre-existing (e.g. caller-exported) OK_CODES must not contaminate
    # the very first run_step call.
    RESULTS=()
    OK_CODES="99"
    run_step "test-envguard" -- bash -c 'exit 1'
    _assert "stale/exported OK_CODES doesn't leak into first call" \
        "FAIL test-envguard (exit 1)" "${RESULTS[0]:-}"

    # H1: run_step exit 0 → OK result
    RESULTS=()
    run_step "test-ok" -- bash -c 'exit 0'
    _assert "run_step(exit 0) → OK" "OK   test-ok" "${RESULTS[0]:-}"
    _assert "run_step(exit 0) → exactly one RESULTS entry" "1" "${#RESULTS[@]}"

    # H1: run_step exit 1 → FAIL result
    RESULTS=()
    run_step "test-fail" -- bash -c 'exit 1'
    _assert "run_step(exit 1) → FAIL" "FAIL test-fail (exit 1)" "${RESULTS[0]:-}"
    _assert "run_step(exit 1) → exactly one RESULTS entry" "1" "${#RESULTS[@]}"

    # H1: OK_CODES extra code is accepted
    RESULTS=()
    OK_CODES=2 run_step "test-ok2" -- bash -c 'exit 2'
    _assert "run_step(OK_CODES=2, exit 2) → OK" "OK   test-ok2" "${RESULTS[0]:-}"
    _assert "run_step(OK_CODES=2, exit 2) → exactly one RESULTS entry" "1" "${#RESULTS[@]}"

    # M5: multi-value OK_CODES — a non-first code in the list is also accepted
    RESULTS=()
    OK_CODES="2 3" run_step "test-ok3" -- bash -c 'exit 3'
    _assert "run_step(OK_CODES='2 3', exit 3) → OK" "OK   test-ok3" "${RESULTS[0]:-}"
    _assert "run_step(OK_CODES='2 3', exit 3) → exactly one RESULTS entry" "1" "${#RESULTS[@]}"

    # H1: OK_CODES resets between calls — must not leak to the next call
    RESULTS=()
    run_step "test-noleak" -- bash -c 'exit 2'
    _assert "OK_CODES does not leak" "FAIL test-noleak (exit 2)" "${RESULTS[0]:-}"
    _assert "OK_CODES does not leak → exactly one RESULTS entry" "1" "${#RESULTS[@]}"

    # L2/L12: malformed OK_CODES values are rejected before the command runs
    RESULTS=()
    OK_CODES="abc" run_step "test-badcodes" -- bash -c 'exit 0'
    _assert "invalid OK_CODES (non-numeric) → FAIL" \
        "FAIL test-badcodes (invalid OK_CODES)" "${RESULTS[0]:-}"
    _assert "invalid OK_CODES (non-numeric) → exactly one RESULTS entry" "1" "${#RESULTS[@]}"

    RESULTS=()
    OK_CODES="-1" run_step "test-badcodes-neg" -- bash -c 'exit 0'
    _assert "invalid OK_CODES (negative) → FAIL" \
        "FAIL test-badcodes-neg (invalid OK_CODES)" "${RESULTS[0]:-}"

    RESULTS=()
    OK_CODES="2.5" run_step "test-badcodes-decimal" -- bash -c 'exit 0'
    _assert "invalid OK_CODES (decimal) → FAIL" \
        "FAIL test-badcodes-decimal (invalid OK_CODES)" "${RESULTS[0]:-}"

    RESULTS=()
    OK_CODES="2 abc" run_step "test-badcodes-mixed" -- bash -c 'exit 0'
    _assert "invalid OK_CODES (mixed valid/invalid) → FAIL" \
        "FAIL test-badcodes-mixed (invalid OK_CODES)" "${RESULTS[0]:-}"

    # L4: no-command branch emits the right RESULTS label
    RESULTS=()
    run_step "test-nocmd"
    _assert "no-command → RESULTS label" \
        "FAIL test-nocmd (no command provided to run_step)" "${RESULTS[0]:-}"
    _assert "no-command → exactly one RESULTS entry" "1" "${#RESULTS[@]}"

    # M1: as_user runs directly when already the invoking user — true in the
    # normal (non-sudo) selftest invocation, where INVOKING_USER is either the
    # current user or "root" (see the as_user fallback comment above).
    _assert "as_user runs directly for the current user" "$CURRENT_USER" "$(as_user id -un)"

    # H2/H3: pk_classify_result is the single source of truth shared with the
    # live PackageKit step (2b) below — exercise all three outcomes end-to-end
    # (not just the raw grep pattern in isolation).
    _assert "pk_classify(rc=0, empty output) → ok" "ok" "$(pk_classify_result 0 '')"
    _assert "pk_classify('nothing to update') → ok" "ok" "$(pk_classify_result 1 'nothing to update')"
    _assert "pk_classify('No updates available') → ok" "ok" "$(pk_classify_result 1 'No updates available')"
    _assert "pk_classify('Nothing to do') → ok" "ok" "$(pk_classify_result 1 'Nothing to do')"
    _assert "pk_classify('no packages require updating') → ok" "ok" \
        "$(pk_classify_result 5 'no packages require updating')"
    _assert "pk_classify(D-Bus timeout text) → timeout" "timeout" \
        "$(pk_classify_result 1 'Command failed: Timeout was reached')"
    _assert "pk_classify(connection error) → fail" "fail" \
        "$(pk_classify_result 1 'error: failed to connect')"
    _assert "pk_classify(bare 'no packages') → fail" "fail" "$(pk_classify_result 1 'no packages')"
    _assert "pk_classify('updated 0 packages') → fail" "fail" \
        "$(pk_classify_result 1 'updated 0 packages')"

    # L11: the flock mechanism actually serializes — a second non-blocking
    # flock against an already-held lock must fail immediately. Exercises the
    # same primitive as the mutual-exclusion guard below, without needing root
    # or the real /run/update-all.lock path.
    _lock_test_file="$(mktemp -u)"
    { exec 8>"$_lock_test_file"; } 2>/dev/null
    if flock -n 8; then
        { exec 7>"$_lock_test_file"; } 2>/dev/null
        if flock -n 7 2>/dev/null; then
            _lock_got="acquired"
            flock -u 7
        else
            _lock_got="held"
        fi
        _assert "second non-blocking flock on an already-held lock is rejected" "held" "$_lock_got"
        exec 7>&- 2>/dev/null || true
        flock -u 8
    else
        fail "SELFTEST FAIL: could not acquire initial test lock (environment issue)"
        _st_fail=$(( _st_fail + 1 ))
    fi
    exec 8>&- 2>/dev/null || true
    rm -f "$_lock_test_file"

    echo
    info "Selftest complete: ${_st_pass} passed, ${_st_fail} failed."
    exit $(( _st_fail > 0 ? 1 : 0 ))
fi

# --- privilege check -------------------------------------------------------
# dnf, snap, and fwupd need root. Re-exec under sudo if not already root.
#
# TOCTOU note: SELF is resolved here (pre-elevation) and read again via $0 by
# the root bash after `exec sudo` below. Deployment assumption: this script
# and its containing directory are root-owned and not group/world-writable,
# so a non-root actor cannot swap the file between the two reads. If deployed
# into a non-root-writable location, that assumption no longer holds.
SELF="$(realpath -- "$0")" || { fail "Cannot resolve script path for '$0'."; exit 1; }
if [[ $EUID -ne 0 ]]; then
    if have sudo; then
        info "Elevating privileges with sudo (flatpak user-scope runs as you)..."
        exec sudo /bin/bash "$SELF" "$@"
        # exec only returns on failure
        fail "exec sudo failed — check sudoers policy or sudo authentication."
        exit 1
    else
        fail "This script needs root (for dnf/snap/fwupd) and sudo is not available."
        exit 1
    fi
fi

# --- argument guard --------------------------------------------------------
# This script takes no arguments. Validate once, as root, after re-exec so
# the check fires exactly once regardless of how the script was invoked.
if [[ $# -gt 0 ]]; then
    fail "Usage: update-all.sh  (no arguments accepted)"
    exit 1
fi

# --- mutual exclusion guard ------------------------------------------------
# Prevent concurrent invocations from racing on the RPM db lock,
# the PackageKit daemon, or the fwupd daemon. Uses a non-blocking flock so
# a second invocation fails immediately rather than hanging indefinitely.
have flock || { fail "flock is not available; cannot guarantee single-instance execution."; exit 1; }
# Only serializes concurrent update-all runs, not external package managers.
# The lock path is parameterizable so tests can override it without root.
# UPDATE_ALL_LOCK_FILE must point at a directory that is NOT world-writable
# (e.g. /run, or a private test tmpdir) — the open below follows symlinks and
# truncates the target, so a pre-planted symlink in a world-writable directory
# such as /tmp could cause an arbitrary file to be truncated.
_LOCK_FILE="${UPDATE_ALL_LOCK_FILE:-/run/update-all.lock}"
# Brace group limits the 2>/dev/null redirect to the exec alone, preserving
# stderr for all subsequent commands (bare `exec 9>... 2>/dev/null` would
# permanently close stderr for the entire rest of the script).
# Note: fd 9 is not close-on-exec, so it is inherited by every child process
# run via run_step (dnf, flatpak, pkcon, snap, fwupdmgr). None of those are
# expected to background/daemonize themselves while holding it; if one ever
# does, the lock would outlive this script and wrongly reject the next run.
{ exec 9>"$_LOCK_FILE"; } 2>/dev/null \
    || { fail "Cannot open lock file ${_LOCK_FILE} — check permissions/space."; exit 1; }
flock -n 9 || { fail "Another update-all is already running."; exit 1; }

# --- direct root invocation warning ----------------------------------------
# When the script is run as root without sudo (e.g. after `sudo su -`),
# SUDO_USER is unset so INVOKING_USER is "root". The user-scope flatpak
# update will then run against /root/.local rather than the real user's home.
if [[ "$INVOKING_USER" == "root" ]]; then
    warn "SUDO_USER not set — user-scope flatpak will run as root's installation. Run via: sudo ./update-all.sh"
fi

# --- the updates -----------------------------------------------------------

# 1. Flatpak — apps and runtimes, both user and system scope.
# Labels are defined once here so the skip-branch RESULTS entries stay in sync
# with the run_step labels above — a single source of truth.
FLATPAK_LABELS=(
    "flatpak (user)"
    "flatpak (system)"
    "flatpak (remove unused, user)"
    "flatpak (remove unused, system)"
)
if have flatpak; then
    # Labels below must match FLATPAK_LABELS above — two places, one source of truth.
    # Per-user installation, run as the invoking user.
    run_step "flatpak (user)"   -- as_user flatpak update --user -y
    # System-wide installation, run as root.
    run_step "flatpak (system)" -- flatpak update --system -y
    # Clean up runtimes no longer needed by any app (both scopes).
    run_step "flatpak (remove unused, user)"   -- as_user flatpak uninstall --user --unused -y
    run_step "flatpak (remove unused, system)" -- flatpak uninstall --system --unused -y
else
    warn "flatpak not found; skipping flatpak update."
    for label in "${FLATPAK_LABELS[@]}"; do
        RESULTS+=("SKIP ${label} (not installed)")
    done
fi

# 2. dnf — system RPM packages.
#
# NOTE: packagekitd runs as a persistent daemon and may hold the RPM
# transaction lock. If `dnf upgrade` exits non-zero with a lock error,
# KDE Discover or the Plasma update notifier may be active — close them
# and retry. The flock guard above prevents a second update-all from
# racing this step, but it does not quiesce the PackageKit daemon itself.
dnf_failed=0
if have dnf; then
    run_step "dnf" -- dnf upgrade --refresh -y || dnf_failed=1
else
    warn "dnf not found; skipping system package update."
    RESULTS+=("SKIP dnf (not installed)")
fi

# 2b. PackageKit — keep KDE Discover's view in sync with dnf.
#
# Discover (and the Plasma update notifier) reads PackageKit, which keeps its
# OWN repo-metadata cache, separate from dnf's. After the dnf upgrade above,
# that cache is stale: Discover still lists the packages dnf JUST installed and
# stages a PackageKit "offline update" — the install-on-reboot-then-reboot-again
# behavior you've seen. Refreshing PackageKit's cache (and draining anything it
# still considers pending) makes Discover agree there is nothing to do, so it
# stops forcing those offline updates.
if have pkcon; then
    # Re-download repo metadata into PackageKit's cache. "force" overrides the
    # "refreshed too recently" guard so it always actually refreshes — so if
    # this still fails, it's a genuine error (network/repo unreachable, auth
    # failure), not the guard tripping. Tracked below so the subsequent
    # update's result can say so, instead of silently reporting OK against a
    # cache that never actually resynced.
    pk_refresh_failed=0
    run_step "PackageKit (refresh cache)" -- pkcon refresh force || pk_refresh_failed=1

    # Belt-and-suspenders: apply anything PackageKit STILL thinks is pending.
    # Normally nothing, since dnf already upgraded everything. This runs LIVE
    # (online), NOT as an offline/reboot update. pkcon reports "no updates" via
    # its output text rather than a stable exit code, so we decide from output.
    #
    # This update step runs regardless of the dnf/refresh outcomes above (by
    # design — pkcon may still have valid cached metadata even when one of
    # them failed, so attempting the update is still worthwhile). But if dnf
    # or the refresh failed for a real reason, an apparent OK here doesn't
    # mean the cache is actually in sync with dnf's post-upgrade state — so
    # annotate the result below rather than reporting a bare, misleading OK.
    info "Updating PackageKit (pending packages, if any)..."
    # LC_ALL=C LANGUAGE= force English output; LANG=C alone does not override LC_ALL or
    # LANGUAGE (GLib checks them first), so non-English locales would defeat the grep below.
    # Note: -y is a non-interactive hint (suppress confirmation prompts); pkcon may
    # silently ignore it if the installed version does not recognise this flag.
    pk_out=$(LC_ALL=C LANGUAGE= pkcon update -y -p 2>&1); pk_rc=$?
    printf '%s\n' "$pk_out"

    pk_note=""
    [[ $dnf_failed -eq 1 ]] && pk_note+=" (dnf upgrade failed — sync may run against a non-post-upgrade state)"
    [[ $pk_refresh_failed -eq 1 ]] && pk_note+=" (cache refresh failed — result unverified)"

    # pk_classify_result (defined near run_step, shared with the selftest) is
    # the single source of truth for the "nothing to do"/timeout/fail pattern
    # matching — see PK_NOTHING_TO_DO_PATTERN there for the full rationale.
    case "$(pk_classify_result "$pk_rc" "$pk_out")" in
        ok)
            ok "PackageKit update completed.${pk_note}"
            RESULTS+=("OK   PackageKit (update)${pk_note}")
            ;;
        timeout)
            # dnf already applied all updates above, so this is a cosmetic D-Bus
            # race; classify as OK (not SKIP — the tool was present and ran) so
            # the summary correctly distinguishes a D-Bus timeout from an absent
            # pkcon installation.
            ok "PackageKit update: D-Bus timeout (ignored — dnf already applied updates; Discover cache may lag).${pk_note}"
            RESULTS+=("OK   PackageKit (update) (D-Bus timeout, ignored)${pk_note}")
            ;;
        *)
            fail "PackageKit update failed (exit ${pk_rc})."
            RESULTS+=("FAIL PackageKit (update) (exit ${pk_rc})")
            ;;
    esac
else
    warn "pkcon not found; skipping PackageKit/Discover sync."
    RESULTS+=("SKIP PackageKit (refresh cache) (not installed)")
    RESULTS+=("SKIP PackageKit (update) (not installed)")
fi

# 3. snap — Snap packages.
if have snap; then
    run_step "snap" -- snap refresh
else
    warn "snap not found; skipping snap update."
    RESULTS+=("SKIP snap (not installed)")
fi

# 4. fwupd — firmware (BIOS/UEFI, SSDs, docks, peripherals via LVFS).
if have fwupdmgr; then
    # Refresh metadata. --force avoids the "refreshed too recently" error.
    # Exit code 2 means "metadata already current" — treat as success.
    OK_CODES=2 run_step "fwupd (refresh)" -- fwupdmgr refresh --force
    # Apply updates. Exit code 2 means "nothing to do" — treat as success.
    # Note: some firmware applies on next reboot rather than immediately.
    # --assume-yes requires fwupd >= 1.3.0 (Fedora 30+)
    OK_CODES=2 run_step "fwupd (update)" -- fwupdmgr update --assume-yes
else
    warn "fwupdmgr not found; skipping firmware update."
    RESULTS+=("SKIP fwupd (refresh) (not installed)")
    RESULTS+=("SKIP fwupd (update) (not installed)")
fi

# --- summary ---------------------------------------------------------------
echo
info "Summary"
overall=0
for line in "${RESULTS[@]}"; do
    case "$line" in
        OK*)   ok   "$line" ;;
        SKIP*) warn "$line" ;;
        *)     [[ "$line" =~ ^FAIL ]] || warn "BUG: malformed RESULTS entry: $line"
               fail "$line"; overall=1 ;;
    esac
done

if [[ $overall -eq 0 ]]; then
    ok "All updates finished without errors."
else
    fail "One or more updates failed — see above."
fi

# --- reboot hint -----------------------------------------------------------
# Did this run replace core libraries/services (kernel, glibc, systemd, dbus,
# ...) that are still running from before the update? Only RPM packages drive
# an OS reboot, so this is a dnf check; flatpak/snap/firmware don't.
#
# We use `dnf needs-restarting -r` which exits 0 (no reboot needed) or 1
# (reboot required). This is stable across dnf4 and dnf5. The `--reboothint`
# flag existed in dnf4 but its presence on dnf5 is not guaranteed; `-r` is
# the portable choice. No `sudo` here: by this point the script has already
# re-exec'd itself as root.
echo
# Run needs-restarting -r directly; detect a missing plugin from the output
# text rather than probing with `--help` first (avoids a redundant dnf startup).
if have dnf; then
    info "Checking whether a reboot is required..."
    reboot_out=$(dnf needs-restarting -r 2>&1); reboot_rc=$?
    # `-r` exits 0 = no reboot needed, 1 = reboot required (dnf4 and dnf5).
    # Detect missing plugin by output text instead of a separate --help probe.
    if grep -qi 'no such command\|unknown subcommand' <<<"$reboot_out"; then
        warn "dnf needs-restarting plugin not found; skipping reboot check."
    elif [[ $reboot_rc -eq 0 ]]; then
        ok "No reboot required."
    elif [[ $reboot_rc -eq 1 ]]; then
        # dnf's generic failure exit code is ALSO 1 (broken repo metadata, RPM
        # db lock, network failure, ...) — don't trust the exit code alone.
        # Sanity-check the output actually looks like a triggering package
        # list rather than an error, before declaring a reboot required.
        if [[ -z "$reboot_out" ]] || grep -qi 'error' <<<"$reboot_out"; then
            warn "dnf needs-restarting exited 1, but the output doesn't look like a package list — reboot status is ambiguous (the check itself may have failed). Review output below."
            [[ -n "$reboot_out" ]] && warn "dnf output: ${reboot_out}"
        else
            alert "*** REBOOT REQUIRED *** core packages were updated; reboot to apply them."
            # Print the package list so the operator can see what triggered the hint.
            printf '%s\n' "$reboot_out"
        fi
    else
        warn "Could not determine reboot status (exit ${reboot_rc})."
        [[ -n "$reboot_out" ]] && warn "dnf output: ${reboot_out}"
    fi
fi

exit "$overall"
