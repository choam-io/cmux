#!/usr/bin/env bash
set -euo pipefail

# Integration test for nsmux session persistence.
# Tests: snapshot survives quit, layout restores correctly, restore commands work.
#
# Usage:
#   ./test-session-restore.sh [--build]   # --build rebuilds nsmux first

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP="/Applications/nsmux.app"
SNAPSHOT_DIR="$HOME/Library/Application Support/cmux"
SNAPSHOT_FILE="$SNAPSHOT_DIR/session-io.choam.nsmux.json"
BACKUP_FILE="/tmp/nsmux-test-snapshot-backup.json"
LOG_FILE="/tmp/nsmux-session-test.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; FAILURES=$((FAILURES + 1)); }
info() { echo -e "${YELLOW}→ $1${NC}"; }

FAILURES=0

# Build if requested
if [[ "${1:-}" == "--build" ]]; then
    info "Building nsmux..."
    cd "$PROJECT_DIR"
    ./scripts/build-nsmux.sh 2>&1 | tail -3
    pkill -f "nsmux.app" 2>/dev/null || true
    sleep 1
    rm -rf "$APP"
    cp -R build-nsmux/nsmux.app "$APP"
fi

# Kill any running nsmux
pkill -f "nsmux.app" 2>/dev/null || true
sleep 2

# ─── Test 1: Snapshot load and layout restore ────────────────────────────

info "Test 1: Layout restore (2 panels, horizontal split, nvim + shell)"

# Write a test snapshot
cat > "$SNAPSHOT_FILE" << 'SNAPSHOT'
{
  "createdAt": 1774390000,
  "version": 1,
  "windows": [{
    "display": {"displayID": 4, "frame": {"height": 1440, "width": 5120, "x": 0, "y": 0}, "visibleFrame": {"height": 1415, "width": 5064, "x": 56, "y": 0}},
    "frame": {"height": 1000, "width": 1600, "x": 200, "y": 200},
    "sidebar": {"isVisible": true, "selection": "tabs", "width": 200},
    "tabManager": {
      "selectedWorkspaceIndex": 0,
      "workspaces": [{
        "currentDirectory": "/Users/nodeselector",
        "isPinned": false,
        "layout": {
          "type": "split",
          "split": {
            "orientation": "horizontal",
            "dividerPosition": 0.5,
            "first": {"type": "pane", "pane": {"panelIds": ["AAAA0001-0000-0000-0000-000000000001"], "selectedPanelId": "AAAA0001-0000-0000-0000-000000000001"}},
            "second": {"type": "pane", "pane": {"panelIds": ["AAAA0002-0000-0000-0000-000000000002"], "selectedPanelId": "AAAA0002-0000-0000-0000-000000000002"}}
          }
        },
        "panels": [
          {"id": "AAAA0001-0000-0000-0000-000000000001", "type": "terminal", "title": "nvim-test", "isPinned": false, "isManuallyUnread": false, "listeningPorts": [], "terminal": {"workingDirectory": "/tmp", "restoreCommand": "nvim"}},
          {"id": "AAAA0002-0000-0000-0000-000000000002", "type": "terminal", "title": "shell-test", "isPinned": false, "isManuallyUnread": false, "listeningPorts": [], "terminal": {"workingDirectory": "/Users/nodeselector"}}
        ],
        "processTitle": "session-test",
        "logEntries": [],
        "statusEntries": []
      }]
    }
  }]
}
SNAPSHOT

# Launch nsmux
info "Launching nsmux..."
open "$APP"
sleep 8

# Check: is nsmux running?
if pgrep -x nsmux > /dev/null 2>&1; then
    pass "nsmux is running"
else
    fail "nsmux is not running"
fi

