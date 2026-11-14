<p align="center">
  <img src="branding/panelet/app-icon.png" width="112" alt="Panelet app icon">
</p>

<h1 align="center">Panelet</h1>

<p align="center"><strong>One screen. More room.</strong></p>

<p align="center">Split one Mac display into two independent desktops, each with its own menu bar and native full-screen Spaces.</p>

<p align="center"><strong>English</strong> · <a href="README.zh-CN.md">简体中文</a></p>

<p align="center">
  <a href="#installation">Install</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#troubleshooting">Get help</a> ·
  <a href="#contributing">Contribute</a> ·
  <a href="#license">License</a>
</p>

## Features

- **Desktop splits.** Keep two workspaces on the same display. Open multiple windows in either region, drag them between regions, and use macOS full screen independently.
- **Window Pair.** Temporarily place one full-screen window in each region. Search for windows, drag them into place, swap their positions, and save frequently used pairs.
- **Per-display layouts.** Split multiple displays at once and save the direction, ratio, and rendering mode for each. By default, portrait displays split top to bottom and landscape displays split side by side. Choose a 1:1, 2:1, or 1:2 ratio.
- **Desktop recovery.** Panelet restores the display arrangement and attempts to move windows back when a split ends. After an unexpected quit, it attempts recovery on the next launch if the display configuration matches.

## Installation

- macOS 14 or later.
- Xcode or Xcode Command Line Tools, and Python 3.
- A valid Apple Development signing identity in your Keychain for the default first-time build.

Build from source, install, and open Panelet with the following commands.

```sh
git clone https://github.com/rankangkang/panelet.git
cd panelet
./build.sh --install
```

Open the installed copy at `/Applications/Panelet.app` for everyday use and when granting permissions. If your Keychain has multiple valid signing identities, set `PANELET_SIGN_IDENTITY` to the certificate name or fingerprint on first install.

To update, get the new source and choose **Quit Panelet** from the menu bar. Follow the prompts to restore any active splits, then run `./build.sh --install` again. The update reuses the installed signing identity and bundle identifier `dev.cmkk.panelet` so macOS can keep your existing permissions.

### First-time setup

1. In **System Settings → Desktop & Dock**, turn on **Displays have separate Spaces**. If you just changed this setting, log out and back in when macOS prompts you.
2. Open Panelet and follow **Getting Started** to grant **Screen Recording** and **Accessibility**. If Panelet is missing from a permissions list, use **+** to select `/Applications/Panelet.app`.
3. Click **Restart and Continue** if prompted. Once permissions are ready, click **Finish Setup**. To try it right away, click **Try a Split…** and choose a display and layout. You can reopen the guide from **Getting Started…** in the menu bar.

## Quick start

### Split a desktop

From the Panelet menu bar icon, choose **Split Desktop** and select a display. The two desktops stay active until you merge the display. To change the layout, merge it first, then open **Settings… → Desktop Split** to adjust the direction and ratio and see the preview update.

### Pair two windows

Press **⌃⇧S** (Control–Shift–S) to open the window picker. Select a display and two windows, then click **Start Split** or press Return. Each window opens in a native full-screen Space.

The pair ends automatically when either window exits full screen or closes, or when either app quits. Any desktop split that was already active on that display stays in place.

| Default shortcut | Action |
| --- | --- |
| **⌃⇧S** | Open the window picker |
| **⌃⇧J** | Restore the split under the pointer or end its window pair |
| **Esc** | Cancel a split while it is being prepared in the window picker |

Customize the two global shortcuts in **Settings… → Shortcuts**. To restore every display at once, choose **Restore All Displays…** from the menu bar. You can change the interface language in **Settings… → General**.

## Compatibility and privacy

Panelet uses the private macOS API `CGVirtualDisplay` to create two virtual displays, then uses ScreenCaptureKit to show both feeds on the physical display. macOS updates can affect virtual display behavior. Protected video or capture-restricted windows may appear black. Verify high refresh rates, HDR, and wide color on your hardware.

Screen Recording lets Panelet compose the split desktops and preview windows. Panelet captures and processes screen images locally. Accessibility lets Panelet move and restore windows and route the pointer between regions. Preferences and saved pairs stay on your Mac. Saved pairs contain app identifiers and window titles for matching. You can preview and export a diagnostic report with selected environment and performance data.

## Troubleshooting

| Symptom | What to do |
| --- | --- |
| The split button is disabled | In **Settings… → Permissions**, check **Screen Recording**, **Accessibility**, and **Displays have separate Spaces**. |
| A split fails to start or the picture looks wrong | Select **Check Environment…** from the menu bar to check whether the required macOS interfaces are available. |
| A display or window did not return to its previous position | Choose **Restore All Displays…** from the menu bar. If any windows still need recovery, choose **Retry Window Recovery…**. |

Bug reports and feature requests are welcome. For a bug report, include the Panelet version or Git commit used to build it, the macOS version, your display setup, steps to reproduce, and what you expected versus what happened. You can attach a diagnostic report exported from **Settings… → Diagnostics → Preview Report…**. [GitHub Issues](https://github.com/rankangkang/panelet/issues)

## Contributing

Panelet is written in Swift with AppKit. Pull requests for bug fixes, documentation, and translations are welcome. Describe what your change fixes or improves and how you verified it.

```sh
./tests/run.sh
./build.sh
```

`./tests/run.sh` runs logic tests and localization checks. `./build.sh` builds the app. You can also open `Panelet.xcodeproj` and build the Panelet scheme. Keep App Sandbox disabled so the app can create virtual displays. To test the interface or permissions, update with `./build.sh --install` and launch Panelet from Applications.

<details>
<summary>Inspecting displays and testing on a Mac</summary>

Run this command to list detected displays with their orientation, scale, refresh rate, and position.

```sh
/Applications/Panelet.app/Contents/MacOS/Panelet --list
```

When changing split or recovery logic, check stacked and side-by-side layouts, exiting full screen from either window, starting and ending a window pair on an existing desktop split, and restoring one display while other splits are active. Use test windows when checking recovery failures.

The acceptance notes below are in Simplified Chinese.

- [Splitting, recovery, and diagnostics](tests/acceptance-2026-11-14.md)
- [First-time setup](tests/onboarding-acceptance-2026-11-14.md)
- [Two portrait displays and window pairs](tests/acceptance-2026-11-13.md)

</details>

## License

Panelet is licensed under the GNU Affero General Public License, version 3 only (`AGPL-3.0-only`). [License text](LICENSE)

The virtual display implementation draws on Telas. [Upstream project](https://github.com/eduardoworrel/telas) · [Third-party licenses and notices](THIRD_PARTY_NOTICES) · [Panelet branding](branding/panelet/README.md)
