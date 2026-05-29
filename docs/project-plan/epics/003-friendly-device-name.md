---
type: epic
id: 003
title: Friendly device name in picker
status: done
milestone: v1.2.0
issue: 3
opened: 2026-05-28
shipped: 2026-05-28
tags: [connection]
---

# Epic 003: Friendly device name in picker

> Backfilled for the historical record. Full implementation log is [[phases]] Phase 13.

## Why
Issue #3 (顯示手機名稱): the device picker labelled rows with the last 6 chars of the UDID
instead of the iPhone's real name.

## Goal
Picker rows show `DeviceName` ("Harry's iPhone"), falling back to `udid[-6:]` on any lookup
failure — no regression for unpaired / remoted-only devices.

## Outcome
Shipped in PR #7 (`fix: show friendly device name in picker (closes #3)`), released in v1.2.0.
`tm_list_devices.py` reads `all_values["DeviceName"]` via a lockdown client (`autopair=False`).
See [[phases]] Phase 13.
