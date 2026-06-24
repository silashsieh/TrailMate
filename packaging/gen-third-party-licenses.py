#!/usr/bin/env python3
"""Regenerate THIRD-PARTY-LICENSES.md from the bundled Python environment.

Scans the freshly-built PythonResources/ (CPython runtime + python-libs/) for
every package's declared license, classifies each as copyleft (GPL/LGPL/MPL) or
permissive, and writes the inventory used to document binary distributions.

Run by packaging/build.sh after the bundle is assembled. Run it with the
*bundled* interpreter so platform.python_version() reports the shipped CPython.

Usage:
    python3 gen-third-party-licenses.py [PYTHON_RESOURCES_DIR]

PYTHON_RESOURCES_DIR defaults to <repo>/PythonResources. The output file is
written to <repo>/THIRD-PARTY-LICENSES.md (repo = parent of that directory).

Exit status is 0 even when a previously-unseen copyleft dependency appears, but
a loud warning is printed to stderr — a new GPL/LGPL/MPL package can change the
license of the distributed aggregate and needs a human to review LICENSING.md.
"""

import glob
import os
import platform
import sys

# Copyleft packages we already account for in LICENSING.md. A copyleft package
# NOT in this set is new since the docs were last reviewed — warn loudly.
KNOWN_COPYLEFT = {
    "pymobiledevice3", "developer-disk-image", "developer_disk_image",
    "ipsw-parser", "opack2", "pycrashreport", "pyiosbackup", "pygnuutils",
    "parameter-decorators", "pylzss", "certifi", "jinxed", "tqdm",
    # pymobiledevice3's bundled pure-Python TCP/IP stack (PyTCP), all GPLv3.
    "pmd-net-addr", "pmd-net-proto", "pmd-pytcp",
}

# Corrections for packages whose PyPI metadata is wrong or ambiguous. Keyed by
# the canonical name (lowercased, underscores -> hyphens). Value: (spdx, note).
OVERRIDES = {
    "pytun-pmd3": ("MIT", "bundled LICENSE; PyPI classifier mislabels it GPLv3"),
    "remotezip2": ("MIT", "bundled LICENSE; License field text mislabels it GPLv3"),
    "asn1": ("BSD-3-Clause", ""),
    "pycryptodome": ("BSD-2-Clause AND Public Domain", ""),
    "python-dateutil": ("Apache-2.0 OR BSD-3-Clause", ""),
    # METADATA declares no license; bundled LICENSE file is MIT.
    "apple-compress": ("MIT", ""),
}


def canon(name):
    return name.strip().lower().replace("_", "-")


def classifier_to_spdx(text):
    """Map a free-form classifier / License field to a coarse SPDX-ish id.

    Cosmetic precision (BSD-2 vs BSD-3) doesn't matter here; the only
    load-bearing distinction is copyleft vs permissive, so substring order
    checks LGPL before GPL and the copyleft families before the rest.
    """
    t = text.lower()
    if "lesser general public" in t or "lgpl" in t:
        return "LGPL-3.0"
    if "general public license" in t or ("gpl" in t and "lgpl" not in t):
        return "GPL-3.0-or-later"
    if "mozilla" in t or "mpl" in t:
        return "MPL-2.0"
    if "apache" in t:
        return "Apache-2.0"
    if "python software foundation" in t or "psf" in t:
        return "PSF-2.0"
    if "isc" in t:
        return "ISC"
    if "mit-cmu" in t or "cmu" in t:
        return "MIT-CMU"
    if "bsd" in t:
        if "2-clause" in t or "two clause" in t or "2 clause" in t:
            return "BSD-2-Clause"
        return "BSD-3-Clause"
    if "mit" in t:
        return "MIT"
    if "public domain" in t:
        return "Public Domain"
    return text.strip()[:40] or "UNKNOWN"


