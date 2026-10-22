# Published v0.1.1 runtime verification

**Measured, 2026-10-22:** the [prerelease](https://github.com/ziahamza/ios-voip-sdk/releases/tag/v0.1.1)
and [successful release run](https://github.com/ziahamza/ios-voip-sdk/actions/runs/39719750680)
meet R9's published-artifact acceptance. The annotated tag identifies runtime
source `cbfcc5373eb5ca4955476bd753038790c87b25bd`.

- [receipt.json](receipt.json) records the four release assets and SHA-256
  digests, three successful post-download attestation checks, checksum check,
  exact eight-file archive comparison and offline documentation checks.
- [provenance.json](provenance.json) retains allowlisted public decoded
  verification fields and the signed statement's subject digests. The opaque
  certificate and signature bytes remain in the digest-bound release asset
  `attestation.sigstore.json`, which can be downloaded and verified directly.
- [tagged-package-check.json](tagged-package-check.json) is the unchanged CI
  `release-check.json` result: the tagged package passed source/version,
  architecture, toolchain and file checks with `packageVerified: true`.

All downloaded release assets equal the retained Actions release artifacts.
The tar contains only regular files and directories with safe relative paths;
each of its eight files equals both the downloaded extraction and the exact
CI-qualified `out/runtime-dist`. Comparison reads archive members as bytes and
does not execute them. The lead implementer also ran the tagged package checker
successfully against the downloaded extraction. The receipt preserves hashes of
the original verification output and comparison record without local paths.

CI built arm64 and x86_64 slices and executed the runtime only on arm64, on
macOS 26.6.2 / iOS simulator 26.5 (23F77), with Xcode 26.6 (17F113), Swift 6.3.3,
Clang 21 and simulator SDK 26.5 (23F81a). The `ios-27.0` behavior profile remains
an iPhone device reference. The tagged standalone runtime predates SDK M0 and
the dedicated LCK acceptance target B; no SDK milestone, media transport, real
APNs delivery or new device behavior is qualified here. R3 teardown callbacks
remain uncharacterized.
