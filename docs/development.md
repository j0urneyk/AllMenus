# Development

## Requirements
- macOS 14 or later (Liquid Glass shelf style needs macOS 26), Apple silicon
- Xcode command line tools (`swiftc`, `codesign`, `iconutil`), Python 3

There is no Xcode project: `build.sh` compiles `Sources/*.swift` with `swiftc` and assembles the app bundle.

## Build
```bash
./build.sh                                  # writes "All Menus.app" next to the script
cp -R "All Menus.app" ~/Applications/
open ~/Applications/"All Menus.app"
```
`build.sh` also generates the app icon (once, from `Tools/MakeIcon.swift`) and the localized strings (every build, from `Tools/strings.py`).

## Signing and keeping permissions
macOS ties the Accessibility and Screen Recording permissions to the app's code signature. An ad hoc signature changes with every build, so permissions would have to be granted again after each one. To avoid that, create a local signing certificate once:
```bash
./Tools/make_signing_cert.sh
```
This creates a self-signed **"All Menus Local Signing"** certificate (valid for 10 years) in your login keychain. `build.sh` uses it when present, so the requirement macOS checks (`identifier "local.allmenus" and certificate leaf = H"…"`) stays the same across builds. Without it, `build.sh` falls back to ad hoc signing.
- The certificate's trust settings are not changed; Keychain Access showing it as "not trusted" is expected and signing works anyway.
- If permissions stop working after the signature changed (for example the first build after creating the certificate): in System Settings → Privacy & Security → Accessibility (and Screen & System Audio Recording), select All Menus, remove it with −, and add it again with +. Toggling the switch isn't enough, because the old entry was stored for the old signature.
- Remove the certificate with:
  ```bash
  security delete-identity -c "All Menus Local Signing" ~/Library/Keychains/login.keychain-db
  ```

## Project layout
| Path | What it is |
|---|---|
| `Sources/main.swift` | App delegate, launch, and the command-line test and render modes |
| `Sources/MenuExtras.swift` | Reading menu bar items (Accessibility), hidden detection, opening items, background prefetch |
| `Sources/IconCache.swift`, `Sources/Matting.swift` | Capturing icons and separating them from the menu bar background |
| `Sources/ShelfController.swift` | The shelf window: placement, open/close morph, mask, keyboard, auto-dismiss |
| `Sources/ShelfView.swift` | SwiftUI content: shelf path, grid and list layouts, search, caret |
| `Sources/FlyTo.swift` | The flight of a picked icon to the menu bar or into the notch |
| `Sources/Triggers.swift` | Global shortcut, notch hover and click |
| `Sources/Settings.swift` | Preferences, shortcut model, Korean composition and search |
| `Sources/SettingsWindow.swift`, `Sources/Onboarding.swift`, `Sources/Permissions.swift` | Settings window, permission guide, permission helpers |
| `Sources/L10n.swift` | `L()` for localized text |
| `Sources/DemoContent.swift`, `Sources/DemoRecorder.swift` | Made-up items and the GIF recorder for documentation |
| `Sources/SelfTest.swift`, `Sources/BuiltinSuite.swift`, `Sources/FrameMeter.swift` | Verification tools (see [testing.md](testing.md)) |
| `Tests/fixture.swift` | Test app that adds status items of known shape, or overfills the menu bar |
| `Tools/` | Icon generator, translations, localization checker, signing-certificate script |

## Localization
English and Korean. The app follows the macOS language; any other language gets English.
- All UI text goes through `L("English source text")`; text with values uses format strings, e.g. `L("%ld items", n)`.
- Korean translations live in `Tools/strings.py` (English → Korean). The build writes `Resources/en.lproj` and `Resources/ko.lproj` from it (both are generated and not committed).
- `python3 Tools/check_l10n.py` fails on a key without a Korean translation, a format-specifier mismatch (`%ld`, `%@`) between key and translation, or Korean text anywhere in the project outside the Korean-language feature itself. Lines that are part of that feature (the Hangul tables for Korean search, the 2-set keyboard map, the names Korean macOS gives system items) are tagged `// ko-data`.
- To add a language: write a table like `Tools/strings.py` that generates `<language>.lproj/Localizable.strings`, and add it to the copy list in `build.sh` and to `CFBundleLocalizations`.
- App names, system item names and the text inside icons (such as the clock) come from macOS and the apps, so they follow the system language rather than the app's.

## Documentation images
Images in `docs/images` are made from **demo items** (never the apps on the machine that produced them) over a drawn backdrop:
```bash
"./All Menus.app/Contents/MacOS/AllMenus" --render-docs docs/images -AppleLanguages "(en)"
"./All Menus.app/Contents/MacOS/AllMenus" --record-demo docs/images/demo.gif -AppleLanguages "(en)"
```
- `--render-docs` draws the shelf (grid, list, search), the Appearance settings and the first permission-guide step, off screen.
- `--record-demo` shows the shelf on the notched display for about four seconds, captures **only the shelf's own window** (ScreenCaptureKit, `desktopIndependentWindow`), and lays each frame over the drawn backdrop. It needs Screen Recording permission for the process that runs it.
- `AM_DEMO=1` runs the whole app with demo items; picking one does nothing.

## Environment variables
| Variable | Effect |
|---|---|
| `AM_DEMO=1` | Demo items instead of the real menu bar |
| `AM_TIMING=1` | Print how long each step of opening takes |
| `AM_NOSHADOW`, `AM_NOCONTENT`, `AM_KEEPORDERED`, `AM_SIMPLEMORPH` | Experiments used to rule out causes of dropped frames (no shadow, no content, keep the window ordered in, single-stage morph) |
| `AM_PROBE_MS` | How long `--openprobe` keeps the shelf open |
| `AM_RENDER_KEYS`, `AM_RENDER_FOCUS` | Search text and focused search box for `--render-notch` |
| `ALLMENUS_ONBOARDING_STEP` | Which permission-guide step to show first |
| `ALLMENUS_KEYCHAIN` | Keychain used by `Tools/make_signing_cert.sh` (testing only) |

## Previous names
The app was first called MenuShelf. On first launch it moves preferences from the old defaults domain (`local.menushelf`) to `local.allmenus`, and the icon cache from `~/Library/Caches/MenuShelf` to `~/Library/Caches/AllMenus`.