# Check: did the snapshot get overwritten by completeStartupSessionRestore?
PANEL_COUNT=$(python3 -c "
import json
with open('$SNAPSHOT_FILE') as f:
    d = json.load(f)
print(len(d['windows'][0]['tabManager']['workspaces'][0]['panels']))
")
if [[ "$PANEL_COUNT" -ge 2 ]]; then
    pass "Snapshot has $PANEL_COUNT panels after restore (not clobbered)"
else
    fail "Snapshot clobbered: only $PANEL_COUNT panel(s) after restore"
fi

# Check: layout is split
LAYOUT_TYPE=$(python3 -c "
import json
with open('$SNAPSHOT_FILE') as f:
    d = json.load(f)
layout = d['windows'][0]['tabManager']['workspaces'][0]['layout']
print('split' if 'split' in layout else 'pane')
")
if [[ "$LAYOUT_TYPE" == "split" ]]; then
    pass "Layout is split"
else
    fail "Layout is $LAYOUT_TYPE (expected split)"
fi

# Check: nvim is running
if pgrep -f "nvim" | grep -v grep > /dev/null 2>&1; then
    NVIM_PARENT=$(ps -p $(pgrep -f "exec -l nvim" | head -1) -o ppid= 2>/dev/null | tr -d ' ')
    NSMUX_PID=$(pgrep -x nsmux | head -1)
    pass "nvim is running"
else
    fail "nvim is not running"
fi

# ─── Test 2: Quit does not clobber snapshot ──────────────────────────────

# Wait for autosave to re-detect nvim after restore
sleep 8

info "Test 2: Snapshot survives quit"

# Wait for autosave to capture current state
sleep 10

# Backup snapshot
cp "$SNAPSHOT_FILE" "$BACKUP_FILE"
BEFORE_SIZE=$(wc -c < "$BACKUP_FILE" | tr -d ' ')
BEFORE_PANELS=$(python3 -c "
import json
with open('$BACKUP_FILE') as f:
    d = json.load(f)
print(len(d['windows'][0]['tabManager']['workspaces'][0]['panels']))
")

info "Snapshot before quit: $BEFORE_PANELS panels, $BEFORE_SIZE bytes"

# Quit nsmux
pkill -f "nsmux.app" 2>/dev/null || true
sleep 3

AFTER_PANELS=$(python3 -c "
import json
with open('$SNAPSHOT_FILE') as f:
    d = json.load(f)
print(len(d['windows'][0]['tabManager']['workspaces'][0]['panels']))
")
AFTER_SIZE=$(wc -c < "$SNAPSHOT_FILE" | tr -d ' ')

info "Snapshot after quit: $AFTER_PANELS panels, $AFTER_SIZE bytes"

if [[ "$AFTER_PANELS" -ge "$BEFORE_PANELS" ]]; then
    pass "Snapshot not clobbered on quit ($AFTER_PANELS >= $BEFORE_PANELS panels)"
else
    fail "Snapshot clobbered on quit ($AFTER_PANELS < $BEFORE_PANELS panels)"
fi

# ─── Test 3: Second restore works ────────────────────────────────────────

info "Test 3: Second restore from surviving snapshot"

# Make sure nsmux is fully stopped
sleep 2

# Launch again
open "$APP"
sleep 8

RESTORED_PANELS=$(python3 -c "
import json
with open('$SNAPSHOT_FILE') as f:
    d = json.load(f)
print(len(d['windows'][0]['tabManager']['workspaces'][0]['panels']))
")

if [[ "$RESTORED_PANELS" -ge "$BEFORE_PANELS" ]]; then
    pass "Second restore preserved panels ($RESTORED_PANELS >= $BEFORE_PANELS)"
else
    fail "Second restore degraded ($RESTORED_PANELS < $BEFORE_PANELS panels)"
fi

# Check nvim running again
if pgrep -f "exec -l nvim" > /dev/null 2>&1; then
    pass "nvim restored on second launch"
else
    fail "nvim not restored on second launch"
fi

# ─── Test 4: Nested split layout ─────────────────────────────────────────

info "Test 4: Complex layout (3 panels, nested splits)"

pkill -f "nsmux.app" 2>/dev/null || true
sleep 2

cat > "$SNAPSHOT_FILE" << 'SNAPSHOT'
{
  "createdAt": 1774390000,
  "version": 1,
  "windows": [{
    "display": {"displayID": 4, "frame": {"height": 1440, "width": 5120, "x": 0, "y": 0}, "visibleFrame": {"height": 1415, "width": 5064, "x": 56, "y": 0}},
    "frame": {"height": 1000, "width": 1600, "x": 200, "y": 200},
    "sidebar": {"isVisible": true, "selection": "tabs", "width": 200},
    "tabManager": {
      "selectedWorkspaceIndex": 0,
      "workspaces": [{
        "currentDirectory": "/Users/nodeselector",
        "isPinned": false,
        "layout": {
          "type": "split",
          "split": {
            "orientation": "horizontal",
            "dividerPosition": 0.5,
            "first": {"type": "pane", "pane": {"panelIds": ["BBBB0001-0000-0000-0000-000000000001"], "selectedPanelId": "BBBB0001-0000-0000-0000-000000000001"}},
            "second": {
              "type": "split",
              "split": {
                "orientation": "vertical",
                "dividerPosition": 0.5,
                "first": {"type": "pane", "pane": {"panelIds": ["BBBB0002-0000-0000-0000-000000000002"], "selectedPanelId": "BBBB0002-0000-0000-0000-000000000002"}},
                "second": {"type": "pane", "pane": {"panelIds": ["BBBB0003-0000-0000-0000-000000000003"], "selectedPanelId": "BBBB0003-0000-0000-0000-000000000003"}}
              }
            }
          }
        },
        "panels": [
          {"id": "BBBB0001-0000-0000-0000-000000000001", "type": "terminal", "title": "nvim-left", "isPinned": false, "isManuallyUnread": false, "listeningPorts": [], "terminal": {"workingDirectory": "/tmp", "restoreCommand": "nvim"}},
          {"id": "BBBB0002-0000-0000-0000-000000000002", "type": "terminal", "title": "shell-topright", "isPinned": false, "isManuallyUnread": false, "listeningPorts": [], "terminal": {"workingDirectory": "/Users/nodeselector"}},
          {"id": "BBBB0003-0000-0000-0000-000000000003", "type": "terminal", "title": "shell-bottomright", "isPinned": false, "isManuallyUnread": false, "listeningPorts": [], "terminal": {"workingDirectory": "/Users/nodeselector"}}
        ],
        "processTitle": "complex-layout-test",
        "logEntries": [],
        "statusEntries": []
      }]
    }
  }]
}
SNAPSHOT

open "$APP"
sleep 8

COMPLEX_PANELS=$(python3 -c "
import json
with open('$SNAPSHOT_FILE') as f:
    d = json.load(f)
print(len(d['windows'][0]['tabManager']['workspaces'][0]['panels']))
")

if [[ "$COMPLEX_PANELS" -ge 3 ]]; then
    pass "Complex layout restored: $COMPLEX_PANELS panels"
else
    fail "Complex layout degraded: $COMPLEX_PANELS panels (expected 3)"
fi

# Cleanup
pkill -f "nsmux.app" 2>/dev/null || true

# ─── Summary ──────────────────────────────────────────────────────────────

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}$FAILURES test(s) failed${NC}"
    exit 1
fi
