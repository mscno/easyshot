# Easyshot MCP server

AI agents can capture, read and record the screen through Easyshot using the [Model Context Protocol](https://modelcontextprotocol.io). The agent starts `Easyshot --mcp` as a stdio server; it exits when the agent closes the connection. There is no daemon, Dock icon, capture bar or update check in this mode, and stdout carries only protocol JSON.

## Setup

Install Easyshot in `/Applications` and grant Screen Recording once (open the app normally and capture anything). The server runs as its own responsible process, so the Easyshot permission applies, not your terminal's or the agent's.

**Claude Code**

```sh
claude mcp add --scope user easyshot -- /Applications/Easyshot.app/Contents/MacOS/Easyshot --mcp
```

**Codex** (`~/.codex/config.toml`)

```toml
[mcp_servers.easyshot]
command = "/Applications/Easyshot.app/Contents/MacOS/Easyshot"
args = ["--mcp"]
```

**Claude Desktop** (`~/Library/Application Support/Claude/claude_desktop_config.json`)

```json
{
  "mcpServers": {
    "easyshot": {
      "command": "/Applications/Easyshot.app/Contents/MacOS/Easyshot",
      "args": ["--mcp"]
    }
  }
}
```

Other clients that support local stdio servers use the same command and argument.

## Tools

| Tool | Purpose |
| --- | --- |
| `list_displays` | Display ids, frames, native pixel sizes and scale. Needs no permission. |
| `list_windows` | On-screen app windows front to back: `window_id`, app, bundle id, title, frame. Filter with `app`/`title`. |
| `screenshot` | Capture a display, window, area or the active window. Returns the saved file path, pixel size, frame and a downscaled preview image. |
| `ocr` | Text and QR/barcodes from a capture or an image `path`, with a frame for each line. |
| `record_start` | Start an MP4 recording of a display, window, area or the active window. Returns `recording_id`. |
| `record_stop` | Finish a recording; returns its path, duration and size. |
| `upload` | Upload an image to Easyshot Cloud and return its share link (direct-download edition, signed in). With **Check for secrets before uploading** on, an image with detected secrets is refused unless the call passes `redact: true` (black them out) or `allow_secrets: true`. The type is read from the file's bytes, every frame of an animation is checked, and an image that cannot be checked (undecodable, or more than 120 frames) or an animation with findings (which cannot be redacted) is refused unless `allow_secrets: true`. |
| `open_in_editor` | Open an image, recording or `.easyshot.json` project in the Easyshot editor for the user. |

**Coordinates.** All frames and `rect` arguments are global points with the origin at the top left of the main display, the same space as `list_displays` and `list_windows`. A display to the left of the main display has negative `x`. Capture files keep native pixels; `scale` relates the two.

**Targets.** `screenshot`, `ocr` and `record_start` accept `target` (`display`, `window`, `area`, `active_window`) with `display_id`, `window_id`, `app`/`title`, or `rect` `{x, y, width, height}`. When `target` is omitted it is inferred: `rect` means area, `window_id` or `app` means window, otherwise the main display.

**Screenshots.** The full-resolution capture is saved to the Screenshots folder and the Library in the format chosen in Settings; pass `save: false` to skip the file. The preview returned to the agent is JPEG (or `image_format: "png"`) with a long edge of `max_dimension` pixels, default 1568. Window captures omit the shadow and pointer unless `shadow`/`cursor` are true. Nothing touches the clipboard unless `copy` is true.

**OCR.** Line frames are global points for screen targets (`coordinate_space: "screen_points"`), so the centre of a line is a click target, and image pixels for files (`"image_pixels"`). Recognition runs on device with Vision.

**Recording.** Frame rate (`fps`) and pointer (`cursor`) are per call; system audio and microphone follow Easyshot Settings. Recordings stop on `record_stop`, after `max_seconds` (default 300, at most 3600), or when the server exits, and are always finalized. A recording that stopped on its own is still returned by `record_stop`.

## Permissions and errors

Tool failures return `isError: true` with a message the agent can relay. Without Screen Recording access, capture tools ask macOS to show the permission prompt once and report what to enable; restart the server after granting it. A rebuilt ad-hoc development copy is a different app to macOS and needs its own grant.

## Implementation notes

- Requests are processed concurrently; screen enumeration is shared between calls within 250 ms. Window captures use ScreenCaptureKit's still-image API at native resolution; PNG/JPEG encoding of the file and the preview run in parallel off the main thread.
- The server never creates an `NSApplication` and avoids AppKit calls that register with LaunchServices, so `easyshot://` launcher URLs keep reaching a normal capture session while an agent is connected. `open_in_editor` launches that normal session with `easyshot://edit?path=…`.
- Launched by a terminal or agent, `--mcp` respawns itself once with disclaimed responsibility (the mechanism Chromium uses for its helpers), so macOS attributes privacy checks to Easyshot.
