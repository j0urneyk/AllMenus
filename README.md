# All Menus

A Mac app that gathers **every app icon in the menu bar — including the ones the notch hides — into one shelf that grows out of the notch.**
Click an icon and it flies to its real spot in the menu bar, where **that app's own menu (or popover) opens, exactly as it would from the menu bar.**

At menu bar height the shelf is only as wide as the notch (like the Dynamic Island) and widens only below the menu bar. It never covers or overlaps menu bar icons, and the menu bar stays clickable while the shelf is open.

## Opening
- **Rest the pointer on the notch** (0.1 s by default, 0–0.6 s in Settings) or **click the notch**
  (mouse-moved events barely arrive over the menu bar, so the pointer position is sampled 30 times a second)
- **⌃⌥M** (change it in Settings → Shortcut)

In the shelf:
- Choose the layout: **Grid** (icon tiles) or **List** (icon, name, owning app, hidden badge). In the list, wide text-like icons such as the clock or timers show a symbol on the left and their actual content on the right, like a value.
- Click, or pick with ←→↑↓ and press ⏎
- Search box: while the shelf has the keyboard, the caret blinks (the macOS rate of 0.53 s, solid while typing). When the shelf was opened by resting on the notch, click the search box to give it the keyboard.
- Just type to search. With the Korean input source active, typed jamo are assembled into syllables as you type, and Korean initial-consonant search works too.
  (The shelf receives raw key events rather than going through the input method, so it implements 2-set (Dubeolsik) composition itself. Search matches on the jamo actually typed, so in-between composition states never hide a result.)
- esc: clear the search → press again to close. ⌘,: Settings
- An orange dot (●) marks an icon that is hidden in the menu bar of this screen right now.

When the shelf was opened by resting on the notch, it closes once the pointer leaves it. In that case it doesn't take keystrokes until the pointer is over the shelf.

## Settings (⚙︎ in the shelf, ⌘, or open the app again)
| Tab | What's there |
|---|---|
| General | Open at login, open by resting on / clicking the notch, delay, close when the pointer leaves, shelf position (below the notch / at the pointer) |
| Shortcut | Shortcut on/off, record a key combination, keys inside the shelf |
| Appearance | Layout (Grid / List), shelf style (Out of the Notch / Liquid Glass), icon color (original / monochrome), names under icons, group hidden items first, animation (Full / Simple / Off), fly to the menu bar, trackpad haptics |
| Items | Drag to reorder, ★ to pin, hide from the shelf |
| Permissions | Accessibility and Screen Recording status with Allow buttons, show the permission guide again |
| About | Version |

## Languages
English and Korean. The app follows the macOS language; any other language (Japanese, for example) gets English.

- **Code:** all UI text goes through `L("English source text")` (`Sources/L10n.swift`). Text with values uses format strings, e.g. `L("%ld items", n)`.
- **Translations:** `Tools/strings.py` (English → Korean). The build generates `Localizable.strings` in `Resources/en.lproj` and `Resources/ko.lproj` and copies them into the app.
- **Checker:** `python3 Tools/check_l10n.py` fails on a key without a Korean translation, a format-specifier mismatch (`%ld`, `%@`) between key and translation, or Korean text anywhere in the project outside the Korean-language feature itself. Lines that are part of that feature (Hangul tables for Korean search, the 2-set keyboard map, the names Korean macOS gives system items) are tagged `// ko-data`.
- **Seeing the screens:** rendered off screen, without taking focus:
  ```bash
  "./All Menus.app/Contents/MacOS/AllMenus" --render-ui <folder> -AppleLanguages "(en)"
  ```
  Writes PNGs of the shelf (grid and list), the six Settings tabs and the four permission-guide steps. Add `--simulate-missing` to render them as if no permission had been granted.
- **Adding a language:** create a table like `Tools/strings.py` that generates `<language>.lproj/Localizable.strings`, and add it to the copy list in `build.sh` and to `CFBundleLocalizations`.

App names, system item names (Battery, Control Center) and the text inside icons such as the clock come from macOS and the apps as they are, so they follow the system language rather than the app's.

## Build / install
```bash
./build.sh                      # builds "All Menus.app" (Xcode command line tools, macOS 14+; Liquid Glass needs macOS 26)
cp -R "All Menus.app" ~/Applications/
open ~/Applications/"All Menus.app"
```
On first launch a permission guide walks through the steps.
- **Accessibility** (required): detected the moment it's granted, and the guide moves on by itself.
- **Screen Recording** (optional): used for the real icon images. macOS applies this permission only after a restart, so there is a "Restart to Apply" button.

