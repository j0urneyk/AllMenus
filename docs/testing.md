# Testing

All Menus is checked with tools built into the app binary rather than by eye. Each one measures something outside the code under test: windows that appear on screen, pixels on screen, frames the system actually drew.

Commands below assume the app was built with `./build.sh`; `AM` stands for the binary:
```bash
AM="./All Menus.app/Contents/MacOS/AllMenus"
```

## Quick checks
| Command | What it checks |
|---|---|
| `"$AM" --list` | Detected items, whether each is hidden, icon state, and how long reading the list takes |
| `"$AM" --selftest [name...]` | Opens each item for real and passes only if a window owned by that item's app (menu or popover) appears; then closes it |
| `"$AM" --measure` | Time to open the shelf, five times (never takes the keyboard) |
| `"$AM" --openprobe` | The outline the render server is drawing and the content opacity, every 30 ms while opening and closing |
| `"$AM" --search-probe` | Types a search step by step and fails if the shelf's outline or window changes size at any step |
| `"$AM" --repro-search` | Search, close, reopen at once; compares the shelf size with what its content needs |
| `"$AM" --flytest <name> <folder>` | Picks an item and times the flight until the real menu opens, with screenshots |
| `"$AM" --clickthrough auto` | With the shelf open, clicks a real menu bar item under the shelf's transparent area; passes if its menu opens |
| `"$AM" --route-test` | Flight routes against this Mac's notch: no overlap with the notch while gliding; hidden items enter it only at the end, from straight below |
| `"$AM" --render-notch out.png` | Renders the shelf as it looks under a notch, off screen |
| `"$AM" --render-ui <folder> -AppleLanguages "(en)"` | Renders the shelf, all Settings tabs and the permission guide off screen (`--simulate-missing` for the no-permission state) |
| `"$AM" --hangul-test` | Korean 2-set composition and Korean search (see below) |
| `python3 Tools/check_l10n.py` | Translations complete, format specifiers matching, no Korean outside the Korean-language feature |

## Test fixture
`Tests/fixture.swift` is a tiny app that adds status items to the menu bar:
```bash
swiftc -O Tests/fixture.swift -o Tests/fixture
Tests/fixture overflow 6 &          # six wide items: overfills the menu bar to produce hidden items
Tests/fixture icons /tmp/truth &    # items with icons of known shape; writes the exact images as ground truth
```

### Background removal
```bash
"$AM" --matte-test /tmp/truth       # with "Tests/fixture icons /tmp/truth" running
```
Captures the fixture's icons through the same path the app uses and compares them with the ground truth: shape IoU must be at least 0.95, and the monochrome/colored classification must be right. Measured on the active menu bar: IoU 1.000 for both icons, mean color error 0.005.

## On the MacBook display: `--builtin-suite`
macOS uses the menu bar of the display that was last **clicked** as the active menu bar, and item positions and menus follow it; window focus alone doesn't change it. With an external display, tests would otherwise run on the wrong menu bar.
```bash
open -n -W --stdout log.txt "All Menus.app" --args --builtin-suite <folder> test0 test1
```
1. Puts a small window on the MacBook display and clicks it once (the pointer is put back), then checks that the items report MacBook positions.
2. Opens and closes the shelf there, then for each target picks it and records whether the flight window goes away and the real menu opens, capturing the area around the notch.

It has to be started with `open` so the app can take focus; focus moves for a few seconds while it runs.

### Frame rate
Put `--fps` before the targets. A ScreenCaptureKit stream is opened at up to 120 fps; it delivers a frame only when the screen changed, so frames counted during an animation are frames really drawn. A plain animated square is measured first as the ceiling of the method, and only the area below the menu bar is measured (the notch has no pixels).

MacBook display (120 Hz), 2026-11-18; ceiling of the method about 108–111 fps:

| Phase | Before | After |
|---|---|---|
| Shelf opening | 101–107 fps, 2–4 late frames in the first 0.1 s | 108–112 fps, at most the first frame late |
| Shelf closing | 101–110 fps | 109 fps |
| Icon flight | 108–109 fps | 111–113 fps |
| Main thread blocked when opening | 47–95 ms | 11–21 ms |

Shadows, shelf content, window creation and the morph itself were ruled out first, one at a time (`AM_NOSHADOW`, `AM_NOCONTENT`, `AM_KEEPORDERED`, `AM_SIMPLEMORPH`). The cause was reading the menu bar items on the main thread; see [how-it-works.md](how-it-works.md).

## Korean input
```bash
"$AM" --hangul-test
```
2-set (Dubeolsik) key sequences must compose into the right syllables (compound vowels and finals, a final consonant moving to the next syllable, lone consonants), and search must find items by syllables, by jamo typed mid-composition and by initial consonants. The composer is `Hangul.compose` in `Sources/Settings.swift`.
