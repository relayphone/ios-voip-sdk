#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p out
xcrun swiftc -swift-version 6 modules/expo2-spike/apple/HandlerCell.swift tests/HandlerCellTest.swift -o out/handler-cell-test
out/handler-cell-test
