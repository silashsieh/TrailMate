#!/bin/bash
# tm_tunneld.sh — privileged wrapper for `pymobiledevice3 remote tunneld`.
#
# Launched as root by TrailMate.app via `osascript … with administrator
# privileges` — ONE auth prompt for the whole session. Runs a single tunneld
# that auto-tunnels every connected device (usb + wifi + usbmux). The host
# queries tunneld's HTTP API (127.0.0.1:$PORT/) directly for each device's
# current RSD endpoint, so this wrapper publishes no addresses — only an
# early-exit error. Parent-watches the host PID so a host crash can't leak the
# tunnel daemon, and tears down on a .stop sentinel.
#
# Replaces the per-device tm_tunnel.sh (one `lockdown start-tunnel` per device,
# one prompt each) — see epic 012. The RSD address+port tunneld assigns are
# ephemeral (they change on every sleep/wake), so the host re-queries on every
# connect rather than caching anything here.
#
# Args:
#   $1 control file path (.error written on early tunneld exit; .stop polled)
#   $2 host PID (parent watcher target)
#   $3 PYTHONHOME — bundled CPython root
#   $4 PYTHONPATH — bundled site-packages
#   $5 tunneld port

set -u

CTRL="$1"
PARENT_PID="$2"
PY_HOME="$3"
PY_LIBS="$4"
PORT="$5"

PY="$PY_HOME/bin/python3.13"

export PYTHONHOME="$PY_HOME"
export PYTHONPATH="$PY_LIBS"
export PYTHONNOUSERSITE=1
export PYTHONUNBUFFERED=1
export PYTHONDONTWRITEBYTECODE=1

cleanup() {
    if [ -n "${TUNNELD_PID:-}" ]; then
        # Ask politely first (SIGTERM / its own graceful shutdown), then ESCALATE.
        # A tunneld holding a live TUN tunnel wedges on shutdown — it acks
        # SIGINT/SIGTERM but never exits — so a plain `kill -TERM` + `wait` would
        # block here forever and leak the root daemon on the port (epic 031/032).
        # Poll for a short grace period, then SIGKILL (uncatchable) so teardown
        # always completes. We run as root, so we can force-kill our own child;
        # the kernel reclaims the utun interface when the process dies.
        kill -TERM "$TUNNELD_PID" 2>/dev/null
        for _ in $(seq 1 12); do                 # ~3s grace for a clean exit
            kill -0 "$TUNNELD_PID" 2>/dev/null || break
            sleep 0.25
        done
        kill -KILL "$TUNNELD_PID" 2>/dev/null     # force if still wedged
        wait "$TUNNELD_PID" 2>/dev/null
    fi
    rm -f "$CTRL" "$CTRL.stop" "$CTRL.err" "$CTRL.error"
}
trap cleanup EXIT INT TERM HUP

"$PY" -m pymobiledevice3 remote tunneld \
    --host 127.0.0.1 --port "$PORT" -p tcp \
    > "$CTRL.err" 2>&1 &
TUNNELD_PID=$!

# Early-exit check: if tunneld dies immediately (e.g. port already in use),
# surface its output as $CTRL.error so the host fails fast instead of polling
# the HTTP endpoint until timeout.
for _ in $(seq 1 8); do
    if ! kill -0 "$TUNNELD_PID" 2>/dev/null; then
        mv "$CTRL.err" "$CTRL.error" 2>/dev/null || true
        exit 1
    fi
    sleep 0.25
done

# Hold open until the host signals stop, the host process dies, or tunneld
# exits unexpectedly. Readiness itself is detected host-side by polling the
# HTTP endpoint — no readiness signal needed here.
while kill -0 "$PARENT_PID" 2>/dev/null && [ ! -f "$CTRL.stop" ]; do
    if ! kill -0 "$TUNNELD_PID" 2>/dev/null; then break; fi
    sleep 1
done
