#!/usr/bin/env bash
# install-daemon.sh — One-time setup for the AssetWipe privileged daemon.
# Run this once per technician machine. After this, no sudo is ever needed
# to trigger a wipe — Claude's skill communicates with the daemon directly.

set -euo pipefail

DAEMON_LABEL="com.asana.assetwipe"
PLIST_SRC="$(cd "$(dirname "$0")" && pwd)/com.asana.assetwipe.plist"
DAEMON_SRC="$(cd "$(dirname "$0")" && pwd)/assetwipe-daemon.py"
DAEMON_BIN="/usr/local/bin/assetwipe-daemon"
PLIST_DEST="/Library/LaunchDaemons/${DAEMON_LABEL}.plist"

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()     { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

echo ""
echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   AssetWipe Daemon Installer         ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
echo ""

# ── Preflight checks ─────────────────────────────────────────────────────────
[[ -f "$DAEMON_SRC" ]]  || error "assetwipe-daemon.py not found next to this script."
[[ -f "$PLIST_SRC" ]]   || error "com.asana.assetwipe.plist not found next to this script."
command -v python3 >/dev/null 2>&1 || error "python3 is required but not installed."

log "Installing AssetWipe daemon (you will be prompted for your sudo password)..."

# ── Install daemon binary ─────────────────────────────────────────────────────
sudo cp "$DAEMON_SRC" "$DAEMON_BIN"
sudo chmod 755 "$DAEMON_BIN"
sudo chown root:wheel "$DAEMON_BIN"
success "Daemon installed at $DAEMON_BIN"

# ── Install LaunchDaemon plist ────────────────────────────────────────────────
sudo cp "$PLIST_SRC" "$PLIST_DEST"
sudo chmod 644 "$PLIST_DEST"
sudo chown root:wheel "$PLIST_DEST"
success "LaunchDaemon plist installed at $PLIST_DEST"

# ── Load (or reload) the daemon ───────────────────────────────────────────────
# Unload silently if already loaded, then load fresh
sudo launchctl unload "$PLIST_DEST" 2>/dev/null || true
sudo launchctl load -w "$PLIST_DEST"
success "Daemon loaded and running."

# ── Verify ───────────────────────────────────────────────────────────────────
sleep 1   # give the daemon a moment to bind the socket
if [[ -S "/var/run/assetwipe.sock" ]]; then
    response=$(python3 -c "
import socket, json
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('/var/run/assetwipe.sock')
s.sendall(json.dumps({'command': 'status'}).encode() + b'\n')
print(s.recv(1024).decode().strip())
s.close()
" 2>/dev/null)
    success "Daemon verified: $response"
else
    warn "Socket not found at /var/run/assetwipe.sock — daemon may still be starting. Check /var/log/assetwipe-daemon.log if the issue persists."
fi

echo ""
success "Daemon setup complete."

# ── Install the Claude skill ──────────────────────────────────────────────────
echo ""
log "Installing AssetWipe skill into Claude..."

SKILL_URL="https://raw.githubusercontent.com/IanForde/AssetWipe/refs/heads/main/asset-wipe-skill.skill"
SKILL_DEST="$HOME/Downloads/asset-wipe.skill"

if curl -fsSL "$SKILL_URL" -o "$SKILL_DEST" 2>/dev/null; then
    success "Skill downloaded to $SKILL_DEST"
    log "Opening in Claude — click 'Save skill' when prompted..."
    open "$SKILL_DEST"
else
    warn "Could not download skill automatically."
    echo ""
    echo "  Install manually:"
    echo "  1. Download: $SKILL_URL"
    echo "  2. Open the downloaded .skill file — Claude will show a 'Save skill' button"
    echo ""
fi

echo ""
success "All done. Run 'wipe the connected Mac' in Claude to trigger a wipe."
echo ""
