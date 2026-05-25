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
import sys

from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation


def emit(msg: str) -> None:
    sys.stdout.write(msg + "\n")
    sys.stdout.flush()


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
        except Exception as e:
            emit(f"ERR 3 Command failed: {e}")


async def main() -> None:
    if len(sys.argv) != 3:
        emit("ERR 1 Usage: tm_daemon.py <rsd_address> <rsd_port>")
        sys.exit(1)

    rsd_address = sys.argv[1]
    rsd_port = int(sys.argv[2])

    try:
        rsd = RemoteServiceDiscoveryService((rsd_address, rsd_port))
        await rsd.connect()
    except Exception as e:
        emit(f"ERR 10 RSD connection failed: {e}")
        sys.exit(1)

    try:
        async with DvtProvider(rsd) as dvt, LocationSimulation(dvt) as location:
            emit("READY")

            loop = asyncio.get_event_loop()
            stdin_reader = asyncio.StreamReader()
            protocol = asyncio.StreamReaderProtocol(stdin_reader)
            await loop.connect_read_pipe(lambda: protocol, sys.stdin)

            await command_loop(location, stdin_reader)
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
