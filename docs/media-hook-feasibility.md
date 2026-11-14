# Native media hook feasibility

`VoIPMediaTesting` is optional: select the Swift package product or the CocoaPods `MediaTesting`
subspec. The implementation exists only in Debug iOS Simulator builds. It is absent on devices,
on macOS and in Release builds. LiveKit is not a dependency of the core SDK products.

The selected provider is LiveKit Swift **2.19.0**, whose package and podspec pin LK-prefixed
WebRTC **150.7871.04**. The Expo example uses native LiveKit through `NativeCallMedia`; it does
not install the React Native WebRTC provider alongside it.

`MarkerAudioEngine` installs after LiveKit's session/mixer observers before room creation.
It replaces hardware capture with the shared 12-slot `tones-v2` source at `engineWillConnectInput`, without enabling
the audio session. `DecodedAudioProbe.attach(to:)` observes the actual remote track.
The output observer inserts a unity-gain meter **after** the ordinary engine's main mixer and
before its output node. It does not use manual rendering or the decoder as output evidence.

The example first uses `AudioManager.setEngineAvailability(.none)`, prepares the room, then
enables its engine only through `CallMedia.activate()`. The check requires a stopped engine and
no output samples before activation. It then requires both decoder and output PCM, verifies
that LiveKit's mixer output-volume gate silences output while decoded audio continues, and
requests mute through `VoIPClient`. Its native observer mutes the real microphone publication.
A separate peer requires the complete current-fixture marker before mute and silence afterwards. The unchanged
source is never artificially zeroed in response to mute.

`MediaAudioProbe.expectSilence` checks every channel and requires an installed tap with live
callback coverage throughout the requested interval. Missing callbacks cannot count as silence.
Swift Testing covers missing taps, stopped callbacks, both stereo layouts, real silent frames
and an intentional nonzero leak. The peer independently monitors its receiver during mute.

`.github/workflows/media-feasibility.yml` runs the example on one simulator on the standard
`xcode-27` GitHub-hosted image. The existing CI simulator suite also runs the Swift Testing controls.
The feasibility job retains its result and build
logs, then deletes its simulator and temporary builds. The server is pinned to LiveKit 1.13.11,
using Homebrew's checksum-pinned ARM64 macOS bottle because upstream publishes no macOS archive;
the throwaway peer's exact Node dependency is in `tools/media-test/package.json` and its lockfile.
The example selects the official tagged CocoaPods sources explicitly because the Swift release
is not indexed on CocoaPods trunk.

This qualifies software capture, publication and post-mixer PCM. It does not establish physical
microphone/speaker operation, Bluetooth routing or acoustic latency. The shared TypeScript
contract and reusable host fixture are separate changes.

## Marker qualification

