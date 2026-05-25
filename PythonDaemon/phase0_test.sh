#!/bin/bash
# Phase 0 — Prove pymobiledevice3 works with your iPhone
#
# Prerequisites:
#   1. iPhone connected via USB
#   2. Developer Mode enabled on iPhone
#      (Settings → Privacy & Security → Developer Mode → toggle on → reboot → trust)
#   3. iPhone unlocked and trusted to this Mac
#
# Usage: run each step manually, one at a time.

VENV="/Users/harry/Documents/pikmin/TrailMate/PythonDaemon/.venv/bin"
PMD3="$VENV/pymobiledevice3"

echo "=== Phase 0: TrailMate Platform Verification ==="
echo ""
echo "pymobiledevice3 version: $($PMD3 version 2>/dev/null)"
echo ""

case "${1:-help}" in
  step1)
    echo "--- Step 1: List connected devices ---"
    echo "Running: pymobiledevice3 usbmux list"
    echo ""
    $PMD3 usbmux list
    echo ""
    echo "✓ If you see your iPhone above, proceed to step 2."
    echo "✗ If empty: ensure iPhone is unlocked, connected via USB, and trusted."
    ;;

  step2)
    echo "--- Step 2: Auto-mount Developer Disk Image ---"
    echo "Running: sudo pymobiledevice3 mounter auto-mount"
    echo "(requires sudo — enter your Mac password)"
    echo ""
    sudo $PMD3 mounter auto-mount
    echo ""
    echo "✓ If mount succeeded, proceed to step 3."
    echo "✗ If it failed, try mounting via Xcode first (Window → Devices and Simulators)."
    ;;

  step3)
    echo "--- Step 3: Start RSD tunnel ---"
    echo "Running: sudo pymobiledevice3 lockdown start-tunnel"
    echo ""
    echo "This will print an RSD address and port. KEEP THIS TERMINAL OPEN."
    echo "Copy the address and port, then open a NEW terminal for step 4."
    echo ""
    sudo $PMD3 lockdown start-tunnel
    ;;

  step4)
    if [ -z "$2" ] || [ -z "$3" ]; then
      echo "Usage: ./phase0_test.sh step4 <rsd-address> <rsd-port>"
      echo "Example: ./phase0_test.sh step4 fd7a:e92b:8f1c::1 60892"
      exit 1
    fi
    RSD_ADDR="$2"
    RSD_PORT="$3"
    echo "--- Step 4: Simulate location (Taipei 101) ---"
    echo "Running: pymobiledevice3 developer dvt simulate-location set --rsd $RSD_ADDR $RSD_PORT -- 25.0330 121.5654"
    echo ""
    $PMD3 developer dvt simulate-location set --rsd "$RSD_ADDR" "$RSD_PORT" -- 25.0330 121.5654
    echo ""
    echo "✓ Check Apple Maps on your iPhone — you should be near Taipei 101."
    echo "  When verified, proceed to step 5."
    ;;

  step5)
    if [ -z "$2" ] || [ -z "$3" ]; then
      echo "Usage: ./phase0_test.sh step5 <rsd-address> <rsd-port>"
      echo "Example: ./phase0_test.sh step5 fd7a:e92b:8f1c::1 60892"
      exit 1
    fi
    RSD_ADDR="$2"
    RSD_PORT="$3"
    echo "--- Step 5: Clear simulated location ---"
    echo "Running: pymobiledevice3 developer dvt simulate-location clear --rsd $RSD_ADDR $RSD_PORT"
    echo ""
    $PMD3 developer dvt simulate-location clear --rsd "$RSD_ADDR" "$RSD_PORT"
    echo ""
    echo "✓ Check Apple Maps — location should revert to your real position."
    echo ""
    echo "=== Phase 0 COMPLETE ==="
    echo "All steps passed. pymobiledevice3 works with your device."
    echo "You're ready for Phase 1 (Swift app development)."
    ;;

  help|*)
    echo "Usage: ./phase0_test.sh <step>"
    echo ""
    echo "Steps (run in order):"
    echo "  step1              List connected USB devices"
    echo "  step2              Auto-mount Developer Disk Image (requires sudo)"
    echo "  step3              Start RSD tunnel (requires sudo, keeps running)"
    echo "  step4 <addr> <port>  Simulate location: Taipei 101"
    echo "  step5 <addr> <port>  Clear simulated location"
    echo ""
    echo "Prerequisites:"
    echo "  - iPhone connected via USB, unlocked, trusted"
    echo "  - Developer Mode enabled on iPhone"
    echo "    (Settings → Privacy & Security → Developer Mode)"
    ;;
esac
