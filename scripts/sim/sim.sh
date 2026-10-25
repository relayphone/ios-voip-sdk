#!/bin/bash
# Source from a runner; SIM_STATE must point into that runner's fresh output.
SIM_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sim.py"
if [[ -n "${SIM_STATE:-}" ]]; then
  export SIM_STATE
  if [[ -z "${SIM_FAILURE_MARKER:-}" ]]; then export SIM_FAILURE_MARKER="$SIM_STATE.failure"; fi
fi

sim_cli() {
  SIM_RECOVERY_TIMEOUT=${SIM_CLEANUP_TIMEOUT:-30} python3 "$SIM_HELPER" "$@"
}

sim_limit() {
  local seconds=$1 status=0 current state=${SIM_STATE:-}
  shift
  if [[ -n "${SIM_STATE:-}" ]]; then
    export SIM_STATE
    if [[ -z "${SIM_FAILURE_MARKER:-}" ]]; then export SIM_FAILURE_MARKER="$SIM_STATE.failure"; fi
  fi
  # These existing product probes are migrated separately with their owners.
  # They remain bounded, but never enter the lifecycle/retry policy.
  if [[ "${1:-}" == xcrun && "${2:-}" == simctl &&
        ( "${3:-}" == spawn || "${3:-}" == get_app_container ) ]]; then state=''; fi
  if [[ -z "$state" && "${SIM_ACCEPTED_STATUS:-}" == 1 ]]; then
    sim_cli call --accepted-status "$SIM_ACCEPTED_STATUS" "$state" "$seconds" "$@" || status=$?
  else
    sim_cli call "$state" "$seconds" "$@" || status=$?
  fi
  if [[ -n "${SIM_STATE:-}" ]]; then
    current=$(sim_cli current "$SIM_STATE") || return 1
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
  sim_cli checkpoint "$SIM_STATE"
}

sim_cleanup() {
  sim_cli cleanup "$SIM_STATE" --timeout "${1:-${SIM_CLEANUP_TIMEOUT:-30}}"
}
