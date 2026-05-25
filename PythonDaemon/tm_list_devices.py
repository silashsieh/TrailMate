#!/usr/bin/env python3
"""TrailMate Device Lister.

One-shot enumeration of paired iOS devices reachable from this Mac, used by
the TrailMate sidebar to populate the device picker.

Outputs one JSON object per line on stdout:
    {"udid": "...", "name": "...", "connectionType": "USB"|"WiFi",
     "host": null|str, "port": null|int}

Exits 0 on success even if no devices found. Errors go to stderr and do not
abort the process — partial results are still useful.
"""

import asyncio
import json
import sys

from pymobiledevice3 import usbmux
from pymobiledevice3.bonjour import browse_remoted


def emit(record: dict) -> None:
    sys.stdout.write(json.dumps(record) + "\n")
    sys.stdout.flush()


async def main() -> None:
    seen: set[str] = set()

    try:
        usb_devs = await usbmux.list_devices()
        for d in usb_devs:
            udid = getattr(d, "serial", None)
            if not udid or udid in seen:
                continue
            seen.add(udid)
            ctype_raw = str(getattr(d, "connection_type", "")).upper()
            ctype = "USB" if "USB" in ctype_raw else "WiFi"
            emit({
                "udid": udid,
                "name": udid[-6:],
                "connectionType": ctype,
                "host": None,
                "port": None,
            })
    except Exception as e:
        sys.stderr.write(f"usbmux error: {e}\n")

    try:
        services = await browse_remoted(timeout=2)
        for s in services:
            instance = getattr(s, "instance", "") or ""
            # Service instance names usually start with the UDID, e.g.
            # "00008101-XXXXXX._remoted._tcp.local."
            udid = instance.split(".")[0] if instance else ""
            if not udid or udid in seen:
                continue
            seen.add(udid)
            addresses = getattr(s, "addresses", None) or []
            host = addresses[0] if addresses else getattr(s, "host", None)
            emit({
                "udid": udid,
                "name": udid[-6:],
                "connectionType": "WiFi",
                "host": host,
                "port": getattr(s, "port", None),
            })
    except Exception as e:
        sys.stderr.write(f"bonjour error: {e}\n")


if __name__ == "__main__":
    asyncio.run(main())
