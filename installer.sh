#!/usr/bin/env bash
# installer.sh — AssetWipe complete one-command setup
#
# Installs everything needed to run AssetWipe as a Claude skill:
#   1. macvdmtool  (auto-built from source if missing)
#   2. cfgutil     (auto-installed via Apple Configurator 2 if present)
#   3. AssetWipe privileged daemon (LaunchDaemon — runs wipes without sudo)
#   4. AssetWipe Claude skill  (opens in Claude for one-click save)
#
# Designed to be run via curl — this is what the Automator app should call:
#   curl -fsSL https://raw.githubusercontent.com/IanForde/AssetWipe/refs/heads/main/installer.sh | bash

set -euo pipefail

GITHUB_RAW="https://raw.githubusercontent.com/IanForde/AssetWipe/refs/heads/main"
DAEMON_LABEL="com.asana.assetwipe"
DAEMON_BIN="/usr/local/bin/assetwipe-daemon"
PLIST_DEST="/Library/LaunchDaemons/${DAEMON_LABEL}.plist"
DAEMON_SOCKET="/var/run/assetwipe.sock"
SKILL_DEST="$HOME/Downloads/asset-wipe.skill"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log()     { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()    { echo -e "\n${CYAN}▶ $*${NC}"; }

# Temp workspace — cleaned up automatically on exit
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         AssetWipe Installer              ║${NC}"
echo -e "${BLUE}║   Setting up your Mac wipe toolkit...    ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
echo ""

# ── Step 1: macvdmtool ────────────────────────────────────────────────────────
step "Checking macvdmtool..."

if command -v macvdmtool >/dev/null 2>&1; then
    success "macvdmtool is already installed."
else
    warn "macvdmtool not found. Installing..."

    if ! xcode-select -p >/dev/null 2>&1; then
        log "Xcode Command Line Tools not found. Installing silently via softwareupdate..."
        # Non-GUI install: create the trigger file, find the CLT package, install it.
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
                || error "CLT install failed. Run 'xcode-select --install' manually then re-run this installer."
        else
            error "Could not find Xcode Command Line Tools in softwareupdate. Run 'xcode-select --install' manually then re-run."
        fi
    fi

    if git clone --depth 1 https://github.com/AsahiLinux/macvdmtool.git "$TMP/macvdmtool" 2>/dev/null \
        && make -C "$TMP/macvdmtool" 2>/dev/null \
        && sudo cp "$TMP/macvdmtool/macvdmtool" /usr/local/bin/macvdmtool; then
        success "macvdmtool installed."
    else
        error "macvdmtool auto-install failed. Install Xcode CLT manually (xcode-select --install) then re-run."
    fi
fi

# ── Step 2: cfgutil ───────────────────────────────────────────────────────────
step "Checking cfgutil..."

# Check PATH and common direct locations
_cfgutil_found=false
if command -v cfgutil >/dev/null 2>&1; then
    _cfgutil_found=true
else
    for candidate in /usr/local/bin/cfgutil /usr/bin/cfgutil; do
        if [[ -x "$candidate" ]]; then
            export PATH="$(dirname "$candidate"):$PATH"
            _cfgutil_found=true
            break
        fi
    done
fi

if $_cfgutil_found; then
    success "cfgutil is already installed."
else
    warn "cfgutil not found. Checking for Apple Configurator 2..."

    # Remove any stale cfgutil symlinks that would block the installer
    find /usr/local/bin /usr/local/share/man \
        -maxdepth 3 -name "cfgutil*" -type l 2>/dev/null | while read -r f; do
            [[ ! -e "$f" ]] && { warn "Removing stale symlink: $f"; sudo rm -f "$f"; } || true
        done || true

    AC2="/Applications/Apple Configurator 2.app"
    if [[ -d "$AC2" ]]; then
        AC2_INSTALLER="$AC2/Contents/MacOS/installer"
        AC2_PKG=$(find "$AC2" -name "*.pkg" 2>/dev/null | head -1)

        if [[ -x "$AC2_INSTALLER" ]]; then
            log "Running Apple Configurator 2 Automation Tools installer..."
            if "$AC2_INSTALLER" install 2>/dev/null || sudo "$AC2_INSTALLER" install 2>/dev/null; then
                success "cfgutil installed."
            else
                warn "Auto-install failed."
                echo "  Fix: Open Apple Configurator 2 → Install Automation Tools, then re-run."
                exit 1
            fi
        elif [[ -n "$AC2_PKG" ]]; then
            log "Installing cfgutil from bundled package..."
            sudo installer -pkg "$AC2_PKG" -target / >/dev/null 2>&1 && success "cfgutil installed." || {
                warn "Package install failed. Open Apple Configurator 2 → Install Automation Tools."
                exit 1
            }
        else
            warn "Apple Configurator 2 is installed but the Automation Tools installer wasn't found."
            echo "  Fix: Open Apple Configurator 2 → Install Automation Tools from the menu bar."
            exit 1
        fi
    else
        echo ""
        echo -e "  ${RED}Apple Configurator 2 is not installed.${NC}"
        echo "  Install it from the Mac App Store, then re-run this installer:"
        echo "  https://apps.apple.com/app/apple-configurator-2/id1037126344"
        echo ""
        exit 1
    fi
fi

# ── Step 3: AssetWipe daemon ──────────────────────────────────────────────────
step "Installing AssetWipe daemon..."

log "Downloading daemon from GitHub..."
curl -fsSL "$GITHUB_RAW/assetwipe-daemon.py" -o "$TMP/assetwipe-daemon" \
    || error "Failed to download daemon. Check your internet connection."

curl -fsSL "$GITHUB_RAW/com.asana.assetwipe.plist" -o "$TMP/com.asana.assetwipe.plist" \
    || error "Failed to download LaunchDaemon plist."

log "Installing daemon binary..."
sudo cp "$TMP/assetwipe-daemon" "$DAEMON_BIN"
sudo chmod 755 "$DAEMON_BIN"
sudo chown root:wheel "$DAEMON_BIN"

log "Installing LaunchDaemon..."
sudo cp "$TMP/com.asana.assetwipe.plist" "$PLIST_DEST"
sudo chmod 644 "$PLIST_DEST"
sudo chown root:wheel "$PLIST_DEST"

# Write config so the daemon knows where to watch for file triggers.
# This is the bridge between Claude's sandbox and the daemon.
WATCH_DIR="$HOME/Documents/Claude/Projects/AssetWipe"
CONFIG_DIR="/Library/Application Support/AssetWipe"
sudo mkdir -p "$CONFIG_DIR"
sudo bash -c "cat > '$CONFIG_DIR/config.json'" <<EOF
{
    "watch_dir": "$WATCH_DIR"
}
EOF
sudo chmod 644 "$CONFIG_DIR/config.json"

# Ensure the watch directory exists and is writable by Claude's sandbox
mkdir -p "$WATCH_DIR"

log "Loading daemon..."
sudo launchctl unload "$PLIST_DEST" 2>/dev/null || true
sudo launchctl load -w "$PLIST_DEST"

# Verify socket appeared — give the daemon a moment to bind
sleep 3
if [[ -S "$DAEMON_SOCKET" ]]; then
    DAEMON_STATUS=$(python3 -c "
import socket, json
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('$DAEMON_SOCKET')
s.sendall(json.dumps({'command': 'status'}).encode() + b'\n')
print(json.loads(s.recv(1024).decode().strip()).get('output',''))
s.close()
" 2>/dev/null) || true
    success "Daemon running: ${DAEMON_STATUS:-OK}"
else
    warn "Daemon socket not yet visible — it may still be starting. Check /var/log/assetwipe-daemon.log if issues persist."
fi

# ── Step 4: Claude skill ──────────────────────────────────────────────────────
step "Installing AssetWipe Claude skill..."

log "Downloading skill file..."
if curl -fsSL "$GITHUB_RAW/asset-wipe-skill.skill" -o "$SKILL_DEST" 2>/dev/null; then
    success "Skill downloaded to ~/Downloads/asset-wipe.skill"

    # Try opening in Claude directly, fall back to generic open
    if open -a "Claude" "$SKILL_DEST" 2>/dev/null; then
        log "Skill file opened in Claude."
    else
        open "$SKILL_DEST" 2>/dev/null || true
    fi

    echo ""
    echo -e "  ${CYAN}ACTION REQUIRED:${NC}"
    echo "  Claude should now be open with a 'Save skill' prompt."
    echo "  Click 'Save skill' to complete the installation."
    echo ""
else
    warn "Could not download skill file automatically."
    echo ""
    echo "  Install manually:"
    echo "  1. Download: $GITHUB_RAW/asset-wipe-skill.skill"
    echo "  2. Open it — Claude will show a 'Save skill' button"
    echo ""
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║           Installation Complete          ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
echo ""
echo "  Once you've clicked 'Save skill' in Claude, you're ready."
echo "  Just say: \"wipe the connected Mac\" and Claude handles the rest."
echo ""
