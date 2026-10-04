#!/bin/sh
# Keep WebKit downloads in a fresh process to avoid cross-suite timeouts.
set -eu

repo_dir=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
cd "$repo_dir"
world="performance-tests-$(date +%s)-$$"
MNML_PROBE="$world" swift test "$@" --skip DownloadLifecycleTests
MNML_PROBE="$world-downloads" swift test "$@" --skip-build --filter DownloadLifecycleTests
