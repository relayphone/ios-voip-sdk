# R9 local preparation checks

Measured on 2026-10-22 against the R9 working tree: the adjacent JSON files are successful output from `python3 discovery/check_release_controls.py`, `python3 discovery/check_image_identity.py`, and `python3 discovery/check_harness.py`. Release/package fixtures are synthetic and do not invoke Apple tools or establish live attestation. The harness includes explicit legacy replay for the committed pre-shipping strict-v2 fixtures and refuses those captures as fresh shipping evidence.

The native dual-slice build and archive were verification-only and deleted. The milestone handoff records the toolchain and scope. Actual release acceptance remains proposed until an annotated-tag workflow builds and publishes its own qualified distribution.
