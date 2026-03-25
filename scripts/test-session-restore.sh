#!/usr/bin/env bash
set -euo pipefail

# Integration test for nsmux session persistence.
# Tests layout restore, nvim/pi restore, quit protection, and state stability.
#
# Usage:
#   ./test-session-restore.sh [--build]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP="/Applications/nsmux.app"
SNAPSHOT_DIR="$HOME/Library/Application Support/cmux"
SNAPSHOT_FILE="$SNAPSHOT_DIR/session-io.choam.nsmux.json"
BACKUP_FILE="/tmp/nsmux-test-snapshot-backup.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; FAILURES=$((FAILURES + 1)); }
info() { echo -e "${YELLOW}→ $1${NC}"; }

FAILURES=0

snapshot_panel_count() {
    python3 -c "
import json
with open('$SNAPSHOT_FILE') as f:
    d = json.load(f)
total = 0
for w in d['windows']:
    for ws in w['tabManager']['workspaces']:
        total += len(ws['panels'])
print(total)
" 2>/dev/null || echo "0"
}

snapshot_layout_type() {
    python3 -c "
import json
with open('$SNAPSHOT_FILE') as f:
    d = json.load(f)
layout = d['windows'][0]['tabManager']['workspaces'][0]['layout']
print('split' if 'split' in layout else 'pane')
" 2>/dev/null || echo "unknown"
}

snapshot_restore_commands() {
    python3 -c "
import json
with open('$SNAPSHOT_FILE') as f:
    d = json.load(f)
for w in d['windows']:
    for ws in w['tabManager']['workspaces']:
        for p in ws['panels']:
            t = p.get('terminal', {})
            rc = t.get('restoreCommand')
            if rc:
                print(rc[:60])
" 2>/dev/null
}

kill_nsmux() {
    pkill -f "nsmux.app" 2>/dev/null || true
    # Wait until fully dead
    for i in $(seq 1 10); do
        pgrep -x nsmux > /dev/null 2>&1 || break
        sleep 1
    done
    sleep 1
}

write_test_snapshot() {
    local name="$1"
    local json="$2"
    mkdir -p "$SNAPSHOT_DIR"
    echo "$json" > "$SNAPSHOT_FILE"
}

launch_and_wait() {
    local wait_secs="${1:-12}"
    open "$APP"
    sleep "$wait_secs"
}

if [[ "${1:-}" == "--build" ]]; then
    info "Building nsmux..."
    cd "$PROJECT_DIR"
    ./scripts/build-nsmux.sh 2>&1 | tail -3
    kill_nsmux
    rm -rf "$APP"
    cp -R build-nsmux/nsmux.app "$APP"
fi

kill_nsmux

# ═══════════════════════════════════════════════════════════════════════════
# Test 1: Basic layout restore (2 panels, horizontal split)
# ═══════════════════════════════════════════════════════════════════════════

info "Test 1: Basic 2-panel split layout restore"

write_test_snapshot "basic-split" '{
  "createdAt": 1774390000, "version": 1,
  "windows": [{"display": {"displayID": 4, "frame": {"height": 1440, "width": 5120, "x": 0, "y": 0}, "visibleFrame": {"height": 1415, "width": 5064, "x": 56, "y": 0}},
    "frame": {"height": 1000, "width": 1600, "x": 200, "y": 200},
    "sidebar": {"isVisible": true, "selection": "tabs", "width": 200},
    "tabManager": {"selectedWorkspaceIndex": 0, "workspaces": [{"currentDirectory": "/Users/nodeselector", "isPinned": false,
      "layout": {"type": "split", "split": {"orientation": "horizontal", "dividerPosition": 0.5,
        "first": {"type": "pane", "pane": {"panelIds": ["AAAA0001-0000-0000-0000-000000000001"], "selectedPanelId": "AAAA0001-0000-0000-0000-000000000001"}},
        "second": {"type": "pane", "pane": {"panelIds": ["AAAA0002-0000-0000-0000-000000000002"], "selectedPanelId": "AAAA0002-0000-0000-0000-000000000002"}}}},
      "panels": [
        {"id": "AAAA0001-0000-0000-0000-000000000001", "type": "terminal", "title": "left", "isPinned": false, "isManuallyUnread": false, "listeningPorts": [], "terminal": {"workingDirectory": "/tmp"}},
        {"id": "AAAA0002-0000-0000-0000-000000000002", "type": "terminal", "title": "right", "isPinned": false, "isManuallyUnread": false, "listeningPorts": [], "terminal": {"workingDirectory": "/Users/nodeselector"}}],
      "processTitle": "test-basic", "logEntries": [], "statusEntries": []}]}}]}'

