# Easyshot

Formerly Shotglass. On first launch Easyshot imports the old app's settings and capture history. macOS asks for Screen Recording permission again because the bundle ID changed.

A native Apple Silicon macOS capture utility inspired by CleanShot X, built in Swift, SwiftUI, AppKit, ScreenCaptureKit, Vision, and AVFoundation. Uses macOS Liquid Glass through native `glassEffect`, `GlassEffectContainer`, and glass button styles. No subscription required; an account is needed only for the optional Easyshot Cloud links. Direct downloads use Sparkle for updates.

![Easyshot screenshot selector](docs/screenshot.png)

## Run

Source repository: [mscno/shotglass](https://github.com/mscno/shotglass) (public).

Open `dist/Easyshot.app`. Launching or reopening the app shows a compact Liquid Glass capture bar at the bottom of the current display. The capture bar and transparent selector open together, without waiting for desktop frames. Escape works throughout startup. The last capture mode and area are remembered across launches. There is no Dock icon, persistent menu-bar item, global hotkey registration, or login launch. Capture or cancel ends the session and exits the process. Settings and Library open only when requested. Quick Access cards keep the session until the last one closes; explicitly opened editors, pins, recordings, and library windows keep it active until finished.

For a permanent installation, copy the app to `/Applications` or `~/Applications` before enabling permissions. Requires an Apple Silicon Mac (M1 or newer) running macOS 26 or later. Intel builds are intentionally excluded.

If prompted, allow Screen Recording in **System Settings → Privacy & Security → Screen & System Audio Recording**. On older macOS versions this section is called Screen Recording. Relaunch after changing the permission if macOS requests it. Camera and microphone permissions are requested only when those recording options are enabled. Automatic scrolling and shortcut display during recordings additionally require Accessibility access; ordinary screenshots and local capture keys do not.

## Capture workflow

The selector uses clear, nonopaque AppKit panels. macOS renders the actual windows, video and games underneath directly; Easyshot draws only the selection border, resize handles, translucent window tint and outside dimming. There is no desktop-preview capture stream, screenshot backdrop, image copying or preview frame-rate limit. Clear pixels still belong to the selector's native input surface, so clicking, dragging or scrolling cannot reach apps below. Nonactivating panels keep the underlying app active while accepting local capture keys. Window mode refreshes window metadata; screen and area mode require none to open. Escape cancels from the selector, Options popover or text fields and ends the on-demand session.

- **Full screen:** a thin inset border follows the display under the pointer, with its name and capture resolution in pixels. Move to another display to switch targets, then click it or press Return to capture.
- **Active window:** capture the frontmost window of the app you were using before opening Easyshot.
- **Choose window:** hover to see a blue outline and tint, the app icon/name, and the window title, then click it. Window positions and front-to-back ordering update during selection. The window is captured independently, without surrounding apps.
- **Area (default):** your last rectangle is already selected. Drag inside to move it, drag a handle to resize it, or drag outside to replace it. Press Return or click Capture when ready. Moving/resizing never captures on release. When the rectangle overlaps the bottom toolbar, the toolbar fades out in 0.16 seconds and stops intercepting clicks. Move or resize the rectangle clear of the toolbar to fade it back in over 0.2 seconds. The rectangle stays visible, keys 1–5/Return/Escape remain available, and Reduce Motion is respected.
- **Draw new:** click Draw new or press **N**, then draw anywhere, including inside the old area. Drag or click two corners; hold Shift while dragging for a square. The bar waits for Return/Capture by default. Enable **Options → Snap on draw** to capture and close immediately after drawing a new rectangle, including drawing outside the old area or clicking two corners. The toggle is remembered across launches; moving or resizing an existing area still waits for Capture. The explicit `easyshot://draw` launcher command captures a new area immediately on release. Areas can span displays.
- **Reset area:** press **X** (or **Delete**, or click the eraser button) to wipe the current rectangle, any half-drawn corner and any drag in progress, and start drawing from scratch. Your saved last area is untouched until a new capture replaces it.
- **Last area:** capture your previous selection immediately. Choose Last area in the bar to recall and adjust it first. If the saved display was disconnected, the bar brings the rectangle onto the current screen.
- **Preset area:** enter an exact size in the overlay, or save your last area as a named preset. Selection dimensions are in logical screen points; screenshots preserve the display's native pixel density.
- **Aspect lock:** **Options → Aspect** keeps drawn, two-corner and resized areas at 16:9, 4:3, 1:1 or 9:16. Corners keep the opposite corner fixed; edges grow symmetrically. Shift still draws a square.
- **Capture Text:** press **T** (or the text button, `easyshot://capture-text`, or the *Capture Text* App Intent) to switch the bar to text. Return recognizes text and QR codes on device, in reading order, copies them and shows a toast. No file or history entry is made unless **Settings → Keep a screenshot when capturing text** is on.
- **Magnifier:** press **M** for a crosshair and pixel loupe with display coordinates in points and pixels, the selection size and the sRGB hex color under the pointer; **C** copies the color. The setting is remembered. While it is on, Easyshot takes 21×21-pixel captures of the area under the pointer, one at a time and at most once per display frame, with Easyshot's own windows excluded. While it is off, nothing is sampled.
- **Freeze screen:** **Options → Freeze screen** takes one still of each display as the selector opens and shows it instead of the live desktop, so menus, hover states and tooltips stay put. Area and screen captures use those stills; window captures stay live. A capture timer ignores the stills.
- **Window backgrounds:** **Settings → Window background** wraps window captures in padding over the desktop wallpaper, a gradient, a solid color or transparency, at the capture's native pixels. The window shadow toggle applies as before. Composition runs off the main thread.

Open Easyshot from Applications, Spotlight, or Raycast. The numbered mode icons match **1–5 from left to right: Full screen, Choose window, Area, Active window, Last area**. While the capture bar is focused, press **A** for area, **D/N** to draw a new rectangle, **F/S** for full screen, **W** for a window, **V** for the active window, or **R** to recall the last area. **Return** captures; **Esc** cancels and quits. **Tab/Shift-Tab** cycles modes and **Space** toggles area/window. **⌘L** opens Library; **⌘,** opens basic Settings. Arrow keys move an existing region by one point; Shift-arrow moves it by ten. These keys never intercept typing in another application.

The compact icon toolbar follows [Apple's Screenshot panel](https://support.apple.com/guide/mac-help/mh26782/mac): screen/window/area first, additional tools in a second group, then Options and Capture. It uses system light/dark appearance, native Liquid Glass, neutral selection highlights, and alternating black/white dashed region borders with larger circular resize handles, and a camera pointer for window capture. Options contains the timer, exact size, aspect lock, saved areas, clipboard and folder toggles, Snap on draw, After capture, Magnifier, Freeze screen, Settings, and Library. Hover a mode or button for its name, shortcut and a short explanation. Tooltips appear after a brief delay above the capture overlay, follow the currently hovered control, and never steal focus or intercept clicks.

Every screenshot saves as **PNG** to **`~/Documents/Screenshots`** and copies to the clipboard by default. The clipboard includes both the image and its file URL, allowing image pasting and file pasting. Recordings use a file URL; GIFs also include their animated GIF data. Filenames include milliseconds and a unique suffix to prevent rapid captures from overwriting each other.

Still captures use macOS's native screenshot dimensions. Area captures crop integer pixels from the native display image without resizing; window captures retain the full window and optional shadow without fitting them into a smaller video surface. PNG exports preserve the original pixel dimensions, transparency and color profile. A selection measured in points produces twice as many pixels on a 2× Retina display. Mixed-density captures use the highest density among the captured displays, with no smoothing when combining them. JPEG export and an explicit editor Resize remain separate choices. Existing blurred captures must be taken again; PNG encoding cannot restore detail lost during an earlier capture.

After each capture a **Quick Access** card slides into the corner of the display you captured. This is the default, under **Options → After capture**. Each card is a nonactivating Liquid Glass panel. Its actions are Copy, Save As, Annotate, Upload & copy link (when signed in to Easyshot Cloud), Pin and Copy Text. Recordings show their duration and offer Trim and GIF instead. Drag the thumbnail into any app to drop the file, or click it to annotate or trim. Up to five cards stack upward; older ones close. Cards close after 5 seconds by default; choose 3 or 10 seconds or Never in Settings. Hovering any card pauses every timer. A horizontal trackpad swipe dismisses a card. `easyshot://restore-overlay`, the *Restore Last Quick Access Card* App Intent or the Raycast command brings back the most recently closed card, even from an earlier session. The app quits when the last card closes and nothing else is open. Choose **Thumbnail · 3 seconds** for the previous small click-to-edit preview, or **Nothing**. Every completed capture keeps its own file, while the clipboard holds the latest. Relaunching during an active capture queues the newest request until the current write finishes. No background service, daemon, or login item is used.

Configure the destination, PNG/JPEG format, clipboard behavior, capture delay, shadows, cursor, and recording settings in Settings. With folder saving disabled, captures remain in an internal history directory. Removing an item from history preserves its file.

## Keys while capture is open

| Action | Key |
| --- | --- |
| Area · reuse/adjust rectangle | 3 or A |
| Draw a fresh rectangle | D or N |
| Full screen | 1 or F or S |
| Choose window | 2 or W |
| Active window | 4 or V |
| Recall last area | 5 or R |
| Reset the draw area | X or Delete |
| Capture Text on/off | T |
| Magnifier on/off | M |
| Copy the color under the magnifier | C |
| Capture, upload and copy a link | U (configurable) or ⇧Return |
| Capture | Return |
| Cancel and quit | Esc |
| Basic Settings | ⌘, |
| Library | ⌘L |

### Global shortcuts without a resident process

Easyshot registers no global hotkeys and keeps no process running. Instead it ships **App Intents**: Capture Area, Capture Window, Capture Full Screen, Capture Text, Repeat Last Area, Record Screen, Open Library, and Restore Last Quick Access Card. They appear in the Shortcuts app and in Spotlight once the app has been opened. To bind a key, add one to a shortcut in **Shortcuts → (shortcut) → Details → Add Keyboard Shortcut**, or to the action in Spotlight's quick-key settings. macOS launches Easyshot for the action, and it quits afterwards as usual. Raycast hotkeys on the script commands work the same way. Each intent takes the same route as its launcher URL. `scripts/build-app.sh` extracts the intents' `Metadata.appintents` with Xcode's `appintentsmetadataprocessor`, because SwiftPM does not.

When upgrading, older global-shortcut preferences are ignored and an enabled Easyshot login item is unregistered. Quit older running Easyshot copies to release their previous global shortcuts.

## Easyshot Cloud: links for SSH and chat

Screenshots do not paste across SSH. Easyshot Cloud (direct-download edition only) uploads an image to your private Easyshot backend and puts a short link on the clipboard instead. Paste the link into the terminal, a coding agent, or chat; `curl -L`, browsers and Markdown image embeds all follow it. Links stop working after 30 days and uploads are deleted.

1. Run the backend (see [`server/README.md`](server/README.md)) and sign in under **Settings → Easyshot Cloud**. Use *Server* to point at your deployment; sessions are stored in the macOS Keychain.
2. Three ways to get a link:
   - In the capture bar press **U** (change it in Settings) or **⇧Return**, or click the link button: capture → upload → link copied.
   - **Paste as Link** (`easyshot://paste-upload`): converts the image already on your clipboard (⌃⌘⇧4, a copied file, anything) into a link. Give the Raycast command *Easyshot Paste as Link* a hotkey. The hotkey is configured in Raycast, which keeps Easyshot free of resident processes and global shortcuts.
   - Library → ⋯ → **Upload & copy link** for an existing capture.
3. The **Cloud** page lists everything you have uploaded, grouped by day, with expiry countdowns, copy-link and delete.

## Raycast and launcher integration

Install Easyshot in `~/Applications` or `/Applications`. Add **`integrations/raycast`** through **Raycast Settings → Extensions → + → Add Script Directory**, then type **shot** to find the capture bar, Draw New Area, Repeat Area, Capture Text, Restore Last Capture, and Library commands. See [Raycast's Script Commands instructions](https://github.com/raycast/script-commands#install-script-commands-from-this-repository). The main Easyshot command opens the bottom bar with your last mode selected. You can assign it the alias `shot` in Raycast.

The app also handles these URLs, usable from Raycast Quicklinks, Shortcuts, or `open`:

```sh
open 'easyshot://capture'       # compact bar, last mode remembered
open 'easyshot://draw'          # fresh selection, capture on release
open 'easyshot://repeat'        # instant previous-area capture
open 'easyshot://library'      # separate main window
open 'easyshot://settings'
open 'easyshot://fullscreen'
open 'easyshot://window'
open 'easyshot://active-window'
open 'easyshot://upload'        # capture, upload, copy a link
open 'easyshot://paste-upload'  # upload the clipboard image, copy a link
open 'easyshot://cloud'         # Library, Cloud page
open 'easyshot://capture-text'  # select an area, copy its text and QR codes
open 'easyshot://record'        # select an area to record, or stop recording
open 'easyshot://restore-overlay' # reopen the last closed Quick Access card
open 'easyshot://edit?path=/absolute/file.png'  # open a file in the editor
```

The app remembers the foreground application while running and ignores launcher activation, so opening the bar through Raycast preserves the application you were working in for Active Window. URL routing handles both first launch and an already running app. Scripts require the packaged app to be registered with macOS; opening the installed app once does this.

## AI agents (MCP)

Claude Code, Codex, Claude Desktop and other MCP clients can drive Easyshot: list displays and windows, take native-resolution screenshots with a downscaled preview, read on-screen text with frames for clicking, record MP4s, upload to Easyshot Cloud and open the editor. The agent starts `Easyshot --mcp` as a stdio server for the length of its session; no resident process is added.

```sh
claude mcp add --scope user easyshot -- /Applications/Easyshot.app/Contents/MacOS/Easyshot --mcp
```

See [docs/MCP.md](docs/MCP.md) for Codex and Claude Desktop configuration, tools, coordinates and permissions.

## Included tools

- Quick Access cards after every capture (or an optional three-second thumbnail). Copy, pin, OCR, sharing, and Finder reveal are also available in the Library.
- Searchable persistent local history, including recognized text, screenshot/recording filters, and import. **Settings → History and privacy** can keep history forever, for a month or for a week; older entries leave history when it next loads. Files in your screenshots folder are never deleted, only copies inside Easyshot's own history folder.
- Named reusable region presets and a capture timer.
- Annotation editor: arrows (straight, curved with a draggable bend handle, double-headed, tapered), lines, rectangles, ellipses, smoothed freehand drawing, a highlighter that snaps to the text line underneath, text with six presets (plain, outlined, pill, callout, code, title), numbered steps, solid redaction, pixelation, blur, spotlight, crop with free/1:1/4:3/16:9/9:16 aspects and snapping to image, text and shape edges, proportional resize, rotation, flip, and undo/redo. Saved color palette and the system eyedropper. Pixelation shuffles and jitters its mosaic blocks, so pixelated text cannot be reconstructed.
- **Find secrets**: on-device text recognition proposes redactions for API keys and tokens (OpenAI, GitHub, Slack, AWS, Google, Stripe and others), JWTs, private keys, long random tokens, emails, IP addresses, Luhn-valid card numbers and `password=` values. Review the boxes (click one to keep it visible), then **Redact N** paints solid boxes. UUIDs and git SHAs are ignored unless enabled. With **Check for secrets before uploading** (on by default), every Cloud upload runs the same check and offers Redact and Upload, Upload Unchanged or Cancel.
- Backgrounds: none, a solid color, 20 generated gradients and mesh-style backdrops, or the desktop wallpaper; padding, corner radius, shadow, aspect (auto, 16:9, 1:1, 4:3, 9:16), nine-point alignment, and auto-balance, which pads around the visible window rather than its transparent shadow margin. Save combinations as presets. A floating export preview shows the result.
- Editable `.easyshot.json` projects containing the original image and annotations. Import a saved project to continue editing. PNG/JPEG exports flatten all markup. Keep editable projects private when the source contains sensitive information because projects intentionally preserve the original pixels.
- Combine images below or beside, through import or drag and drop onto the editor canvas.
- On-device text recognition and QR/barcode recognition, with searchable recognized text in history. OCR adds text to the clipboard while keeping the image/file representations available.
- Floating reference images with resizing, opacity, click-through mode, and Window-menu unlock.
- MP4 recording of a screen, window, or region, with selectable frame rate, cursor, system audio, microphone, webcam bubble (circle, rounded or square; three sizes; any corner), click highlights (color, size, filled or outline) and keystroke captions (shortcuts only or all keys, top or bottom, dark or light). The recording pill has a timer, pause/resume and stop; paused time is cut from every track, so the video continues one frame after the pause. **Record as GIF** records an MP4 internally and saves and copies only the GIF. **Clean desktop** hides desktop icons in display and area recordings and can replace the wallpaper with a solid color; Finder windows and the Dock stay visible. Overlays are composited on the GPU from cached sprites: 4.3 ms/frame wall and 3.4–3.8 ms CPU at 2560×1440 with clicks, a caption and the camera, against 14.5–20 ms on the earlier CPU path (`--effects-bench`).
- **Studio recordings** (Settings → Recording → Studio): the cursor is hidden while recording and its position, clicks, keystroke timing (never key identities) and shape are logged to a hidden `.<name>.mp4.easyshot-cursor.json` sidecar; frames stay a passthrough, so capture costs the same as a plain recording. No Accessibility or Input Monitoring access is needed. Opening the recording adds a Studio panel: automatic zooms on clicks and typing bursts, a timeline strip (drag to add a zoom, click one to remove it), a spring-smoothed, enlarged cursor that dips on click, optional zoom motion blur, gradient/colour/wallpaper/custom-image backgrounds with padding, rounded corners and shadow. Preview and export use the same Core Image graph on the GPU; static layers render once per plan. Export at source, 1080p or 4K (never upscaled) in H.264 or HEVC, keeping audio and the trim range. Frame the export as 16:9, 1:1 or 9:16: the crop follows the zoom and cursor. Cursor styles: macOS, highlighted (a soft halo) or a dot; motion blur strength is adjustable. Studio shares the editor's 20 backgrounds. Edits save to a `.easyshot-studio.json` sidecar; older plans open with defaults for newer settings.
- Microphone/system-audio mixing for playback, trimming, GIF export, and native video sharing. GIFs export at 10 fps and a maximum dimension of 960 pixels, with a two-minute duration limit.
- Scrolling screenshots, vertical or horizontal (choose the direction before the second frame), with overlap detection and duplicate rejection. Horizontal frames are turned a quarter turn through the same matcher. Select only the moving content, excluding fixed headers. Scroll manually and add frames, or enable automatic scrolling. Finish saves and copies the combined image. Auto scrolling is bounded to avoid unbounded captures.
- Desktop-icon exclusion from display captures.

## Scope and limitations

This is an independent local implementation, with its own interface and assets. It does not connect to CleanShot accounts or copy CleanShot's private services or proprietary project format.

CleanShot Cloud hosting, team comments, transcripts, SSO/SCIM, and domain management are not implemented. Sharing uses the native macOS share sheet or file drag and drop. The video editor supports trim, GIF export and Studio zoom/cursor/background export; it has no multi-clip timeline, cuts, speed changes or 3D scenes. Studio typing zooms aim at the last click because the caret position is not recorded. Window recordings map the cursor to the window's frame at the start, so moving the window during a Studio recording offsets the cursor. Studio recordings saved without Studio export have no cursor. Scrolling capture depends on sufficient overlap; animations and fixed elements can prevent matching. Horizontal scrolling captures are limited to 19,000 pixels wide. Recording a region spanning several monitors records the display containing the largest part of that region; screenshots can span monitors.

## Build from source

With Xcode 26 or later and its command-line tools installed:

```sh
bash scripts/build-app.sh                 # release app, Apple Silicon only
open dist/Easyshot.app
```

The script builds the executable, packages the `.app` and generates an original icon. Without `SIGNING_IDENTITY` it produces a development build: bundle ID `no.paraply.easyshot.dev`, named *Easyshot Dev*, URL scheme `easyshot-dev://`, with no Sparkle feed. It is signed with the first *Apple Development* or *Developer ID Application* identity in your keychain. Override the identity with `LOCAL_SIGNING_IDENTITY`. macOS ties Screen Recording, Accessibility, camera and microphone grants to the signature's designated requirement. With a stable identity, those grants survive rebuilds and version bumps. The separate bundle ID keeps development builds from replacing the installed release's grants. With no identity available, the script falls back to an ad-hoc signature, which macOS treats as a new app on every build. Set `DEV_BUNDLE=0` to keep the release bundle ID locally. For signed and notarized drag-to-Applications DMGs, follow [the release setup](docs/RELEASING.md). The **Release signed DMG** workflow runs on `master` pushes or manually, publishing the verified DMG and checksum as a downloadable Actions artifact. A versioned draft release is optional. Grant permissions once to *Easyshot Dev*; signed releases keep theirs across Sparkle updates because they share the Paraply Developer ID requirement.

Mac App Store preparation is documented in [the Store guide](docs/APP_STORE.md). A separate sandboxed edition, local package scripts, privacy/support copy and listing drafts are prepared. The app will be free under Paraply Ventures AS. Uploading and submission are on hold; public pages, Store distribution certificates, contacts and final screenshots still need completion. The Store edition uses manual scrolling and omits global keystroke captions.

Open `Package.swift` in Xcode to develop the app. Always run the packaged app when checking privacy permissions.

## Verification

```sh
swift test
bash scripts/build-app.sh debug
dist/Easyshot.app/Contents/MacOS/Easyshot --self-test
dist/Easyshot.app/Contents/MacOS/Easyshot --capture-test
dist/Easyshot.app/Contents/MacOS/Easyshot --studio-test       # offline: synthetic 1440p60 → Studio export, no permissions
dist/Easyshot.app/Contents/MacOS/Easyshot --editor-test       # offline: editor tools, secret OCR, backgrounds, retention, pause/resume, overlays, reframed export
dist/Easyshot.app/Contents/MacOS/Easyshot --effects-bench     # offline: per-frame recording overlay cost at 1440p
dist/Easyshot.app/Contents/MacOS/Easyshot --idle-exit-test
dist/Easyshot.app/Contents/MacOS/Easyshot --escape-exit-test
dist/Easyshot.app/Contents/MacOS/Easyshot --live-selection-test
dist/Easyshot.app/Contents/MacOS/Easyshot --startup-benchmark
```

Validated on this Mac:

- 41 deterministic unit tests for geometry, filenames, selection drawing/moving/all eight resize handles, forced redraw inside a previous area, square drawing at a display edge, cross-display regions, launcher URLs, local capture keys, mode persistence, rapid thumbnail replacement/stale-timer protection, session exit conditions, native pixel crop boundaries, and pixel-exact PNG export including Display P3 and transparency.
- An optional native screenshot test checks full display/window pixel dimensions and a one-pixel checkerboard for resampling. Run `EASYSHOT_TEST_SCREEN_CAPTURE=1 swift test --filter NativeScreenshotTests` on a Mac with Screen Recording access already granted. It creates a temporary test window, requests no permissions, changes no saved settings or clipboard data, and saves no captures. CI skips this display-dependent test.
- 64 integration checks covering persisted snap-on-draw behavior, automatic capture/close for drag and two-corner drawing, invalid-area rejection, move/resize safety, transparent interiors and translucent dimming in all five modes, cleared old selection pixels, rectangle dragging/resizing, full-screen border/name/resolution and display routing, toolbar numeric keys, preferences and lifecycle, annotation export, clipboard/file saving, OCR, scrolling stitching and video export.
- 15 live capture checks covering full-screen/area/window captures, native pixel dimensions, repeated areas, window hit testing and active-window routing, PNG and file clipboard representations, actual MP4 recording with effects, GIF export and trimming.
- 19 native-selector checks covering immediate surfaces without capture metadata, keyboard focus, WindowServer input routing across clear interiors/handles/outside areas on both displays in all five modes, animated native underlay visibility and advancing animation during rectangle movement, tooltips, toolbar overlap fading and input routing, fade reversal, Escape and cleanup.
- Before the Liquid Glass update, the workspace and editor were rendered from native SwiftUI views and inspected visually. Liquid Glass uses the window compositor and cannot be fully validated with AppKit bitmap-only rendering; incomplete bitmap previews were removed.

The capture test uses a temporary folder, captures the real desktop, records two seconds of a small region, and restores the preexisting clipboard after checking clipboard output. It does not add records to the normal library. Full mouse/keyboard UI automation remains unavailable because Computer Use did not approve access to Easyshot. Selection behavior, key mapping, URL parsing, persisted settings, and lifecycle rules are covered by automated tests. Actual toolbar interaction and its compositor-rendered Liquid Glass appearance still need visual review. Webcam hardware, microphone mixing, automatic scrolling events, and physical multi-monitor capture have not been verified end to end.

Latest 1.6.2 verification: 35 unit tests, 64 offline checks, 19 native-selector checks and actual Escape/idle process termination passed. Version 1.6.0 also passed 15 real capture checks. Native checks use public WindowServer hit queries and directly invoked view methods; they never inject input into other applications. The animated-underlay test verifies native visibility and advancing Core Animation while moving the selection; physical interaction over a specific game or video still requires manual review.

## Performance

Startup no longer enumerates shareable content, captures desktop backdrops or starts preview streams for screen/area selection. It creates the clear selector and Liquid Glass toolbar immediately. macOS composes underlying content at its own rate. The selector redraws only when selection geometry or the window target changes. Window hit testing caches a WindowServer snapshot for one display frame and uses indexed window lookup. History remains lazy, screenshot export reuses the encoded PNG for clipboard output, and no fixed launcher or preselection wait remains.

See [the performance review](docs/PERFORMANCE.md) for local measurements and limits of the benchmark.

## Updates

Direct-download builds use Sparkle 2.10.0. Automatic update checks are enabled by default and use a signed feed on GitHub Releases, with no system-profile reporting. Use **Check for Updates…** or enable **Automatically install updates** in settings. Automatic installation is opt-in. Update archives and feeds are signed with a separate Ed25519 key, and release apps/DMGs remain Paraply-signed, Apple-notarized and stapled.

The first Sparkle-enabled version must be installed manually. Subsequent stable releases publish `appcast.xml` alongside their DMG; previews and drafts do not enter the latest stable feed. Capture diagnostics and UI tests disable network update checks.

Easyshot checks at the first safe idle point of a capture session and stays alive while the check completes. Failed checks are attempted at most once per launch. Installation waits for capture/export; the Store edition has no Sparkle dependency or update controls.
