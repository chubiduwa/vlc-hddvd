#!/usr/bin/env python3
"""Plays the discs made by make_test_disc.py in headless VLC with this plugin, and checks that each plays to
its end: VLC exits by itself, cleanly, and its log shows the plugin went through the disc.

    tools/vlc_disc_test.py --vlc VLC --plugins DIR DISCS [--timeout S] [--keep-logs DIR]

VLC is the VLC executable (vlc.exe, VLC.app/Contents/MacOS/VLC, vlc); DIR holds the built plugin; DISCS is the
folder make_test_disc.py wrote (its standard/ and advanced/ discs are played, whichever exist). Exits non-zero
if any disc fails, printing the end of its log.

First an EVOB of the advanced disc is played as a plain file without the plugin: if VLC itself exits with an
error that way (some builds crash at exit), the same exit code from a disc is only reported, not a failure.
--gdb runs VLC under gdb and prints the backtrace of a crash.
"""
import argparse
import os
import pathlib
import subprocess
import sys
import tempfile

# Log lines each disc must produce, in any order.
EXPECT = {
    "standard": [
        "HD DVD: 2 titles, 1 title sets, first play yes",
        "cell: tt VTS 1 PGC 2 PG 3 cell 3",  # the feature's last chapter
        "VM stopped",
    ],
    "advanced": [
        'HD DVD Advanced Content: "',
        'title 0 "feature" at frame 0',
        "CHAPTERS.XMF: 1 scripts run",
        "playlist ended",
    ],
}
# Log lines that fail a disc.
REJECT = ["panic", "cannot load the Advanced Content playlist", "not an HD DVD Standard Content disc"]


def play(vlc, plugins, mrl, timeout, log, gdb=False):
    """Plays `mrl`; returns VLC's exit code (None: timed out), its log, and gdb's crash report if any."""
    env = dict(os.environ)
    env.pop("VLC_PLUGIN_PATH", None)
    if plugins:
        env["VLC_PLUGIN_PATH"] = os.path.abspath(plugins)
    cmd = [vlc, "-I", "dummy", "--ignore-config", "--reset-plugins-cache", "--no-media-library",
           "--vout=dummy", "--aout=dummy", "--play-and-exit", "-vv",
           "--file-logging", f"--logfile={log}", "--log-verbose=2", mrl]
    if gdb:
        cmd = ["gdb", "-q", "-batch", "-return-child-result", "-ex", "set pagination off", "-ex", "run",
               "-ex", "info sharedlibrary", "-ex", "thread apply all bt 40", "--args"] + cmd
    try:
        r = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        code, out = r.returncode, r.stdout.decode(errors="replace")
    except subprocess.TimeoutExpired as e:
        code, out = None, (e.stdout or b"").decode(errors="replace")
    try:
        with open(log, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        text = ""
    crash = ""
    if gdb and "received signal" in out:
        crash = out[out.index("received signal") - 40:] if out.index("received signal") >= 40 else out
        if code == 0:
            code = -1  # gdb exits normally after a crash in batch mode
    return code, text or out, crash


def disc_mrl(disc):
    return "hddvd:" + pathlib.Path(disc).resolve().as_uri()[len("file:"):]


def indent(text):
    return "\n".join("  " + l for l in text.splitlines())


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("discs")
    ap.add_argument("--vlc", required=True)
    ap.add_argument("--plugins", required=True)
    ap.add_argument("--timeout", type=float, default=150)
    ap.add_argument("--keep-logs", help="folder to keep the VLC logs in")
    ap.add_argument("--gdb", action="store_true", help="run VLC under gdb; print a crash's backtrace")
    args = ap.parse_args()

    kinds = [k for k in EXPECT if os.path.isdir(os.path.join(args.discs, k))]
    if not kinds:
        sys.exit(f"vlc_disc_test: no standard/ or advanced/ disc in {args.discs}")
    logs = args.keep_logs or tempfile.mkdtemp(prefix="vlc_disc_test")
    os.makedirs(logs, exist_ok=True)

    base_code = None
    evo = os.path.join(args.discs, "advanced", "HVDVD_TS", "INTRO.EVO")
    if os.path.exists(evo):
        base_code, _, base_crash = play(args.vlc, None, pathlib.Path(evo).resolve().as_uri(), args.timeout,
                                        os.path.join(logs, "baseline.log"), args.gdb)
        print(f"baseline (an EVOB as a plain file, no plugin): VLC exit code {base_code}")
        if base_crash:
            print(indent(base_crash))

    failed = []
    for k in kinds:
        log = os.path.join(logs, f"{k}.log")
        code, text, crash = play(args.vlc, args.plugins, disc_mrl(os.path.join(args.discs, k)), args.timeout, log,
                                 args.gdb)
        problems = []
        notes = []
        if code is None:
            problems.append(f"VLC did not exit within {args.timeout:.0f} s (hang)")
        elif code != 0 and code == base_code:
            notes.append(f"VLC exited with code {code}, as without the plugin")
        elif code != 0:
            problems.append(f"VLC exited with code {code} ({code & 0xFFFFFFFF:#x})")
        problems += [f"missing from the log: {e!r}" for e in EXPECT[k] if e not in text]
        problems += [f"in the log: {r!r}" for r in REJECT if r in text]
        if problems:
            failed.append(k)
            print(f"FAIL {k}:")
            for p in problems:
                print(f"  {p}")
            lines = [l for l in text.splitlines() if "hddvd" in l or "error" in l]
            print("  --- last plugin and error lines of the log ---")
            for l in lines[-60:]:
                print(f"  {l}")
        else:
            print(f"ok   {k}" + "".join(f" ({n})" for n in notes))
        if crash:
            print(f"  --- gdb ---")
            print(indent(crash))
    print(f"logs in {logs}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