### Signing and keeping permissions
`build.sh` signs with the **"All Menus Local Signing"** certificate when it is in the login keychain.
The requirement macOS uses to recognize the app (`identifier "local.allmenus" and certificate leaf = H"…"`) then stays the same across builds, so **permissions granted once survive rebuilds.**
Without the certificate it signs ad hoc, and permissions must be granted again after every build.
After the signature changes, toggling the switch in the list is not enough: select All Menus in the list, **remove it with − and add it again with +**, because the old entry was stored for the old signature.

The certificate is self-signed on this Mac (valid for 10 years). Its trust settings were not changed, so Keychain Access showing it as "not trusted" is expected. To remove it:
```bash
security delete-identity -c "All Menus Local Signing" ~/Library/Keychains/login.keychain-db
```

The app was first called MenuShelf (bundle identifier `local.menushelf`). On first launch it moves the preferences saved under that identifier to `local.allmenus`, and the icon cache from `~/Library/Caches/MenuShelf` to `~/Library/Caches/AllMenus`.

## Animation (Full mode)
- **Two-stage opening:** the outline (the notch "neck" plus the body below the menu bar) is a single path. The notch first drops down while still narrow (about 0.1 s), then widens with a slight overshoot and settles (about 0.45 s). Closing runs in reverse: it narrows first, then rolls up (0.3 s). These are Core Animation keyframes, drawn by the system renderer at the display's refresh rate (up to 120 Hz).
- **Cascading tiles:** tiles closest to the notch (center, top row) come down first, as if flowing out of the notch.
- **Gliding selection:** moving with the pointer or the arrow keys slides a single blue highlight between tiles.
- **Icon flight:** on click, the destination glows softly first, then the icon lifts and flies there. The tile background shrinks to the icon's size and fades; on landing a ripple spreads and the real menu opens (about 0.45 s).
  - **A route that never crosses the notch:** the icon travels sideways below the menu bar and, for a visible icon, rises straight up into the bar right under it.
  - **Hidden icons** (behind the notch, touching it, or not drawn in the menu bar at all, such as left of the notch over the app menus) really live behind the notch, so they are **drawn into the notch:** the icon travels below the menu bar to just under the notch, then rises, shrinks and disappears into it. The notch's lower edge glows briefly, then the menu opens. The shelf folds back into the same notch. On screens without a notch, the icon fades out just under the menu bar where the menu opens.
  - `--route-test` checks this against this Mac's notch geometry. Routes to visible icons overlap the notch at 0 points (the earlier route: 285). For hidden icons it checks that the glide never touches the notch and that the icon enters it only at the end, straight from below.
- **Trackpad haptics:** a very light tap when the shelf opens and when an icon lands. Only on Force Touch trackpads; it can be turned off in Settings.

Choose the animation in Settings → Appearance → Motion.
- **Full:** the shape change and the icon flight above
- **Simple:** a 0.16 s fade only; menus open as soon as you click
- **Off:** opens and closes instantly

With macOS "Reduce motion" on (Accessibility → Display), Full behaves like Simple.

The shelf never changes size while it is open. Icons are re-captured only before opening (resting on the notch) and after a close without picking an item. Re-capturing 0.7 s after opening used to change the width from 540 to 505 pt, because text-like icons such as the clock change width between captures.

## How it works
- **Listing:** collects icons from each app's `AXExtrasMenuBar` (Accessibility API) and decides "hidden" by whether the item's menu bar window in `CGWindowList` is actually drawn on screen.
- **Opening:** sends `AXPress` to the item. macOS opens the real menu even for an icon that isn't visible in the menu bar. For apps that ignore `AXPress`, if no menu appears within 0.4 s, a real click is sent instead (only when the icon is visible).
- **Icon images (background removal):**
  - The menu bar is captured and each icon is separated from it. The top and bottom rows of the item's window are taken as background, and every pixel's alpha comes from how far it moved away from that background (difference matting).
  - Pixels that only moved toward white, toward black or in brightness mark a monochrome icon, which is recolored to match the shelf; colored icons keep their colors.
  - The faint "pill" behind the clock and Control Center, and fragments spilling over from neighboring icons, are removed.
  - Captures from the active menu bar are preferred and are not overwritten by captures from a menu bar that draws icons dimmed, such as one on an external display.

