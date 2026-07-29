#!/usr/bin/env bash
# deploy.sh — Asset Wipe Deploy Script
# Checks dependencies, puts device into DFU mode, waits for it to appear, then restores.

set -euo pipefail

# ── Flags ─────────────────────────────────────────────────────────────────────
DRY_RUN=false
for arg in "$@"; do
    [[ "$arg" == "--dry-run" ]] && DRY_RUN=true
done

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()     { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
dryrun()  { echo -e "${CYAN}[DRY-RUN]${NC} $*"; }

# ── Dependency: macvdmtool ────────────────────────────────────────────────────
check_macvdmtool() {
    if command -v macvdmtool >/dev/null 2>&1; then
        success "macvdmtool is installed."
        return 0
    fi

    warn "macvdmtool not found. Attempting to install..."

    # Requires Xcode Command Line Tools
    if ! xcode-select -p >/dev/null 2>&1; then
        log "Installing Xcode Command Line Tools (you may see a system prompt)..."
        xcode-select --install
        echo ""
        log "Wait for Xcode CLT install to complete, then re-run this script."
        exit 1
    fi

    # Clone, build, install
    local tmp_dir
    tmp_dir=$(mktemp -d)
    if git clone --depth 1 https://github.com/AsahiLinux/macvdmtool.git "$tmp_dir/macvdmtool" 2>/dev/null \
        && make -C "$tmp_dir/macvdmtool" 2>/dev/null \
        && sudo cp "$tmp_dir/macvdmtool/macvdmtool" /usr/local/bin/macvdmtool; then
        rm -rf "$tmp_dir"
        success "macvdmtool installed successfully."
    else
        rm -rf "$tmp_dir"
        error "Auto-install failed. Install macvdmtool manually:"
        echo ""
        echo "  1. Install Xcode Command Line Tools:"
        echo "       xcode-select --install"
        echo ""
        echo "  2. Clone and build:"
        echo "       git clone https://github.com/AsahiLinux/macvdmtool.git"
        echo "       cd macvdmtool && make"
        echo "       sudo cp macvdmtool /usr/local/bin"
        echo ""
        exit 1
    fi
}

# ── Dependency: cfgutil ───────────────────────────────────────────────────────
check_cfgutil() {
    # Check PATH first, then common install locations directly
    if command -v cfgutil >/dev/null 2>&1; then
        success "cfgutil is installed."
        return 0
    fi

    for candidate in /usr/local/bin/cfgutil /usr/bin/cfgutil; do
        if [[ -x "$candidate" ]]; then
            # Working binary — just make sure it's in PATH
            export PATH="$(dirname "$candidate"):$PATH"
            success "cfgutil found at $candidate (added to PATH)."
            return 0
        fi
    done

    # Sweep all broken cfgutil symlinks the installer might trip over
    local stale_links
    stale_links=$(find /usr/local/bin /usr/local/share/man \
        -maxdepth 3 -name "cfgutil*" -type l 2>/dev/null | while read -r f; do
            [[ ! -e "$f" ]] && echo "$f"
        done)

    if [[ -n "$stale_links" ]]; then
        warn "Removing stale cfgutil symlinks..."
        echo "$stale_links" | xargs sudo rm -f
    fi

    warn "cfgutil not found. Checking for Apple Configurator 2..."

    # cfgutil ships bundled inside Apple Configurator 2 as an installer package.
    # If AC2 is installed we can run that package directly without going through the GUI.
    local ac2_app="/Applications/Apple Configurator 2.app"

    if [[ -d "$ac2_app" ]]; then
        # Newer AC2 versions ship a custom installer binary rather than a .pkg.
        local ac2_installer="$ac2_app/Contents/MacOS/installer"
        local pkg
        pkg=$(find "$ac2_app" -name "*.pkg" 2>/dev/null | head -1)

        if [[ -x "$ac2_installer" ]]; then
            log "Found Automation Tools installer. Installing cfgutil..."
            # The installer binary requires a command argument.
            # Try 'install' without sudo first (handles auth internally),
            # then fall back to sudo if it exits non-zero.
            local install_output
            if install_output=$("$ac2_installer" install 2>&1); then
                success "cfgutil installed successfully."
                return 0
            elif install_output=$(sudo "$ac2_installer" install 2>&1); then
                success "cfgutil installed successfully."
                return 0
            else
                error "Installer failed: $install_output"
                echo ""
                echo "  Fix: Open Apple Configurator 2 → Install Automation Tools from the menu bar."
                echo ""
                exit 1
            fi
        elif [[ -n "$pkg" ]]; then
            log "Found Automation Tools package. Installing cfgutil..."
            if sudo installer -pkg "$pkg" -target / >/dev/null 2>&1; then
                success "cfgutil installed successfully."
                return 0
            else
                error "Installer failed. Try manually: Apple Configurator 2 → Install Automation Tools"
                exit 1
            fi
        else
            error "Apple Configurator 2 is installed but the Automation Tools installer was not found inside it."
            echo ""
            echo "  Fix: Open Apple Configurator 2 → Install Automation Tools from the menu bar."
            echo ""
            exit 1
        fi
    fi

    # AC2 not installed — nothing we can do automatically.
    error "Apple Configurator 2 is not installed. cfgutil cannot be auto-installed without it."
    echo ""
    echo "  1. Install Apple Configurator 2 from the Mac App Store:"
    echo "     https://apps.apple.com/app/apple-configurator-2/id1037126344"
    echo ""
    echo "  2. Re-run this script — cfgutil will be installed automatically."
    echo ""
    exit 1
}

# ── DFU Mode ──────────────────────────────────────────────────────────────────
enter_dfu_mode() {
    if [[ "$DRY_RUN" == true ]]; then
        dryrun "Would run: sudo macvdmtool dfu"
        return 0
    fi
    log "Putting device into DFU mode..."
    sudo macvdmtool dfu
    success "DFU command sent."
}

# ── Wait for device to appear in cfgutil ─────────────────────────────────────
wait_for_device() {
    if [[ "$DRY_RUN" == true ]]; then
        dryrun "Would poll: cfgutil list (waiting for device to appear)"
        dryrun "Device detected (simulated)."
        return 0
    fi

    local timeout=120   # seconds
    local interval=5
    local elapsed=0

    log "Waiting for device to appear in Apple Configurator (timeout: ${timeout}s)..."

    while (( elapsed < timeout )); do
        if cfgutil list 2>/dev/null | grep -q "ECID"; then
            success "Device detected."
            return 0
        fi
        sleep "$interval"
        (( elapsed += interval ))
        log "Still waiting... (${elapsed}s elapsed)"
    done

    error "Device did not appear within ${timeout}s. Check the cable and DFU state, then try again."
    exit 1
}

# ── Restore ───────────────────────────────────────────────────────────────────
restore_device() {
    if [[ "$DRY_RUN" == true ]]; then
        dryrun "Would run: cfgutil restore"
        return 0
    fi
    log "Starting restore..."
    cfgutil restore
    success "Restore complete."
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════╗${NC}"
    echo -e "${BLUE}║     AssetWipe Deploy Tool     ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════╝${NC}"
    $DRY_RUN && echo -e "${CYAN}  ⚠  DRY-RUN MODE — no changes will be made to any device${NC}"
    echo ""

    # 1. Dependency checks
    check_macvdmtool
    check_cfgutil

    echo ""

    # 2. DFU → wait → restore
    enter_dfu_mode
    wait_for_device
    restore_device

    echo ""
    if [[ "$DRY_RUN" == true ]]; then
        success "Dry run complete. All steps passed — run without --dry-run to wipe a real device."
    else
        success "Done. Device has been wiped and restored."
    fi
    echo ""
}

main "$@"
