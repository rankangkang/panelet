#!/bin/zsh
# Disposable AppKit windows for UI acceptance; never touches working documents.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/product-acceptance
swiftc -parse-as-library tests/AcceptanceFixture.swift -framework AppKit -o build/product-acceptance/Fixture
for variant in One Two Unsupported; do
  app="build/product-acceptance/PaneletQA${variant}.app"
  mkdir -p "$app/Contents/MacOS"
  cp build/product-acceptance/Fixture "$app/Contents/MacOS/Fixture"
  python3 - "$app/Contents/Info.plist" "$variant" <<'PY'
import plistlib, sys
from pathlib import Path
variant = sys.argv[2]
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    "CFBundleExecutable": "Fixture", "CFBundleIdentifier": "dev.cmkk.panelet.qa." + variant.lower(),
    "CFBundleName": "Panelet QA " + variant, "CFBundlePackageType": "APPL", "FixtureName": variant,
    "NSHighResolutionCapable": True,
}))
PY
  codesign --force --sign - "$app"
done
