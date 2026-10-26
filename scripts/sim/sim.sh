#!/bin/bash
# Source from a runner; SIM_STATE must point into that runner's fresh output.
SIM_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sim.py"

sim_limit() {
  local seconds=$1 status=0 current state=${SIM_STATE:-} accepted=0
  shift
  # These existing product probes are migrated separately with their owners.
  # They remain bounded, but never enter the lifecycle/retry policy.
  if [[ "${1:-}" == xcrun && "${2:-}" == simctl &&
        ( "${3:-}" == spawn || "${3:-}" == get_app_container ) ]]; then state=''; fi
  if [[ -z "$state" && "${SIM_ACCEPTED_STATUS:-}" == 1 ]]; then
    python3 "$SIM_HELPER" call --accepted-status "$SIM_ACCEPTED_STATUS" "$state" "$seconds" "$@" || status=$?
    if [[ "$status" -eq 1 && "${SIM_ACCEPTED_STATUS:-}" == 1 ]]; then accepted=1; fi
  else
    python3 "$SIM_HELPER" call "$state" "$seconds" "$@" || status=$?
  fi
  if [[ -n "${SIM_STATE:-}" ]]; then
    if [[ "$status" -ne 0 && "$accepted" -ne 1 ]]; then
      : > "$SIM_STATE.failure"
    else
      rm -f "$SIM_STATE.failure"
    fi
    current=$(python3 "$SIM_HELPER" current "$SIM_STATE") || { : > "$SIM_STATE.failure"; return 1; }
    # A boot/install retry replaces the device. Every subsequent command and
    # product identity must use the replacement, including the caller's trap.
    if [[ -n "$current" && "$current" != "${UDID:-}" ]]; then
      UDID=$current
      if declare -F simulator_changed >/dev/null; then simulator_changed "$current" || return 1; fi
    fi
  fi
  return "$status"
}

sim_checkpoint() {
  python3 "$SIM_HELPER" checkpoint "$SIM_STATE"
}

sim_cleanup() {
  python3 "$SIM_HELPER" cleanup "$SIM_STATE" "$@"
}
