#!/usr/bin/env bash
#
# update-all-ubuntu.sh — update flatpak, apt (system debs), PackageKit
# (Discover sync), snap, and firmware (fwupd), then check whether a reboot is
# required.
#
# Ubuntu counterpart of update-all-fedora.sh: same structure, same helpers,
# same RESULTS/summary contract. It covers everything KDE Discover fronts on
# an Ubuntu system — debs via the PackageKit aptcc backend, snaps, flatpaks,
# and firmware via fwupd.
#
# Each updater runs independently; a failure in one does not stop the others.
# A summary of successes/failures is printed at the end.
#
# Scope notes:
#   * Flatpak is updated for BOTH the per-user and system-wide installations.
#     The user-scope update runs as the invoking user, not as root.
#   * apt, pkcon, snap, and fwupd require root and run under sudo.

set -u  # treat unset variables as errors; we intentionally do NOT use -e
        # because we want to keep going after a failed updater.

# Pin PATH to a known-safe value so all tool lookups are predictable when
# running as root regardless of the invoking user's PATH. All tools used by
# this script (apt-get, flatpak, pkcon, fwupdmgr, snap, dpkg-query, env,
# flock, id, realpath, tput, grep, bash) live in /usr/sbin or /usr/bin on
# Ubuntu.
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
    # ${1:-} (not $1) because under set -u a hypothetical future zero-argument
    # call would otherwise hard-abort the whole script with "unbound
    # variable" instead of degrading through the FAIL/RESULTS path below.
    local label=${1:-}
    local code
    # Capture OK_CODES into a local, then reset the global immediately —
    # before the no-label guard below, not after — so a caller that sets
    # OK_CODES on the same line as a mistakenly label-less call (e.g.
    # `OK_CODES=2 run_step`) can never leak it into the *next* call. Every
    # return path from this function must clear the global, not just the
    # normal-completion path; using the captured local below preserves the
    # value this call itself needs.
    local _ok_codes_in=${OK_CODES:-}
    OK_CODES=""  # reset for the next call
    if [[ -z "$label" ]]; then
        fail "run_step: called with no label."
        RESULTS+=("FAIL run_step (no label)")
        return 1
    fi
    shift
    [[ "${1:-}" == "--" ]] && shift

    local -a ok_codes
    read -ra ok_codes <<< "0 ${_ok_codes_in}"

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
# output, which would cause false OKs. Every alternative is anchored to a
# whole line (^...$) for the same reason — these are known standalone pkcon
# messages (see docs/error-handling-guidelines.md), not fragments expected to
# appear embedded in other text, so anchoring only removes false-OK matches,
# it doesn't weaken legitimate detection.
#
# CAVEAT (inherited, unverified on Ubuntu): the first four alternatives are
# carried over from update-all-fedora.sh, where the "no packages require
# updating" widening was verified against a real Fedora 44 / dnf5-backend
# transcript. Ubuntu's PackageKit uses the aptcc backend, whose "nothing to
# do" wording has NOT been verified against a real transcript here. The fifth
# alternative ("there are no updates available[ at this time]") is the
# pkcon client's own no-updates message seen on Debian-family systems — also
# unverified against a real Ubuntu transcript. Since step 2b's "nothing to
# do" is the normal, everyday outcome (apt already did the real work in step
# 2), a pattern that stops matching turns routine successful runs into a
# FAIL, not just misses a rare false-OK — if a real Ubuntu run captures a
# different wording, widen the pattern the same way the Fedora one was.
readonly PK_NOTHING_TO_DO_PATTERN='^nothing to update$|^no updates available$|^nothing to do$|^no packages require updating( to newer versions)?\.?$|^there are no updates available( at this time)?\.?$'

# pk_classify_result <rc> <output> — classify a `pkcon update` outcome from its
# exit code and captured stdout/stderr text. Echoes exactly one of:
#   ok      — succeeded, or nothing was pending (matches PK_NOTHING_TO_DO_PATTERN)
#   timeout — the daemon finishes the transaction but the D-Bus client times
#             out waiting for the completion signal and exits 1 with "Command
#             failed: Timeout was reached". Observed with the dnf5 backend on
#             Fedora 41+; unverified with Ubuntu's aptcc backend but retained
#             — it is a client-side D-Bus race, not backend behavior, and the
#             match is narrow enough (rc 1 + exact message) not to hide real
#             failures.
#   fail    — genuine failure
pk_classify_result() {
    local rc=${1:-} out=${2:-}
    if [[ $rc -eq 0 ]] || grep -qiE "$PK_NOTHING_TO_DO_PATTERN" <<<"$out"; then
        echo "ok"
    # Restricted to rc == 1 and the fuller, specific message: the bare
    # substring "timeout was reached" is also libcurl's stock text for
    # CURLE_OPERATION_TIMEDOUT, so a genuine network/repo timeout during the
    # update could otherwise be misclassified as the benign D-Bus race and
    # silently hide a real failure.
    elif [[ $rc -eq 1 ]] && grep -qi 'Command failed: Timeout was reached' <<<"$out"; then
        echo "timeout"
    else
        echo "fail"
    fi
}

