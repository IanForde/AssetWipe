#!/usr/bin/env bash
# DeployScript.sh — Asset Wipe Deploy Script
# If the AssetWipe daemon is running, uses the privileged socket (no sudo needed).
# Otherwise falls back to direct execution with sudo.

set -euo pipefail

DAEMON_SOCKET="/var/run/assetwipe.sock"

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

# ── Daemon communication ──────────────────────────────────────────────────────
# Script directory — used as the file-trigger location when running from
# Claude's sandbox (where the socket is not accessible).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TRIGGER_FILE="$SCRIPT_DIR/.assetwipe-trigger"
RESULT_FILE="$SCRIPT_DIR/.assetwipe-result"

daemon_running() {
    [[ -S "$DAEMON_SOCKET" ]]
}

# Send a command to the daemon. Uses the Unix socket if reachable (terminal),
# otherwise falls back to file-based trigger via the mounted project directory
# (Claude sandbox).
daemon_send() {
    local cmd="$1"
    local timeout="${2:-600}"   # default 10 min — restore can be slow

    if daemon_running; then
        # ── Socket mode (terminal) ──────────────────────────────────────────
        python3 -c "
import socket, json, sys
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect('$DAEMON_SOCKET')
    s.sendall(json.dumps({'command': '$cmd'}).encode() + b'\n')
    data = b''
    while b'\n' not in data:
        chunk = s.recv(4096)
        if not chunk: break
        data += chunk
    r = json.loads(data.decode().strip())
    print(r.get('output', ''))
    sys.exit(0 if r.get('success') else 1)
except Exception as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)
" 2>&1
    else
        # ── File trigger mode (Claude sandbox) ─────────────────────────────
        rm -f "$RESULT_FILE"
        echo "{\"command\": \"$cmd\"}" > "$TRIGGER_FILE"

        local elapsed=0
        while (( elapsed < timeout )); do
            if [[ -f "$RESULT_FILE" ]]; then
                local output success
                output=$(python3 -c "import json; print(json.load(open('$RESULT_FILE')).get('output',''))" 2>/dev/null)
                success=$(python3 -c "import json; print('0' if json.load(open('$RESULT_FILE')).get('success') else '1')" 2>/dev/null)
                rm -f "$RESULT_FILE"
                echo "$output"
                return "${success:-1}"
            fi
            sleep 1
            (( elapsed++ ))
        done

        rm -f "$TRIGGER_FILE" "$RESULT_FILE"
        echo "Timed out waiting for daemon response after ${timeout}s" >&2
        return 1
    fi
}

# True if the daemon is reachable via either channel
daemon_available() {
    # Socket mode (terminal on macOS)
    daemon_running && return 0

    # File trigger mode: either we're in the Linux sandbox (non-Darwin),
    # or the macOS config points at this directory.
    if [[ "$(uname -s 2>/dev/null)" != "Darwin" ]]; then
        # Running inside Claude's Linux sandbox — use file triggers if writable
        [[ -w "$SCRIPT_DIR" ]]
        return
    fi

    # macOS without socket — check if daemon config points here
    python3 -c "
import json, os
cfg = '/Library/Application Support/AssetWipe/config.json'
d = json.load(open(cfg)).get('watch_dir','') if os.path.exists(cfg) else ''
exit(0 if d and os.path.isdir(d) and os.path.realpath(d) == os.path.realpath('$SCRIPT_DIR') else 1)
" 2>/dev/null
}

# ── Dependency: macvdmtool ────────────────────────────────────────────────────
check_macvdmtool() {
    if command -v macvdmtool >/dev/null 2>&1; then
        success "macvdmtool is installed."
        return 0
    fi

    warn "macvdmtool not found. Attempting to install..."

    # Requires Xcode Command Line Tools — install silently via softwareupdate
    if ! xcode-select -p >/dev/null 2>&1; then
        log "Xcode Command Line Tools not found. Installing silently..."
        touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
        CLT_PKG=$(softwareupdate -l 2>/dev/null \
            | grep -B1 "Command Line Tools" \
            | awk -F'*' '/^\s*\*/{print $2}' \
            | sed 's/^ Label: //' \
            | sort -V | tail -1)
        rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress

        if [[ -n "$CLT_PKG" ]]; then
            log "Installing: $CLT_PKG"
            sudo softwareupdate -i "$CLT_PKG" --verbose \
                && success "Xcode Command Line Tools installed." \
                || { error "CLT install failed. Run 'xcode-select --install' manually then re-run."; exit 1; }
        else
            error "Could not find Xcode CLT in softwareupdate. Run 'xcode-select --install' manually then re-run."
            exit 1
        fi
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

    # Sweep all broken cfgutil symlinks the installer might trip over.
    # Use || true throughout so set -e doesn't exit if paths don't exist.
    local stale_links
    stale_links=$(find /usr/local/bin /usr/local/share/man \
        -maxdepth 3 -name "cfgutil*" -type l 2>/dev/null | while read -r f; do
            [[ ! -e "$f" ]] && echo "$f" || true
        done) || true

    if [[ -n "$stale_links" ]]; then
        warn "Removing stale cfgutil symlinks..."
        echo "$stale_links" | xargs sudo rm -f || true
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
        dryrun "Would run: macvdmtool dfu"
        return 0
    fi
    log "Putting device into DFU mode..."
    if daemon_available; then
        daemon_send dfu
    else
        sudo macvdmtool dfu
    fi
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
        local list_output
        if daemon_available; then
            list_output=$(daemon_send list 2>/dev/null) || true
        else
            list_output=$(cfgutil list 2>/dev/null) || true
        fi

        if echo "$list_output" | grep -q "ECID"; then
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
    if daemon_available; then
        daemon_send restore
    else
        cfgutil restore
    fi
    success "Restore complete."
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════╗${NC}"
    echo -e "${BLUE}║     AssetWipe Deploy Tool     ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════╝${NC}"
    $DRY_RUN && echo -e "${CYAN}  ⚠  DRY-RUN MODE — no changes will be made to any device${NC}"

    if daemon_running; then
        echo -e "  ${GREEN}✓  Daemon mode (socket) — no sudo required${NC}"
    elif daemon_available; then
        echo -e "  ${GREEN}✓  Daemon mode (file trigger) — no sudo required${NC}"
    else
        echo -e "  ${YELLOW}⚠  Direct mode — sudo required (run installer.sh to avoid this)${NC}"
    fi
    echo ""

    # Dependency checks only needed in direct mode — daemon handles its own tools
    if ! daemon_running && ! daemon_available; then
        check_macvdmtool
        check_cfgutil
    else
        success "Daemon available — skipping local dependency checks."
    fi

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
