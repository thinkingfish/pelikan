#!/usr/bin/env bash
#
# Manual test: debug log rotation (minutely) + klog size-based rotation (2 KB)
#
# What this tests:
#   1. Debug log rotates every minute with gzip compression
#   2. Klog rotates when file exceeds 2 KB, keeps at most 3 rotated files
#   3. Both rotation mechanisms work correctly under load
#
# Configuration (see test_log_rotation.toml):
#   [debug]
#     log_level = "debug"
#     log_rotation_interval = "minutely"
#     log_max_size = 4096  (4 KB)
#     log_max_keep_files = 5
#
#   [klog]
#     max_size = 2048  (2 KB)
#     max_keep_files = 3
#     sample = 1  (log every command)
#
# Usage:
#   ./tests/manual/test_log_rotation.sh
#
# The script will:
#   - Build pelikan-pingserver in release mode
#   - Start the server with aggressive rotation settings
#   - Send PING traffic in a loop for ~3 minutes
#   - Periodically print the log directory contents
#   - Clean up on exit
#
# Known issue (as of 2026-03-22):
#   The klog file remains empty. The klog! macro uses log::error!(target: "klog", ...)
#   which goes through the tracing-log bridge. The klog layer's writer-level filter
#   (MakeWriterExt::with_filter) checks meta.target() == "klog", but for log-bridged
#   events the raw tracing metadata target may not match the original log record target.
#   The debug log correctly shows "klog:" as the target because the fmt layer uses
#   NormalizeEvent for display, but the writer filter sees the raw (pre-normalization)
#   metadata. Fix: use tracing::error! directly in the klog! macro, or use a layer-level
#   filter instead of a writer-level filter.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOG_DIR="/tmp/pelikan_test_logs"
CONFIG="$SCRIPT_DIR/test_log_rotation.toml"
BINARY="$REPO_ROOT/target/release/pelikan-pingserver"
PID=""

cleanup() {
    echo ""
    echo "=== Cleaning up ==="
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
        echo "Stopped pingserver (PID $PID)"
    fi
    echo ""
    echo "=== Final log directory contents ==="
    ls -lhS "$LOG_DIR/" 2>/dev/null || echo "(no log dir)"
    echo ""
    echo "Log directory preserved at: $LOG_DIR"
    echo "To clean up: rm -rf $LOG_DIR"
}
trap cleanup EXIT

echo "=== Building pelikan-pingserver (release) ==="
cd "$REPO_ROOT"
cargo build --release -p pelikan-pingserver
echo "Build complete: $BINARY"

echo ""
echo "=== Preparing log directory ==="
rm -rf "$LOG_DIR"
mkdir -p "$LOG_DIR"
echo "Log directory: $LOG_DIR"

echo ""
echo "=== Starting pingserver ==="
echo "Config: $CONFIG"
echo "  debug log: $LOG_DIR/debug.log (minutely rotation, 4 KB max size, keep 5)"
echo "  klog:      $LOG_DIR/klog.log  (size rotation at 2 KB, keep 3)"
echo ""
"$BINARY" "$CONFIG" &
PID=$!
echo "Pingserver started (PID $PID)"

# Wait for the server to be ready
sleep 2
if ! kill -0 "$PID" 2>/dev/null; then
    echo "ERROR: pingserver failed to start"
    exit 1
fi

# Quick sanity check
RESPONSE=$(printf "PING\r\n" | nc -w 1 localhost 12321 2>/dev/null || true)
if [[ "$RESPONSE" == *"PONG"* ]]; then
    echo "Sanity check: server responds to PING with PONG"
else
    echo "WARNING: server did not respond to PING (got: '$RESPONSE')"
fi

echo ""
echo "=== Sending PING traffic for ~3 minutes ==="
echo "  (klog sample=1, so every command is logged)"
echo "  Watching for log rotation..."
echo ""

DURATION=180  # 3 minutes — should see at least 2 minutely rotations
START=$(date +%s)
ITER=0

