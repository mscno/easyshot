# Easyshot 1.6.0 performance review

Focus: native rendering over video/games, selector startup, window hover and capture completion. Apple Silicon only; macOS 26.6.1; two connected displays. No resident service was added.

## Rendering correction

The previous opaque selector replayed the desktop through 30 fps ScreenCaptureKit streams. Capturing, converting and displaying desktop frames introduced latency, limited visible frame rate and could show black/stale frames or affect the underlying application's visibility. It was the wrong architecture for a selection overlay.

1.6.0 removes `LiveDesktop.swift`, selector snapshots, preview streams, retained desktop images and Refresh Desktop. The selector uses nonopaque, clear, nonactivating AppKit panels. macOS composes the actual underlying windows directly. Easyshot renders borders, handles, a translucent window tint and outside dimming; selected area/screen interiors have zero alpha. Native input acceptance remains enabled independently of visual alpha. Nonactivating panels accept local keys while leaving the underlying application active.

Screen/area startup neither enumerates shareable content nor captures pixels. Window modes refresh metadata to identify targets. ScreenCaptureKit is still used when a screenshot or recording is explicitly requested.

## Startup measurements

Five fresh release/arm64 processes. The timer starts in `main` before `NSApplication.shared`. The benchmark invokes the production launcher, records when the toolbar and selector are ordered on screen, closes them and exits. It preserves the saved capture mode and does not save captures or change the clipboard. These measurements exclude process loading before `main`, Spotlight/Raycast latency and the compositor's subsequent display commit. They are local observations under varying system load, not controlled hardware benchmarks.

| Milestone | Original baseline | 1.5.0 | 1.6.0 |
| --- | ---: | ---: | ---: |
| Toolbar ordered, median | 1,004.2 ms | 255.5 ms | 203.7 ms |
| Selection available, median | 1,421.4 ms | 783.9 ms | 203.8 ms |

The earlier selection-ready measurement waited for desktop preview frames on both displays. That dependency no longer exists: native transparent selection opens together with the toolbar. The milestones represent user-facing readiness implemented differently, not equivalent streaming throughput measurements. No general 10× speedup claim is made.

| 1.6.0 run | Toolbar | Selector |
| --- | ---: | ---: |
| 1 | 220.0 ms | 220.0 ms |
| 2 | 175.4 ms | 175.4 ms |
| 3 | 203.7 ms | 203.8 ms |
| 4 | 199.9 ms | 199.9 ms |
| 5 | 224.2 ms | 224.2 ms |

Previous 1.5.0 toolbar values: 331.2, 229.0, 224.9, 255.5, 273.2 ms. Its live-selector values: 853.0, 766.9, 716.6, 816.2, 783.9 ms. Original baseline toolbar values: 983.6, 1004.2, 1020.2, 1002.4, 1089.5 ms; live-ready values: 1392.6, 1383.6, 1421.4, 1425.9, 1522.3 ms.

## Retained optimizations

- No fixed 300 ms launcher delay or 180 ms preselection delay. Routing is coalesced with a main-actor yield; pending launches prevent premature exit.
- History loads lazily when used. No duplicate initial permission preflight in the controller.
- Window sorting uses indexed rank lookup. Mouse hover caches WindowServer metadata for one display frame; selection redraws only when target or geometry changes.
- No extra fixed 120 ms capture delay. PNG clipboard export reuses the encoded capture bytes rather than reading and recompressing the file.
- Toolbar overlap still fades to zero in 0.16 seconds and back in 0.2 seconds, respecting Reduce Motion. Selection input remains available beneath the faded toolbar.

## Verification

35 unit tests, 55 offline integration checks, 15 actual capture/clipboard/recording/export checks, 19 native-selector checks, Escape/idle process-exit checks and five successful startup runs passed.

The native selector diagnostic queries public `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)` after WindowServer commits the windows. Clear rectangle interiors, handles and outside points route to the selector on both displays in all five modes. It also confirms local keyboard focus, unchanged foreground application, underlying-window visibility and advancing native Core Animation during repeated rectangle movement. Offscreen pixel tests confirm zero-alpha selected interiors, stable translucent dimming and removal of stale selection holes. Toolbar fading, routing beneath a faded toolbar, reverse animations, tooltips, Escape and task cleanup are covered.

Diagnostics call view event handlers directly and query native window state; they do not synthesize OS input. A specific real game/video, physical dragging and Liquid Glass appearance still require manual review. The animation diagnostic confirms native composition remains live; it is not a numerical frame-rate benchmark.
