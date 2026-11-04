#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
frameworks="$(xcode-select -p)/Library/Developer/Frameworks"
testing_lib="$(xcode-select -p)/Library/Developer/usr/lib"
if [[ -d "$frameworks/Testing.framework" ]]; then
    swift test --build-system native --disable-xctest -Xswiftc -F -Xswiftc "$frameworks" \
        -Xlinker -F -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" \
        -Xlinker -rpath -Xlinker "$testing_lib" "$@"
else
    swift test --build-system native --disable-xctest "$@"
fi
