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

    if [[ $# -eq 0 ]]; then
        # Defensive assertion — all call sites pass a command; this branch should not be reached.
        fail "run_step: '${label}' — no command specified."
        RESULTS+=("FAIL ${label} (exit 1)")
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

# --- identify the invoking (non-root) user ---------------------------------
# Captured BEFORE we elevate, so we can run user-scope flatpak as them.
INVOKING_USER="${SUDO_USER:-${USER:-root}}"
if ! id -u "$INVOKING_USER" &>/dev/null; then
    fail "SUDO_USER '${INVOKING_USER}' is not a valid user; aborting."
    exit 1
fi
CURRENT_USER="$(id -un)"   # cached; always "root" after the privilege re-exec

# as_user <command...> — run a command as the invoking user.
# Falls back to running directly if we're already that user.
#
# Note: if INVOKING_USER is "root" (direct root execution without sudo),
# user-scope operations run as root — known limitation; see the warning
# emitted after the privilege check for details.
as_user() {
    if [[ "$INVOKING_USER" == "root" || "$CURRENT_USER" == "$INVOKING_USER" ]]; then
        "$@"
    else
        sudo -Hu "$INVOKING_USER" "$@"
    fi
}

# --- privilege check -------------------------------------------------------
# dnf, snap, and fwupd need root. Re-exec under sudo if not already root.
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
exec 9>/run/update-all.lock 2>/dev/null \
    || { fail "Cannot open lock file /run/update-all.lock — check permissions/space."; exit 1; }
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
if have dnf; then
    run_step "dnf" -- dnf upgrade --refresh -y
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
    # "refreshed too recently" guard so it always actually refreshes.
    run_step "PackageKit (refresh cache)" -- pkcon refresh force

    # Belt-and-suspenders: apply anything PackageKit STILL thinks is pending.
    # Normally nothing, since dnf already upgraded everything. This runs LIVE
    # (online), NOT as an offline/reboot update. pkcon reports "no updates" via
    # its output text rather than a stable exit code, so we decide from output.
    #
    # Note: this update step runs regardless of the refresh outcome above (by
    # design — pkcon may still have valid cached metadata even when the refresh
    # step reports failure, so attempting the update is still worthwhile).
    info "Updating PackageKit (pending packages, if any)..."
    # LC_ALL=C LANGUAGE= force English output; LANG=C alone does not override LC_ALL or
    # LANGUAGE (GLib checks them first), so non-English locales would defeat the grep below.
    # Note: -y is a non-interactive hint (suppress confirmation prompts); pkcon may
    # silently ignore it if the installed version does not recognise this flag.
    pk_out=$(LC_ALL=C LANGUAGE= pkcon update -y -p 2>&1); pk_rc=$?
    printf '%s\n' "$pk_out"
    # Pattern matches pkcon "nothing to do" messages (bare "no packages/updates"
    # is intentionally omitted — it also matches error strings, causing false OKs;
    # "updated 0 packages" is likewise omitted — it appears in failure output too):
    #   nothing to update              — pkcon: no pending packages in cache
    #   no updates available           — pkcon: cache shows nothing pending
    #   ^nothing to do$                — pkcon: generic "already current" (anchored to avoid
    #                                    matching error strings that contain this phrase)
    #   no packages require updating   — pkcon + DNF5 backend (Fedora 41+): exits 5 despite
    #                                    having nothing to install; match text to treat as OK
    if [[ $pk_rc -eq 0 ]] || grep -qiE \
        'nothing to update|no updates available|^nothing to do$|no packages require updating' \
        <<<"$pk_out"; then
        ok "PackageKit update completed."
        RESULTS+=("OK   PackageKit (update)")
    elif grep -qi 'timeout was reached' <<<"$pk_out"; then
        # pkcon + DNF5 backend (Fedora 41+): the daemon finishes the transaction
        # ("Status: Finished") but the D-Bus client times out waiting for the
        # completion signal and exits 1 with "Command failed: Timeout was reached".
        # dnf already applied all updates above, so this is a cosmetic D-Bus race,
        # not a real failure — warn rather than fail so overall exit stays 0.
        warn "PackageKit update timed out (D-Bus race with DNF5 backend) — dnf already applied all updates; Discover cache may lag until the next refresh."
        RESULTS+=("SKIP PackageKit (update) (timeout)")
    else
        fail "PackageKit update failed (exit ${pk_rc})."
        RESULTS+=("FAIL PackageKit (update) (exit ${pk_rc})")
    fi
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
# Probe using `--help` rather than `dnf help <subcommand>` because on dnf5
# (Fedora 41+) the latter may exit non-zero even when the plugin is present.
if have dnf && dnf needs-restarting --help &>/dev/null; then
    info "Checking whether a reboot is required..."
    # `-r` exits 0 = no reboot needed, 1 = reboot required (dnf4 and dnf5).
    reboot_out=$(dnf needs-restarting -r 2>&1); reboot_rc=$?
    if [[ $reboot_rc -eq 0 ]]; then
        ok "No reboot required."
    elif [[ $reboot_rc -eq 1 ]]; then
        alert "*** REBOOT REQUIRED *** core packages were updated; reboot to apply them."
    else
        warn "Could not determine reboot status (exit ${reboot_rc})."
        [[ -n "$reboot_out" ]] && warn "dnf output: ${reboot_out}"
    fi
else
    warn "dnf or needs-restarting plugin not found; skipping reboot check."
fi

exit "$overall"