def read_metadata(meta_path):
    """Return (name, version, spdx, note) for one *.dist-info/METADATA."""
    name = version = expr = field = ""
    classifiers = []
    with open(meta_path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if line.strip() == "":
                break  # headers end at the first blank line
            if line.startswith("Name: ") and not name:
                name = line[6:].strip()
            elif line.startswith("Version: ") and not version:
                version = line[9:].strip()
            elif line.startswith("License-Expression: ") and not expr:
                expr = line[20:].strip()
            elif line.startswith("Classifier: License"):
                classifiers.append(line.split("::")[-1].strip())
            elif line.startswith("License: ") and not field:
                field = line[9:].strip()

    key = canon(name)
    if key in OVERRIDES:
        spdx, note = OVERRIDES[key]
    elif expr:
        spdx, note = expr, ""
    elif classifiers:
        spdx = " AND ".join(dict.fromkeys(classifier_to_spdx(c) for c in classifiers))
        note = ""
    elif field:
        spdx, note = classifier_to_spdx(field), ""
    else:
        spdx, note = "UNKNOWN", ""
    return name, version, spdx, note


def is_copyleft(spdx):
    s = spdx.upper()
    return "GPL" in s or "MPL" in s or "MOZILLA" in s


def copyleft_rank(spdx):
    s = spdx.upper()
    if "LGPL" in s:
        return 1
    if "GPL" in s:
        return 0
    return 2  # MPL and friends


def display(spdx, note):
    return f"{spdx} ({note})" if note else spdx


def main():
    pyres = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "PythonResources")
    pyres = os.path.abspath(pyres)
    repo = os.path.dirname(pyres)
    libs = os.path.join(pyres, "python-libs")
    out_path = os.path.join(repo, "THIRD-PARTY-LICENSES.md")

    pkgs = []
    for meta in sorted(glob.glob(os.path.join(libs, "*.dist-info", "METADATA"))):
        name, version, spdx, note = read_metadata(meta)
        if name:
            pkgs.append((name, version, spdx, note))

    # Runtime: bundled CPython (PSF) + pip (MIT), discovered from the tree.
    runtime = [("CPython", platform.python_version(), "PSF-2.0 (Python Software Foundation License)")]
    for pip_meta in glob.glob(os.path.join(
            pyres, "python", "lib", "python*", "site-packages", "pip-*.dist-info", "METADATA")):
        n, v, _s, _note = read_metadata(pip_meta)
        runtime.append(("pip", v, "MIT"))
        break

    copyleft = sorted((p for p in pkgs if is_copyleft(p[2])),
                      key=lambda p: (copyleft_rank(p[2]), p[0].lower()))
    permissive = sorted((p for p in pkgs if not is_copyleft(p[2])),
                        key=lambda p: p[0].lower())

    new_copyleft = [p for p in copyleft if canon(p[0]) not in KNOWN_COPYLEFT]

    lines = []
    lines.append("# Third-Party Licenses")
    lines.append("")
    lines.append("TrailMate's **release builds** (the `.dmg`) bundle a CPython runtime and a set")
    lines.append("of Python libraries inside the app. This file inventories every bundled")
    lines.append("component and its license. The full license text of each package travels with")
    lines.append("it inside the app bundle (in the package's `*.dist-info/` metadata under")
    lines.append("`Contents/Resources/PythonResources/python-libs/`).")
    lines.append("")
    lines.append("This inventory does not apply to the source repository alone — the bundled")
    lines.append("libraries (`PythonResources/`) are assembled at build time by")
    lines.append("`packaging/build.sh`, which regenerates this file. It is not hand-edited.")
    lines.append("")
    lines.append("See [`LICENSING.md`](LICENSING.md) for how these combine and why a binary")
    lines.append("distribution as a whole is conveyed under GPL-3.0-or-later.")
    lines.append("")
    lines.append("## Runtime")
    lines.append("")
    lines.append("| Component | Version | License |")
    lines.append("|-----------|---------|---------|")
    for name, version, lic in runtime:
        lines.append(f"| {name} | {version} | {lic} |")
    lines.append("")
    lines.append("## Copyleft components (the ones that determine the aggregate license)")
    lines.append("")
    lines.append("These force the binary aggregate to be GPL-3.0-or-later (GPL), or carry")
    lines.append("file-level / weak copyleft obligations (LGPL, MPL). They are bundled")
    lines.append("unmodified; corresponding source is each project's upstream tag at the bundled")
    lines.append("version (see `LICENSING.md`).")
    lines.append("")
    lines.append("| Package | Version | License |")
    lines.append("|---------|---------|---------|")
    for name, version, spdx, note in copyleft:
        lic = display(spdx, note)
        if "GPL" in spdx.upper() and "LGPL" not in spdx.upper():
            lic = f"**{lic}**"
        lines.append(f"| {name} | {version} | {lic} |")
    lines.append("")
    lines.append("## Permissive components")
    lines.append("")
    lines.append("All compatible with conveying the aggregate under GPL-3.0-or-later.")
    lines.append("")
    lines.append("| Package | Version | License |")
    lines.append("|---------|---------|---------|")
    for name, version, spdx, note in permissive:
        lines.append(f"| {name} | {version} | {display(spdx, note)} |")
    lines.append("")
    lines.append("---")
    lines.append("")
    lines.append("*Generated by `packaging/gen-third-party-licenses.py` from the bundled")
    lines.append("`*.dist-info/METADATA` of TrailMate's pinned Python environment. Regenerated")
    lines.append("on every `packaging/build.sh` run.*")
    lines.append("")

    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))

    print(f"→ Wrote {out_path}: {len(pkgs)} packages "
          f"({len(copyleft)} copyleft, {len(permissive)} permissive)")
    if new_copyleft:
        names = ", ".join(f"{p[0]} ({p[2]})" for p in new_copyleft)
        sys.stderr.write(
            "\n⚠️  NEW copyleft dependency not seen in LICENSING.md: " + names +
            "\n    Review LICENSING.md — the distributed aggregate's license may change.\n\n")


if __name__ == "__main__":
    main()
