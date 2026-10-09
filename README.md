# vlc-hddvd

[![CI](https://github.com/chubiduwa/vlc-hddvd/actions/workflows/ci.yml/badge.svg)](https://github.com/chubiduwa/vlc-hddvd/actions/workflows/ci.yml)

An HD DVD plugin for VLC 3.0.

## What it supports

- **HD DVD Standard Content** (`HVDVD_TS`): menus, buttons, still frames and interactive titles, with the disc's
  own navigation logic.
- **Disc images** (`.iso`) read directly, or a folder holding a disc (a mounted disc, or a copy of one).
- **HD DVD sub-pictures and button highlights.**
- **VLC controls:** arrow keys, Enter and the mouse for buttons; the disc-menu key; Playback > Title and Chapter.

Not supported yet:

- Advanced Content
- angles on interleaved cells

Not going to be supported:

- encrypted (AACS) discs
- physical drives (unless already unencrypted already)

## Install

Download the zip for your VLC from the [latest release](https://github.com/chubiduwa/vlc-hddvd/releases/latest).
It needs VLC 3.0, 64-bit.

| VLC | Zip |
|---|---|
| macOS, Apple silicon (the arm64 or universal VLC) | `hddvd-macos-aarch64.zip` |
| macOS, Intel | `hddvd-macos-x86_64.zip` |
| Windows, 64-bit | `hddvd-windows-x86_64.zip` |
| Linux, x86_64 | `hddvd-linux-x86_64.zip` |
| Linux, arm64 | `hddvd-linux-aarch64.zip` |

Each zip holds one file, the plugin.

### macOS

Unzip it into a folder of its own, and let VLC find it through `VLC_PLUGIN_PATH`. Don't copy it into VLC.app,
which would break the app's signature.

```sh
mkdir -p ~/vlc-hddvd && cd ~/vlc-hddvd
curl -LO https://github.com/chubiduwa/vlc-hddvd/releases/latest/download/hddvd-macos-aarch64.zip  # or -x86_64
unzip hddvd-macos-aarch64.zip
xattr -d com.apple.quarantine libhddvd_plugin.dylib 2>/dev/null  # only needed if downloaded with a browser

VLC_PLUGIN_PATH=~/vlc-hddvd /Applications/VLC.app/Contents/MacOS/VLC --reset-plugins-cache "hddvd:///path/to/Disc.iso"
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
mkdir -p ~/vlc-hddvd && cd ~/vlc-hddvd
curl -LO https://github.com/chubiduwa/vlc-hddvd/releases/latest/download/hddvd-linux-x86_64.zip  # or -aarch64
unzip hddvd-linux-x86_64.zip

VLC_PLUGIN_PATH=~/vlc-hddvd vlc --reset-plugins-cache "hddvd:///path/to/Disc.iso"
```

## Play

Open the disc with the `hddvd://` scheme (URL-encode the path: `'` → `%27`, space → `%20`). The disc can be an
`.iso` file or a folder:

```sh
vlc "hddvd:///path/to/Bob%27s%20Disc.iso"
vlc "hddvd:///Volumes/DISC"
vlc "hddvd:///C:/Discs/Disc.iso"          # Windows
```

On Windows you can also use Media > Open Network Stream with the same `hddvd:///…` address.

Append `#title[:chapter]` to start at a title, e.g. `hddvd:///path/to/Disc.iso#21`.

| Action | macOS | Windows / Linux |
|---|---|---|
| Move between buttons | Arrow keys | Arrow keys |
| Press a button | Enter, or click | Enter, or click |
| Disc menu | Ctrl+M | Shift+M |
| Previous / next chapter | Ctrl+U / Ctrl+D | Shift+P / Shift+N |

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

## License

LGPL 2.1 or later.