The shared profile is specified in merged [#294](https://github.com/relayphone/ios-voip-sdk/pull/294).
This branch includes merged [#295](https://github.com/relayphone/ios-voip-sdk/pull/295), the shared
emission generator opened before its fixture re-run. Both sources emit 150 ms of 400 Hz before
and after the unchanged marker, with 5 ms raised-cosine fades only at the emission's outer edges.

Both sources use the shared `createMarker` / `emissionSamples` profile: twelve 60 ms slots, amplitude 0.2, 5 ms raised-cosine fades,
650/950/1350/1850 Hz, and distinct fixture-scoped direction identities. Swift receives the exact
frequency sequence from the TypeScript fixture, restarts phase per slot, and matches both
marker and emission PCM16 parity hashes in `docs/media-testing.md` (native parity checks use
the actual capture sample functions).
Only the central 20 ms of each slot is scored, with 20 ms guards on both sides. Unmodified, bounded PCM from the far end, iOS
decoder and iOS post-output tap is checked with the shared `detectMarker`. Every slot must reach
confidence **0.8**, and the whole marker must be present in every observed channel. Energy alone
never establishes audio. The unreleased profile replaces tones-v1 as specified by the shared contract; the 0.8 threshold
and complete-marker requirement are unchanged.

The synthetic capture enters after Apple's hardware voice-processing node. For this Debug-only
reference fixture, capture explicitly requests **WebRTC software** AEC and AGC, with NS disabled. The injected
signal traverses AEC and AGC; synthetic tones do not qualify noise-suppression fidelity. Runtime requested/active state and the actual RTP codec (Opus,
including RED encapsulation) are required in the receipt. The Node peer publishes raw PCM without
a capture APM: `fromDevice` covers iOS capture AEC/AGC then Opus; `toDevice` covers peer Opus, iOS
decoding and post-output. This does not claim a physical microphone or a Node capture APM test.

CI runs the fixed `synthetic` configuration (AEC/AGC on, NS off) on one simulator.
Each result retains every slot's confidence and signed
margin above 0.8, including the best rejected complete candidate when detection fails. The job
summary lists all channels and slots; `media-result-synthetic.json` preserves full precision.
The run retains the complete-marker gate and all mute/activation checks. Each channel
also reports captured tail duration and post-roll coverage. The fixture requires 150 ms of
post-roll plus 20 ms for detector alignment uncertainty; that capture gate does not change marker
detection. Three-second native captures and the three-second far-end positive window cover the tail
at any emission phase. A truncated emission may still detect its complete marker while failing
this separate coverage gate.

Elastic alignment is supplied by [#296](https://github.com/relayphone/ios-voip-sdk/pull/296).
Measurements score each slot at the detector's chosen start and retain its sample offset,
relative drift, confidence and margin. Tail coverage is measured after the last aligned slot,
not after a fixed 720 ms grid. Rejected fixed-grid diagnostics are labelled and cannot count as
accepted elastic evidence. All twelve slots still require confidence >=0.8; final drift stays
within ±60 ms and local alignment within ±15 ms.

Both sources precompute the byte-identical emission outside their capture/publish loops.
Marker analysis runs in an owned Node worker with a 20-second deadline and bounded termination,
so detection cannot interrupt the peer packet clock. Worker failure supplies no audio or silence
receipt. Tests check published insert/delete drift lists, scoring at the actual chosen starts,
and parent-clock progress while analysis runs. Real iOS margins and drifts with this detector
are reported below for the first elastic CI measurement run.

The detector update changes received-slot alignment only. Emitted PCM, the
energy floor and the 0.8 complete-marker rule remain fixed. A failed matrix remains unqualified.

Duplex qualification remains incomplete; generator-only controls do not establish codec or
audio-processing survival.

## Current pipeline evidence

The fixed synthetic configuration uses AEC/AGC on and NS off. Native results for this
configuration are pending CI. The earlier processing-matrix evidence below predates that
decision and does not qualify the new configuration. Failures still retain per-slot evidence;
AEC stays enabled. See [the shared test scope](media-testing.md#synthetic-capture-configuration).

The [elastic run at 25915cd](https://github.com/relayphone/ios-voip-sdk/actions/runs/43530306294)
failed all five modes. Every uplink slot scored zero (margin -0.8); all receivers stayed connected
with live readers, but received only zero PCM. The source callback counter remained zero.

| Processing | Generated samples | Receiver samples / RMS | Decoded min / final drift ms | Output min / final drift ms | Native failure phase |
| --- | --- | --- | --- | --- | --- |
| all | 0 | 218880 / 0 | 0.999719 / -22 | 0.999767 / -24 | publicationGate |
| withoutNS | 0 | 196800 / 0 | 0.999560 / -54 | 0.999564 / -54 | publicationGate |
| withoutAGC | 0 | 175200 / 0 | 0.999782 / -47 | 0.999779 / -47 | publicationGate |
| withoutAEC | 0 | 174240 / 0 | 0.105167 / 0 | 0.095937 / 0 | publicationGate |
| none | 0 | 182880 / 0 | 0.999530 / -53 | 0.999530 / -53 | captureProcessing |

The decoded and output paths pass complete elastic detection and post-roll coverage in four
modes. The without-AEC values are rejected fixed-grid diagnostics, so their zero drift is not
an accepted alignment. The all-disabled mode stops at processing-state validation. Full slot
starts, confidence, margins and drift lists are retained in the CI summary and artifacts.

The capture hook disconnected the hardware-input path feeding LiveKit’s sink. Apple requires
[AVAudioSinkNode to remain downstream of the input node](https://developer.apple.com/videos/play/wwdc2019/510/).
The revised graph keeps an owned zero-gain hardware branch alongside the marker, preserving
the input clock while excluding microphone PCM. Its graph regression checks the retained
connection, zero gain, stopped state and cleanup; actual callback progress and duplex, mute
and activation behavior still require the next native CI run.

### Earlier fixed-grid observations

The [tones-v2 run at 1a64a8d3](https://github.com/relayphone/ios-voip-sdk/actions/runs/43489084670)
failed. Only the without-NS variant produced a receipt: software AEC/AGC were active, NS was
inactive, and both RTP directions used Opus. Its best complete candidates were rejected:
minimum confidence 0.727294 in decoded audio (margin -0.072706), 0.760370 after output
(margin -0.039630), and 0 for each scored uplink slot. This is not duplex qualification or
proof that an individual processing effect caused attenuation. The other variants failed
connection startup or authentication, leaving the processing comparison incomplete.

Rejected candidate measurements for the without-NS run; every channel shown was mono.

| Slot | Downlink Hz | Decoded confidence (margin) | Output confidence (margin) | Uplink confidence (margin) |
| --- | --- | --- | --- | --- |
| 0 | 650 | 0.727294 (-0.072706) | 0.777461 (-0.022539) | 0.000000 (-0.800000) |
| 1 | 950 | 0.999741 (+0.199741) | 0.999757 (+0.199757) | 0.000000 (-0.800000) |
| 2 | 1350 | 0.999721 (+0.199721) | 0.999786 (+0.199786) | 0.000000 (-0.800000) |
| 3 | 1850 | 0.998941 (+0.198941) | 0.998825 (+0.198825) | 0.000000 (-0.800000) |
| 4 | 1350 | 0.999618 (+0.199618) | 0.999600 (+0.199600) | 0.000000 (-0.800000) |
| 5 | 950 | 0.999912 (+0.199912) | 0.999931 (+0.199931) | 0.000000 (-0.800000) |
| 6 | 1350 | 0.999820 (+0.199820) | 0.999805 (+0.199805) | 0.000000 (-0.800000) |
| 7 | 650 | 0.999819 (+0.199819) | 0.999815 (+0.199815) | 0.000000 (-0.800000) |
| 8 | 1350 | 0.998166 (+0.198166) | 0.997917 (+0.197917) | 0.000000 (-0.800000) |
| 9 | 1850 | 0.999704 (+0.199704) | 0.999715 (+0.199715) | 0.000000 (-0.800000) |
| 10 | 950 | 0.957710 (+0.157710) | 0.933724 (+0.133724) | 0.000000 (-0.800000) |
| 11 | 1850 | 0.795710 (-0.004290) | 0.760370 (-0.039630) | 0.000000 (-0.800000) |

The f4f68ff5 revision removes synchronous simulator commands from the peer's packet-clock event loop,
uses fresh local ports, and awaits the owned server's actual exit before advancing. Native
captures begin again at audio activation, excluding pre-activation decoder buffers. Connection,
cleanup, simulator and fixture operations have hard deadlines. The emission amendment adds the specified pre/post-roll to both sources. No marker waveform,
processing flag, energy floor or confidence threshold is changed. The receipts additionally
report generated capture samples and receiver sample/liveness counts for diagnosis.
