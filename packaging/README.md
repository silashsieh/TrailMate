# Bundled Python build

`packaging/build.sh` produces `TrailMate/PythonResources/` — a self-contained
CPython runtime plus `pymobiledevice3` that the built `TrailMate.app` carries
inside `Contents/Resources/`. Once the bundle exists, double-clicking the app
needs no system Python.

## Prerequisites

- macOS on Apple Silicon
- Xcode Command Line Tools (`xcode-select --install`) for `curl`, `codesign`
- ~150 MB free disk for the download cache and output

## Build

```sh
cd TrailMate
./packaging/build.sh
```

Output: `TrailMate/PythonResources/` (~210 MB — pmd3 pulls in cryptography,
Pillow, qh3, IPython, etc.; not all of pmd3's CLI extras are prunable
without breaking its core import path). The PBS tarball is cached in
`packaging/.cache/` between runs.

To bump the interpreter version:

```sh
PBS_TAG=20260510 PY_VERSION=3.13.13 ./packaging/build.sh
```

Find the latest tag at <https://github.com/astral-sh/python-build-standalone/releases>.

## One-time Xcode wiring

After running `build.sh` for the first time:

1. **Add the folder reference** — drag `PythonResources/` from Finder into
   the Xcode project navigator. Pick **Create folder references** (blue
   folder icon). Check the TrailMate target. This auto-adds it to Copy
   Bundle Resources.

2. **Wire the entitlements** — Target → Build Settings → "Code Signing
   Entitlements" → `TrailMate/TrailMate.entitlements`. (`allow-jit` is
   required because Hardened Runtime is on.)

3. **Re-sign Run Script phase** — Target → Build Phases → +Run Script,
   place after Copy Bundle Resources, name it
   `Re-sign embedded Python binaries`:

   ```sh
   RES="$CODESIGNING_FOLDER_PATH/Contents/Resources/PythonResources"
   [ -d "$RES" ] || exit 0
   find "$RES/python" "$RES/python-libs" \
        \( -name '*.so' -o -name '*.dylib' -o -path '*/bin/python3*' \) \
        -type f -print0 | while IFS= read -r -d '' f; do
     codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
              --options runtime --timestamp=none "$f" 2>/dev/null || true
   done
   ```

   The `:--` fallback ad-hoc-signs when no identity is set, matching the
   README's "build from source, run unsigned" stance.
