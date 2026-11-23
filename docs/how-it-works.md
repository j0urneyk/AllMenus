# How All Menus works

## Finding the menu bar items
- Every running app exposes its menu bar items ("status items") through the Accessibility API as `AXExtrasMenuBar`. All Menus reads those, with their titles, descriptions and on-screen frames.
- Whether an item is **hidden** is decided by the item's own window in `CGWindowList`: macOS keeps a window for every status item, but doesn't draw the ones that don't fit (behind the notch, or squeezed out by long app menus). An item whose window isn't on screen is hidden, and so is one that isn't entirely to the right of the notch: an item that was drawn once and then pushed behind the notch keeps its on-screen flag.
- With an external display connected, macOS keeps a menu bar on each display. "Hidden" is judged for the display the shelf opens on, and an item's counterpart on the other display is found by pairing windows of equal width in right-to-left order.
- The list is read on a background thread ahead of time: when the pointer reaches the notch (during the hover delay) and every 5 seconds. Reading it on the main thread when opening took 37–45 ms, up to 290 ms with an app that answers slowly, and was the cause of dropped frames at the start of the opening animation.

## Opening an item's menu
- All Menus sends `AXPress` to the item. macOS opens the **app's real menu or popover**, at the item's real spot in the menu bar, even when the item isn't drawn.
- `AXPress` blocks until the menu closes, so it runs off the main thread.
- Some apps accept `AXPress` and do nothing, because they react only to mouse events: they watch for a mouse-down in their button's window (a local event monitor), check the type of the current event, put a view of their own on the button, or use a gesture recognizer. `AXPress` produces no mouse event. If nothing of the item's app appears within 0.4 s (`ItemOpener`):
  - **Visible:** a real click is sent (the pointer is put back afterwards). An event tap looks at that click on its way to the app and remembers it, including the layer context (`CAContext`) the window server addressed it to, in an undocumented event field. AppKit needs it to find the status item's window, because on macOS 26 the windows in the menu bar belong to Control Center; a click without it arrives in the app without a window.
  - **Hidden, opened before while visible:** the remembered click is posted to that process only. The app doesn't know or care that its item isn't drawn. Addresses are kept in memory, until either app quits.
  - **Hidden, never opened while visible:** the app is opened again, as by double-clicking it in Finder. Menu bar apps usually answer by showing their popover or window.
- A press that **switches** something opens nothing either, and a click would switch it back. The item's window is captured before and after (macOS lets a window that isn't drawn be captured); if it changed and stays changed, the press worked. Items that change all the time (a timer) are told apart by a third capture.
- Which way an item needs is remembered, so the next pick goes straight to it. Items that opened by a press never get a click.
- Nothing is ever moved in the menu bar. Moving hidden items into view by a synthetic ⌘-drag was tried and dropped: putting them back isn't reliable.

## Icon images
The shelf shows the icons as they look in the menu bar, separated from the menu bar's background (difference matting). This needs the Screen Recording permission; without it, app icons and SF Symbols stand in.
- Each item's window is captured. Its top and bottom rows are pure background (the window is taller than anything drawn in it), so the background is interpolated per column between them.
- For every pixel, alpha is the smallest value that explains it as "some color composited over that background".
- A pixel that moved toward white, toward black, or only in brightness (the vibrancy macOS uses on inactive displays) belongs to a monochrome glyph. Monochrome icons are recolored to match the shelf; colored icons keep their colors.
- Alpha is normalized so the solid inside of the icon is fully opaque (inactive displays draw icons dimmed, and for colored pixels the difference to the background is only a lower bound).
- The faint "pill" macOS draws behind the clock and Control Center is peeled off, and anything touching the left or right edge (a neighbor spilling over) is removed.
- Captures from the active menu bar are kept in preference to dimmed captures from another display. Icons are cached in `~/Library/Caches/AllMenus`.
- Accuracy is measured against a fixture with icons of known shape: shape IoU 1.000 and mean color error 0.005 for captures from the active menu bar (see [testing.md](testing.md)).
- Icons are re-captured before the shelf opens (when the pointer reaches the notch) and after a close without picking an item, never while the shelf is open: text-like icons such as the clock change width between captures, which used to resize the open shelf.

## The shelf
### Shape
- The outline is a single path: a "neck" exactly as wide as the notch fills the menu bar height, and the body widens only **below** the menu bar, joined by concave shoulders. The shelf therefore never covers real menu bar items (macOS 26 draws those above other windows anyway), and clicks on the menu bar pass through the shelf's transparent area.
- The closed shape is the notch itself; the open shape has the same path elements, so Core Animation can interpolate between them.

### Opening and closing (Full animation)
- **Two stages:** the notch first drops down while still narrow (about 0.1 s), then widens with a slight overshoot (about 0.45 s in total). Closing runs in reverse in 0.3 s. These are `CAKeyframeAnimation`s on the path (and its shadow), drawn by the render server at the display's refresh rate.
- The content sits in a view masked by the same animated outline, so while the body grows out of the notch the content only shows inside it.
- The window is first committed at the closed, notch-sized (invisible) state; the morph starts on the next frame, so the first-frame cost of showing a window is paid before anything moves. At launch the shelf is drawn once, invisibly, for the same reason.
- Tiles cascade in from the notch (center and top row first), and the selection highlight is a single shape that glides between tiles (`matchedGeometryEffect`).
- The **Simple** animation mode is a 0.16 s fade; **Off** is instant. macOS "Reduce motion" turns Full into Simple.

### Size
The size is measured once when the shelf opens and stays fixed while it is open.
- **Search** changes results inside that frame: the grid dims tiles that don't match, in place; the list gathers the matches at the top, with the footer kept at the bottom.
- Icon images are frozen per opening, so a capture that arrives while the shelf is open can't change tile sizes.
- Measurement uses a fresh SwiftUI view identity every time; reusing the old one could return the size from before the latest model change.

### Keyboard and focus
- Opened by the shortcut or a notch click, the shelf takes the keyboard right away.
- Opened by resting the pointer on the notch, it doesn't (so a pointer brushing the notch never steals typing). It takes the keyboard once the pointer is over the shelf or the search box is clicked, and it closes when the pointer leaves.
- The shelf receives raw key events, not input-method text. With the Korean 2-set (Dubeolsik) layout active, typed Latin keys are mapped to jamo and composed into syllables by the app itself; search matches on the typed jamo, so in-between composition states never hide a result, and initial-consonant (choseong) search works too.

## Picking an item: the flight
- The clicked icon lifts off its tile and travels to the item. The tile background shrinks to the glyph and fades on the way; the destination glows before the icon arrives; on arrival the real menu opens (about 0.45 s).
- **Visible item:** the icon travels below the menu bar and rises straight up into the bar right under the item, so its path never crosses the notch.
- **Hidden item** (behind the notch, touching it, or not drawn at all): it really lives behind the notch, so the icon is drawn into the notch. It travels below the menu bar to just under the notch, rises, shrinks and disappears while the notch's lower edge glows, and the menu opens. On a display without a notch it fades out just under the menu bar, where the menu opens.
- The flight is Core Animation on a separate click-through overlay window. When the icon lands where a menu is about to open, the overlay drops below menu level so nothing covers the menu.

## Settings and data
- Preferences are stored in the app's defaults domain (`local.allmenus`). The app was first called MenuShelf (`local.menushelf`); preferences saved under that identifier are moved over once on first launch.
- Global shortcut: Carbon `RegisterEventHotKey` (no extra permission). Notch hover: the pointer position is sampled 30 times a second, because mouse-moved events barely arrive while the pointer is over the menu bar.
