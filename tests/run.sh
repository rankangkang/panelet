#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/vertical-split-tests.XXXXXXXX")"
trap 'rm -rf "$TEST_BUILD"' EXIT
swiftc Panelet/QuickExitPolicy.swift tests/QuickExitPolicyTests.swift -o "$TEST_BUILD/quick-exit-tests"
"$TEST_BUILD/quick-exit-tests"
swiftc Panelet/RecoveryJournal.swift tests/RecoveryJournalTests.swift -framework AppKit -o "$TEST_BUILD/recovery-tests"
"$TEST_BUILD/recovery-tests"
swiftc Panelet/DisplayScanner.swift tests/SplitLayoutTests.swift -framework AppKit -o "$TEST_BUILD/layout-tests"
"$TEST_BUILD/layout-tests"
swiftc Panelet/QuitPolicy.swift tests/QuitPolicyTests.swift -o "$TEST_BUILD/quit-tests"
"$TEST_BUILD/quit-tests"
plutil -lint Panelet.xcodeproj/project.pbxproj
