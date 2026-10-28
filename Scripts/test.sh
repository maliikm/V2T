#!/bin/bash
# Swift 6 regression tests, with support for Command Line Tools without Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

developer_dir="$(xcode-select -p)"
frameworks="$developer_dir/Library/Developer/Frameworks"
test_args=("$@")
if [[ -n "${SDKROOT:-}" ]]; then test_args+=(--sdk "$SDKROOT"); fi
# Newer CLT packages place the Testing macro plugin outside SwiftPM's
# automatic search path. Explicit loading is harmless when already found.
testing_plugin="$developer_dir/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "$testing_plugin" ]]; then
    test_args+=(-Xswiftc -load-plugin-library -Xswiftc "$testing_plugin")
fi
if [[ -d "$frameworks/Testing.framework" ]]; then
    # Some CLT releases omit the _Testing_Foundation Swift module. These
    # tests use core Testing assertions, not its optional Foundation overlay.
    swift test --disable-xctest \
        -Xswiftc -F -Xswiftc "$frameworks" \
        -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
        -Xlinker -rpath -Xlinker "$frameworks" "${test_args[@]}"
else
    swift test --disable-xctest "${test_args[@]}"
fi
