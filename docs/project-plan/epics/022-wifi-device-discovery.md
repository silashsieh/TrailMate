---
type: epic
id: 022
title: Fix Wi-Fi device discovery in the picker
status: in-progress
milestone: v1.6.0
issue:
opened: 2026-06-10
shipped:
tags: [bug, connection]
---

# Epic 022: Fix Wi-Fi device discovery in the picker

## Why
Owner report (2026-06-10): no Wi-Fi devices ever appear in the sidebar picker. Root-caused in
the bundled lister `PythonDaemon/tm_list_devices.py`: the Bonjour/`browse_remoted` branch crashes
while serializing a discovered service, so the **entire** Wi-Fi scan aborts and emits nothing.

Reproduced with the bundled interpreter (`tm_list_devices.py`): the USB device lists fine, then
`bonjour error: Object of type Address is not JSON serializable`.

## Goal
A device on the same Wi-Fi network (with Wi-Fi connections enabled) shows up in the picker
labelled "Wi-Fi", and a single un-identifiable/duplicate service no longer wipes out the whole
Wi-Fi scan.

## Out of scope
- **Connecting** to a Wi-Fi device end-to-end. This epic fixes *discovery* (the device appearing
  in the picker). The tunnel path for a Wi-Fi/RSD device (today `lockdown start-tunnel --udid` is
  USB-oriented) is a separate concern — verify and, if needed, file a follow-up.
- A privileged (root) lister. Discovery must stay prompt-free.

## Stories
- [x] Fix the `Address`-not-serializable crash (use the zone-qualified `full_ip`)
- [x] Make the remoted loop per-service resilient (one bad service can't abort the rest)
- [x] Only emit services whose instance name is a real iOS UDID; dedup against USB

## Open questions
- **Wi-Fi UDID without root.** A genuine Wi-Fi advertisement is named `<UDID>._remoted._tcp`, so
  the instance-name parse yields the real UDID — no connection needed. But the USB-transport
  remoted service is named `ncm._remoted._tcp` (no UDID), and resolving a UDID from a service that
  lacks one needs an RSD handshake, which needs `stop_remoted()` → suspending macOS's root-owned
  `remoted` → **root**. The no-prompt lister can't do that, so such services are skipped. If a
  device only ever advertises without a UDID, Wi-Fi-only discovery would need a design decision
  (resolve identity at connect-time under the existing root tunnel, etc.) — track separately.

## Decisions made along the way
- **Filter by UDID shape, don't emit garbage.** The `ncm._remoted._tcp` USB-transport service
  (seen while USB is attached) parses to `udid="ncm"`; emit nothing for it rather than a broken
  picker row. Real Wi-Fi advertisements (`<UDID>._remoted._tcp`) pass the UDID check. (2026-06-10)
- **`addr.full_ip`, not `addr.ip`** — link-local addresses (`fe80::…%en9`) need the zone id to be
  usable; `full_ip` carries it (matches pymobiledevice3's own `get_rsds`). (2026-06-10)

## Bugs / follow-ups found while building
- `browse_remoted` is flaky run-to-run (0 vs 1 services across back-to-back calls). The picker has
  a Rescan button, so this is tolerable; note it if it proves a real annoyance.
- The **usbmux** branch already surfaces a Wi-Fi-synced device (`connectionType` ≠ USB → "WiFi",
  host/port null), and during this work the owner's device showed up that way. So a Wi-Fi device
  can arrive via *either* path; the crash only sank the Bonjour fallback. No change needed to the
  usbmux branch.

## Acceptance criteria
- [x] `tm_list_devices.py` runs without a traceback when a remoted service is present
- [~] A real Wi-Fi advertisement (`<UDID>._remoted._tcp`) is emitted with a usable host —
  proven deterministically with a mock service (zone-qualified `full_ip`, UDID parsed); live
  Bonjour-only confirmation pending (the owner's device arrived via the usbmux path this session)
- [x] The USB-transport `ncm._remoted._tcp` service does not produce a bogus picker row
