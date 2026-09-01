# Third-Party Licenses

TrailMate's **release builds** (the `.dmg`) bundle Sparkle, a CPython runtime,
and a set of Python libraries inside the app. This file inventories every
bundled component and its license. Python package license text travels in the
app bundle's `*.dist-info/` metadata under
`Contents/Resources/PythonResources/python-libs/`; Sparkle's full notice is
published upstream with the exact pinned source package.

This inventory does not apply to the source repository alone — the bundled
libraries (`PythonResources/`) are assembled at build time by
`packaging/build.sh`, which regenerates this file. It is not hand-edited.

See [`LICENSING.md`](LICENSING.md) for how these combine and why a binary
distribution as a whole is conveyed under GPL-3.0-or-later.

## Native framework

| Component | Version | License |
|-----------|---------|---------|
| Sparkle | 2.9.6 | MIT with bundled permissive notices |

## Runtime

| Component | Version | License |
|-----------|---------|---------|
| CPython | 3.13.13 | PSF-2.0 (Python Software Foundation License) |
| pip | 26.1.1 | MIT |

## Copyleft components (the ones that determine the aggregate license)

These force the binary aggregate to be GPL-3.0-or-later (GPL), or carry
file-level / weak copyleft obligations (LGPL, MPL). They are bundled
unmodified; corresponding source is each project's upstream tag at the bundled
version (see `LICENSING.md`).

| Package | Version | License |
|---------|---------|---------|
| developer_disk_image | 0.2.0 | **GPL-3.0-or-later** |
| ipsw-parser | 1.7.3 | **GPL-3.0-or-later** |
| opack2 | 0.0.1 | **GPL-3.0-or-later** |
| parameter-decorators | 0.0.2 | **GPL-3.0-or-later** |
| pmd-net-addr | 0.0.2 | **GPL-3.0-or-later** |
| pmd-net-proto | 0.0.2 | **GPL-3.0-or-later** |
| pmd-pytcp | 0.0.4 | **GPL-3.0-or-later** |
| pycrashreport | 2.0.0 | **GPL-3.0-or-later** |
| pygnuutils | 0.1.1 | **GPL-3.0-or-later** |
| pyiosbackup | 0.2.4 | **GPL-3.0-or-later** |
| pymobiledevice3 | 9.30.1 | **GPL-3.0-or-later** |
| pylzss | 0.3.4 | LGPL-3.0 |
| certifi | 2026.6.17 | MPL-2.0 |
| jinxed | 2.0.4 | MPL-2.0 |
| tqdm | 4.68.3 | MPL-2.0 |

## Permissive components

All compatible with conveying the aggregate under GPL-3.0-or-later.

| Package | Version | License |
|---------|---------|---------|
| annotated-doc | 0.0.4 | MIT |
| annotated-types | 0.7.0 | MIT |
| anyio | 4.14.0 | MIT |
| apple-compress | 0.2.3 | MIT |
| arrow | 1.4.0 | Apache-2.0 |
| asn1 | 2.8.0 | BSD-3-Clause |
| asttokens | 3.0.1 | Apache-2.0 |
| blessed | 1.44.0 | MIT |
| bpylist2 | 4.1.1 | MIT |
| cffi | 2.0.0 | MIT |
| charset-normalizer | 3.4.7 | MIT |
| click | 8.4.1 | BSD-3-Clause |
| coloredlogs | 15.0.1 | MIT |
| construct | 2.10.70 | MIT |
| construct-typing | 0.7.0 | MIT |
| cryptography | 49.0.0 | Apache-2.0 OR BSD-3-Clause |
| daemonize | 2.5.0 | MIT |
| decorator | 5.3.1 | BSD-2-Clause |
| defusedxml | 0.7.1 | PSF-2.0 |
| editor | 1.8.0 | MIT |
| enum-compat | 0.0.3 | MIT |
| executing | 2.2.1 | MIT |
| fastapi | 0.138.0 | MIT |
| gpxpy | 1.6.2 | Apache-2.0 |
| h11 | 0.16.0 | MIT |
| hexdump | 3.3 | Public Domain |
| humanfriendly | 10.0 | MIT |
| hyperframe | 6.1.0 | MIT |
| idna | 3.18 | BSD-3-Clause |
| ifaddr | 0.2.0 | MIT |
| inquirer3 | 0.6.1 | MIT |
| ipython | 9.14.1 | BSD-3-Clause |
| ipython_pygments_lexers | 1.1.1 | BSD-3-Clause |
| jedi | 0.20.0 | MIT |
| loguru | 0.7.3 | MIT |
| markdown-it-py | 4.2.0 | MIT |
| matplotlib-inline | 0.2.2 | BSD-3-Clause |
| mdurl | 0.1.2 | MIT |
| packaging | 26.2 | Apache-2.0 OR BSD-2-Clause |
| parso | 0.8.7 | MIT |
| pexpect | 4.9.0 | ISC |
| pillow | 12.2.0 | MIT-CMU |
| plumbum | 2.0.1 | MIT |
| prompt_toolkit | 3.0.52 | BSD-3-Clause |
| psutil | 7.2.2 | BSD-3-Clause |
| ptyprocess | 0.7.0 | ISC |
| pure_eval | 0.2.3 | MIT |
| pycparser | 3.0 | BSD-3-Clause |
| pycryptodome | 3.23.0 | BSD-2-Clause AND Public Domain |
| pydantic | 2.13.4 | MIT |
| pydantic_core | 2.46.4 | MIT |
| Pygments | 2.20.0 | BSD-2-Clause |
| pyimg4 | 0.8.8 | MIT |
| pykdebugparser | 1.2.7 | MIT |
| python-dateutil | 2.9.0.post0 | Apache-2.0 OR BSD-3-Clause |
| python-pcapng | 2.1.1 | Apache-2.0 |
| pytun-pmd3 | 3.0.3 | MIT (bundled LICENSE; PyPI classifier mislabels it GPLv3) |
| pyusb | 1.3.1 | BSD-3-Clause |
| qh3 | 1.9.2 | BSD-3-Clause |
| readchar | 4.2.2 | MIT |
| remotezip2 | 0.0.2 | MIT (bundled LICENSE; License field text mislabels it GPLv3) |
| requests | 2.34.2 | Apache-2.0 |
| rich | 15.0.0 | MIT |
| runs | 1.3.0 | MIT |
| shellingham | 1.5.4 | ISC |
| six | 1.17.0 | MIT |
| srptools | 1.0.1 | BSD-3-Clause |
| stack-data | 0.6.3 | MIT |
| starlette | 1.3.1 | BSD-3-Clause |
| termcolor | 3.3.0 | MIT |
| traitlets | 5.15.1 | BSD-3-Clause |
| typer | 0.26.7 | MIT |
| typer-injector | 0.3.0 | MIT |
| typing-inspection | 0.4.2 | MIT |
| typing_extensions | 4.15.0 | PSF-2.0 |
| tzdata | 2026.2 | Apache-2.0 |
| urllib3 | 2.7.0 | MIT |
| uvicorn | 0.49.0 | BSD-3-Clause |
| wcwidth | 0.8.1 | MIT |
| wsproto | 1.3.2 | MIT |
| xmod | 1.10.0 | MIT |
| xonsh | 0.23.8 | BSD-2-Clause |

---

*Generated by `packaging/gen-third-party-licenses.py` from the bundled
`*.dist-info/METADATA` of TrailMate's pinned Python environment. Regenerated
on every `packaging/build.sh` run.*
