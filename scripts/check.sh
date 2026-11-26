#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
python3 scripts/check-docs.py
python3 scripts/check-harness.py
xcodebuild -project Phosdeck.xcodeproj -scheme Phosdeck -derivedDataPath build -destination 'platform=macOS' test
