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

# Track results for the final summary.
declare -a RESULTS=()

# have <command> — true if a command exists on PATH.
have() { command -v "$1" >/dev/null 2>&1; }

# run_step <label> -- <command...>
# Runs a command, records the outcome, and reports it.
# Optionally accept extra "success" exit codes (e.g. fwupd's "nothing to do")
# by setting OK_CODES to a space-separated list before calling.
run_step() {
    local label=$1
    shift
    [[ "${1:-}" == "--" ]] && shift

    local -a ok_codes=(0 ${OK_CODES:-})
    OK_CODES=""  # reset for the next call

    if [[ $# -eq 0 ]]; then
        fail "run_step: '${label}' — no command specified."
        RESULTS+=("FAIL ${label} (no command)")
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
INVOKING_USER="${SUDO_USER:-$USER}"

# as_user <command...> — run a command as the invoking user.
# Falls back to running directly if we're already that user.
as_user() {
    if [[ "$INVOKING_USER" == "root" || "$(id -un)" == "$INVOKING_USER" ]]; then
        "$@"
    else
        sudo -u "$INVOKING_USER" "$@"
    fi
}

# --- privilege check -------------------------------------------------------
# dnf, snap, and fwupd need root. Re-exec under sudo if not already root.
SELF="$(realpath -- "$0")"
if [[ $EUID -ne 0 ]]; then
    if have sudo; then
        info "Elevating privileges with sudo (flatpak user-scope runs as you)..."
        exec sudo --preserve-env=SUDO_USER bash "$SELF" "$@"
        # exec only returns on failure
        fail "exec sudo failed — check sudoers policy or sudo authentication."
        exit 1
    else
        fail "This script needs root (for dnf/snap/fwupd) and sudo is not available."
        exit 1
    fi
fi

# --- the updates -----------------------------------------------------------

# 1. Flatpak — apps and runtimes, both user and system scope.
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
    for label in "flatpak (user)" "flatpak (system)" "flatpak (remove unused, user)" "flatpak (remove unused, system)"; do
        RESULTS+=("SKIP ${label} (not installed)")
    done
fi

# 2. dnf — system RPM packages.
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
    info "Updating PackageKit (pending packages, if any)..."
    pk_out=$(LANG=C pkcon update -y -p 2>&1); pk_rc=$?
    printf '%s\n' "$pk_out"
    if [[ $pk_rc -eq 0 ]] || grep -qiE 'no (updates|packages)|nothing to do' <<<"$pk_out"; then
        ok "PackageKit update completed."
        RESULTS+=("OK   PackageKit (update)")
    else
        fail "PackageKit update failed (exit ${pk_rc})."
        RESULTS+=("FAIL PackageKit (update, exit ${pk_rc})")
    fi
else
    warn "pkcon not found; skipping PackageKit/Discover sync."
    RESULTS+=("SKIP PackageKit (not installed)")
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
    OK_CODES=2 run_step "fwupd (update)" -- fwupdmgr update --assume-yes
else
    warn "fwupdmgr not found; skipping firmware update."
    RESULTS+=("SKIP fwupd (not installed)")
fi

# --- summary ---------------------------------------------------------------
echo
info "Summary"
overall=0
for line in "${RESULTS[@]}"; do
    case "$line" in
        OK*)   ok   "$line" ;;
        SKIP*) warn "$line" ;;
        *)     fail "$line"; overall=1 ;;
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
# Note: on dnf5 the `-r/--reboothint` flag is a no-op kept only for dnf4
# compatibility -- plain `dnf needs-restarting` provides the hint. We still
# pass the flag (harmless on both) but decide from the OUTPUT TEXT, which is
# stable across dnf4/dnf5, rather than the exit code. No `sudo` here: by this
# point the script has already re-exec'd itself as root.
echo
if have dnf && dnf help needs-restarting &>/dev/null 2>&1; then
    info "Checking whether a reboot is required..."
    reboot_out=$(LANG=C dnf needs-restarting --reboothint 2>&1)
    if grep -qi 'reboot is required' <<<"$reboot_out"; then
        printf '%s%s*** REBOOT REQUIRED ***%s core packages were updated; reboot to apply them.\n' \
            "$bold" "$yellow" "$reset"
    elif grep -qi 'reboot should not be necessary' <<<"$reboot_out"; then
        ok "No reboot required."
    else
        warn "Could not determine reboot status; raw output below:"
        printf '%s\n' "$reboot_out"
    fi
else
    warn "dnf or needs-restarting plugin not found; skipping reboot check."
fi

exit "$overall"
