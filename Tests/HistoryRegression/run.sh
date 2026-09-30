#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/search-history-regression.XXXXXX")
trap 'rm -rf "$test_root"' EXIT HUP INT TERM

swiftc \
  -parse-as-library \
  -swift-version 5 \
  "$repo_root/Sources/mnml/Address.swift" \
  "$repo_root/Sources/mnml/History.swift" \
  "$repo_root/Tests/HistoryRegression/Stubs.swift" \
  "$repo_root/Tests/HistoryRegression/main.swift" \
  -o "$test_root/history-regression"

MNML_HISTORY_TEST_ROOT="$test_root/store" "$test_root/history-regression"
