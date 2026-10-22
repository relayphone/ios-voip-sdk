# Host-only media binding controls

Run `python3 discovery/check_expo_media.py`. It compiles the real selected
Objective-C binding sources with ARC, modules, and warnings as errors into three
separate macOS test binaries. Explicit facades provide only the public API subset
used by each binding. The fake AVAudioSession has a distinct Objective-C runtime
name so it cannot collide with a host framework class. The LiveKit facade follows the inspected public RN source call-site shape; it
does not qualify a shipped framework ABI. No system audio activation,
React Native runtime, LiveKit framework, or WebRTC framework is exercised.

The WebRTC controls verify external/manual ownership, enable/disable ordering
around each supplied activation/deactivation callback, off-main operations and
completion, synchronous authorization withdrawal before delayed activation can
enable media, and reset revocation without a fabricated deactivation callback.
A separately linked binary contains no RTCAudioSession class and requires
explicit adapter-unavailable errors, with no required class link symbol.

The LiveKit controls invoke the real helper's injected registry and instance
initialize/invalidate methods. The fake registry returns its existing module and
ADM; construction counts ensure the binding creates neither. Controls cover late
attachment after authorization has been supplied by the host control, replacement ownership,
old invalidation, and reset. The private attachment contract is declared only in
the control to deterministically deliver a stale acquisition token: an initially
available obsolete ADM is gated off, while a stale result pointing to the current
ADM cannot disable it. A separate invalidated-owner token also gates its
initially available, never-bound ADM off. This does not simulate real RN initialization scheduling.
The missing-registry diagnostic is observed through a host-only replacement of
NSLog; media logic uses the unchanged production sources.

Bounded semaphores establish ordering without sleeps. Temporary compiler and
module-cache outputs are removed. The receipt rejects source changes during the
run and hashes the production and facade inputs. These are host controls, not
native media/activation acceptance or SDK version-pair qualification.
