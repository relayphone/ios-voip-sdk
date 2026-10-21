# Runtime releases

**Proposed:** v0.1.1 is the next standalone runtime prerelease. Its acceptance is a successful annotated-tag run of [Runtime release](../.github/workflows/runtime-release.yml), with the CI-built archive, checksums, qualification record and GitHub artifact attestation published together. Preparing this workflow does not establish that acceptance.

`VERSION` is the runtime version source. The build embeds it in `CKSimRuntimeVersion()`, copies it into the distribution and records it in `build-info.json`; the CLI requires the package values to match. Discovery binds the loaded version to the run manifest and packaged build information. Semantic runtime versions, including v0.1.1, use all shipping conformance checks. Historical captures that predate runtime identity require `--allow-legacy`; `--allow-legacy --require-receipts` retains receipt checks for the committed pre-shipping synthetic fixtures. Fresh receipt-bound captures always require shipping identity and journal evidence.

After the release changes are merged and main's CI is green, create an **annotated** tag named `v` followed by `VERSION` on that merged commit and push it. For example, from a clean checkout of the desired main commit:

```sh
git tag -a v0.1.1 -m "CallKit Simulator v0.1.1"
git push origin v0.1.1
```

The workflow refuses lightweight tags, version mismatches, dirty checkouts, and commits not reachable from `origin/main`. The historical `v0.1` tag and release stay unchanged. A release must not upload artifacts packed on a developer machine.

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

**Measured offline controls:** `python3 discovery/check_release_controls.py` exercises annotated/merged tag acceptance, lightweight and unmerged tag refusal, version/source/toolchain/SDK/architecture/checksum mismatch refusal, normalized archive metadata and identical bytes after filesystem timestamps change. `python3 discovery/check_image_identity.py` covers new-version shipping recognition and loaded/package version mismatches. These synthetic checks do not establish native simulator behavior or a live GitHub attestation.

## Primary sources checked on 2026-10-22

- [GitHub's artifact attestation guide](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations) describes the `id-token` and `attestations` permissions and provenance verification.
- [actions/attest v4.2.2 schema](https://github.com/actions/attest/blob/1e69f48acb82d1966a394da916b4c1698aa569d6/action.yml) supplies `subject-path`, `create-storage-record` and `bundle-path`; [its implementation](https://github.com/actions/attest/blob/1e69f48acb82d1966a394da916b4c1698aa569d6/src/attest.ts) limits artifact storage records to OCI registry uploads. File releases disable those records.
- [checkout v7.0.1](https://github.com/actions/checkout/releases/tag/v7.0.1), [upload-artifact v7.0.2](https://github.com/actions/upload-artifact/releases/tag/v7.0.2) and [attest v4.2.2](https://github.com/actions/attest/releases/tag/v4.2.2) are the verified stable releases used for the pinned actions.
- The official [gh attestation verify](https://cli.github.com/manual/gh_attestation_verify) manual documents the source/workflow restrictions; [gh release create](https://cli.github.com/manual/gh_release_create) documents `--verify-tag`, which does not itself require an annotated tag.
