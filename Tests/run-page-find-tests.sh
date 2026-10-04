#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/mnml-page-find-tests.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM

swiftc -swift-version 5 -parse-as-library \
    "$repo_dir/Sources/mnml/PageFind.swift" \
    "$repo_dir/Tests/PageFindHarness.swift" \
    -o "$build_dir/page-find-tests"
"$build_dir/page-find-tests"
