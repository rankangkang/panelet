#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/vertical-split-tests.XXXXXXXX")"
trap 'rm -rf "$TEST_BUILD"' EXIT
swiftc Panelet/Localization.swift Panelet/QuickExitPolicy.swift tests/QuickExitPolicyTests.swift -o "$TEST_BUILD/quick-exit-tests"
"$TEST_BUILD/quick-exit-tests"
swiftc Panelet/Localization.swift Panelet/RecoveryJournal.swift tests/RecoveryJournalTests.swift -framework AppKit -o "$TEST_BUILD/recovery-tests"
"$TEST_BUILD/recovery-tests"
swiftc Panelet/Localization.swift Panelet/ProductPreferences.swift Panelet/DisplayScanner.swift tests/SplitLayoutTests.swift -framework AppKit -o "$TEST_BUILD/layout-tests"
"$TEST_BUILD/layout-tests"
swiftc Panelet/Localization.swift Panelet/ProductPreferences.swift Panelet/DisplayScanner.swift Panelet/PhysicalScreenScreenshot.swift Panelet/MouseRouter.swift tests/CaptureRoutingTests.swift -framework AppKit -o "$TEST_BUILD/capture-routing-tests"
"$TEST_BUILD/capture-routing-tests"
swiftc Panelet/Localization.swift Panelet/QuitPolicy.swift tests/QuitPolicyTests.swift -o "$TEST_BUILD/quit-tests"
"$TEST_BUILD/quit-tests"
swiftc Panelet/Localization.swift Panelet/EnvironmentCheck.swift tests/EnvironmentCheckTests.swift -framework AppKit -o "$TEST_BUILD/environment-tests"
"$TEST_BUILD/environment-tests"
swiftc Panelet/Localization.swift Panelet/ProductPreferences.swift Panelet/DisplayScanner.swift Panelet/EnvironmentCheck.swift Panelet/Diagnostics.swift Panelet/PlacementGeometry.swift tests/ProductBehaviorTests.swift -framework AppKit -o "$TEST_BUILD/product-tests"
"$TEST_BUILD/product-tests"
python3 tests/check-localizations.py
plutil -lint Panelet.xcodeproj/project.pbxproj
