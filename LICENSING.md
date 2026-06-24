# Licensing

TrailMate is made of two separately-licensed parts plus a large set of bundled
third-party components. This document explains exactly what is licensed how, and
why — read it before reusing TrailMate's code or redistributing its binaries.

## TL;DR

| Part | License | Where |
|------|---------|-------|
| TrailMate macOS app (Swift source) | **MIT** | `TrailMate/`, `TrailMateTests/`, `TrailMateUITests/`, `TrailMate.xcodeproj`, `TrailMate.icon/`, `packaging/` | 
| TrailMate Python daemon | **GPL-3.0-or-later** | `PythonDaemon/` |
| Bundled Python runtime + libraries (release builds only) | their own licenses — **including GPL-3.0** (see below) | `PythonResources/` (gitignored; assembled at build time into the `.dmg`) |
| **A binary distribution as a whole (the `.dmg`)** | **GPL-3.0-or-later** (it bundles GPL components) | `build/TrailMate-*.dmg` |

In short: **the Swift source is permissively licensed, but the shipped app is a
GPLv3 work** because it bundles GPLv3 components. If you reuse only the Swift
code, MIT applies. If you redistribute a built app, GPLv3 governs the whole.

## Why the split

TrailMate's GUI is a macOS Swift app. It does **not** link or `import` any GPL
code. Instead it launches the Python daemon (`PythonDaemon/tm_daemon.py`) as a
**separate process** and communicates with it over `stdin`/`stdout` using a
simple line-based text protocol (one verb per line — see
`TrailMate/CommandProtocol.swift` and `TrailMate/DaemonBridge.swift`). Device
enumeration and the privileged tunnel are likewise separate processes
(`tm_list_devices.py`, `tm_tunnel.sh`, `tm_tunneld.sh`).

The Python daemon, in turn, **does** `import pymobiledevice3`, which is licensed
**GPL-3.0-or-later**. Code that imports a GPL library and is distributed with it
forms a combined work under the GPL, so the entire `PythonDaemon/` directory is
licensed **GPL-3.0-or-later** (full text in `PythonDaemon/COPYING`).

Because the GUI and the daemon are independent programs that interact only at
arm's length (separate address spaces, a narrow text protocol — not shared
in-memory data structures), the Swift application is treated as a separate work
and is offered under the **MIT License** (`LICENSE.md`). This mirrors the way a
proprietary or permissively-licensed front-end may drive a GPL command-line tool
it invokes as a subprocess.

> **Caveat, stated honestly:** the GUI/daemon boundary being "arm's length" is
> the load-bearing assumption behind the Swift code staying MIT. It is a
> defensible reading of the GPL, but it is a judgement call, not a settled fact.
> If you want zero ambiguity, treat the project as GPL-3.0-or-later throughout.

## What this means for you

- **Reusing TrailMate's Swift code** in your own project: MIT terms — keep the
  copyright notice, otherwise do as you like. You are not taking any GPL code.
- **Redistributing the `.dmg` (or any build of the app):** you are conveying a
  GPLv3 work. You must (a) pass on these license texts and the GPL terms, (b)
  make the **complete corresponding source** of the GPL components available to
  recipients, and (c) add no further restrictions on the GPL parts.
- **Modifying the Python daemon and shipping it:** your changes to
  `PythonDaemon/` are GPLv3 and their source must be offered.

## Corresponding source for GPL components

The bundled GPL libraries (`pymobiledevice3` and its ecosystem — see
`THIRD-PARTY-LICENSES.md`) are shipped **unmodified** from the versions pinned
by `packaging/build.sh`. Their complete corresponding source is the matching
tagged release on each project's upstream repository (e.g.
<https://github.com/doronz88/pymobiledevice3> at the bundled version). The
TrailMate daemon source that combines with them lives in `PythonDaemon/` in this
repository. If you redistribute a build, you must keep this source available to
your recipients (a written offer or a link to this repo at the released tag
satisfies the GPL).

## Bundled third-party licenses

The release app bundles a CPython 3.13 runtime (PSF license) and ~94 Python
packages spanning MIT, BSD, Apache-2.0, ISC, MPL-2.0, LGPL-3.0, PSF, and
GPL-3.0. The full per-package inventory is in
[`THIRD-PARTY-LICENSES.md`](THIRD-PARTY-LICENSES.md). All of these licenses are
compatible with conveying the aggregate under GPL-3.0-or-later:

- **Permissive** (MIT/BSD/Apache-2.0/ISC/PSF/MIT-CMU/Public Domain) — one-way
  compatible into a GPLv3 work.
- **MPL-2.0** (`certifi`, `jinxed`, `tqdm`) — explicitly GPL-compatible;
  per-file copyleft only.
- **LGPL-3.0** (`pylzss`) — used as a separable, replaceable module; its
  `COPYING`/`COPYING.LESSER` are preserved.
- **GPL-3.0-or-later** (`pymobiledevice3`, `developer_disk_image`,
  `ipsw-parser`, `opack2`, `pycrashreport`, `pyiosbackup`, `pygnuutils`,
  `parameter-decorators`) — the reason the aggregate is GPLv3.

## Files

- `LICENSE.md` — MIT License (TrailMate Swift application).
- `PythonDaemon/COPYING` — GNU GPL v3.0 (TrailMate Python daemon).
- `THIRD-PARTY-LICENSES.md` — inventory of every bundled third-party component.
