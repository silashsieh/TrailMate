#!/bin/bash
# tm_tunnel.sh — privileged wrapper for `pymobiledevice3 lockdown start-tunnel`.
#
# Part of the TrailMate Python daemon, distributed under the GNU General Public
# License v3.0 or later (see COPYING and ../LICENSING.md). The TrailMate macOS
# app is licensed separately under the MIT License.
#
# Launched as root by TrailMate.app via `osascript … with administrator
# privileges`, backgrounded so osascript returns immediately after the auth
# dialog. The host app polls a control file for the RSD address+port, then
# touches a .stop sentinel to tear the tunnel down. The wrapper also
# parent-watches the host PID so a host crash can't leak the tunnel.
#
# Args:
#   $1 UDID
#   $2 control file path (will hold "ADDRESS PORT\n" once tunnel is up)
#   $3 host PID (parent watcher target)
#   $4 PYTHONHOME — bundled CPython root
#   $5 PYTHONPATH — bundled site-packages

set -u

UDID="$1"
CTRL="$2"
PARENT_PID="$3"
PY_HOME="$4"
PY_LIBS="$5"

PY="$PY_HOME/bin/python3.13"

export PYTHONHOME="$PY_HOME"
export PYTHONPATH="$PY_LIBS"
export PYTHONNOUSERSITE=1
export PYTHONUNBUFFERED=1
export PYTHONDONTWRITEBYTECODE=1

cleanup() {
    if [ -n "${TUNNEL_PID:-}" ]; then
        kill -TERM "$TUNNEL_PID" 2>/dev/null
        wait "$TUNNEL_PID" 2>/dev/null
    fi
    rm -f "$CTRL" "$CTRL.stop" "$CTRL.err" "$CTRL.error" "$CTRL.line"
}
trap cleanup EXIT INT TERM HUP

"$PY" -m pymobiledevice3 lockdown start-tunnel \
    --udid "$UDID" --script-mode \
    > "$CTRL.line" 2> "$CTRL.err" &
TUNNEL_PID=$!

# Wait up to 30 s for script-mode's "ADDRESS PORT" line.
for _ in $(seq 1 120); do
    if [ -s "$CTRL.line" ]; then break; fi
    if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
        mv "$CTRL.err" "$CTRL.error" 2>/dev/null || true
        exit 1
    fi
    sleep 0.25
done

if [ ! -s "$CTRL.line" ]; then
    echo "timeout waiting for tunnel output" > "$CTRL.error"
    exit 1
fi

# Publish the address/port atomically — the host polls $CTRL.
mv "$CTRL.line" "$CTRL"

# Hold open until the host signals stop, the host process dies, or the
# tunnel itself exits unexpectedly.
while kill -0 "$PARENT_PID" 2>/dev/null && [ ! -f "$CTRL.stop" ]; do
    if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then break; fi
    sleep 1
done
