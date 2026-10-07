# vlc-hddvd

An HD DVD plugin for VLC 3.0.

## What it supports

- **HD DVD Standard Content** (`HVDVD_TS`): menus, buttons, still frames and interactive titles, with the disc's
  own navigation logic.
- **Disc images** (`.iso`) read directly, or a folder holding a disc (a mounted disc, or a copy of one).
- **HD DVD sub-pictures and button highlights.**
- **VLC controls:** arrow keys, Enter and the mouse for buttons; the disc-menu key; Playback > Title and Chapter.

Not supported yet: Advanced Content (most later discs), encrypted (AACS) discs, physical drives, and angles on
interleaved cells. Tested on macOS; Windows builds but is untested.

## Install

Build it (needs [Zig](https://ziglang.org) 0.17 and the VLC 3.0 plugin SDK):

```sh
zig build --prefix zig-out/macos -Dvlc-sdk=/path/to/vlc-3.0.x/sdk -Dtarget=aarch64-macos       # macOS (Apple silicon)
zig build --prefix zig-out/macos -Dvlc-sdk=/path/to/vlc-3.0.x/sdk -Dtarget=x86_64-macos        # macOS (Intel)
zig build --prefix zig-out/win64 -Dvlc-sdk=/path/to/vlc-3.0.x/sdk -Dtarget=x86_64-windows-gnu  # Windows
```

Then point VLC at the plugin folder, or copy the plugin into VLC's `plugins/access/` folder (Windows):

```sh
export VLC_PLUGIN_PATH=$PWD/zig-out/macos/lib
```

## Play

Open the disc with the `hddvd://` scheme (URL-encode the path: `'` → `%27`, space → `%20`):

```sh
/Applications/VLC.app/Contents/MacOS/VLC --reset-plugins-cache "hddvd:///path/to/Disc.iso"
vlc "hddvd:///Volumes/DISC"
```

Append `#title[:chapter]` to start at a title, e.g. `hddvd:///path/to/Disc.iso#21`.

| Action | macOS | Windows / Linux |
|---|---|---|
| Move between buttons | Arrow keys | Arrow keys |
| Press a button | Enter, or click | Enter, or click |
| Disc menu | Ctrl+M | Shift+M |
| Previous / next chapter | Ctrl+U / Ctrl+D | Shift+P / Shift+N |

## License

LGPL 2.1 or later.
