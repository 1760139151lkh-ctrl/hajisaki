#!/bin/bash
# Standalone Xcode build entry. Run on a Mac with Xcode selected.
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-Debug}"
destination="${DESTINATION:-generic/platform=iOS Simulator}"
signing=(CODE_SIGNING_ALLOWED=NO)
if [[ "$destination" == *Simulator* ]]; then
  signing=(CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
fi
xcodebuild -project App/HajiSaki.xcodeproj -scheme HajiSaki \
  -configuration "$configuration" -destination "$destination" \
  -derivedDataPath build "${signing[@]}" build