launch_and_wait 8

# Check immediately
COUNT_T1=$(snapshot_panel_count)
LAYOUT_T1=$(snapshot_layout_type)

# Wait more and check stability
sleep 12
COUNT_T2=$(snapshot_panel_count)
LAYOUT_T2=$(snapshot_layout_type)

if [[ "$COUNT_T1" -ge 2 ]]; then pass "Initial restore: $COUNT_T1 panels"
else fail "Initial restore: only $COUNT_T1 panel(s) (expected 2)"; fi

if [[ "$LAYOUT_T1" == "split" ]]; then pass "Initial layout: split"
else fail "Initial layout: $LAYOUT_T1 (expected split)"; fi

if [[ "$COUNT_T2" -ge 2 ]]; then pass "Stable after 20s: $COUNT_T2 panels"
else fail "State degraded after 20s: $COUNT_T2 panels (was $COUNT_T1)"; fi

if [[ "$COUNT_T2" -ge "$COUNT_T1" ]]; then pass "State stable (no flash-and-reset)"
else fail "STATE UNSTABLE: went from $COUNT_T1 to $COUNT_T2 panels (flash-and-reset bug)"; fi

kill_nsmux

# ═══════════════════════════════════════════════════════════════════════════
# Test 2: nvim restore command
# ═══════════════════════════════════════════════════════════════════════════

info "Test 2: nvim restoreCommand launches nvim"

write_test_snapshot "nvim-restore" '{
  "createdAt": 1774390000, "version": 1,
  "windows": [{"display": {"displayID": 4, "frame": {"height": 1440, "width": 5120, "x": 0, "y": 0}, "visibleFrame": {"height": 1415, "width": 5064, "x": 56, "y": 0}},
    "frame": {"height": 1000, "width": 1600, "x": 200, "y": 200},
    "sidebar": {"isVisible": true, "selection": "tabs", "width": 200},
    "tabManager": {"selectedWorkspaceIndex": 0, "workspaces": [{"currentDirectory": "/Users/nodeselector", "isPinned": false,
      "layout": {"type": "split", "split": {"orientation": "horizontal", "dividerPosition": 0.5,
        "first": {"type": "pane", "pane": {"panelIds": ["AAAA0001-0000-0000-0000-000000000001"], "selectedPanelId": "AAAA0001-0000-0000-0000-000000000001"}},
        "second": {"type": "pane", "pane": {"panelIds": ["AAAA0002-0000-0000-0000-000000000002"], "selectedPanelId": "AAAA0002-0000-0000-0000-000000000002"}}}},
      "panels": [
        {"id": "AAAA0001-0000-0000-0000-000000000001", "type": "terminal", "title": "nvim-pane", "isPinned": false, "isManuallyUnread": false, "listeningPorts": [], "terminal": {"workingDirectory": "/tmp", "restoreCommand": "nvim"}},
        {"id": "AAAA0002-0000-0000-0000-000000000002", "type": "terminal", "title": "shell-pane", "isPinned": false, "isManuallyUnread": false, "listeningPorts": [], "terminal": {"workingDirectory": "/Users/nodeselector"}}],
      "processTitle": "test-nvim", "logEntries": [], "statusEntries": []}]}}]}'

launch_and_wait 8

# Check nvim immediately
NVIM_T1=$(pgrep -f "exec -l nvim" > /dev/null 2>&1 && echo "yes" || echo "no")

# Check stability
sleep 12
NVIM_T2=$(pgrep -f "exec -l nvim" > /dev/null 2>&1 && echo "yes" || echo "no")
COUNT_NVIM=$(snapshot_panel_count)

if [[ "$NVIM_T1" == "yes" ]]; then pass "nvim running at 8s"
else fail "nvim NOT running at 8s"; fi