## Verification tools
```bash
"./All Menus.app/Contents/MacOS/AllMenus" --list                 # detected items, hidden state, icon state
"./All Menus.app/Contents/MacOS/AllMenus" --selftest [name...]   # opens each item for real, checks its app's menu window appears, then closes it
"./All Menus.app/Contents/MacOS/AllMenus" --measure              # time to open the shelf (never takes the keyboard)
"./All Menus.app/Contents/MacOS/AllMenus" --flytest TEST0 <folder> # icon flight → time until the real menu opens, plus screenshots
"./All Menus.app/Contents/MacOS/AllMenus" --clickthrough auto    # with the shelf open, does a click on a menu bar icon pass through?
"./All Menus.app/Contents/MacOS/AllMenus" --render-notch out.png # renders the shelf as it looks under a notch, off screen
"./All Menus.app/Contents/MacOS/AllMenus" --openprobe            # prints the drawn outline size and content opacity every 30 ms while opening and closing
"./All Menus.app/Contents/MacOS/AllMenus" --repro-search         # search "rex" → close → reopen at once, then compare the shelf size with its content
open -n -W --stdout log.txt "All Menus.app" --args --builtin-suite <folder> test0 codexbar deepl   # end-to-end test on the MacBook display (see below)
```
Background-removal accuracy is measured with a test app that puts icons of known shape in the menu bar and writes the ground-truth images to files.
```bash
swiftc -O Tests/fixture.swift -o Tests/fixture && mkdir -p /tmp/truth && (Tests/fixture icons /tmp/truth &)
"./All Menus.app/Contents/MacOS/AllMenus" --matte-test /tmp/truth   # shape IoU ≥ 0.95, monochrome/color classification
```
`Tests/fixture overflow 6` overfills the menu bar on purpose to reproduce hidden icons.

**Testing on the MacBook display (notch): `--builtin-suite`**

macOS uses the menu bar of the display that was last **clicked** as the active menu bar; item positions and where menus open follow it. Window focus alone doesn't change it.

So the suite:
1. puts a small test window on the MacBook display and clicks it once (the pointer is put back afterwards),
2. checks that the items now report MacBook positions,
3. runs shelf open/close and, per target, the flight, landing and real menu opening on the MacBook display while capturing the area around the notch.

It must be started with `open` so the app can take focus. Focus moves for a few seconds while it runs.

Put `--fps` before the targets to measure frame rates: a ScreenCaptureKit stream is opened at up to 120 frames per second and only frames where the screen actually changed are counted. The ceiling of the method is measured too, with a plain animated square.

Results on the MacBook display (120 Hz), 2026-11-18. The ceiling of this method (plain square) is about 108–111 fps; only the area below the menu bar is measured (the notch area has no pixels).

| Phase | Before | After |
|---|---|---|
| Shelf opening | 101–107 fps, 2–4 late frames in the first 0.1 s | 108–112 fps, at most the first frame late |
| Shelf closing | 101–110 fps | 109 fps |
| Icon flight | 108–109 fps | 111–113 fps |
| Main thread blocked when opening | 47–95 ms | 11–21 ms |

Cause and fixes:
- **Cause:** every opening read the menu bar item list on the main thread (Accessibility queries to every app: 37–45 ms, up to 290 ms with a slow app).
- **Fix 1:** the list is read ahead of time on a background thread, refreshed when the pointer reaches the notch and every 5 seconds.
- **Fix 2:** the window is first drawn at the closed, notch-sized (invisible) state, and the animation starts on the next frame.
- **Fix 3:** the shelf is drawn once, invisibly, when the app launches.

Shadows, shelf content, window creation and the morph itself were each changed in turn and ruled out (reproducible with the `AM_NOSHADOW`, `AM_NOCONTENT`, `AM_KEEPORDERED` and `AM_SIMPLEMORPH` environment variables). `AM_TIMING=1` prints how long each step of opening takes.

## Limitations
- Menus open at the item's real spot (near the notch for hidden items), because they are the apps' real menus; the flight animation shows where.
- An app that ignores `AXPress` while its icon is also hidden in the menu bar cannot be opened.
- An icon that has never been drawn on screen is shown with its app icon instead.
