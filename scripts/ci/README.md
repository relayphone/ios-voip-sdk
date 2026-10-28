`scripts/ci/bounded <seconds> <command> [args...]` runs argv directly, preserving
its exit status and streams. At the deadline it sends SIGTERM to its owned
process group, allows ten seconds of grace, then sends SIGKILL. A bounded reap
can take another two seconds. Deadline expiry returns 124; interruption returns
128 plus the signal number. Cleanup failures are reported without claiming the
group is gone.

Use it for local GitHub commands, downloads, scans and simulator commands:

```sh
scripts/ci/bounded 40 gh issue view 93 --repo relayphone/ios-voip-sdk
scripts/ci/bounded 20 du -sh /tmp/one-owned-output
scripts/ci/bounded 20 find /tmp/one-owned-output -maxdepth 2 -type f
scripts/ci/bounded 30 xcrun simctl list devices -j
scripts/ci/bounded 40 curl --fail --output /tmp/owned-download.zip URL
scripts/ci/bounded 2700 gh pr checks 116 --watch --fail-fast --interval 60
```

Capture lengthy output in a file and inspect only the needed lines. Simulator
lifecycle runners retain `scripts/sim` ownership, retry and checkpoint policy;
the generic command wrapper grants no simulator retry or app replay.
