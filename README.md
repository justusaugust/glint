<p align="center"><img src="Assets/GlintPreview.png" width="160" alt="Glint icon"></p>

# Glint

A small native macOS app switcher with Liquid Glass, a hold shortcut, and predictions that learn your switching habits.

Hold **Right Command**, type an app name, then release to open the selected app. Hold and release without typing to choose the learned prediction. Press a numbered result key to select it, even after typing; Shift + number enters a literal digit (for example, 1Password). Escape cancels. Control–Option–Space opens a regular search palette.

- Searches installed apps, including apps that aren't running.
- Settings → Apps supports aliases, pinned suggestions, and exclusions. Exact app names still take priority.
- Sends a reopen event to recover apps whose last window was closed, with a normal macOS open fallback if that event is rejected. Cold launches use the standard launch event. If macOS reports failure after the app opens, Glint checks for a real window owned by that exact app before showing an error. Only this failure path gets a short recovery check; successful launches do not wait. An app finishing Quit does not cancel an in-progress hold selection when macOS activates another app.
- Optionally choose a window: select a running app, press Tab (or its chevron), then release Command. The window picker stays open. Use arrows or type part of a window title; press Return or a displayed number to focus it. Right Arrow also opens the picker. Minimized windows are included. Left Arrow or Escape returns to the saved app search; Escape again cancels.
- Looks up windows only when requested, with a short Accessibility timeout. No background window scanning or title history. Optional thumbnails use native ScreenCaptureKit snapshots of the three displayed windows, delivered as each snapshot completes. On a cold visit a softly defocused app icon fills each thumbnail until its real snapshot arrives, with no timed reveal or blocked selection. Cached images appear sharp immediately. Visible windows use faster native discovery, with full-discovery fallback for hidden or other-Space windows and a direct full query for minimized windows; macOS Screen Recording permission is requested only through Enable previews. A RAM-only cache retains at most 18 thumbnails for fast repeat visits: snapshots under one second old avoid recapture; older snapshots can display immediately for up to ten seconds while refreshing. Entries are checked against the same Accessibility window, title and geometry. The cache clears on sleep or when permission loss is detected and never writes to disk; expired entries are removed on the next window-picker render. If windows are unavailable or a selected window closes, Glint opens its app instead.
- A launch request survives an app finishing an earlier Quit: Glint watches that process for up to three seconds and reopens after it exits. There is no wait on ordinary activation. A later keypress, click, launcher request or sleep cancels recovery; the interaction monitor only cancels the request and does not read typed characters. This is a short request guard, not an app crash monitor.
- Learns app pairs, short sequences, time of day, and recent context. Older habits fade with a 14-day half-life.
- Updates the app catalog from filesystem and workspace notifications. No polling timers or network services.
- Stores only timestamps and app identifiers in a local SQLite database. No typed queries, window titles, document paths, or web activity are recorded.

## Build

Requires macOS 26 or later and Xcode 27 with its Swift toolchain and Icon Composer support.

```sh
./build.sh
swift test --build-system native -c release --disable-sandbox
```

The build produces `Glint.app`. Move it to `/Applications` and open it. Enable the hold shortcut in Settings → Keyboard and allow Glint in System Settings → Privacy & Security → Accessibility (called Device Control and Data Access on newer macOS versions). Quit another launcher first if it uses the same physical key.

The build uses an available Apple Development identity to keep local permissions stable between builds; otherwise it signs ad hoc. Set `CODE_SIGN_IDENTITY` to select a specific identity. Local builds are not notarized. macOS may ask for permission again after a signing identity or install path changes.

## Learning

Predictions combine a smoothed app-to-app model with recency and time context. Repeated short-sequence evidence can outweigh recency as confidence grows. Explicit text matches always take priority over predictions.

Typing includes the source app in learned ranking. Once it exits, it leads matching suggestions for immediate reopening; pins and stronger text matches still take priority. Empty suggestions omit it while it is running. Learning and recent context stay fixed for each presentation, so an automatic focus handoff cannot rewrite the ranking mid-selection. Learning continues for the next presentation. Prediction weights are reused for the same catalog input and source eligibility, with at most two cached modes per presentation. Text matching and app rules still run for every query; closing the palette releases the cache. An explicit app choice stays selected and visible through refreshes, until you type a new query or dismiss the palette.

Settings → Learning can import Applight's local history. Choose its containing folder so SQLite can read its journal. Imports are read-only and skip duplicates. Glint is an independent implementation and contains no Applight code or assets.

Data stays in `~/Library/Application Support/Glint/switches.sqlite`. Startup reads the most recent 100,000 switches; older records remain stored. This repository contains no personal history. To run an optional chronological replay on your own data, provide `GLINT_HISTORY_PATH` pointing to a JSON array of `SwitchEvent` records. The test prints aggregate accuracy and latency locally.

## Design and implementation

AppKit panel and controls, Apple's glass material, Swift concurrency for app scanning, SQLite for local history, and a small dependency-free ranking model. The icon is a minimal folded ribbon SVG authored with Claude Opus and finished in Apple Icon Composer; its editable source is in `Assets/Glint.icon`.

Tests cover search tiers, windowless and nonrunning candidates, Unicode names, gesture cancellation, native field editing, numbered results, aliases and exclusions, adaptive predictions, read-only import, duplicate imports, persistence, and search performance. Native keyboard interception, OS permissions, and app-specific reopen behavior also require testing on a real Mac.

## License

MIT. See [LICENSE](LICENSE).
