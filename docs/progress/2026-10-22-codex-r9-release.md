# R9: published runtime artifact acceptance

**Measured:** [CallKit Simulator v0.1.1](https://github.com/ziahamza/ios-voip-sdk/releases/tag/v0.1.1)
was published by [release run 39719750680](https://github.com/ziahamza/ios-voip-sdk/actions/runs/39719750680).
Both release jobs passed, including the full tagged discovery qualification,
packaging, attestation, pre-publication verification and prerelease publication.
The annotated tag points to `cbfcc5373eb5ca4955476bd753038790c87b25bd`.

The [public evidence](https://github.com/ziahamza/ios-voip-sdk/blob/addd1bf4a2d1abf90133fa6e6224f71f5271d5d4/docs/verification/2026-10-22-runtime-r9-release/README.md)
records successful verification of all three attested downloaded subjects:
archive, `SHA256SUMS` and `qualification.json`. Signer restrictions match the
repository's release workflow, `refs/tags/v0.1.1` and that exact source commit,
with self-hosted runners denied. GitHub's asset digests match the downloaded
bytes. All eight safe archive files equal the exact CI-qualified distribution.
The tagged package checker reports `packageVerified: true`.

The runtime's acceptance scope is the tagged standalone package: arm64 execution
on iOS simulator 26.5 with Xcode 26.6, with both arm64 and x86_64 slices built.
The `ios-27.0` profile remains the device reference. This predates SDK M0 and
the dedicated LCK acceptance target B; it does not qualify those targets, media
transport, new device behavior or R3 teardown callbacks.

This follow-up changes documentation and public evidence only. No release,
tag, package bytes or license changed. Existing offline release controls (18)
and image-identity controls (14) pass; no simulator or native build was run for
this follow-up. The proposed status in `docs/runtime-releases.md` now points to
this measured acceptance. Future releases still require a new annotated,
version-matching tag on merged, clean source and their own CI-built evidence.

Independent spec/claims and standards reviews found no actionable issues. Both
reviewers separately compared the public receipt with the retained downloaded
assets, verification output and exact qualified distribution.
