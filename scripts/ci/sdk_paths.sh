#!/bin/bash
# Source in each producer/consumer step; artifacts retain these relative paths.
: "${RUNNER_TEMP:?GitHub runner temporary directory is required}"
export SDK_M0_BUILD_ROOT="$RUNNER_TEMP/sdk-m0-build"
export SDK_M0_BUILD_LOGS="$SDK_M0_BUILD_ROOT/build-logs"
export SDK_M0_APP="$SDK_M0_BUILD_ROOT/example/Example.app"
export SDK_M0_BOOTSTRAP_APP="$SDK_M0_BUILD_ROOT/bootstrap/SDKBootstrap.app"
export SDK_M0_DEVICE_PROBE="$SDK_M0_BUILD_ROOT/device/SDKDeviceProbe"
export SDK_M0_SPM_DEVICE_DIR="$SDK_M0_BUILD_ROOT/spm-device"
export SDK_M0_BUILD_RECEIPT="$SDK_M0_BUILD_ROOT/build-receipt.json"
export SDK_M1_CONTRACT_BUILD="$SDK_M0_BUILD_ROOT/m1-contracts"
export SDK_SYSTEM_CONTROL_PACKAGE="$SDK_M0_BUILD_ROOT/system-control"
export SDK_PUSH_ENTRY_BUILD="$SDK_M0_BUILD_ROOT/push-entry"
mkdir -p "$SDK_M0_BUILD_LOGS"
