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
import copy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import xml.etree.ElementTree as ET

import make_test_disc

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
REJECT = ["panic", "cannot load the Advanced Content playlist", "not an HD DVD Standard Content disc",
          "buffer too late", "buffer deadlock prevented", "no decoder for", "no vout found"]


def play(vlc, plugins, mrl, timeout, log, gdb=False, extra=()):
    """Plays `mrl`; returns VLC's exit code (None: timed out), its log, and gdb's crash report if any."""
    env = dict(os.environ)
    env.pop("VLC_PLUGIN_PATH", None)
    if plugins:
        env["VLC_PLUGIN_PATH"] = os.path.abspath(plugins)
    cmd = [vlc, "-I", "dummy", "--ignore-config", "--reset-plugins-cache", "--no-media-library",
           "--vout=dummy", "--aout=dummy", "--play-and-exit", "-vv",
           "--file-logging", f"--logfile={log}", "--log-verbose=2", *extra, mrl]
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


def regressions(args, logs):
    source = pathlib.Path(args.discs) / "advanced"
    if not source.is_dir():
        return []
    namespace = make_test_disc.PLAYLIST_NS
    ET.register_namespace("", namespace)

    def tag(name):
        return f"{{{namespace}}}{name}"

    failed = []
    with tempfile.TemporaryDirectory(prefix="hddvd-regressions-") as work:
        root = pathlib.Path(work)
        marker = root / "outside.txt"
        marker.write_text("Synthetic containment marker.\n", encoding="ascii")

        def fixture(name):
            disc = root / name
            shutil.copytree(source, disc)
            playlist = disc / "ADV_OBJ" / "VPLST000.XPL"
            tree = ET.parse(playlist)
            titles = tree.find(tag("TitleSet"))
            first = titles.find(tag("FirstPlayTitle"))
            if first is not None:
                titles.remove(first)
            title = titles.find(tag("Title"))
            title.set("titleDuration", "00:00:02:00")
            for child in list(title):
                if child.tag in (tag("PrimaryAudioVideoClip"), tag("ChapterList")):
                    title.remove(child)
                elif child.tag == tag("ApplicationSegment"):
                    child.set("titleTimeEnd", "00:00:02:00")
            return disc, playlist, tree, title

        def resource(title, uri):
            ET.SubElement(title, tag("TitleResource"), {
                "src": uri, "size": str(marker.stat().st_size), "priority": "1", "multiplexed": "false",
                "titleTimeBegin": "00:00:00:00", "titleTimeEnd": "00:00:02:00",
            })

        def check(name, fixture_data, expected=(), forbidden=(), extra=(), natural_end=True):
            disc, playlist, tree, _ = fixture_data
            tree.write(playlist, encoding="utf-8", xml_declaration=True)
            began = time.monotonic()
            code, text, crash = play(args.vlc, args.plugins, disc_mrl(disc), min(args.timeout, 20),
                                     os.path.join(logs, name + ".log"), args.gdb, extra)
            elapsed = time.monotonic() - began
            required = ["CHAPTERS.XMF: 1 scripts run", *expected]
            if natural_end:
                required.append("playlist ended")
            problems = []
            if code != 0:
                problems.append(f"VLC exit code {code}")
            if natural_end and elapsed < 1.8:
                problems.append(f"two-second title ended early ({elapsed:.2f} s)")
            problems += [f"missing {line!r}" for line in required if line not in text]
            problems += [f"unexpected {line!r}" for line in (*REJECT, *forbidden) if line in text]
            if problems:
                failed.append(name)
                print(f"FAIL {name}: " + "; ".join(problems))
                if crash:
                    print(indent(crash))
            else:
                print(f"ok   {name}")

        check("application-only", fixture("application-only"), expected=("main video: 16x16",))

        case = fixture("application-transition")
        case[3].set("onEnd", "after-app")
        titles = case[2].find(tag("TitleSet"))
        original = ET.parse(source / "ADV_OBJ" / "VPLST000.XPL")
        intro = copy.deepcopy(original.find(tag("TitleSet")).find(tag("FirstPlayTitle")))
        intro.set("titleDuration", "00:00:02:00")
        intro.find(tag("PrimaryAudioVideoClip")).set("titleTimeEnd", "00:00:02:00")
        titles.insert(0, intro)
        outro = copy.deepcopy(intro)
        outro.tag = tag("Title")
        outro.set("titleNumber", "2")
        outro.set("id", "after-app")
        titles.append(outro)
        check("application-transition", case, expected=('title 1 "after-app"', "main video: 16x16"))

        paused_jump_script = """
var playlist = Player.playlist;
var timers = [];
Diagnostics.listeners.add(Diagnostics.listeners.LISTENER_TYPE_DEBUGGER);
Diagnostics.trace.autoFlush = true;
function report(message) {
    Diagnostics.trace.writeLine(message, "paused-jump", Diagnostics.TRACE_LEVEL_INFO);
}
function later(callback) {
    var timer = createTimer("00:00:00:30", TIMER_APPLICATION, callback);
    timer.autoReset = false;
    timer.enabled = true;
    timers.push(timer);
}
function failed(target) {
    report("PAUSED-JUMP-FAIL target=" + target + " actual=" + playlist.currentTitle.elapsedTime + " state=" + playlist.playState);
    playlist.play();
    playlist.stop();
}
function verify(target, next) {
    later(function () {
        if (playlist.playState !== playlist.PLAYSTATE_PAUSE || playlist.currentTitle.elapsedTime !== target) {
            failed(target);
            return;
        }
        later(function () {
            if (playlist.playState !== playlist.PLAYSTATE_PAUSE || playlist.currentTitle.elapsedTime !== target) {
                failed(target);
                return;
            }
            next();
        });
    });
}
later(function () {
    playlist.pause();
    playlist.currentTitle.jump("00:00:03:00", false);
    verify("00:00:03:00", function () {
        playlist.currentTitle.jump("00:00:04:00", false);
        verify("00:00:04:00", function () {
            playlist.play();
            later(function () {
                if (playlist.playState !== playlist.PLAYSTATE_PLAY || playlist.currentTitle.elapsedTime === "00:00:04:00") {
                    failed("resumed");
                    return;
                }
                report("PAUSED-JUMP-OK");
                playlist.stop();
            });
        });
    });
});
"""
        for background in (False, True):
            name = "paused-jump-background" if background else "paused-jump-video"
            case = fixture(name)
            case[3].set("titleDuration", "00:00:08:00")
            case[3].find(tag("ApplicationSegment")).set("titleTimeEnd", "00:00:08:00")
            if not background:
                clip = copy.deepcopy(original.find(tag("TitleSet")).find(tag("Title")).find(tag("PrimaryAudioVideoClip")))
                clip.set("titleTimeEnd", "00:00:08:00")
                case[3].insert(0, clip)
            files = [(name, mime, paused_jump_script if name == "CHAPTERS.JS" else data)
                     for name, mime, data in make_test_disc.app_files(3)]
            (case[0] / "ADV_OBJ" / "CHAPTERS.ACA").write_bytes(make_test_disc.archive(files))
            check(name, case, expected=("PAUSED-JUMP-OK",),
                  forbidden=("PAUSED-JUMP-FAIL", "with an uncaught exception"),
                  extra=("--hddvd-trust-content",), natural_end=False)

        case = fixture("containment")
        resource(case[3], "file:///dvddisc/%2e%2e/outside.txt")
        expected = ["%2e%2e/outside.txt (BadUri)"]
        link = case[0] / "ADV_OBJ" / "outside.txt"
        try:
            link.symlink_to(marker)
        except OSError:
            print("note containment: symlink creation unavailable; encoded traversal is still checked")
        else:
            resource(case[3], "file:///dvddisc/ADV_OBJ/outside.txt")
            expected.append("cannot load file:///dvddisc/ADV_OBJ/outside.txt")
        check("containment", case, expected=expected, forbidden=("loaded file:///dvddisc/%2e%2e/",))

        case = fixture("script-shutdown")
        files = [(name, mime, "while (true) {}" if name == "CHAPTERS.JS" else data)
                 for name, mime, data in make_test_disc.app_files(3)]
        (case[0] / "ADV_OBJ" / "CHAPTERS.ACA").write_bytes(make_test_disc.archive(files))
        check("script-shutdown", case, extra=("--run-time=1",), natural_end=False)

        requests = []

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append(self.path)
                data = marker.read_bytes()
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *unused):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        thread.start()
        try:
            uri = f"http://127.0.0.1:{server.server_port}/outside.txt"
            for trusted in (False, True):
                name = "network-trusted" if trusted else "network-restricted"
                case = fixture(name)
                resource(case[3], uri)
                requests.clear()
                check(name, case, expected=() if trusted else (uri + " (NotPermitted)",),
                      extra=("--hddvd-trust-content",) if trusted else ())
                if bool(requests) != trusted:
                    failed.append(name)
                    print(f"FAIL {name}: HTTP requests {requests!r}")
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
    return failed


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
    failed += regressions(args, logs)
    print(f"logs in {logs}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
