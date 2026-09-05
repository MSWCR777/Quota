#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
app_dir="$project_dir/../dist/QuotaNook.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
swiftc -O -parse-as-library -framework AppKit -framework SwiftUI -framework Combine \
  "$project_dir/Sources/main.swift" "$project_dir/Sources/Tests.swift" \
  -o "$app_dir/Contents/MacOS/CodexQuotaIsland"
cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
codesign --force --deep --sign - "$app_dir"
echo "Built $app_dir"