if [[ "$NVIM_T2" == "yes" ]]; then pass "nvim still running at 20s"
else fail "nvim DIED between 8s and 20s (flash-and-reset)"; fi

if [[ "$COUNT_NVIM" -ge 2 ]]; then pass "Layout stable with nvim: $COUNT_NVIM panels"
else fail "Layout degraded with nvim: $COUNT_NVIM panels"; fi

kill_nsmux

# ═══════════════════════════════════════════════════════════════════════════
# Test 3: Snapshot survives quit
# ═══════════════════════════════════════════════════════════════════════════

info "Test 3: Snapshot survives quit and second restore works"

write_test_snapshot "quit-survive" '{
  "createdAt": 1774390000, "version": 1,
  "windows": [{"display": {"displayID": 4, "frame": {"height": 1440, "width": 5120, "x": 0, "y": 0}, "visibleFrame": {"height": 1415, "width": 5064, "x": 56, "y": 0}},
    "frame": {"height": 1000, "width": 1600, "x": 200, "y": 200},
    "sidebar": {"isVisible": true, "selection": "tabs", "width": 200},
    "tabManager": {"selectedWorkspaceIndex": 0, "workspaces": [{"currentDirectory": "/Users/nodeselector", "isPinned": false,
      "layout": {"type": "split", "split": {"orientation": "horizontal", "dividerPosition": 0.5,
        "first": {"type": "pane", "pane": {"panelIds": ["AAAA0001-0000-0000-0000-000000000001"], "selectedPanelId": "AAAA0001-0000-0000-0000-000000000001"}},
        "second": {"type": "pane", "pane": {"panelIds": ["AAAA0002-0000-0000-0000-000000000002"], "selectedPanelId": "AAAA0002-0000-0000-0000-000000000002"}}}},
      "panels": [
        {"id": "AAAA0001-0000-0000-0000-000000000001", "type": "terminal", "title": "nvim-pane", "isPinned": false, "isManuallyUnread": false, "listeningPorts": [], "terminal": {"workingDirectory": "/tmp", "restoreCommand": "nvim"}},
        {"id": "AAAA0002-0000-0000-0000-000000000002", "type": "terminal", "title": "shell-pane", "isPinned": false, "isManuallyUnread": false, "listeningPorts": [], "terminal": {"workingDirectory": "/Users/nodeselector"}}],
      "processTitle": "test-quit", "logEntries": [], "statusEntries": []}]}}]}'

launch_and_wait 20  # Wait for autosave to capture restored state

BEFORE_QUIT=$(snapshot_panel_count)
cp "$SNAPSHOT_FILE" "$BACKUP_FILE"

kill_nsmux

AFTER_QUIT=$(snapshot_panel_count)
if [[ "$AFTER_QUIT" -ge "$BEFORE_QUIT" ]]; then pass "Snapshot survived quit ($AFTER_QUIT >= $BEFORE_QUIT panels)"
else fail "Snapshot CLOBBERED on quit ($AFTER_QUIT < $BEFORE_QUIT)"; fi

# Second restore
launch_and_wait 8
SECOND_T1=$(snapshot_panel_count)
NVIM_SECOND_T1=$(pgrep -f "exec -l nvim" > /dev/null 2>&1 && echo "yes" || echo "no")

sleep 12
SECOND_T2=$(snapshot_panel_count)
NVIM_SECOND_T2=$(pgrep -f "exec -l nvim" > /dev/null 2>&1 && echo "yes" || echo "no")

if [[ "$SECOND_T1" -ge 2 ]]; then pass "Second restore: $SECOND_T1 panels at 8s"
else fail "Second restore failed: $SECOND_T1 panels at 8s"; fi

if [[ "$SECOND_T2" -ge "$SECOND_T1" ]]; then pass "Second restore stable ($SECOND_T2 >= $SECOND_T1)"
else fail "Second restore UNSTABLE: $SECOND_T1 -> $SECOND_T2 panels"; fi

if [[ "$NVIM_SECOND_T1" == "yes" ]]; then pass "nvim running on second restore (8s)"
else fail "nvim NOT running on second restore (8s)"; fi

if [[ "$NVIM_SECOND_T2" == "yes" ]]; then pass "nvim stable on second restore (20s)"
else fail "nvim DIED on second restore between 8s and 20s"; fi

