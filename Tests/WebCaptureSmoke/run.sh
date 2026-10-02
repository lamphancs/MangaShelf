#!/bin/bash
# Requires Xcode, Python 3, and a booted iOS Simulator. Does not touch the installed MangaShelf app.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
work_dir="$(mktemp -d /tmp/MangaShelfCaptureTest.XXXXXX)"
bundle_id=com.lp.MangaShelf.CaptureSmoke
simulator_id="${1:-$(xcrun simctl list devices booted -j | python3 -c 'import sys,json; print(next(d["udid"] for ds in json.load(sys.stdin)["devices"].values() for d in ds if d["state"] == "Booted"))')}"
server_pid=""
cleanup() {
    if [[ -n "$server_pid" ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    xcrun simctl terminate "$simulator_id" "$bundle_id" >/dev/null 2>&1 || true
    echo "Test artifacts: $work_dir"
}
trap cleanup EXIT
cp -R "$repo_root/MangaShelf" "$repo_root/MangaShelf.xcodeproj" "$repo_root/PROJECT.md" "$work_dir/"
cp "$repo_root/Tests/WebCaptureSmoke/SmokeApp.swift" "$work_dir/MangaShelf/App/MangaShelfApp.swift"
# Let the OS choose an unused local port.
python3 "$repo_root/Tests/WebCaptureSmoke/server.py" "$repo_root/Tests/WebCaptureSmoke" "$work_dir/port" >"$work_dir/server.log" 2>&1 &
server_pid=$!
xcodebuild -project "$work_dir/MangaShelf.xcodeproj" -scheme MangaShelf -sdk iphonesimulator \
    -configuration Debug -destination "platform=iOS Simulator,id=$simulator_id" \
    -derivedDataPath "$work_dir/build" PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" \
    CODE_SIGNING_ALLOWED=NO build >"$work_dir/build.log" 2>&1 || { tail -80 "$work_dir/build.log"; exit 1; }
xcrun simctl install "$simulator_id" "$work_dir/build/Build/Products/Debug-iphonesimulator/MangaShelf.app"
container_path="$(xcrun simctl get_app_container "$simulator_id" "$bundle_id" data)"
# Remove only this test's previous result to prevent false positives on repeat runs.
rm -f "$container_path/Documents/result.txt"
SIMCTL_CHILD_CAPTURE_TEST_ONLY="${CAPTURE_TEST_ONLY:-}" SIMCTL_CHILD_CAPTURE_SMOKE_URL="${CAPTURE_SMOKE_URL:-http://127.0.0.1:$(cat "$work_dir/port")/}" \
    xcrun simctl launch "$simulator_id" "$bundle_id"
for _ in $(seq 1 300); do
    if [[ -f "$container_path/Documents/result.txt" ]]; then
        cp "$container_path/Documents/result.txt" "$work_dir/result.txt"
        cat "$work_dir/result.txt"
        echo
        if grep -q 'FAIL' "$work_dir/result.txt"; then exit 1; fi
        cp "$container_path/Documents/full.pdf" "$container_path/Documents/bottom.pdf" "$work_dir/"
        exit 0
    fi
    sleep 1
done
echo "FAIL: Smoke test timed out"
exit 1
