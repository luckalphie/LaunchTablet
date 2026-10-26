# LaunchTablet

[简体中文](README.md)

A native macOS app launcher built with SwiftUI and AppKit, designed for large displays. **0.3.0 Preview**; packaged builds target **Apple Silicon**, with a minimum deployment target of macOS 14.

This is an independent community project and is not affiliated with or endorsed by Apple. The interface supports English and Simplified Chinese, following the system by default with an instant language switch in Settings.

Apple, Microsoft Edge, Google Chrome, and the app icons shown in the preview belong to their respective owners. The MIT license applies to this project's code and original assets.

![LaunchTablet interface preview](docs/images/overview-en.png)

The preview renders the actual interface offscreen using sample apps, without personal app lists or wallpaper.

## Features

- A fullscreen background with a centered grid capped at **1120 × 790 logical points**. The grid scales down on smaller screens.
- Horizontal pagination, search by name or pinyin, keyboard navigation, and layered Escape handling.
- Drag apps or folders to reorder with insertion guides. Drop onto folders, hover to open them, or move apps between folders. Escape cancels the drag. Layout and hidden apps are saved locally.
- The launcher settles from 112% scale to its normal size when opened, and enlarges while fading out when dismissed. Folder and hidden-app transitions also respect Reduce Motion.
- Default folders for utilities, games, and system helpers. Web apps from Edge Apps and Chrome Apps directories get separate browser folders.
- Apple apps appear first; third-party apps use an estimated installation order. Manual arrangements are preserved.
- Opens on the display containing the pointer. Default shortcut: **Control + Option + Space**.

## Build and run

Use macOS with **Swift 6 or newer** and a matching macOS SDK. Scripts follow the current developer tools selected by `xcode-select`, and honor `DEVELOPER_DIR` and `SDKROOT` without changing system settings.

| Command | Result |
| --- | --- |
| `sh scripts/run.sh` | Run from source |
| `sh scripts/test.sh` | Run Swift Testing checks |
| `sh scripts/build-app.sh` | Build `dist/LaunchTablet.app` for arm64 |
| `sh scripts/build-dmg.sh` | Build a DMG and SHA-256 checksum in `dist/` |
| `sh scripts/export-preview.sh` | Render the documentation preview using isolated sample data |

If your compiler and SDK do not match, select a compatible developer tools installation with `DEVELOPER_DIR`; optionally supply `SDKROOT`. Complete any required Xcode first-launch setup yourself.

The local CLT installation's default macOS 27 SDK lacks the `SwiftUIMacros` plugin. Full Xcode builds successfully; CLT also passes all 57 tests when explicitly using its bundled macOS 26.5 SDK. If you encounter that error, use full Xcode or a matching SDK. Scripts do not silently downgrade the SDK.

The internal secondary-display test build is produced by `sh scripts/build-app.sh --test-secondary` in `.build/ui-testing/`. It uses a separate bundle identifier and will not fall back to the main display. Its layout is isolated in `.build/ui-testing/layout.json`, and it does not register a global shortcut.

## Install a test build

Open the DMG, drag LaunchTablet into Applications, eject the image, and launch the installed copy. Quit the previous version before replacing it.

Preview builds are ad hoc signed and are **not notarized**. macOS may block a downloaded copy; after trying to open it, use **System Settings → Privacy & Security → Open Anyway** if you trust the sender. There is no need to disable system security.

## Status and limitations

- Local development and desktop checks use Apple Silicon and macOS 27. The macOS 14 deployment target is not a claim that every supported OS version has been tested.
- 57 local checks cover layout, migrations, search, keyboard behavior, and simulated scrolling. Real trackpad gestures and the updated native drag interactions still need further desktop validation.
- App categories and installation dates come from system metadata and may be missing or inaccurate.
- Packaged builds are arm64 only. Intel packages are not provided.
- GitHub Actions checks shell scripts, runs tests, and compiles an arm64 executable. Hosted CI results will only be available after the first push.

## Language and upgrades

Choose **System default**, **简体中文**, or **English** under **Settings → Language**. The choice is saved and updates the interface, menus, hints, errors, and accessibility labels immediately. Unsupported system languages fall back to English. Default category labels are translated; custom folder names and installed app names are preserved.

When upgrading from the old Launchpad project name, LaunchTablet reads the old layout only if no new layout exists. The next save writes to the LaunchTablet directory and preserves the old file. Existing new settings and layout take priority, and the packaged app migrates the old shortcut preference.

## Privacy

The app reads local app metadata and icons for display and search, and the current display's wallpaper for its blurred background. It contains no networking, telemetry, or analytics code.

Layout, folder names, hidden apps, and observed installation dates are stored in `~/Library/Application Support/LaunchTablet/layout.json`. Shortcut and interface language preferences use macOS user defaults. Apps without a bundle identifier use their local path as an ID, so review layout files before sharing them in an issue.

Carbon registers the selected global shortcut; other keyboard and scroll handling stays within this process. The app does not require Accessibility, Input Monitoring, or Screen Recording permission.

## Contributing and license

See [Contributing](CONTRIBUTING.md) and the [Java developer guide](docs/开发导读.md), currently in Chinese. The project is licensed under the [MIT License](LICENSE).

Build products, local Xcode workspace state, and the `dist/` directory are excluded from Git. Publish downloadable DMGs and checksums through GitHub Releases.
