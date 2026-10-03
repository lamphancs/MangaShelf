#!/bin/bash
# Requires Xcode, Python 3, and a booted iOS Simulator. Does not touch the installed MangaShelf app.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
work_dir="$(mktemp -d /tmp/MangaShelfAddSeriesTest.XXXXXX)"
bundle_id=com.lp.MangaShelf.AddSeriesSmoke
simulator_id="${1:-$(xcrun simctl list devices booted -j | python3 -c 'import sys,json; print(next(d["udid"] for ds in json.load(sys.stdin)["devices"].values() for d in ds if d["state"] == "Booted"))')}"
cleanup() {
    xcrun simctl terminate "$simulator_id" "$bundle_id" >/dev/null 2>&1 || true
    echo "Test artifacts: $work_dir"
}
trap cleanup EXIT
cp -R "$repo_root/MangaShelf" "$repo_root/MangaShelf.xcodeproj" "$repo_root/PROJECT.md" "$work_dir/"
cp "$repo_root/Tests/AddSeriesSmoke/SmokeApp.swift" "$work_dir/MangaShelf/App/MangaShelfApp.swift"
xcodebuild -project "$work_dir/MangaShelf.xcodeproj" -scheme MangaShelf -sdk iphonesimulator \
    -configuration Debug -destination "platform=iOS Simulator,id=$simulator_id" \
    -derivedDataPath "$work_dir/build" PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" \
    CODE_SIGNING_ALLOWED=NO build >"$work_dir/build.log" 2>&1 || { tail -80 "$work_dir/build.log"; exit 1; }
xcrun simctl install "$simulator_id" "$work_dir/build/Build/Products/Debug-iphonesimulator/MangaShelf.app"
container_path="$(xcrun simctl get_app_container "$simulator_id" "$bundle_id" data)"
# Remove only this test's previous result to prevent false positives on repeat runs.
rm -f "$container_path/Documents/result.txt"
xcrun simctl launch "$simulator_id" "$bundle_id"
for _ in $(seq 1 30); do
    if [[ -f "$container_path/Documents/result.txt" ]]; then
        cp "$container_path/Documents/result.txt" "$work_dir/result.txt"
        cat "$work_dir/result.txt"
        echo
        if grep -q 'FAIL' "$work_dir/result.txt"; then exit 1; fi
        exit 0
    fi
    sleep 1
done
echo "FAIL: Smoke test timed out"
exit 1
