#!/usr/bin/env python3
"""TrailMate Location Simulation Daemon.

Maintains a persistent DVT connection to an iOS device and accepts
location commands over stdin. The DVT session stays alive for the
entire daemon lifetime — this is required because simulated location
reverts to real GPS the moment the session drops.

Usage:
    python3 tm_daemon.py <rsd_address> <rsd_port>

Stdin commands:
    SET <lat> <lon>   Set simulated location (responds OK)
    SETQ <lat> <lon>  Set simulated location (no response, for high-frequency playback)
    CLEAR             Clear simulated location (session stays alive)
    HEARTBEAT         Liveness check
    QUIT              Graceful shutdown

Stdout events:
    READY             DVT connected, accepting commands
    OK                Last command succeeded
    ERR <code> <msg>  Last command failed
    EXIT              Shutdown acknowledgment
"""

import asyncio
import os
import signal
import sys
import threading
import time

from pymobiledevice3.exceptions import ConnectionTerminatedError, StreamClosedError
from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation

# Exception classes that indicate the DVT/RSD pipe has gone away — recover is
# impossible without re-establishing the tunnel from scratch. Treated as fatal.
_TUNNEL_FATAL = (ConnectionTerminatedError, StreamClosedError, ConnectionResetError, BrokenPipeError)


def emit(msg: str) -> None:
    sys.stdout.write(msg + "\n")
    sys.stdout.flush()


def _install_parent_watcher() -> None:
    # If TM_PARENT_PID is set and the host app dies (graceful exit, crash,
    # SIGKILL), we get reparented to launchd (PID 1). Exit immediately so
    # we don't outlive the app holding the DVT session open.
    raw = os.environ.get("TM_PARENT_PID", "")
    try:
        target = int(raw)
    except ValueError:
        return
    if target <= 1:
        return

    def watch() -> None:
        while True:
            if os.getppid() != target:
                os._exit(0)
            time.sleep(2)

    threading.Thread(target=watch, daemon=True).start()


async def command_loop(location: LocationSimulation, reader: asyncio.StreamReader) -> None:
    while True:
        line_bytes = await reader.readline()
        if not line_bytes:
            break

        line = line_bytes.decode().strip()
        if not line:
            continue

        parts = line.split()
        cmd = parts[0].upper()

        try:
            if cmd == "SET" and len(parts) == 3:
                lat, lon = float(parts[1]), float(parts[2])
                await location.set(lat, lon)
                emit("OK")
            elif cmd == "SETQ" and len(parts) == 3:
                lat, lon = float(parts[1]), float(parts[2])
                await location.set(lat, lon)
            elif cmd == "CLEAR":
                await location.clear()
                emit("OK")
            elif cmd == "HEARTBEAT":
                emit("OK")
            elif cmd == "QUIT":
                try:
                    await location.clear()
                except Exception:
                    pass
                emit("EXIT")
                return
            else:
                emit(f"ERR 2 Unknown command: {line}")
        except _TUNNEL_FATAL as e:
            # Tunnel/RSD pipe gone — host re-connect is required. Emit a
            # distinct line so the Swift side can flip to .error promptly
            # instead of waiting for the next failing command.
            emit(f"TUNNEL_DOWN {type(e).__name__}: {e}")
            return
        except Exception as e:
            emit(f"ERR 3 Command failed: {e}")


async def main() -> None:
    _install_parent_watcher()

    if len(sys.argv) != 3:
        emit("ERR 1 Usage: tm_daemon.py <rsd_address> <rsd_port>")
        sys.exit(1)

    rsd_address = sys.argv[1]
    rsd_port = int(sys.argv[2])

    # Signals → asyncio.Event so the `async with` exits run cleanly
    # (clearing the DVT location) before the process dies.
    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        try:
            loop.add_signal_handler(sig, stop_event.set)
        except (NotImplementedError, RuntimeError):
            pass

    try:
        rsd = RemoteServiceDiscoveryService((rsd_address, rsd_port))
        await rsd.connect()
    except Exception as e:
        emit(f"ERR 10 RSD connection failed: {e}")
        sys.exit(1)

    try:
        async with DvtProvider(rsd) as dvt, LocationSimulation(dvt) as location:
            emit("READY")

            stdin_reader = asyncio.StreamReader()
            protocol = asyncio.StreamReaderProtocol(stdin_reader)
            await loop.connect_read_pipe(lambda: protocol, sys.stdin)

            cmd_task = asyncio.create_task(command_loop(location, stdin_reader))
            stop_task = asyncio.create_task(stop_event.wait())

            done, pending = await asyncio.wait(
                {cmd_task, stop_task},
                return_when=asyncio.FIRST_COMPLETED,
            )
            for t in pending:
                t.cancel()
            for t in pending:
                try:
                    await t
                except (asyncio.CancelledError, Exception):
                    pass
    except Exception as e:
        emit(f"ERR 11 DVT session failed: {e}")
        sys.exit(1)
    finally:
        try:
            await rsd.close()
        except Exception:
            pass


if __name__ == "__main__":
    asyncio.run(main())
