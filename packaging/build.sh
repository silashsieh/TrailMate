#!/usr/bin/env bash
# Build the bundled Python runtime + deps for TrailMate.app.
# Output: TrailMate/PythonResources/ (folder-referenced by Xcode).
#
# Idempotent — re-running rebuilds from scratch but reuses the PBS download
# in packaging/.cache/.
#
# Bump PBS_TAG / PY_VERSION when a newer python-build-standalone release ships
# (https://github.com/astral-sh/python-build-standalone/releases). Both can
# be overridden via env vars without editing this file.

set -euo pipefail

PBS_TAG="${PBS_TAG:-20260510}"
PY_VERSION="${PY_VERSION:-3.13.13}"
PMD3_SPEC="${PMD3_SPEC:-pymobiledevice3>=9.12}"

PY_MAJOR_MINOR="${PY_VERSION%.*}"
ARCH_TAG="aarch64-apple-darwin"
PBS_ASSET="cpython-${PY_VERSION}+${PBS_TAG}-${ARCH_TAG}-install_only_stripped.tar.gz"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/${PBS_ASSET}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/PythonResources"
CACHE="$ROOT/packaging/.cache"

mkdir -p "$CACHE"

# 1. Download PBS tarball (cached).
if [ ! -f "$CACHE/$PBS_ASSET" ]; then
    echo "→ Downloading $PBS_ASSET"
    curl -L --fail --progress-bar -o "$CACHE/$PBS_ASSET.partial" "$PBS_URL"
    mv "$CACHE/$PBS_ASSET.partial" "$CACHE/$PBS_ASSET"
else
    echo "→ Using cached $PBS_ASSET"
fi

# 2. Reset output dir and extract PBS. Clear contents in-place rather than
# rmdir-ing $OUT — Finder can recreate .DS_Store between rm's scan and final
# directory removal, breaking `rm -rf` under `set -e`.
mkdir -p "$OUT"
find "$OUT" -mindepth 1 -delete 2>/dev/null || \
    find "$OUT" -mindepth 1 -exec rm -rf {} + 2>/dev/null || true
echo "→ Extracting CPython $PY_VERSION"
tar -xzf "$CACHE/$PBS_ASSET" -C "$OUT"   # produces $OUT/python/

PY="$OUT/python/bin/python${PY_MAJOR_MINOR}"
[ -x "$PY" ] || { echo "✗ Expected interpreter at $PY"; exit 1; }

# 3. Install pmd3 into python-libs/.
# We run pip from the bundled PBS interpreter, so it natively resolves arm64
# + cp313 wheels for the running platform — no need for --platform / --python-
# version (which would force --only-binary=:all: per pip's rules, and reject
# sdist-only deps like hexdump). Default behaviour falls back to sdist for
# the handful of pure-Python deps that don't ship wheels.
echo "→ Installing $PMD3_SPEC"
"$PY" -m pip install \
    --target "$OUT/python-libs" \
    --no-compile \
    --upgrade \
    --quiet \
    "$PMD3_SPEC"

# 4. Copy daemon + privileged wrapper scripts into the bundle root.
echo "→ Copying daemon scripts"
cp "$ROOT/PythonDaemon/tm_daemon.py" "$OUT/"
cp "$ROOT/PythonDaemon/tm_list_devices.py" "$OUT/"
cp "$ROOT/PythonDaemon/tm_tunnel.sh" "$OUT/"
chmod +x "$OUT/tm_tunnel.sh"

# 5. Trim caches. Keep *.dist-info — some packages query their own metadata
# at runtime via importlib.metadata, and stripping it triggers obscure failures
# deep in the dependency tree.
echo "→ Trimming"
find "$OUT" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$OUT" -name '*.pyc' -delete 2>/dev/null || true

# 6. Sanity check — exercise every import the daemon and lister rely on.
echo "→ Verifying bundled interpreter"
PYTHONHOME="$OUT/python" PYTHONPATH="$OUT/python-libs" PYTHONNOUSERSITE=1 \
    "$PY" -c "
from importlib.metadata import version
print(f'pymobiledevice3 {version(\"pymobiledevice3\")} OK')
from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation
from pymobiledevice3.usbmux import list_devices
print('daemon + lister imports OK')
"

echo
echo "✓ Bundle ready: $OUT"
du -sh "$OUT"
