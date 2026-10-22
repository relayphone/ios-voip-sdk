# Audio correction verification

`receipt.json` binds the working source inputs and command results. The acceptance scope here is host and compiler validation only. Native app/media journeys remain pending after integration with A0/A1/A7/A8.

Reproduce the focused controls from the repository root:

```sh
bash Tests/AudioSessionQueue/run.sh
python3 Tests/AudioSessionQueue/check_audio_compilation.py
python3 Tests/AudioLifecycle/check_audio_lifecycle.py
bash Tests/VoIPSDK/run.sh
bash Tests/AudioCore/run.sh
bash Tests/AudioCore/run_livekit.sh
python3 discovery/check_expo_media.py
python3 discovery/check_expo_bridge.py
python3 discovery/check_sdk_m2.py
npm run typecheck
```

The lifecycle helper compiles actual installed SDK headers and executes the real observer with explicit host facades. Its forced legacy compiler branch does not claim an older installed SDK or older OS execution. Expo media and Swift LiveKit controls exercise production sources against public-contract facades, with no media transport, real notification delivery or framework ABI measurement. The M2 conformance controls are synthetic positive/tamper fixtures; they do not turn previous native runs into acceptance of the new source.