kill_nsmux

# ═══════════════════════════════════════════════════════════════════════════
# Test 4: Pi session restore
# ═══════════════════════════════════════════════════════════════════════════

info "Test 4: Pi session restore"

PI_PATH="$HOME/.nvm/versions/node/v24.13.1/bin/pi"
SESSION_FILE=$(ls -t "$HOME/.pi/agent/sessions/--Users-nodeselector--/"*.jsonl 2>/dev/null | head -1)

if [[ -z "$SESSION_FILE" ]] || [[ ! -f "$PI_PATH" ]]; then
    info "Skipping pi test (pi=$PI_PATH session=$SESSION_FILE)"
else

    python3 - "$PI_PATH" "$SESSION_FILE" "$SNAPSHOT_FILE" << 'PYEOF'
import json, sys
pi_path = sys.argv[1]
session_file = sys.argv[2]
snapshot_file = sys.argv[3]
restore_cmd = f"{pi_path} --session '{session_file}'"
snapshot = {
    "createdAt": 1774390000, "version": 1,
    "windows": [{"display": {"displayID": 4, "frame": {"height": 1440, "width": 5120, "x": 0, "y": 0}, "visibleFrame": {"height": 1415, "width": 5064, "x": 56, "y": 0}},
        "frame": {"height": 1000, "width": 1600, "x": 200, "y": 200},
        "sidebar": {"isVisible": True, "selection": "tabs", "width": 200},
        "tabManager": {"selectedWorkspaceIndex": 0, "workspaces": [{"currentDirectory": "/Users/nodeselector", "isPinned": False,
            "layout": {"type": "split", "split": {"orientation": "horizontal", "dividerPosition": 0.5,
                "first": {"type": "pane", "pane": {"panelIds": ["CCCC0001-0000-0000-0000-000000000001"], "selectedPanelId": "CCCC0001-0000-0000-0000-000000000001"}},
                "second": {"type": "pane", "pane": {"panelIds": ["CCCC0002-0000-0000-0000-000000000002"], "selectedPanelId": "CCCC0002-0000-0000-0000-000000000002"}}}},
            "panels": [
                {"id": "CCCC0001-0000-0000-0000-000000000001", "type": "terminal", "title": "pi-test", "isPinned": False, "isManuallyUnread": False, "listeningPorts": [], "terminal": {"workingDirectory": "/Users/nodeselector", "restoreCommand": restore_cmd}},
                {"id": "CCCC0002-0000-0000-0000-000000000002", "type": "terminal", "title": "shell-test", "isPinned": False, "isManuallyUnread": False, "listeningPorts": [], "terminal": {"workingDirectory": "/Users/nodeselector"}}],
            "processTitle": "test-pi", "logEntries": [], "statusEntries": []}]}}]}
with open(snapshot_file, "w") as f:
    json.dump(snapshot, f)
PYEOF

    launch_and_wait 10

    PI_T1=$(pgrep -f "pi.*--session" > /dev/null 2>&1 && echo "yes" || (pgrep -f "pi-coding-agent" > /dev/null 2>&1 && echo "yes" || echo "no"))
    COUNT_PI_T1=$(snapshot_panel_count)

    sleep 12
    PI_T2=$(pgrep -f "pi.*--session" > /dev/null 2>&1 && echo "yes" || (pgrep -f "pi-coding-agent" > /dev/null 2>&1 && echo "yes" || echo "no"))
    COUNT_PI_T2=$(snapshot_panel_count)

    if [[ "$COUNT_PI_T1" -ge 2 ]]; then pass "Pi layout restored: $COUNT_PI_T1 panels at 10s"
    else fail "Pi layout degraded: $COUNT_PI_T1 panels at 10s"; fi

    if [[ "$PI_T1" == "yes" ]]; then pass "Pi process running at 10s"
    else fail "Pi process NOT running at 10s"; fi

    if [[ "$COUNT_PI_T2" -ge "$COUNT_PI_T1" ]]; then pass "Pi layout stable ($COUNT_PI_T2 >= $COUNT_PI_T1)"
    else fail "Pi layout UNSTABLE: $COUNT_PI_T1 -> $COUNT_PI_T2 panels"; fi

    if [[ "$PI_T2" == "yes" ]]; then pass "Pi process stable at 22s"
    else fail "Pi process DIED between 10s and 22s"; fi

    # Quit/restore cycle for pi
    sleep 8
    kill_nsmux

    AFTER_PI_QUIT=$(snapshot_panel_count)
    if [[ "$AFTER_PI_QUIT" -ge 2 ]]; then pass "Pi snapshot survived quit ($AFTER_PI_QUIT panels)"
    else fail "Pi snapshot CLOBBERED on quit ($AFTER_PI_QUIT panels)"; fi

    launch_and_wait 12
    PI_SECOND=$(pgrep -f "pi.*--session" > /dev/null 2>&1 && echo "yes" || (pgrep -f "pi-coding-agent" > /dev/null 2>&1 && echo "yes" || echo "no"))
    if [[ "$PI_SECOND" == "yes" ]]; then pass "Pi restored on second launch"
    else fail "Pi NOT restored on second launch"; fi

    kill_nsmux
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test 5: Complex nested layout
# ═══════════════════════════════════════════════════════════════════════════

