#!/bin/zsh
# Builds Panelet.app into ./build. Pass --install to copy it to /Applications and open it.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Panelet.app"
INSTALLED_APP="/Applications/Panelet.app"
LEGACY_APP="/Applications/VerticalSplitDemo.app"
ARCH="$(uname -m)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

if [[ "${1:-}" == "--install" ]] && { pgrep -x Panelet >/dev/null || pgrep -x VerticalSplitDemo >/dev/null; }; then
  echo "请先退出正在运行的 Panelet（或旧版竖屏上下分屏）。有分屏时，请确认合并后退出。"
  exit 1
fi

SIGN_IDENTITY="${PANELET_SIGN_IDENTITY:-${VERTICAL_SPLIT_SIGN_IDENTITY:-}}"
PREVIOUS_REQUIREMENT=""
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_REFERENCE="$APP"
  if [[ "${1:-}" == "--install" && -d "$INSTALLED_APP" ]]; then
    SIGN_REFERENCE="$INSTALLED_APP"
  fi
  if [[ ! -d "$SIGN_REFERENCE" && -d "$INSTALLED_APP" ]]; then
    SIGN_REFERENCE="$INSTALLED_APP"
  elif [[ ! -d "$SIGN_REFERENCE" && -d "$LEGACY_APP" ]]; then
    SIGN_REFERENCE="$LEGACY_APP"
  fi
  if [[ -d "$SIGN_REFERENCE" ]]; then
    SIGNATURE="$(codesign --display --verbose=2 -r- "$SIGN_REFERENCE" 2>&1)" || {
      echo "无法读取现有 App 的签名。请用 PANELET_SIGN_IDENTITY 指定签名身份。" >&2
      exit 1
    }
    SIGN_IDENTITY="$(awk '/^Authority=/ && !found++ { sub(/^Authority=/, ""); print }' <<< "$SIGNATURE")"
    if [[ -n "$SIGN_IDENTITY" ]]; then
      PREVIOUS_REQUIREMENT="$(sed -n 's/^designated => //p' <<< "$SIGNATURE")"
      # One-time approved bundle ID migration; keep the existing certificate requirements.
      PREVIOUS_REQUIREMENT="${PREVIOUS_REQUIREMENT//dev.cmkk.vertical-split-demo/dev.cmkk.panelet}"
    fi
  fi
  if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk '/ "Apple Development: / { print $2 }' | sort -u)"
    if [[ -z "$SIGN_IDENTITY" || "$SIGN_IDENTITY" == *$'\n'* ]]; then
      echo "请在钥匙串中准备一份有效的 Apple Development 证书，或用 PANELET_SIGN_IDENTITY 指定签名身份。" >&2
      exit 1
    fi
  fi
fi

# Keep the previous app available if compilation or signing fails.
mkdir -p build
STAGING="$(mktemp -d build/.vertical-split-build.XXXXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
STAGED_APP="$STAGING/Panelet.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp -R Panelet/Resources/* "$STAGED_APP/Contents/Resources/"
cp LICENSE LICENSE_NOTICE THIRD_PARTY_NOTICES "$STAGED_APP/Contents/Resources/"
python3 - "$STAGED_APP/Contents/Info.plist" <<'PY'
import pathlib, sys
text = pathlib.Path("Panelet/Info.plist").read_text()
text = text.replace("$(EXECUTABLE_NAME)", "Panelet")
text = text.replace("$(PRODUCT_BUNDLE_IDENTIFIER)", "dev.cmkk.panelet")
text = text.replace("$(PRODUCT_NAME)", "Panelet")
pathlib.Path(sys.argv[1]).write_text(text)
PY

swiftc -O -g \
  -target "${ARCH}-apple-macos14.0" \
  -sdk "$SDK" \
  -swift-version 5 \
  -parse-as-library \
  -import-objc-header Panelet/VirtualDisplay.h \
  -framework AppKit \
  -framework ScreenCaptureKit \
  -framework CoreMedia \
  -framework CoreVideo \
  -framework IOSurface \
  -framework ApplicationServices \
  -framework Carbon \
  -framework QuartzCore \
  Panelet/DisplayScanner.swift \
  Panelet/EnvironmentCheck.swift \
  Panelet/ProductPreferences.swift \
  Panelet/PlacementGeometry.swift \
  Panelet/Diagnostics.swift \
  Panelet/Localization.swift \
  Panelet/HalfScreen.swift \
  Panelet/MouseRouter.swift \
  Panelet/WindowPlacement.swift \
  Panelet/Session.swift \
  Panelet/QuickExitPolicy.swift \
  Panelet/QuitPolicy.swift \
  Panelet/RecoveryJournal.swift \
  Panelet/WindowPreviewGrid.swift \
  Panelet/QuickSplitPanel.swift \
  Panelet/GlobalShortcuts.swift \
  Panelet/AppMain.swift \
  -o "$STAGED_APP/Contents/MacOS/Panelet"

codesign --force --sign "$SIGN_IDENTITY" --options runtime \
  --entitlements Panelet/Panelet.entitlements \
  "$STAGED_APP"

verify_flags=(--verify --strict)
if [[ -n "$PREVIOUS_REQUIREMENT" ]]; then
  verify_flags+=(--test-requirement="=$PREVIOUS_REQUIREMENT")
fi
codesign "${verify_flags[@]}" "$STAGED_APP"
rm -rf "$APP"
mv "$STAGED_APP" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--list" ]]; then
  "$APP/Contents/MacOS/Panelet" --list
fi

if [[ "${1:-}" == "--install" ]]; then
  rm -rf "$INSTALLED_APP"
  cp -R "$APP" "$INSTALLED_APP"
  # Keep the previous application as a local rollback copy after the rename.
  if [[ -d "$LEGACY_APP" ]]; then
    mkdir -p build/previous-install
    mv "$LEGACY_APP" "build/previous-install/VerticalSplitDemo-$(date +%Y%m%d-%H%M%S).app"
  fi
  open "$INSTALLED_APP"
  echo "Installed $INSTALLED_APP"
fi
