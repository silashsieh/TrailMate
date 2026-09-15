#!/usr/bin/env python3
#
# Copyright (c) 2026 Silas Hsieh
#
# This file is part of the TrailMate Python daemon. Because it imports
# pymobiledevice3 (GPL-3.0-or-later), it is a combined work and is distributed
# under the GNU General Public License v3.0 or later. See the COPYING file in
# this directory and ../LICENSING.md for the full terms. The TrailMate macOS
# app that drives this daemon is licensed separately under the MIT License.
#
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
import re
import sys

from pymobiledevice3 import usbmux
from pymobiledevice3.bonjour import browse_remoted
from pymobiledevice3.lockdown import create_using_usbmux

# A real iOS UDID: modern "8hex-16hex" (A12+) or the legacy 40-hex form. The
# remoted service for a USB/NCM link is named "ncm._remoted._tcp." — not a
# UDID — so this filters that (and any other non-device) advertisement out.
UDID_RE = re.compile(r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}$|^[0-9a-f]{40}$")


def emit(record: dict) -> None:
    sys.stdout.write(json.dumps(record) + "\n")
    sys.stdout.flush()


def service_host(service) -> str | None:
    """Zone-qualified address of a remoted service (e.g. fe80::…%en9). The
    zone id matters — a link-local address is unusable without it — and the
    raw Address object isn't JSON-serializable, so reduce it to its string."""
    for addr in getattr(service, "addresses", None) or []:
        full = getattr(addr, "full_ip", None) or getattr(addr, "ip", None)
        if full:
            return full
    return getattr(service, "host", None)


async def fetch_device_name(udid: str) -> str:
    """Read DeviceName via lockdown over usbmuxd. Falls back to udid suffix
    when the device isn't reachable (e.g. unpaired or pure-remoted only)."""
    try:
        client = await create_using_usbmux(serial=udid, autopair=False)
        try:
            return client.all_values.get("DeviceName") or udid[-6:]
        finally:
            await client.close()
    except Exception as e:
        sys.stderr.write(f"name lookup failed for {udid[-6:]}: {e}\n")
        return udid[-6:]


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
                "name": await fetch_device_name(udid),
                "connectionType": ctype,
                "host": None,
                "port": None,
            })
    except Exception as e:
        sys.stderr.write(f"usbmux error: {e}\n")

    try:
        services = await browse_remoted(timeout=2)
    except Exception as e:
        sys.stderr.write(f"bonjour browse error: {e}\n")
        services = []

    for s in services:
        # Isolate per service: one bad advertisement must not abort the whole
        # Wi-Fi scan (the previous all-encompassing try did, hiding every
        # Wi-Fi device behind a single serialization error).
        try:
            instance = getattr(s, "instance", "") or ""
            # A genuine Wi-Fi advertisement is "<UDID>._remoted._tcp.local.";
            # the USB/NCM transport advertises "ncm._remoted._tcp.local." with
            # no UDID. Only emit when we can read a real UDID, and skip devices
            # already seen over USB.
            udid = instance.split(".")[0] if instance else ""
            if not UDID_RE.match(udid):
                sys.stderr.write(f"skipping remoted service without a UDID: {instance!r}\n")
                continue
            if udid in seen:
                continue
            seen.add(udid)
            emit({
                "udid": udid,
                "name": await fetch_device_name(udid),
                "connectionType": "WiFi",
                "host": service_host(s),
                "port": getattr(s, "port", None),
            })
        except Exception as e:
            sys.stderr.write(f"bonjour service error: {e}\n")


if __name__ == "__main__":
    asyncio.run(main())
