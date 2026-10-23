# Runtime releases

**Measured:** [CallKit Simulator v0.1.1](https://github.com/ziahamza/ios-voip-sdk/releases/tag/v0.1.1) was published as a prerelease on 2026-10-22 by the successful [annotated-tag release run](https://github.com/ziahamza/ios-voip-sdk/actions/runs/39719750680), from `cbfcc5373eb5ca4955476bd753038790c87b25bd`. The downloaded archive, checksums and qualification each pass GitHub attestation verification restricted to that repository, workflow, tag and source commit. All eight extracted files equal the exact CI-qualified distribution. The [public verification receipt](https://github.com/ziahamza/ios-voip-sdk/blob/addd1bf4a2d1abf90133fa6e6224f71f5271d5d4/docs/verification/2026-10-22-runtime-r9-release/receipt.json) binds the assets, provenance, commands and comparison.

This is the standalone runtime at that tag, before SDK M0 and the dedicated LCK acceptance target B. CI executed arm64 on iOS 26.5 (23F77), with Xcode 26.6 (17F113); arm64 and x86_64 simulator slices were built. The `ios-27.0` profile is the device reference. This release does not qualify SDK milestones, iOS 27 simulator execution, media transport or new physical-device behavior.

`VERSION` is the runtime version source. The build embeds it in `CKSimRuntimeVersion()`, copies it into the distribution and records it in `build-info.json`; the CLI requires the package values to match. Discovery binds the loaded version to the run manifest and packaged build information. Semantic runtime versions, including v0.1.1, use all shipping conformance checks. Historical captures that predate runtime identity require `--allow-legacy`; `--allow-legacy --require-receipts` retains receipt checks for the committed pre-shipping synthetic fixtures. Fresh receipt-bound captures always require shipping identity and journal evidence.

For a future release, after its changes are merged and main's CI is green, create an **annotated** tag named `v` followed by `VERSION` on that merged commit and push it. From a clean checkout of the desired main commit:

```sh
git tag -a "v$(cat VERSION)" -m "CallKit Simulator v$(cat VERSION)"
git push origin "v$(cat VERSION)"
```

The workflow refuses lightweight tags, version mismatches, dirty checkouts, and commits not reachable from `origin/main`. Existing tags and releases, including `v0.1` and `v0.1.1`, stay unchanged. A release must not upload artifacts packed on a developer machine.

The macOS job selects Xcode 26.6 and runs the existing full `discovery/run.sh` acceptance, building both arm64 and x86_64 simulator slices. Execution covers the runner's native architecture and installed simulator OS; the run manifest records those actual versions. The `ios-27.0` profile remains a device reference, rather than a claim that hosted CI ran iOS 27.0. Local and CI compiler differences are recorded in `build-info.json`: Xcode version/build, Swift and Clang versions, SDK version/build, architectures, source commit, dirty state and source-input digest.

Only `out/runtime-dist`, the exact distribution exercised by the harness, is packaged. The tar archive sorts entries and normalizes uid/gid to 0, user/group names to empty strings, modes to 0755/0644 and timestamps to the source commit time. Gzip uses that time with no filename header. Repacking the same distribution is reproducible; this does not claim bit-for-bit reproducible Mach-O compilation or signing. `SHA256SUMS` covers the archive, and `qualification.json` carries the source/run binding, manifest and acceptance results. Full traces and receipts are retained as the run's Actions artifact for 90 days.

The workflow attests the archive, checksums and qualification before publishing a prerelease. It includes the Sigstore bundle as `attestation.sigstore.json` and verifies the archive against the expected repository, workflow, source tag and commit before release creation. All actions are pinned by full commit SHA.

To verify a downloaded release (set `COMMIT` to the release's `qualification.json` → `release.sourceCommit`):

```sh
shasum -a 256 -c SHA256SUMS
gh attestation verify callkit-simulator-v0.1.1-macos.tar.gz \
  --repo ziahamza/ios-voip-sdk \
  --signer-workflow ziahamza/ios-voip-sdk/.github/workflows/runtime-release.yml \
  --source-ref refs/tags/v0.1.1 --source-digest "$COMMIT" \
  --deny-self-hosted-runners --bundle attestation.sigstore.json
```

Run the same attestation command with `SHA256SUMS` and `qualification.json` as
the subject as well. All three downloaded subjects were verified for v0.1.1;
the [saved decoded provenance](https://github.com/ziahamza/ios-voip-sdk/blob/addd1bf4a2d1abf90133fa6e6224f71f5271d5d4/docs/verification/2026-10-22-runtime-r9-release/provenance.json)
records their exact digests and the GitHub-hosted signer/source identity.

**Measured offline controls:** `python3 discovery/check_release_controls.py` exercises annotated/merged tag acceptance, lightweight and unmerged tag refusal, version/source/toolchain/SDK/architecture/checksum mismatch refusal, normalized archive metadata and identical bytes after filesystem timestamps change. `python3 discovery/check_image_identity.py` covers new-version shipping recognition and loaded/package version mismatches. These synthetic checks do not establish native simulator behavior or a live GitHub attestation.

## Primary sources checked on 2026-10-22

- [GitHub's artifact attestation guide](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations) describes the `id-token` and `attestations` permissions and provenance verification.
- [actions/attest v4.2.2 schema](https://github.com/actions/attest/blob/1e69f48acb82d1966a394da916b4c1698aa569d6/action.yml) supplies `subject-path`, `create-storage-record` and `bundle-path`; [its implementation](https://github.com/actions/attest/blob/1e69f48acb82d1966a394da916b4c1698aa569d6/src/attest.ts) limits artifact storage records to OCI registry uploads. File releases disable those records.
- [checkout v7.0.1](https://github.com/actions/checkout/releases/tag/v7.0.1), [upload-artifact v7.0.2](https://github.com/actions/upload-artifact/releases/tag/v7.0.2) and [attest v4.2.2](https://github.com/actions/attest/releases/tag/v4.2.2) are the verified stable releases used for the pinned actions.
- The official [gh attestation verify](https://cli.github.com/manual/gh_attestation_verify) manual documents the source/workflow restrictions; [gh release create](https://cli.github.com/manual/gh_release_create) documents `--verify-tag`, which does not itself require an annotated tag.
