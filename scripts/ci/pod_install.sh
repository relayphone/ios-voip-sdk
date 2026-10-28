#!/bin/bash
# Retry only identified React Native download failures; leave all other failures intact.
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
log=$(mktemp "${TMPDIR:-/tmp}/pod-install.XXXXXX") || exit 1
trap 'rm -f "$log"' EXIT
for attempt in 1 2; do
  "$root/scripts/ci/bounded" 600 pod install "$@" 2>&1 | tee "$log"
  statuses=("${PIPESTATUS[@]}")
  status=${statuses[0]}
  if [[ ${statuses[1]} -ne 0 ]]; then exit "${statuses[1]}"; fi
  if [[ $status -eq 0 ]]; then exit 0; fi
  if [[ $status -ge 128 ]]; then exit "$status"; fi
  if ! grep -Eq 'Failed to download .*https://repo[.]reactnative[.]dev/|/usr/bin/curl .*https://repo[.]reactnative[.]dev/' "$log" ||
     ! grep -Eq 'curl: \([0-9]+\)|Failed to download' "$log"; then
    exit "$status"
  fi
  if [[ $attempt -eq 1 ]]; then
    message='- `infra:dependency-download`: failed; scheduled one bounded re-attempt'
  else
    message='- `infra:dependency-download`: re-attempt exhausted'
  fi
  printf '%s\n' "$message" >&2
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then printf '%s\n' "$message" >> "$GITHUB_STEP_SUMMARY" || :; fi
done
exit "$status"
