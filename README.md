# vlc-hddvd

[![CI](https://github.com/chubiduwa/vlc-hddvd/actions/workflows/ci.yml/badge.svg)](https://github.com/chubiduwa/vlc-hddvd/actions/workflows/ci.yml)

An HD DVD plugin for VLC 3.0.

## What it supports

- **HD DVD Standard Content** (`HVDVD_TS`): menus, buttons, still frames and interactive titles, with the disc's
  own navigation logic.
- **HD DVD Advanced Content** (HDi, `ADV_OBJ`): the disc's pop-up menus and applications (scripts, animations,
  menu sounds, bookmarks for the session, games), picture-in-picture and commentary audio, every title,
  chapter, audio and subtitle track.
- **Disc images** (`.iso`) read directly, or a folder holding a disc (a mounted disc, or a copy of one).
- **Encrypted (AACS) discs**, with a key database (`KEYDB.cfg`) that has the disc's key: see [Encrypted discs](#encrypted-discs).
- **VLC controls:** arrow keys, Enter and the mouse for buttons; the disc-menu key; Playback > Title and Chapter.

Not supported yet:

- Advanced Content: network features, Advanced Subtitles, switching to Standard Content, bookmarks kept after
  closing VLC
- Full list: [spec coverage](#spec-coverage)

Not going to be supported:

- physical drives (unless the disc is unencrypted)

## Install

Download the zip for your VLC from the [latest release](https://github.com/chubiduwa/vlc-hddvd/releases/latest).
It needs VLC 3.0, 64-bit.

| VLC | Zip |
|---|---|
| macOS, Apple Silicon (M chips) | [`hddvd-macos-aarch64.zip`](https://github.com/chubiduwa/vlc-hddvd/releases/latest/download/hddvd-macos-aarch64.zip) |
| macOS, Intel | [`hddvd-macos-x86_64.zip`](https://github.com/chubiduwa/vlc-hddvd/releases/latest/download/hddvd-macos-x86_64.zip) |
| Windows, 64-bit | [`hddvd-windows-x86_64.zip`](https://github.com/chubiduwa/vlc-hddvd/releases/latest/download/hddvd-windows-x86_64.zip) |
| Linux, x86_64 | [`hddvd-linux-x86_64.zip`](https://github.com/chubiduwa/vlc-hddvd/releases/latest/download/hddvd-linux-x86_64.zip) |
| Linux, arm64 | [`hddvd-linux-aarch64.zip`](https://github.com/chubiduwa/vlc-hddvd/releases/latest/download/hddvd-linux-aarch64.zip) |

Each zip holds one file, the plugin.

### macOS

Unzip it into a folder of its own, and let VLC find it through `VLC_PLUGIN_PATH`. Don't copy it into VLC.app,
which would break the app's signature.

```sh
# Install
mkdir -p ~/vlc-hddvd && cd ~/vlc-hddvd
curl -LO https://github.com/chubiduwa/vlc-hddvd/releases/latest/download/hddvd-macos-aarch64.zip  # or -x86_64
unzip hddvd-macos-aarch64.zip
xattr -d com.apple.quarantine libhddvd_plugin.dylib 2>/dev/null  # only needed if downloaded with a browser

# Running
VLC_PLUGIN_PATH="$HOME/vlc-hddvd" /Applications/VLC.app/Contents/MacOS/VLC --reset-plugins-cache "hddvd:///path/to/Disc.iso"
```

VLC only sees the plugin when started this way, from a terminal, not from the Dock or Finder.

### Windows

Unzip `libhddvd_plugin.dll` into VLC's `plugins\access\` folder (usually
`C:\Program Files\VideoLAN\VLC\plugins\access\`). Then, once, from a command prompt:

```bat
"C:\Program Files\VideoLAN\VLC\vlc.exe" --reset-plugins-cache
```

After that, VLC finds the plugin however it is started.

### Linux

This works with the distribution's VLC, not the Snap or Flatpak versions:

```sh
# Install
mkdir -p ~/vlc-hddvd && cd ~/vlc-hddvd
curl -LO https://github.com/chubiduwa/vlc-hddvd/releases/latest/download/hddvd-linux-x86_64.zip  # or -aarch64
unzip hddvd-linux-x86_64.zip

# Running
VLC_PLUGIN_PATH="$HOME/vlc-hddvd" vlc --reset-plugins-cache "hddvd:///path/to/Disc.iso"
```

## Play

An HD DVD `.iso` opens like any other file (File > Open, drag and drop, or `vlc /path/to/Disc.iso`).

A folder (a mounted disc, or a copy of one) needs the `hddvd://` scheme, which also works for `.iso` files
(URL-encode the path: `'` → `%27`, space → `%20`):

```sh
vlc "hddvd:///Volumes/DISC"
vlc "hddvd:///path/to/Bob%27s%20Disc.iso"
vlc "hddvd:///C:/Discs/Disc.iso"          # Windows
```

From the GUI, use Media > Open Network Stream with the `hddvd:///…` address.

Append `#title[:chapter]` to start at a title, e.g. `hddvd:///path/to/Disc.iso#21`.

Note: mouse interaction can be enabled/disabled by discs themselves and might not work consistently like DVDs

| Action | macOS | Windows / Linux |
|---|---|---|
| Move between buttons | Arrow keys | Arrow keys |
| Press a button | Enter | Enter |
| Disc menu | Ctrl+M | Shift+M |
| Back / cancel (interactive menus) | Delete (⌫) | Backspace |
| Remote's number keys (e.g. text entry in games) | 0–9 | 0–9 |
| Remote's A / B / C / D buttons (used by some discs, e.g. zoom, bookmark) | Shift+F1–F4 | Shift+F1–F4 |
| Pause (some discs, e.g. games, open their options instead) | Space | Space |
| Previous / next chapter (discs may use them, e.g. to leave a commentary) | Ctrl+U / Ctrl+D | Shift+P / Shift+N |
| Previous / next title | Ctrl+P / Ctrl+N | Shift+O / Shift+B |

### Encrypted discs

Encrypted (AACS) discs need the disc's key in a key database, [`KEYDB.cfg`](https://github.com/chubiduwa/hd-dvd-key-db) (the libaacs format: one line per
disc, `<disc ID> = <title> | V | <volume unique key>`). The plugin looks for it where libaacs does:

**NOTE**: should work with real discs but only if its disc ID is present in `KEYDB.cfg`, there are ways to find the VUK for your physical disc (not referencing the methods here) and add it to `KEYDB.cfg` yourself.

| System | Location |
|---|---|
| macOS | `~/Library/Preferences/aacs/KEYDB.cfg` or `~/.config/aacs/KEYDB.cfg` |
| Windows | `%APPDATA%\aacs\KEYDB.cfg` |
| Linux | `~/.config/aacs/KEYDB.cfg` |

Or set its path with `--hddvd-keydb=/path/to/KEYDB.cfg`. When the key is missing, VLC shows an error naming the disc ID to look for.

### Content trust

Advanced Content is untrusted by default. Resources are limited to the disc and File Cache; network downloads,
session storage and script diagnostics are disabled, and playlists requesting a streaming buffer are rejected.
Only for content you trust, add `--hddvd-trust-content` to allow those operations. Storage still lasts only
until VLC closes, and script network APIs still report an offline player.

Disc signatures are not verified. This policy is not a complete Annex X sandbox.

## Build

Build it (needs [Zig](https://ziglang.org) 0.17 and the VLC 3.0 plugin SDK, the `sdk` folder of VLC's Windows
`.7z` package; its headers serve every platform):

```sh
zig build --prefix zig-out/macos -Dvlc-sdk=/path/to/vlc-3.0.x/sdk -Dtarget=aarch64-macos       # macOS (Apple silicon)
zig build --prefix zig-out/macos -Dvlc-sdk=/path/to/vlc-3.0.x/sdk -Dtarget=x86_64-macos        # macOS (Intel)
zig build --prefix zig-out/win64 -Dvlc-sdk=/path/to/vlc-3.0.x/sdk -Dtarget=x86_64-windows-gnu  # Windows
zig build --prefix zig-out/linux -Dvlc-sdk=/path/to/vlc-3.0.x/sdk -Dtarget=x86_64-linux-gnu \
  -Dvlc-lib=/usr/lib/x86_64-linux-gnu                                                         # Linux (x86_64)
zig build --prefix zig-out/linux -Dvlc-sdk=/path/to/vlc-3.0.x/sdk -Dtarget=aarch64-linux-gnu \
  -Dvlc-lib=/usr/lib/aarch64-linux-gnu                                                        # Linux (arm64)
zig build test                                                                                # unit tests
```

macOS links against `/Applications/VLC.app` (`-Dvlc-app=` for another copy; an Intel build needs the universal
or Intel VLC). Linux links against the system's `libvlccore.so` (Debian/Ubuntu: `libvlccore-dev`); `-Dvlc-lib` is
the folder holding it. It also needs ALSA (`libasound2-dev`): `-Dalsa-include=` names a folder holding the `alsa`
headers folder (a link to `/usr/include/alsa`; not `/usr/include` itself, which would hide Zig's libc headers).

The plugin lands in `zig-out/<platform>/lib` (`bin` on Windows); install it as in [Install](#install), with that
folder as `VLC_PLUGIN_PATH`.

The [CI workflow](.github/workflows/ci.yml) runs the tests and builds every platform on each push; the plugins
are attached to each run as artifacts.

## Reference

Based on HD-DVD spec from: https://github.com/amp64/hddvd-docs

## Spec coverage

What the plugin does not implement yet, by part of the HD DVD specification. The rest of the navigation,
markup, timing and script APIs is implemented; a few details (such as some exception types) may still differ,
and where discs rely on a different behaviour than the spec describes, the plugin follows the discs.

Advanced Content (HDi):

- Network: HTTP requests, network data sources, streamed secondary video and cookies (Annex Y). Scripts see an
  offline player.
- Advanced Subtitles.
- Playing Standard Content from Advanced Content (`StandardContentPlayer.play` does nothing).
- Secondary video played from a file by script (`SecondaryVideoPlayer.play`), and clips with `sync="none"`.
- Persistent storage is kept only until VLC closes.
- Trick play: fast forward, fast reverse, slow motion and frame stepping (the API reports them as unsupported).
- Video capture (`MainVideo.capture`) and image scaling (`changeImageSize`).
- The markup audio object (`audio/x-wav` objects in a page).
- Full Restricted Mode (Annex X), including signature authentication and read-only arbitrary XML documents.
  Resource and storage access is restricted by default; see [Content trust](#content-trust).

Standard Content:

- Sub-picture colour changes within a unit (CHG_COLCON, used by karaoke-style subtitles); 8-bit sub-pictures are
  untested.
- Navigation timers (SPRM 9/10), counter-mode GPRMs, parental blocks, random and shuffle playback (played in
  order).
- Button groups other than the first, display-type selection, and some highlight modes (HLI_SS 2/3; 10/11 are
  treated as new highlights).
- Audio and subtitle stream selection by the disc's commands (VLC chooses the streams).
- Angles in interleaved cells.
- Resuming a menu call mid-cell (it resumes at the start of the cell).

Decryption (AACS):

- Segment and sequence keys, and audio-only title keys (no known disc uses them).
- Keys from a drive or device keys: a key database (`KEYDB.cfg`) is required.
- Recordable discs (UDF VAT or sparable partitions).

### Differences from the spec

Where discs were authored against players that behave differently from the specification, the plugin follows
the discs:

- `Chapter.number`, and the chapter event's `oldValue`/`newValue`, count from 0 (the chapter's index in
  `Title.chapters`). The spec numbers chapters from 1.
- An application's scripts run as one program, in manifest order, rather than as separate scripts: a script may
  use a variable that a later one declares.
- An explicit `navUp`/`navDown`/… of `none` blocks that direction; the spec treats `none` like an unset value.
- `getProperty("backgroundImage")` returns absolute URIs, not the URI as written.
- `changeLayout`'s crop rectangle applies to the scaled video.
- Scripts may use `arguments` and `caller` on functions, which older script engines provided.
- Playlists and markup are parsed leniently (for example integers where the spec has booleans).
- Boolean arguments of DOM methods (`useCapture`, `deep`…) default to false when missing; the spec's argument
  rules would throw.
- `document.createElement` on a page creates an element in the page's namespace, so it is laid out.
- A scheduled event exactly at the time a jump or a title starts from does not fire (discs resume at the time an
  event fired and would get it again); one at 00:00:00:00 fires when a title starts from its beginning.
- A title's first track events go only to the applications running before the title began.
- An `application_end` sent because the title ended or a jump left it cannot be cancelled: the title has already
  changed.
- `dispatchEvent` always returns true: events reach each application later, as queued work items.

## License

LGPL 2.1 or later.
