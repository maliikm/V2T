#!/bin/bash
# Swift 6 regression tests, with support for Command Line Tools without Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

developer_dir="$(xcode-select -p)"
frameworks="$developer_dir/Library/Developer/Frameworks"
if [[ -d "$frameworks/Testing.framework" ]]; then
    # Some CLT releases omit the _Testing_Foundation Swift module. These
    # tests use core Testing assertions, not its optional Foundation overlay.
    swift test --disable-xctest \
        -Xswiftc -F -Xswiftc "$frameworks" \
        -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
        -Xlinker -rpath -Xlinker "$frameworks" "$@"
else
    swift test --disable-xctest "$@"
fi
