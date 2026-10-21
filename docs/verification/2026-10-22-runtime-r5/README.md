# R5 acceptance evidence

**Measured native green:** `image-identity-checks.json` records eleven synthetic controls plus the native loaded-image/package comparison. `runtime.identity` in the receipt-bound console trace records hashes calculated by the probe from its actual engine image, executable and adjacent profile. `manifest.json` records build-side hashes. `build-info.json` records package hashes and the locally built source identity.

The runtime package is deliberately not committed as binary data. To repeat the complete acceptance with a fresh package and owned simulator:

```sh
CKSIM_ONLY=report-threading bash discovery/run.sh
```

Run the offline identity controls alone with `python3 discovery/check_image_identity.py`. `red-control.json` identifies the green hosted capture and the synthetic mutation that the previous shipping identity check incorrectly accepted. The raw capture remains available in that run's `callkit-discovery-macos-26-xcode-26.6` artifact.