info "Test 5: Complex 3-panel nested split layout"

write_test_snapshot "complex" '{
  "createdAt": 1774390000, "version": 1,
  "windows": [{"display": {"displayID": 4, "frame": {"height": 1440, "width": 5120, "x": 0, "y": 0}, "visibleFrame": {"height": 1415, "width": 5064, "x": 56, "y": 0}},
    "frame": {"height": 1000, "width": 1600, "x": 200, "y": 200},
    "sidebar": {"isVisible": true, "selection": "tabs", "width": 200},
    "tabManager": {"selectedWorkspaceIndex": 0, "workspaces": [{"currentDirectory": "/Users/nodeselector", "isPinned": false,
      "layout": {"type": "split", "split": {"orientation": "horizontal", "dividerPosition": 0.5,
        "first": {"type": "pane", "pane": {"panelIds": ["BBBB0001-0000-0000-0000-000000000001"], "selectedPanelId": "BBBB0001-0000-0000-0000-000000000001"}},
        "second": {"type": "split", "split": {"orientation": "vertical", "dividerPosition": 0.5,
          "first": {"type": "pane", "pane": {"panelIds": ["BBBB0002-0000-0000-0000-000000000002"], "selectedPanelId": "BBBB0002-0000-0000-0000-000000000002"}},
          "second": {"type": "pane", "pane": {"panelIds": ["BBBB0003-0000-0000-0000-000000000003"], "selectedPanelId": "BBBB0003-0000-0000-0000-000000000003"}}}}}},
      "panels": [
        {"id": "BBBB0001-0000-0000-0000-000000000001", "type": "terminal", "title": "left", "isPinned": false, "isManuallyUnread": false, "listeningPorts": [], "terminal": {"workingDirectory": "/tmp", "restoreCommand": "nvim"}},
        {"id": "BBBB0002-0000-0000-0000-000000000002", "type": "terminal", "title": "topright", "isPinned": false, "isManuallyUnread": false, "listeningPorts": [], "terminal": {"workingDirectory": "/Users/nodeselector"}},
        {"id": "BBBB0003-0000-0000-0000-000000000003", "type": "terminal", "title": "bottomright", "isPinned": false, "isManuallyUnread": false, "listeningPorts": [], "terminal": {"workingDirectory": "/Users/nodeselector"}}],
      "processTitle": "test-complex", "logEntries": [], "statusEntries": []}]}}]}'

launch_and_wait 8
COMPLEX_T1=$(snapshot_panel_count)
sleep 12
COMPLEX_T2=$(snapshot_panel_count)

if [[ "$COMPLEX_T1" -ge 3 ]]; then pass "Complex layout: $COMPLEX_T1 panels at 8s"
else fail "Complex layout failed: $COMPLEX_T1 panels at 8s (expected 3)"; fi

if [[ "$COMPLEX_T2" -ge "$COMPLEX_T1" ]]; then pass "Complex layout stable ($COMPLEX_T2 >= $COMPLEX_T1)"
else fail "Complex layout UNSTABLE: $COMPLEX_T1 -> $COMPLEX_T2 panels"; fi

kill_nsmux

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}$FAILURES test(s) failed${NC}"
    exit 1
fi
