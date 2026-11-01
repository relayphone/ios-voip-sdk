# Releases

One version covers the whole repository. Each `vX.Y.Z` tag is a release of the SDK, published as
a GitHub prerelease titled "iOS VoIP SDK vX.Y.Z" with the simulator runtime package as its assets.
GitHub lists them under [Releases](https://github.com/relayphone/ios-voip-sdk/releases). v0.1 and
v0.1.1 were releases of the simulator runtime alone, named "CallKit Simulator".

`VERSION` is the release's version, which the CocoaPods spec and the simulator runtime also
carry. The build embeds it in `CKSimRuntimeVersion()`, copies it into the runtime package and
records it in `build-info.json`; `cksim` requires the package's values to match.

## Making a release

In one pull request, move the changelog's Unreleased section under a new heading with the version
and date, such as `## 0.2.0 (2026-11-01)`, leaving an empty Unreleased section above it, and set
`VERSION` to that version.

After that pull request is merged and main's CI is green, create an **annotated** tag named `v`
followed by `VERSION` on the merged commit and push it. From a clean checkout of that commit:

```sh
git tag -a "v$(cat VERSION)" -m "iOS VoIP SDK v$(cat VERSION)"
git push origin "v$(cat VERSION)"
```

The [release workflow](../.github/workflows/runtime-release.yml) refuses lightweight tags,
version mismatches, dirty checkouts and commits that aren't on `origin/main`
(`tools/release.ts check`). On a GitHub-hosted runner with Xcode 27.1 it then:

1. builds the runtime package with arm64 and x86_64 simulator slices (`tools/build-runtime.ts`);
2. runs `swift test`, then `RuntimeTests` on an iOS 27.0 simulator;
3. launches an app that doesn't link the runtime with the package's runtime injected, and
   answers and ends a pushed call with the package's own `cksim` (`tools/runtime-smoke.ts`);
4. archives exactly that package (`tools/package-runtime.ts`) and records `qualification.json`;
5. attests the archive, `SHA256SUMS` and `qualification.json`, verifies the archive's
   attestation, and publishes the prerelease with the Sigstore bundle as
   `attestation.sigstore.json`. Its notes open with a link to the changelog at the tag.

The archive sorts its entries and normalizes owners to 0, modes to 0755 or 0644 and times to the
source commit's time, so archiving the same package again gives the same bytes. That doesn't make
the Mach-O compilation or signing reproducible. `build-info.json` records the Xcode, Swift and
Clang versions, the simulator SDK, the architectures, the source commit, whether the checkout was
dirty, and a digest of the sources. The package and release stay available as the run's artifact
for 90 days. A release never uploads artifacts packed on a developer machine.

## Verifying a release

Set `VERSION` to the release's version and `COMMIT` to its `qualification.json` →
`release.sourceCommit`, then:

```sh
shasum -a 256 -c SHA256SUMS
gh attestation verify "callkit-simulator-v$VERSION-macos.tar.gz" \
  --repo relayphone/ios-voip-sdk \
  --signer-workflow relayphone/ios-voip-sdk/.github/workflows/runtime-release.yml \
  --source-ref "refs/tags/v$VERSION" --source-digest "$COMMIT" \
  --deny-self-hosted-runners --bundle attestation.sigstore.json
```

Run the same command for `SHA256SUMS` and `qualification.json`. v0.1.1 was built before the
repository moved to `relayphone`, so its signer workflow is
`ziahamza/ios-voip-sdk/.github/workflows/runtime-release.yml`.

GitHub documents [artifact attestations](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations)
and [gh attestation verify](https://cli.github.com/manual/gh_attestation_verify).