while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START))
    if [[ $ELAPSED -ge $DURATION ]]; then
        break
    fi

    # Check if server is still alive
    if ! kill -0 "$PID" 2>/dev/null; then
        echo "ERROR: pingserver died unexpectedly after ${ELAPSED}s"
        break
    fi

    # Send a batch of PINGs
    for _ in $(seq 1 20); do
        printf "PING\r\n" | nc -w 1 localhost 12321 > /dev/null 2>&1 || true
    done

    ITER=$((ITER + 1))

    # Print status every 15 seconds
    if [[ $((ITER % 15)) -eq 0 ]]; then
        echo "--- [${ELAPSED}s elapsed] Log directory ---"
        ls -lhS "$LOG_DIR/" 2>/dev/null || true
        echo ""
    fi

    sleep 1
done

echo ""
echo "=== Test complete ==="
echo ""
echo "--- Final log directory listing ---"
ls -lhS "$LOG_DIR/" 2>/dev/null || true
echo ""

# Check for rotated files
DEBUG_ROTATED=$(find "$LOG_DIR" -name "debug.log*" | wc -l)
KLOG_ROTATED=$(find "$LOG_DIR" -name "klog.log*" | wc -l)

echo "=== Results ==="
echo "  Debug log files: $DEBUG_ROTATED (expected > 1 if minutely rotation worked)"
echo "  Klog files:      $KLOG_ROTATED (expected > 1 if size-based rotation worked)"
echo ""

if [[ $DEBUG_ROTATED -gt 1 ]]; then
    echo "  [PASS] Debug log rotation triggered"
else
    echo "  [FAIL] Debug log rotation did NOT trigger (expected minutely rotation)"
fi

# Check if klog events appeared in the debug log (they go there via the debug layer)
KLOG_IN_DEBUG=0
for f in "$LOG_DIR"/debug.log*; do
    if [[ "$f" == *.gz ]]; then
        COUNT=$(zcat "$f" 2>/dev/null | grep -c "klog" || true)
    else
        COUNT=$(grep -c "klog" "$f" 2>/dev/null || true)
    fi
    KLOG_IN_DEBUG=$((KLOG_IN_DEBUG + COUNT))
done

if [[ $KLOG_ROTATED -gt 1 ]]; then
    echo "  [PASS] Klog rotation triggered"
else
    echo "  [FAIL] Klog rotation did NOT trigger (expected size-based rotation at 2 KB)"
    if [[ $KLOG_IN_DEBUG -gt 0 ]]; then
        echo "         NOTE: $KLOG_IN_DEBUG klog events appeared in the DEBUG log instead."
        echo "         This indicates the klog writer filter is not matching log-bridged events."
        echo "         See the known issue note at the top of this script."
    fi
fi

echo ""
echo "=== Debug log rotation details ==="
echo "Rotated debug log files (gzip compressed):"
for f in "$LOG_DIR"/debug.log*.gz; do
    if [[ -f "$f" ]]; then
        SIZE=$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f" 2>/dev/null || echo "?")
        LINES=$(zcat "$f" 2>/dev/null | wc -l || echo "?")
        echo "  $f  ($SIZE bytes compressed, $LINES lines)"
    fi
done
echo ""
echo "Current (active) debug log:"
ACTIVE=$(find "$LOG_DIR" -name "debug.log.*" ! -name "*.gz" 2>/dev/null | head -1)
if [[ -n "$ACTIVE" ]]; then
    SIZE=$(stat -c %s "$ACTIVE" 2>/dev/null || stat -f %z "$ACTIVE" 2>/dev/null || echo "?")
    LINES=$(wc -l < "$ACTIVE" 2>/dev/null || echo "?")
    echo "  $ACTIVE  ($SIZE bytes, $LINES lines)"
fi

echo ""
echo "You can inspect the rotated files in: $LOG_DIR"
echo "  Gzip files can be viewed with: zcat $LOG_DIR/<file>.gz"