# pk_note_for <apt_failed> <pk_refresh_failed> — builds the annotation suffix
# appended to the PackageKit (update) RESULTS/output line when an upstream
# step (the apt upgrade or the PackageKit cache refresh) failed, so an
# apparent OK here isn't mistaken for a fully-verified post-upgrade sync.
# Extracted (like pk_classify_result) so the selftest can cover all 4 flag
# combinations directly instead of only via the inline call site.
pk_note_for() {
    local apt_failed=${1:-} pk_refresh_failed=${2:-}
    local note=""
    [[ "$apt_failed" -eq 1 ]] && note+=" (apt upgrade failed — sync may run against a non-post-upgrade state)"
    [[ "$pk_refresh_failed" -eq 1 ]] && note+=" (cache refresh failed — result unverified)"
    echo "$note"
}

# classify_reboot_marker <marker_exists> <notifier_installed> — classify the
# Ubuntu reboot-required state from two 0/1 flags: whether the
# /run/reboot-required marker file exists, and whether update-notifier-common
# (the package whose dpkg hooks CREATE that marker) is installed. Echoes
# exactly one of:
#   reboot_required — the marker exists; a package postinst (or fwupd, which
#                     writes the same marker when firmware is staged to apply
#                     on reboot) requested a reboot
#   no_reboot       — no marker, and the machinery that would have written one
#                     is present, so its absence is meaningful
#   unknown         — no marker, but update-notifier-common isn't installed:
#                     deb updates never create the marker on this system
#                     (only fwupd would), so "absent"
#                     carries no information — reporting "no reboot" here
#                     would be a silent false negative after every kernel
#                     update
# The marker wins regardless of the notifier flag: if something wrote the
# file, a reboot was requested no matter how the file got there.
# Extracted as a pure function (like pk_classify_result and friends in
# update-all-fedora.sh) so the selftest covers all branches directly instead
# of only via the live call site at the bottom of the script.
classify_reboot_marker() {
    local marker_exists=${1:-} notifier_installed=${2:-}
    if [[ "$marker_exists" -eq 1 ]]; then
        echo "reboot_required"
    elif [[ "$notifier_installed" -eq 1 ]]; then
        echo "no_reboot"
    else
        echo "unknown"
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

# as_user_runs_directly — as_user's direct-vs-sudo branch condition, extracted
# (like pk_classify_result and friends) so as_user and the selftest's skip
# guard share one source of truth instead of hand-duplicated expressions that
# could silently drift apart.
#
# The second condition ($CURRENT_USER == $INVOKING_USER) is dead code after the
# privilege re-exec (CURRENT_USER is always "root" then), but kept as a defensive
# fallback for non-re-exec contexts such as UPDATE_ALL_SELFTEST=1 mode.
as_user_runs_directly() {
    [[ "$INVOKING_USER" == "root" || "$CURRENT_USER" == "$INVOKING_USER" ]]
}

as_user() {
    if as_user_runs_directly; then
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
#   UPDATE_ALL_SELFTEST=1 bash scripts/update-all-ubuntu.sh
# UPDATE_ALL_LOCK_FILE parameterizes the mutual-exclusion guard's path so it
# doesn't have to touch the real /run/update-all.lock, but this does NOT
# bypass the privilege check below: run as an unprivileged user, invocation
# still stops at "needs root" before ever reaching the lock guard, same as
# any other run. It only becomes useful once already root/sudo, e.g.:
#   sudo UPDATE_ALL_LOCK_FILE=/tmp/update-all-test.lock bash scripts/update-all-ubuntu.sh
#
# Known gap: the sudo re-exec itself, the "have sudo" false branch, the "exec
# sudo failed" fallback, the "have flock" false branch, the
# direct-root-invocation warning, and the lock-file open's stderr-capture/
# mktemp-failure paths (see the mutual exclusion guard below) are all
# entry-point/privilege paths that cannot be exercised without root — an
# inherent limitation of testing a root-requiring script unprivileged, not an
# oversight.
if [[ "${UPDATE_ALL_SELFTEST:-}" == "1" ]]; then
    # Internal recursion hook for the OK_CODES anti-contamination test below:
    # when set, run ONLY that check against a genuinely fresh process (so the
    # real top-level "OK_CODES=\"\"" guard near the top of this file runs for
    # real) and exit, instead of the full suite — this avoids infinitely
    # recursing into the full selftest.
    if [[ "${_UPDATE_ALL_ENVGUARD_PROBE:-}" == "1" ]]; then
        RESULTS=()
        # Suppress run_step's own banner/status output (it prints to stdout)
        # so the parent's command substitution captures only the RESULTS
        # line printed below, not the interleaved "==> Updating..."/"[FAIL]"
        # text.
        run_step "test-envguard" -- bash -c 'exit 1' >/dev/null 2>&1
        printf '%s\n' "${RESULTS[0]:-}"
        exit 0
    fi

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

    # have() finds real commands and rejects nonexistent ones
    _assert "have finds a real command (bash)" "yes" "$(have bash && echo yes || echo no)"
    _assert "have rejects a nonexistent command" "no" \
        "$(have this-command-does-not-exist-xyz123 && echo yes || echo no)"

    # A stale/exported OK_CODES from the CALLING shell — i.e. present
    # BEFORE this script's own top-level "OK_CODES=\"\"" guard runs — must
    # not leak into the first run_step call. Setting OK_CODES in *this* shell
    # immediately before the call (the previous version of this test) can't
    # exercise that guard: by this point the guard already ran once, so the
    # test was indistinguishable from ordinary same-line OK_CODES usage — and
    # a value that doesn't match the exit code (99 vs exit 1) passes whether
    # or not the guard exists at all. Instead, export OK_CODES=1 (which WOULD
    # match the command's exit code if it leaked through) into a genuinely
    # fresh process of this same script and let its own guard run for real.
    # Assumes $0 is a real file path (the documented invocation, `bash
    # scripts/update-all-ubuntu.sh`); this would fail with a confusing "No
    # such file or directory" if the script were ever piped into bash's stdin
    # or sourced instead, where $0 is not a resolvable script path.
    _envguard_got="$(OK_CODES=1 _UPDATE_ALL_ENVGUARD_PROBE=1 UPDATE_ALL_SELFTEST=1 bash "$0")"
    _assert "stale/exported OK_CODES doesn't leak into first call" \
        "FAIL test-envguard (exit 1)" "$_envguard_got"

    # run_step exit 0 → OK result
    RESULTS=()
    run_step "test-ok" -- bash -c 'exit 0'
    _assert "run_step(exit 0) → OK" "OK   test-ok" "${RESULTS[0]:-}"
    _assert "run_step(exit 0) → exactly one RESULTS entry" "1" "${#RESULTS[@]}"

    # run_step exit 1 → FAIL result
    RESULTS=()
    run_step "test-fail" -- bash -c 'exit 1'
    _assert "run_step(exit 1) → FAIL" "FAIL test-fail (exit 1)" "${RESULTS[0]:-}"
    _assert "run_step(exit 1) → exactly one RESULTS entry" "1" "${#RESULTS[@]}"

    # OK_CODES extra code is accepted
    RESULTS=()
    OK_CODES=2 run_step "test-ok2" -- bash -c 'exit 2'
    _assert "run_step(OK_CODES=2, exit 2) → OK" "OK   test-ok2" "${RESULTS[0]:-}"
    _assert "run_step(OK_CODES=2, exit 2) → exactly one RESULTS entry" "1" "${#RESULTS[@]}"

    # Multi-value OK_CODES — a non-first code in the list is also accepted
    RESULTS=()
    OK_CODES="2 3" run_step "test-ok3" -- bash -c 'exit 3'
    _assert "run_step(OK_CODES='2 3', exit 3) → OK" "OK   test-ok3" "${RESULTS[0]:-}"
    _assert "run_step(OK_CODES='2 3', exit 3) → exactly one RESULTS entry" "1" "${#RESULTS[@]}"

    # OK_CODES resets between calls — must not leak to the next call
    RESULTS=()
    run_step "test-noleak" -- bash -c 'exit 2'
    _assert "OK_CODES does not leak" "FAIL test-noleak (exit 2)" "${RESULTS[0]:-}"
    _assert "OK_CODES does not leak → exactly one RESULTS entry" "1" "${#RESULTS[@]}"

    # Malformed OK_CODES values are rejected before the command runs
    RESULTS=()
    OK_CODES="abc" run_step "test-badcodes" -- bash -c 'exit 0'
    _assert "invalid OK_CODES (non-numeric) → FAIL" \
        "FAIL test-badcodes (invalid OK_CODES)" "${RESULTS[0]:-}"
    _assert "invalid OK_CODES (non-numeric) → exactly one RESULTS entry" "1" "${#RESULTS[@]}"

    RESULTS=()
    OK_CODES="-1" run_step "test-badcodes-neg" -- bash -c 'exit 0'
    _assert "invalid OK_CODES (negative) → FAIL" \
        "FAIL test-badcodes-neg (invalid OK_CODES)" "${RESULTS[0]:-}"
    _assert "invalid OK_CODES (negative) → exactly one RESULTS entry" "1" "${#RESULTS[@]}"

    RESULTS=()
    OK_CODES="2.5" run_step "test-badcodes-decimal" -- bash -c 'exit 0'
    _assert "invalid OK_CODES (decimal) → FAIL" \
        "FAIL test-badcodes-decimal (invalid OK_CODES)" "${RESULTS[0]:-}"
    _assert "invalid OK_CODES (decimal) → exactly one RESULTS entry" "1" "${#RESULTS[@]}"

    RESULTS=()
    OK_CODES="2 abc" run_step "test-badcodes-mixed" -- bash -c 'exit 0'
    _assert "invalid OK_CODES (mixed valid/invalid) → FAIL" \
        "FAIL test-badcodes-mixed (invalid OK_CODES)" "${RESULTS[0]:-}"
    _assert "invalid OK_CODES (mixed valid/invalid) → exactly one RESULTS entry" "1" "${#RESULTS[@]}"

    # No-command branch emits the right RESULTS label
    RESULTS=()
    run_step "test-nocmd"
    _assert "no-command → RESULTS label" \
        "FAIL test-nocmd (no command provided to run_step)" "${RESULTS[0]:-}"
    _assert "no-command → exactly one RESULTS entry" "1" "${#RESULTS[@]}"

    # No-label guard itself — a call with an empty label must degrade
    # through the FAIL/RESULTS path (not abort under set -u) and must not
    # leak whatever OK_CODES was set alongside it into the next call.
    RESULTS=()
    OK_CODES=2 run_step ""
    _assert "no-label → RESULTS label" "FAIL run_step (no label)" "${RESULTS[0]:-}"
    _assert "no-label → exactly one RESULTS entry" "1" "${#RESULTS[@]}"
    RESULTS=()
    run_step "test-after-nolabel" -- bash -c 'exit 2'
    _assert "no-label call's OK_CODES does not leak into the next call" \
        "FAIL test-after-nolabel (exit 2)" "${RESULTS[0]:-}"

    # as_user runs directly when already the invoking user. Only assert when
    # as_user's direct-execution condition actually holds (shared via
    # as_user_runs_directly, so this guard can never drift from as_user's own
    # branch); if the selftest is invoked with SUDO_USER set to another user
    # (e.g. run via sudo), as_user takes the `sudo -n -Hu` branch and
    # $CURRENT_USER would be the wrong expectation — a false failure.
    # Skipping loses no coverage: the fake-sudo test below exercises that
    # branch deterministically.
    if as_user_runs_directly; then
        _assert "as_user runs directly for the current user" "$CURRENT_USER" "$(as_user id -un)"
    else
        warn "SELFTEST SKIP: as_user direct-execution test (INVOKING_USER='${INVOKING_USER}' differs from CURRENT_USER='${CURRENT_USER}'; sudo branch is covered by the fake-sudo test below)"
    fi

    # The `sudo -n -Hu ...` branch was previously only reachable by
    # happenstance (whether INVOKING_USER == CURRENT_USER held in the test
    # environment) — never deterministically exercised. Force that branch by
    # setting CURRENT_USER/INVOKING_USER to differ, and fake a `sudo` on PATH
    # (safe: it only echoes its argv, never actually elevates or runs
    # anything) so we can assert exactly how as_user invokes it. Restoring
    # CURRENT_USER/INVOKING_USER isn't needed: both are prefix-assignments
    # scoped to the single `as_user` invocation below (bash restores the
    # shell's own values immediately after), and the whole thing additionally
    # runs inside a $(...) subshell, so there is no ordering dependency on
    # what selftest code (if any) runs after this block.
    if _fake_sudo_dir="$(mktemp -d)"; then
        cat > "${_fake_sudo_dir}/sudo" <<'FAKESUDO'
#!/usr/bin/env bash
printf 'sudo-called: %s\n' "$*"
FAKESUDO
        chmod +x "${_fake_sudo_dir}/sudo"
        _as_user_sudo_got="$(PATH="${_fake_sudo_dir}:${PATH}" CURRENT_USER="root" INVOKING_USER="nobody" as_user id -un)"
        _assert "as_user invokes 'sudo -n -Hu <user>' when CURRENT_USER != INVOKING_USER" \
            "sudo-called: -n -Hu nobody id -un" "$_as_user_sudo_got"
        rm -rf "${_fake_sudo_dir}"
    else
        fail "SELFTEST FAIL: mktemp -d failed; skipping as_user sudo-branch test (environment issue)"
        _st_fail=$(( _st_fail + 1 ))
    fi

    # pk_classify_result is the single source of truth shared with the
    # live PackageKit step (2b) below — exercise all three outcomes end-to-end
    # (not just the raw grep pattern in isolation).
    _assert "pk_classify(rc=0, empty output) → ok" "ok" "$(pk_classify_result 0 '')"
    _assert "pk_classify('nothing to update') → ok" "ok" "$(pk_classify_result 1 'nothing to update')"
    _assert "pk_classify('No updates available') → ok" "ok" "$(pk_classify_result 1 'No updates available')"
    _assert "pk_classify('Nothing to do') → ok" "ok" "$(pk_classify_result 1 'Nothing to do')"
    _assert "pk_classify('no packages require updating') → ok" "ok" \
        "$(pk_classify_result 5 'no packages require updating')"
    _assert "pk_classify('No packages require updating to newer versions.') → ok" "ok" \
        "$(pk_classify_result 5 'No packages require updating to newer versions.')"
    # The two optional groups in the "no packages require updating"
    # alternative — "( to newer versions)?" and "\.?" — are independent. The
    # two assertions above cover bare phrase/no period and full phrase/
    # period; cover the remaining two combinations so a refactor that
    # accidentally couples the groups (e.g. "( to newer versions\.)?") can't
    # narrow the pattern and still pass.
    _assert "pk_classify('no packages require updating.' — bare phrase, with period) → ok" "ok" \
        "$(pk_classify_result 5 'no packages require updating.')"
    _assert "pk_classify('No packages require updating to newer versions' — full phrase, no period) → ok" "ok" \
        "$(pk_classify_result 5 'No packages require updating to newer versions')"
    # The "there are no updates available( at this time)?\.?" alternative
    # (pkcon client no-updates wording, added for the Ubuntu/aptcc case) has
    # the same two-independent-optional-groups shape — cover all 4
    # combinations for the same reason as above.
    _assert "pk_classify('there are no updates available' — bare, no period) → ok" "ok" \
        "$(pk_classify_result 5 'there are no updates available')"
    _assert "pk_classify('There are no updates available at this time.' — full, with period) → ok" "ok" \
        "$(pk_classify_result 5 'There are no updates available at this time.')"
    _assert "pk_classify('there are no updates available.' — bare, with period) → ok" "ok" \
        "$(pk_classify_result 5 'there are no updates available.')"
    _assert "pk_classify('There are no updates available at this time' — full, no period) → ok" "ok" \
        "$(pk_classify_result 5 'There are no updates available at this time')"
    _assert "pk_classify(D-Bus timeout text) → timeout" "timeout" \
        "$(pk_classify_result 1 'Command failed: Timeout was reached')"
    _assert "pk_classify(connection error) → fail" "fail" \
        "$(pk_classify_result 1 'error: failed to connect')"
    _assert "pk_classify(bare 'no packages') → fail" "fail" "$(pk_classify_result 1 'no packages')"
    _assert "pk_classify('updated 0 packages') → fail" "fail" \
        "$(pk_classify_result 1 'updated 0 packages')"

    # Every PK_NOTHING_TO_DO_PATTERN alternative is anchored to a whole
    # line — a "nothing to do"-class phrase embedded inside a longer error
    # line must NOT be classified as ok.
    _assert "pk_classify('Error: nothing to do, aborting') → fail" "fail" \
        "$(pk_classify_result 1 'Error: nothing to do, aborting')"
    _assert "pk_classify('nothing to update' embedded in error) → fail" "fail" \
        "$(pk_classify_result 1 'Error: nothing to update, repo unreachable')"
    _assert "pk_classify('no updates available' embedded in error) → fail" "fail" \
        "$(pk_classify_result 1 'Warning: no updates available, connection reset')"
    _assert "pk_classify('no packages require updating' embedded in error) → fail" "fail" \
        "$(pk_classify_result 1 'no packages require updating: transaction aborted')"
    _assert "pk_classify('there are no updates available' embedded in error) → fail" "fail" \
        "$(pk_classify_result 1 'Warning: there are no updates available, cache is stale')"

    # The ^...$ anchors are per-line under `grep` with a here-string, so a
    # "nothing to do"-class phrase sitting alone on ITS OWN line within a
    # multi-line capture must still classify as ok, even with other
    # unrelated lines (banners, progress output) around it.
    _assert "pk_classify(multi-line output, phrase alone on its own line) → ok" "ok" \
        "$(pk_classify_result 1 "$(printf 'Refreshing cache\nnothing to update\nDone')")"
    # And trailing punctuation/text on the SAME line as the phrase must NOT
    # match — the anchor is doing its job, not accidentally still matching
    # via some other unintended path.
    _assert "pk_classify('Nothing to do.' with trailing period) → fail" "fail" \
        "$(pk_classify_result 1 'Nothing to do.')"

    # The "timeout" outcome requires BOTH rc==1 AND the specific message.
    # Confirm the rc gate actually matters: the exact message text with a
    # non-1 rc (e.g. a genuine network-layer timeout surfacing as some other
    # exit code) must fail, not be swallowed as the benign D-Bus race.
    _assert "pk_classify(exact timeout text, wrong rc) → fail" "fail" \
        "$(pk_classify_result 28 'Command failed: Timeout was reached')"
    # And confirm the bare substring "timeout was reached" alone (without the
    # "Command failed:" prefix — e.g. libcurl's CURLE_OPERATION_TIMEDOUT text)
    # no longer matches even at rc=1, since it's not the specific message.
    _assert "pk_classify(bare 'timeout was reached' substring) → fail" "fail" \
        "$(pk_classify_result 1 'curl: (28) Operation timeout was reached')"

    # pk_note_for covers all 4 apt_failed/pk_refresh_failed combinations —
    # extracted (like pk_classify_result) so each is independently testable.
    _assert "pk_note_for(0,0) → no annotation" "" "$(pk_note_for 0 0)"
    _assert "pk_note_for(1,0) → apt-failed annotation" \
        " (apt upgrade failed — sync may run against a non-post-upgrade state)" "$(pk_note_for 1 0)"
    _assert "pk_note_for(0,1) → refresh-failed annotation" \
        " (cache refresh failed — result unverified)" "$(pk_note_for 0 1)"
    _assert "pk_note_for(1,1) → both annotations" \
        " (apt upgrade failed — sync may run against a non-post-upgrade state) (cache refresh failed — result unverified)" \
        "$(pk_note_for 1 1)"

    # classify_reboot_marker covers all branches, including both marker=1
    # combinations — the marker must win regardless of whether
    # update-notifier-common is detected (if something wrote the file, a
    # reboot was requested no matter how it got there).
    _assert "classify_reboot_marker(marker=1, notifier=1) → reboot_required" "reboot_required" \
        "$(classify_reboot_marker 1 1)"
    _assert "classify_reboot_marker(marker=1, notifier=0) → reboot_required (marker wins)" "reboot_required" \
        "$(classify_reboot_marker 1 0)"
    _assert "classify_reboot_marker(marker=0, notifier=1) → no_reboot" "no_reboot" \
        "$(classify_reboot_marker 0 1)"
    _assert "classify_reboot_marker(marker=0, notifier=0) → unknown" "unknown" \
        "$(classify_reboot_marker 0 0)"

    # The flock mechanism actually serializes — a second non-blocking
    # flock against an already-held lock must fail immediately. Exercises the
    # same primitive as the mutual-exclusion guard below, without needing root
    # or the real /run/update-all.lock path.
    # Plain mktemp (not `mktemp -u`), which creates the file atomically —
    # `-u` only reserves a filename without creating it, a TOCTOU-prone
    # pattern (a symlink/file could be planted at that path before the exec
    # below opens it).
    _lock_test_file="$(mktemp)"
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
# apt, pkcon, snap, and fwupd need root. Re-exec under sudo if not already root.
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
        # shellcheck disable=SC2093  # exec is intentional; the lines below only run if it fails
        exec sudo /bin/bash "$SELF" "$@"
        # exec only returns on failure
        fail "exec sudo failed — check sudoers policy or sudo authentication."
        exit 1
    else
        fail "This script needs root (for apt/pkcon/snap/fwupd) and sudo is not available."
        exit 1
    fi
fi

# --- argument guard --------------------------------------------------------
# This script takes no arguments. Validate once, as root, after re-exec so
# the check fires exactly once regardless of how the script was invoked.
if [[ $# -gt 0 ]]; then
    fail "Usage: update-all-ubuntu.sh  (no arguments accepted)"
    exit 1
fi

# --- mutual exclusion guard ------------------------------------------------
# Prevent concurrent invocations from racing on the dpkg/apt locks,
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
# run via run_step (apt-get, flatpak, pkcon, snap, fwupdmgr). None of those
# are expected to background/daemonize themselves while holding it; if one
# ever does, the lock would outlive this script and wrongly reject the next
# run.
# stderr is captured to a temp file (rather than a variable via $(...))
# because `exec 9>...` must run in THIS shell, not a subshell, for fd 9 to
# stay open for the flock call below — command substitution would open it
# in a subshell that exits immediately, closing the fd before flock ever runs.
if _lock_err_file="$(mktemp)"; then
    if ! { exec 9>"$_LOCK_FILE"; } 2>"$_lock_err_file"; then
        _lock_err="$(cat "$_lock_err_file" 2>/dev/null)"
        rm -f "$_lock_err_file"
        fail "Cannot open lock file ${_LOCK_FILE}: ${_lock_err:-unknown error (check permissions/space)}"
        exit 1
    fi
    rm -f "$_lock_err_file"
else
    # mktemp itself failed (e.g. /tmp full/unwritable) — _lock_err_file is
    # empty, so we can't use it as a redirect target (that would itself be an
    # invalid redirect and bash would silently fall through to the "success"
    # branch, masking the real error behind a misleading "already running"
    # message from the flock check below). Fall back to a plain stderr
    # discard and report the one error we do know about.
    { exec 9>"$_LOCK_FILE"; } 2>/dev/null || {
        fail "Cannot open lock file ${_LOCK_FILE} (and mktemp failed — no detail available)."
        exit 1
    }
fi
flock -n 9 || { fail "Another update-all is already running."; exit 1; }

# --- direct root invocation warning ----------------------------------------
# When the script is run as root without sudo (e.g. after `sudo su -`),
# SUDO_USER is unset so INVOKING_USER is "root". The user-scope flatpak
# update will then run against /root/.local rather than the real user's home.
if [[ "$INVOKING_USER" == "root" ]]; then
    warn "SUDO_USER not set — user-scope flatpak will run as root's installation. Run via: sudo ./update-all-ubuntu.sh"
fi

# --- the updates -----------------------------------------------------------

# 1. Flatpak — apps and runtimes, both user and system scope.
# Labels are defined once here and referenced by index below, both in the
# run_step calls AND the skip-branch RESULTS entries, so there is exactly one
# place a label can be edited — a rename can no longer drift the two branches
# out of sync.
FLATPAK_LABELS=(
    "flatpak (user)"
    "flatpak (system)"
    "flatpak (remove unused, user)"
    "flatpak (remove unused, system)"
)
if have flatpak; then
    # Per-user installation, run as the invoking user.
    run_step "${FLATPAK_LABELS[0]}" -- as_user flatpak update --user -y
    # System-wide installation, run as root.
    run_step "${FLATPAK_LABELS[1]}" -- flatpak update --system -y
    # Clean up runtimes no longer needed by any app (both scopes).
    run_step "${FLATPAK_LABELS[2]}" -- as_user flatpak uninstall --user --unused -y
    run_step "${FLATPAK_LABELS[3]}" -- flatpak uninstall --system --unused -y
else
    warn "flatpak not found; skipping flatpak update."
    for label in "${FLATPAK_LABELS[@]}"; do
        RESULTS+=("SKIP ${label} (not installed)")
    done
fi

# 2. apt — system deb packages. Two steps because apt (unlike dnf) has no
# single refresh-and-upgrade command: `apt-get update` refreshes the package
# lists, `apt-get dist-upgrade` applies the upgrades.
#
# dist-upgrade (not plain upgrade): plain `upgrade` refuses any upgrade that
# needs new packages installed or obsolete ones removed (kernel meta-package
# chains do this routinely), silently holding those back — Discover would
# then still show them as pending, defeating the sync goal of step 2b.
# dist-upgrade matches what Discover's PackageKit backend actually performs.
#
# Note on phased updates: Ubuntu phases some updates out gradually; apt may
# report such packages as "deferred due to phasing" and hold them back. That
# is expected behavior, not an error — they arrive in a later run.
#
# Deliberately NOT setting DEBIAN_FRONTEND=noninteractive: this is an
# interactive-terminal tool, and dpkg conffile prompts represent real
# decisions (keep or replace a modified config) that shouldn't be silently
# defaulted. `-y` only suppresses apt's own yes/no confirmation.
#
# NOTE: packagekitd runs as a persistent daemon and may hold the dpkg
# frontend lock. If apt exits non-zero with "Could not get lock
# /var/lib/dpkg/lock-frontend", KDE Discover or an unattended-upgrades run
# may be active — close/wait them out and retry. The flock guard above
# prevents a second update-all from racing this step, but it does not
# quiesce the PackageKit daemon itself.
apt_failed=0
if have apt-get; then
    # A failed list refresh makes the upgrade run against stale lists, so it
    # counts toward apt_failed too — the PackageKit annotation below cares
    # whether the deb state is verifiably post-upgrade, not which sub-step
    # broke it.
    run_step "apt (refresh)" -- apt-get update || apt_failed=1
    run_step "apt (upgrade)" -- apt-get -y dist-upgrade || apt_failed=1
else
    warn "apt-get not found; skipping system package update."
    RESULTS+=("SKIP apt (refresh) (not installed)")
    RESULTS+=("SKIP apt (upgrade) (not installed)")
fi

# 2b. PackageKit — keep KDE Discover's view in sync with apt.
#
# Discover (and the Plasma update notifier) reads PackageKit, which keeps its
# OWN package-list cache, separate from apt's. After the apt upgrade above,
# that cache is stale: Discover still lists the packages apt JUST installed
# and may stage a PackageKit "offline update" — install-on-reboot-then-
# reboot-again behavior. Refreshing PackageKit's cache (and draining anything
# it still considers pending) makes Discover agree there is nothing to do.
# This step therefore MUST run after step 2 — apt changes the package set
# pkcon caches.
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
    # Normally nothing, since apt already upgraded everything. This runs LIVE
    # (online), NOT as an offline/reboot update. pkcon reports "no updates" via
    # its output text rather than a stable exit code, so we decide from output.
    #
    # This update step runs regardless of the apt/refresh outcomes above (by
    # design — pkcon may still have valid cached metadata even when one of
    # them failed, so attempting the update is still worthwhile). But if apt
    # or the refresh failed for a real reason, an apparent OK here doesn't
    # mean the cache is actually in sync with apt's post-upgrade state — so
    # annotate the result below rather than reporting a bare, misleading OK.
    info "Updating PackageKit (pending packages, if any)..."
    # LC_ALL=C LANGUAGE= force English output; LANG=C alone does not override LC_ALL or
    # LANGUAGE (GLib checks them first), so non-English locales would defeat the grep below.
    # Note: -y is a non-interactive hint (suppress confirmation prompts); pkcon may
    # silently ignore it if the installed version does not recognise this flag.
    pk_out=$(LC_ALL=C LANGUAGE='' pkcon update -y -p 2>&1); pk_rc=$?
    printf '%s\n' "$pk_out"

    # pk_note_for (defined near run_step, shared with the selftest) is the
    # single source of truth for this annotation logic.
    pk_note="$(pk_note_for "$apt_failed" "$pk_refresh_failed")"

    # pk_classify_result (defined near run_step, shared with the selftest) is
    # the single source of truth for the "nothing to do"/timeout/fail pattern
    # matching — see PK_NOTHING_TO_DO_PATTERN there for the full rationale.
    case "$(pk_classify_result "$pk_rc" "$pk_out")" in
        ok)
            ok "PackageKit update completed.${pk_note}"
            RESULTS+=("OK   PackageKit (update)${pk_note}")
            ;;
        timeout)
            # apt already applied all updates above, so this is a cosmetic D-Bus
            # race; classify as OK (not SKIP — the tool was present and ran) so
            # the summary correctly distinguishes a D-Bus timeout from an absent
            # pkcon installation.
            ok "PackageKit update: D-Bus timeout (ignored — apt already applied updates; Discover cache may lag).${pk_note}"
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
    # env -u DISPLAY -u XAUTHORITY: DISPLAY often survives into the root
    # environment (sudoers env_keep, SSH X11 forwarding) while the matching
    # XAUTHORITY cookie does not, so fwupdmgr's display probe fails with a
    # noisy "X11 connection rejected because of wrong authentication." line
    # interleaved with its real output (observed on Ubuntu 24.04). fwupdmgr
    # needs no display; unset both so its output stays clean.
    #
    # Refresh metadata. --force avoids the "refreshed too recently" error.
    # Exit code 2 means "metadata already current" — treat as success.
    OK_CODES=2 run_step "fwupd (refresh)" -- env -u DISPLAY -u XAUTHORITY fwupdmgr refresh --force
    # Apply updates. Exit code 2 means "nothing to do" — treat as success.
    # Note: some firmware applies on next reboot rather than immediately.
    # --assume-yes requires fwupd >= 1.3.0 (Ubuntu 20.04+)
    #
    # Known failure mode (observed 2026-07, Ubuntu 24.04): exits 1 with
    # "Blocked executable in the ESP, ensure grub and shim are up to date:
    # ... Authenticode checksum [...] is present in dbx" when the pending
    # UEFI revocation-database (dbx) update lists the hash of a boot binary
    # still present in the EFI System Partition — applying it would make
    # that binary unbootable, so fwupd refuses. This stays a FAIL on
    # purpose: it needs host-side remediation (update/reinstall shim-signed
    # and grub-efi-*-signed so the ESP copies are current, reboot, re-run),
    # not a wider OK_CODES.
    OK_CODES=2 run_step "fwupd (update)" -- env -u DISPLAY -u XAUTHORITY fwupdmgr update --assume-yes
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
# Did this run stage anything that needs a reboot to finish applying?
#
# Ubuntu's mechanism differs from Fedora's `dnf needs-restarting -r`: package
# postinst scripts touch the marker file /run/reboot-required (and append the
# requesting package names to /run/reboot-required.pkgs). fwupd writes the
# same marker when firmware is staged to apply on reboot (observed 2026-07:
# "fwupd" in /run/reboot-required.pkgs after a firmware update with no core
# deb upgraded), so the marker covers more than deb postinsts — which is why
# the alert below doesn't claim WHICH kind of update asked; the "Requested
# by:" list carries that detail. The dpkg-side hooks are
# shipped by update-notifier-common — WITHOUT that package the marker is
# never created, so "file absent" would be indistinguishable from "no reboot
# needed". classify_reboot_marker (defined near run_step, shared with the
# selftest) is the single source of truth for that three-way distinction.
echo
info "Checking whether a reboot is required..."
_marker_exists=0
[[ -e /run/reboot-required ]] && _marker_exists=1
_notifier_installed=0
# dpkg-query prints "install ok installed" for an installed package; any
# other state (config-files, half-installed) or a missing dpkg-query means we
# can't trust the marker machinery to exist. Probe degrades gracefully
# (2>/dev/null || true idiom) rather than aborting on a non-Debian system.
if dpkg-query -W -f '${Status}' update-notifier-common 2>/dev/null | grep -q 'install ok installed'; then
    _notifier_installed=1
fi
case "$(classify_reboot_marker "$_marker_exists" "$_notifier_installed")" in
    reboot_required)
        alert "*** REBOOT REQUIRED *** an update requested a reboot to finish applying."
        # Print the package list so the operator can see what triggered the
        # hint. The .pkgs file may lawfully be absent even when the marker
        # exists (a postinst can touch the marker without appending there).
        if [[ -r /run/reboot-required.pkgs ]]; then
            info "Requested by:"
            sort -u /run/reboot-required.pkgs
        fi
        ;;
    no_reboot)
        ok "No reboot required."
        ;;
    unknown)
        warn "update-notifier-common is not installed — deb updates never create /run/reboot-required on this system, so reboot status is unknown (not necessarily 'no reboot')."
        ;;
esac

exit "$overall"
