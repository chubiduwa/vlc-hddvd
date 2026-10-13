#!/usr/bin/env python3
"""Makes synthetic HD DVD discs, as folders, for testing the plugin in VLC.

    tools/make_test_disc.py OUT [--chapters N] [--chapter-seconds S] [--intro-seconds S] [--only KIND]

OUT/standard is a Standard Content disc (HVDVD_TS with IFOs): First Play jumps to title 1, the intro, whose
post command jumps to title 2, the feature, one cell and one chapter per chapter. Playback stops at its end.

OUT/advanced is an Advanced Content disc (ADV_OBJ with a playlist, HVDVD_TS with the VTI, time maps and EVOBs):
the FirstPlayTitle plays the intro, then title 1, the feature, with a chapter list. An application draws a bar
with one button per chapter and highlights the chapter playing; Enter on a button jumps to that chapter.

The video is ffmpeg's: MPEG-2 1920x1080 at 29.97 interlaced, a colour per chapter with its name ("Intro",
"Chapter 1", ...) and a running time code, in 15-frame closed GOPs (one EVOBU each). The audio is AC-3 stereo
at 48 kHz, a tone per chapter, in private stream 1 (sub_stream_id 0xC0). This script multiplexes them into
EVOBs itself, with the navigation pack (GCI, PCI, DSI) at the start of every EVOBU, and writes the navigation
files from the EVOBUs it made. Everything is generated; nothing comes from a real disc.

Needs Python 3.9+ and ffmpeg (with the drawtext filter for the captions; without it, or without a font, the
video has colours only). --font picks the font; otherwise a common system font is used.
"""
import argparse
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

SECTOR = 2048
FRAME_90K = 3003  # one 29.97 Hz frame in 90 kHz ticks
GOP = 15  # frames per EVOBU
FPS = (30000, 1001)
AC3_FRAME_90K = 2880  # 1536 samples at 48 kHz
# The first frame's presentation time in each EVOB, and how far the SCR runs ahead of the data's DTS.
START_PTM = 30030
SCR_LEAD = 27000
# 30.24 Mbit/s, the maximum HD DVD rate, in units of 50 bytes/s: each pack takes ~49 ticks.
MUX_RATE = 75600
PACK_TICKS = SECTOR * 90000 // (MUX_RATE * 50) + 1

COLOURS = ["0x203a60", "0x6a2a2a", "0x2a6a3a", "0x5a3a7a", "0x6a5a20", "0x206060", "0x704a30", "0x404040"]
FONTS = [
    "/System/Library/Fonts/Supplementary/Arial.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
    "/Library/Fonts/Arial.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    "C:/Windows/Fonts/arial.ttf",
]


def fail(msg):
    print(f"make_test_disc: {msg}", file=sys.stderr)
    sys.exit(1)


# ---- encoding ------------------------------------------------------------------------------------------------


class Segment:
    """A run of the title in one colour, caption and tone: the intro, or one chapter."""

    def __init__(self, label, gops, colour, tone):
        self.label, self.gops, self.colour, self.tone = label, gops, colour, tone

    @property
    def frames(self):
        return self.gops * GOP


def has_drawtext(ffmpeg):
    out = subprocess.run([ffmpeg, "-hide_banner", "-filters"], capture_output=True, text=True).stdout
    return any(line.split()[1:2] == ["drawtext"] for line in out.splitlines() if line.strip())


def encode(ffmpeg, segments, font, work, name):
    """Encodes the segments into one MPEG-2 video and one AC-3 elementary stream; returns their bytes."""
    rate = f"{FPS[0]}/{FPS[1]}"
    total = sum(s.frames for s in segments)
    graph = []
    for i, s in enumerate(segments):
        v = f"color=c={s.colour}:s=1920x1080:r={rate},trim=end_frame={s.frames},setpts=PTS-STARTPTS"
        if font:
            v += (f",drawtext=fontfile={font}:text='{s.label}':fontsize=144:fontcolor=white"
                  ":x=(w-text_w)/2:y=(h-text_h)/2-60")
        graph.append(f"{v}[v{i}]")
        secs = s.frames * FPS[1] / FPS[0] + 0.2  # trimmed to the video's length when multiplexed
        graph.append(f"sine=frequency={s.tone}:sample_rate=48000:duration={secs:.3f},"
                     f"aformat=channel_layouts=stereo[a{i}]")
    n = len(segments)
    graph.append("".join(f"[v{i}]" for i in range(n)) + f"concat=n={n}:v=1:a=0,fps={rate}[vc]")
    if font:
        graph.append(f"[vc]drawtext=fontfile={font}:text='%{{pts\\:hms}}':fontsize=64:fontcolor=white"
                     ":x=(w-text_w)/2:y=h-200[v]")
    else:
        graph.append("[vc]null[v]")
    graph.append("".join(f"[a{i}]" for i in range(n)) + f"concat=n={n}:v=0:a=1[a]")
    m2v, ac3 = name + ".m2v", name + ".ac3"
    cmd = [
        ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-filter_complex", ";".join(graph),
        "-map", "[v]", "-frames:v", str(total), "-c:v", "mpeg2video", "-pix_fmt", "yuv420p",
        "-b:v", "4M", "-maxrate", "15M", "-bufsize", "9781248", "-g", str(GOP), "-bf", "2",
        "-sc_threshold", "1000000000", "-flags", "+cgop+ilme+ildct", "-mpv_flags", "+strict_gop", "-top", "1", "-aspect", "16:9",
        "-f", "mpeg2video", m2v,
        "-map", "[a]", "-c:a", "ac3", "-b:a", "192k", "-f", "ac3", ac3,
    ]
    r = subprocess.run(cmd, capture_output=True, text=True, cwd=work)
    if r.returncode != 0:
        fail(f"ffmpeg failed:\n{r.stderr}")
    with open(os.path.join(work, m2v), "rb") as f:
        video = f.read()
    with open(os.path.join(work, ac3), "rb") as f:
        audio = f.read()
    return video, audio


# ---- elementary streams --------------------------------------------------------------------------------------


class Picture:
    def __init__(self, data, kind, tref):
        self.data, self.kind, self.tref = data, kind, tref  # kind: 1 I, 2 P, 3 B
        self.pts = self.dts = 0


def start_codes(b):
    i = b.find(b"\x00\x00\x01")
    while i >= 0 and i + 3 < len(b):
        yield i, b[i + 3]
        i = b.find(b"\x00\x00\x01", i + 3)


def parse_m2v(b):
    """Splits an MPEG-2 video stream into GOPs of pictures in decode order, each picture with the headers that
    precede it; every GOP starts with a sequence header."""
    units = []  # (offset, code)
    for off, code in start_codes(b):
        if code in (0xB3, 0xB8, 0x00, 0xB7):
            units.append((off, code))
    pics = []
    cur_start = 0
    seen_pic = False
    pic_hdr = None
    for off, code in units:
        if code == 0xB7:
            continue
        if seen_pic and code in (0xB3, 0xB8, 0x00):
            pics.append((cur_start, off, pic_hdr))
            cur_start, seen_pic = off, False
        if code == 0x00:
            seen_pic, pic_hdr = True, off
    pics.append((cur_start, len(b), pic_hdr))

    seq = None
    gops = []
    for s, e, h in pics:
        data = b[s:e]
        tref = (b[h + 4] << 2) | (b[h + 5] >> 6)
        kind = (b[h + 5] >> 3) & 7
        if data.startswith(b"\x00\x00\x01\xb3"):
            seq = data[:data.find(b"\x00\x00\x01\xb8")]
        if b"\x00\x00\x01\xb8" in data[: h - s + 4]:
            if not data.startswith(b"\x00\x00\x01\xb3"):
                if seq is None:
                    fail("the video has no sequence header")
                data = seq + data
            gops.append([])
        if not gops:
            fail("the video does not start with a GOP")
        gops[-1].append(Picture(data, kind, tref))
    for g in gops:
        if len(g) != GOP or g[0].kind != 1:
            fail(f"ffmpeg made a GOP of {len(g)} pictures starting with type {g[0].kind}; expected {GOP}, I first")
    return gops


def time_pictures(gops):
    """Presentation and decoding times: display order from the temporal references, one frame of decoding
    delay."""
    n = 0
    for g in gops:
        base = START_PTM + n * FRAME_90K
        for p in g:
            p.pts = base + p.tref * FRAME_90K
        n += len(g)
    i = 0
    for g in gops:
        for p in g:
            p.dts = START_PTM + (i - 1) * FRAME_90K
            i += 1


AC3_KBPS = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640]


def parse_ac3(b, frames_90k_end):
    """AC-3 frames (48 kHz) with their presentation times, up to the end of the video."""
    out = []
    i = 0
    t = START_PTM
    while i + 5 <= len(b) and t < frames_90k_end:
        if b[i:i + 2] != b"\x0b\x77":
            fail("bad AC-3 sync")
        fscod, frmsizecod = b[i + 4] >> 6, b[i + 4] & 0x3F
        if fscod != 0:
            fail("the AC-3 audio is not 48 kHz")
        size = AC3_KBPS[frmsizecod >> 1] * 4
        out.append((t, b[i:i + size]))
        i += size
        t += AC3_FRAME_90K
    return out


# ---- packs ---------------------------------------------------------------------------------------------------


def pack_header(scr):
    ext = 0
    return bytes([
        0, 0, 1, 0xBA,
        0x44 | ((scr >> 27) & 0x38) | ((scr >> 28) & 0x03),
        (scr >> 20) & 0xFF,
        0x04 | ((scr >> 12) & 0xF8) | ((scr >> 13) & 0x03),
        (scr >> 5) & 0xFF,
        0x04 | ((scr << 3) & 0xF8) | ((ext >> 7) & 0x03),
        ((ext << 1) & 0xFE) | 1,
        (MUX_RATE >> 14) & 0xFF, (MUX_RATE >> 6) & 0xFF, ((MUX_RATE << 2) & 0xFC) | 3,
        0xF8,
    ])


def ts_bytes(prefix, ts):
    return bytes([
        (prefix << 4) | ((ts >> 29) & 0x0E) | 1,
        (ts >> 22) & 0xFF,
        ((ts >> 14) & 0xFE) | 1,
        (ts >> 7) & 0xFF,
        ((ts << 1) & 0xFE) | 1,
    ])


def pes(sid, payload, pts=None, dts=None, stuffing=0, aligned=False):
    hdr = b""
    flags = 0
    if pts is not None:
        if dts is not None and dts != pts:
            hdr, flags = ts_bytes(3, pts) + ts_bytes(1, dts), 0xC0
        else:
            hdr, flags = ts_bytes(2, pts), 0x80
    hdr += b"\xff" * stuffing
    body = bytes([0x81 | (0x04 if aligned else 0), flags, len(hdr)]) + hdr + payload
    return b"\x00\x00\x01" + bytes([sid]) + struct.pack(">H", len(body)) + body


def pes_overhead(pts, dts):
    if pts is None:
        return 9
    return 9 + (10 if dts is not None and dts != pts else 5)


def fill_pack(scr, packet):
    """A pack with one PES packet, padded to a sector."""
    room = SECTOR - 14
    gap = room - len(packet)
    assert gap >= 0
    if gap >= 6:
        packet += b"\x00\x00\x01\xbe" + struct.pack(">H", gap - 6) + b"\xff" * (gap - 6)
    elif gap:
        raise AssertionError("gaps under 6 bytes are stuffed in the PES header")
    return pack_header(scr) + packet


def payload_packs(sid, data, starts, prefix=None):
    """Cuts an elementary stream run into PES packets that each fill a pack. `starts` lists (offset, pts, dts)
    of the access units in `data`; a packet carries the times of the first unit starting in it. With `prefix`
    (a function of the packet's units), private stream 1's sub-stream header goes before the payload.
    Returns [(packet bytes, decoding time, end of its payload in `data`)]."""
    room = SECTOR - 14
    out = []
    pos = 0
    k = 0  # next unit not yet started
    last_t = starts[0][2] if starts[0][2] is not None else starts[0][1]
    pre = 4 if prefix else 0
    while pos < len(data):
        # With a time stamp: does a unit start in the payload?
        u = starts[k] if k < len(starts) else None
        with_ts = room - pes_overhead(u[1], u[2]) - pre if u else 0
        if u and u[0] < pos + with_ts:
            n = min(with_ts, len(data) - pos)
            pts, dts = u[1], u[2]
        else:
            n = min(room - 9 - pre, len(data) - pos)
            if u and u[0] < pos + n:
                n = u[0] - pos  # end just before the unit, whose packet will carry its time
            pts = dts = None
        first = k
        while k < len(starts) and starts[k][0] < pos + n:
            k += 1
        units = starts[first:k]
        payload = (prefix(units, pos) if prefix else b"") + data[pos:pos + n]
        header = pes_overhead(pts, dts)
        gap = room - header - len(payload)
        stuffing = gap if 0 < gap < 6 else 0
        pkt = pes(sid, payload, pts, dts, stuffing, aligned=bool(units) and units[0][0] == pos)
        if pts is not None:
            last_t = dts if dts is not None else pts
        pos += n
        out.append((pkt, last_t, pos))
    return out


def bcd_time(frames):
    """BCD "hh mm ss ff" with the 30 (29.97) fps flags (011)."""
    s, f = divmod(frames, 30)
    m, s = divmod(s, 60)
    h, m = divmod(m, 60)
    bcd = lambda v: ((v // 10) << 4) | (v % 10)
    return bytes([bcd(h), bcd(m), 0x80 | bcd(s), 0x80 | bcd(f)])


class Evobu:
    def __init__(self, lbn, packs, first_ref, s_ptm, frames, cell):
        self.lbn, self.packs, self.first_ref, self.s_ptm, self.frames, self.cell = (
            lbn, packs, first_ref, s_ptm, frames, cell)


def nv_pck(scr, lbn, evobu_ea, refs, s_ptm, e_ptm, evob_idn, c_idn, c_eltm):
    """The navigation pack: system header, GCI, PCI and DSI (Vol. 2 §5.4.2), sized as on discs."""
    sysh = (b"\x00\x00\x01\xbb\x00\x15" + bytes([0x80 | (MUX_RATE >> 15), (MUX_RATE >> 7) & 0xFF,
                                                    ((MUX_RATE << 1) & 0xFE) | 1, 0x04, 0xE1, 0xFF])
            + b"\xe0\xe0\xe8" + b"\xbd\xe0\x3a" + b"\xbf\xe0\x08" + b"\xbe\xe0\x00" + b"\xfd\xe0\xe8")
    gci = bytes(256)
    pci = bytearray(976)
    struct.pack_into(">I", pci, 0, lbn)
    struct.pack_into(">III", pci, 12, s_ptm, e_ptm, e_ptm)
    pci[24:28] = c_eltm
    dsi = bytearray(754)
    struct.pack_into(">III", dsi, 0, scr, lbn, evobu_ea)
    struct.pack_into(">III", dsi, 12, *refs)
    struct.pack_into(">H", dsi, 24, evob_idn)
    dsi[26], dsi[27] = (c_idn >> 8) & 0xFF, c_idn & 0xFF
    dsi[28:32] = c_eltm
    body = (sysh
            + b"\x00\x00\x01\xbf" + struct.pack(">H", 1 + len(gci)) + b"\x04" + gci
            + b"\x00\x00\x01\xbf" + struct.pack(">H", 1 + len(pci)) + b"\x00" + bytes(pci)
            + b"\x00\x00\x01\xbf" + struct.pack(">H", 1 + len(dsi)) + b"\x01" + bytes(dsi))
    assert 14 + len(body) == SECTOR, len(body)
    return pack_header(scr) + body


def mux(gops, audio, cell_starts, evob_idn, base_lbn):
    """Multiplexes an EVOB: per GOP an EVOBU (navigation pack, then video and audio packets by time).
    `cell_starts` are the GOP numbers that start cells. Returns the EVOB's bytes and its EVOBUs."""
    packs = []
    evobus = []
    scr = 0
    a = 0
    frame = 0
    cell = 0
    cell_frame = 0
    end_ptm = START_PTM + sum(len(g) for g in gops) * FRAME_90K
    for gi, g in enumerate(gops):
        if cell + 1 < len(cell_starts) and gi == cell_starts[cell + 1]:
            cell += 1
            cell_frame = frame
        s_ptm = START_PTM + frame * FRAME_90K
        e_ptm = s_ptm + len(g) * FRAME_90K

        data = bytearray()
        starts = []
        for p in g:
            starts.append((len(data), p.pts, p.dts))
            data += p.data
        vpk = payload_packs(0xE0, bytes(data), starts)
        # The video packet the I picture ends in.
        ref_pkt = next(n for n, (_, _, end) in enumerate(vpk) if end >= len(g[0].data))

        last = gi + 1 == len(gops)
        afr = []
        while a < len(audio) and (audio[a][0] < e_ptm or last) and audio[a][0] < end_ptm:
            afr.append(audio[a])
            a += 1
        apk = []
        if afr:
            adata = bytearray()
            astarts = []
            for t, fr in afr:
                astarts.append((len(adata), t, None))
                adata += fr

            def ac3_prefix(units, pos):
                ptr = units[0][0] - pos + 1 if units else 0
                return bytes([0xC0, len(units)]) + struct.pack(">H", ptr)

            apk = payload_packs(0xBD, bytes(adata), astarts, ac3_prefix)

        # By time: video by decoding time, audio by presentation time; video first on a tie.
        order = sorted([(t, 0, i, pkt) for i, (pkt, t, _) in enumerate(vpk)]
                       + [(t, 1, i, pkt) for i, (pkt, t, _) in enumerate(apk)])
        n_packs = 1 + len(order)
        lbn = base_lbn + len(packs)
        # The end of the first reference picture: its last pack, relative to the navigation pack.
        ref_pack = 1 + next(n for n, o in enumerate(order) if o[1] == 0 and o[2] == ref_pkt)
        scr = max(scr + PACK_TICKS if packs else 0, g[0].dts - SCR_LEAD)
        cell_eltm = bcd_time(frame - cell_frame)
        packs.append(nv_pck(scr, lbn, n_packs - 1, (ref_pack, ref_pack, ref_pack), s_ptm, e_ptm, evob_idn,
                            cell + 1, cell_eltm))
        for t, _, _, pkt in order:
            scr = max(scr + PACK_TICKS, t - SCR_LEAD)
            packs.append(fill_pack(scr, pkt))
        evobus.append(Evobu(lbn, n_packs, ref_pack + 1, s_ptm, len(g), cell))
        frame += len(g)
    return b"".join(packs), evobus


class Title:
    """One encoded and multiplexed title: an EVOB, its EVOBUs and chapters."""

    def __init__(self, name, segments, evob, evobus):
        self.name, self.segments, self.evob, self.evobus = name, segments, evob, evobus

    @property
    def frames(self):
        return sum(s.frames for s in self.segments)

    def chapter_frames(self):
        out, f = [], 0
        for s in self.segments:
            out.append(f)
            f += s.frames
        return out


def make_title(ffmpeg, font, work, name, segments, evob_idn=1, base_lbn=0, cache=None):
    if cache is not None and name in cache:
        gops, audio = cache[name]
    else:
        video, ac3 = encode(ffmpeg, segments, font, work, name)
        gops = parse_m2v(video)
        time_pictures(gops)
        audio = parse_ac3(ac3, START_PTM + sum(len(g) for g in gops) * FRAME_90K)
        if cache is not None:
            cache[name] = (gops, audio)
    cell_starts, g = [], 0
    for s in segments:
        cell_starts.append(g)
        g += s.gops
    evob, evobus = mux(gops, audio, cell_starts, evob_idn, base_lbn)
    return Title(name, segments, evob, evobus)


# ---- Standard Content ----------------------------------------------------------------------------------------


def lb_pad(b):
    b = bytes(b)
    return b + bytes(-len(b) % SECTOR)


def cmd_jump_tt(tt):
    return bytes([0x30, 0x02, 0, 0, 0, tt, 0, 0])


def pgci(title, evob_idn, post=()):
    """A title PGC: one program and cell per chapter, and the post commands. The EVOBUs' addresses are
    already in VTSTT_EVOBS."""
    cells = []
    for c, seg in enumerate(title.segments):
        units = [e for e in title.evobus if e.cell == c]
        cat = (0x02000000 if c == 0 else 0x08000000)  # STC discontinuity at the EVOB's start, then seamless
        cells.append((cat, seg.frames, units[0].lbn, units[-1].lbn, units[-1].lbn + units[-1].packs - 1))
    n = len(cells)
    gi = bytearray(304)
    struct.pack_into(">HH", gi, 0, n, n)
    gi[4:8] = bcd_time(title.frames)
    struct.pack_into(">H", gi, 12, 0x8000)  # audio stream 0: decoding stream 0
    cmdt = b""
    if post:
        cmdt = struct.pack(">HHHHH", 0, len(post), 0, 0, 10 + 8 * len(post) - 1) + b"".join(post)
    off = 304
    if cmdt:
        struct.pack_into(">H", gi, 168, off)
        off += len(cmdt)
    pgmap = b"".join(struct.pack(">H", i + 1) for i in range(n))
    struct.pack_into(">H", gi, 170, off)
    off += len(pgmap)
    cpbit = b"".join(struct.pack(">I4sIIIIHH", cat, bcd_time(fr), fs, 0, ls, le, 0, 0)
                     for cat, fr, fs, ls, le in cells)
    struct.pack_into(">H", gi, 172, off)
    off += len(cpbit)
    posit = b"".join(struct.pack(">HH", evob_idn, i + 1) for i in range(n))
    struct.pack_into(">H", gi, 174, off)
    return bytes(gi) + cmdt + pgmap + cpbit + posit, cells


def write_standard(root, titles):
    """HVDVD_TS for `titles` (the intro, then the feature) in one title set."""
    d = os.path.join(root, "HVDVD_TS")
    os.makedirs(d, exist_ok=True)
    # VTSTT_EVOBS: the EVOBs one after the other in HV001T01.EVO (multiplexed at their addresses there).
    lbn = sum(len(t.evob) for t in titles) // SECTOR
    with open(os.path.join(d, "HV001T01.EVO"), "wb") as f:
        for t in titles:
            f.write(t.evob)

    # VTSI tables.
    pgcs, all_cells = [], []
    for i, t in enumerate(titles):
        post = (cmd_jump_tt(i + 2),) if i + 1 < len(titles) else ()
        p, cells = pgci(t, i + 1, post)
        pgcs.append(p)
        all_cells.append(cells)
    srp = b""
    body = b""
    off = 8 + 12 * len(pgcs)
    for i, p in enumerate(pgcs):
        cat = (1 << 63) | ((i + 1) << 48)  # entry PGC of VTS_TTN i + 1
        srp += struct.pack(">QI", cat, off + len(body))
        body += p
    pgcit = struct.pack(">HHI", len(pgcs), 0, 8 + len(srp) + len(body) - 1) + srp + body

    ttus = [[(i + 1, k + 1) for k in range(len(t.segments))] for i, t in enumerate(titles)]
    ptt_body = b"".join(struct.pack(">HH", *e) for ttu in ttus for e in ttu)
    sa, sas = 8 + 4 * len(ttus), []
    for ttu in ttus:
        sas.append(sa)
        sa += 4 * len(ttu)
    ptt = struct.pack(">HHI", len(ttus), 0, 8 + 4 * len(ttus) + len(ptt_body) - 1) + b"".join(
        struct.pack(">I", s) for s in sas) + ptt_body

    # Time maps, one per PGC: the EVOBU holding each whole second.
    maps = []
    for i, t in enumerate(titles):
        secs = int(t.frames * FPS[1] / FPS[0])
        ents = []
        for s in range(1, secs + 1):
            f = s * FPS[0] // FPS[1]
            k = min(f // GOP, len(t.evobus) - 1)
            nxt = min((s + 1) * FPS[0] // FPS[1] // GOP, len(t.evobus) - 1)
            disc = s == secs or t.evobus[nxt].cell != t.evobus[k].cell
            ents.append(t.evobus[k].lbn | (0x80000000 if disc else 0))
        maps.append(struct.pack(">BBH", 1, 0, len(ents)) + b"".join(struct.pack(">I", e) for e in ents))
    sa, sas = 8 + 4 * len(maps), []
    for m in maps:
        sas.append(sa)
        sa += len(m)
    tmapt = struct.pack(">HHI", len(maps), 0, sa - 1) + b"".join(struct.pack(">I", s) for s in sas) + b"".join(maps)

    cpis = b"".join(struct.pack(">HHII", i + 1, c + 1, fs, le)
                    for i, cells in enumerate(all_cells) for c, (_, _, fs, _, le) in enumerate(cells))
    c_adt = struct.pack(">HHI", len(titles), 0, 8 + len(cpis) - 1) + cpis
    units = [e.lbn for t in titles for e in t.evobus]
    admap = struct.pack(">I", 4 + 4 * len(units) - 1) + b"".join(struct.pack(">I", u) for u in units)

    tables = [ptt, pgcit, tmapt, c_adt, admap]
    sas = []
    sa = 1
    for tb in tables:
        sas.append(sa)
        sa += len(lb_pad(tb)) // SECTOR
    vtsi_lbs = sa
    mat = bytearray(SECTOR)
    mat[0:12] = b"STANDARD-VTS"
    evobs_lbs = lbn
    struct.pack_into(">I", mat, 12, 2 * vtsi_lbs + evobs_lbs - 1)  # VTS_EA: VTSI, EVOBS, then the backup
    struct.pack_into(">I", mat, 28, vtsi_lbs - 1)
    struct.pack_into(">H", mat, 32, 0x0010)
    struct.pack_into(">I", mat, 128, SECTOR - 1)
    struct.pack_into(">I", mat, 196, vtsi_lbs)  # VTSTT_EVOBS right after the VTSI
    struct.pack_into(">I", mat, 200, sas[0])
    struct.pack_into(">I", mat, 204, sas[1])
    struct.pack_into(">I", mat, 212, sas[2])
    struct.pack_into(">I", mat, 224, sas[3])
    struct.pack_into(">I", mat, 228, sas[4])
    struct.pack_into(">I", mat, 532, 0x2B08C000)  # MPEG-2, HD 60 Hz, 16:9, interlaced, 1920x1080
    struct.pack_into(">H", mat, 536, 1)
    mat[538:546] = bytes([0x1C, 0x04, 0xC4, 0x00]) + b"en" + bytes([0x00, 0x1F])  # DD+, 48 kHz, 2 ch, "en"
    vtsi = bytes(mat) + b"".join(lb_pad(tb) for tb in tables)
    for ext in ("IFO", "BUP"):
        with open(os.path.join(d, f"HV001I01.{ext}"), "wb") as f:
            f.write(vtsi)

    # VMGI: VMGI_MAT with the First Play PGC (JumpTT 1), TT_SRPT, VTS_ATRT.
    fp = bytearray(304)
    struct.pack_into(">H", fp, 168, 304)
    fp = bytes(fp) + struct.pack(">HHHHH", 1, 0, 0, 0, 10 + 8 - 1) + cmd_jump_tt(1)
    vmg_lbs = 3
    vts_sa = 2 * vmg_lbs  # the VTS follows the VMGI and its backup
    tt = struct.pack(">HHI", len(titles), 0, 8 + 16 * len(titles) - 1) + b"".join(
        struct.pack(">BBHHHHHI", 0x00, 1, 0, len(t.segments), 0, 1, i + 1, vts_sa) for i, t in enumerate(titles))
    atr = struct.pack(">II", 8 + 918 - 1, 0) + bytes(mat[232:1150])
    atrt = struct.pack(">HHII", 1, 0, 12 + len(atr) - 1, 12) + atr
    vmat = bytearray(SECTOR)
    vmat[0:12] = b"HVDVD-VMG100"
    struct.pack_into(">I", vmat, 12, 2 * vmg_lbs - 1)
    struct.pack_into(">I", vmat, 28, vmg_lbs - 1)
    struct.pack_into(">H", vmat, 32, 0x0010)
    struct.pack_into(">HH", vmat, 38, 1, 1)
    vmat[42] = 0x01  # side A
    struct.pack_into(">H", vmat, 62, 1)
    struct.pack_into(">I", vmat, 128, 1158 + len(fp) - 1)
    struct.pack_into(">I", vmat, 132, 1158)
    struct.pack_into(">I", vmat, 196, 1)
    struct.pack_into(">I", vmat, 208, 2)
    struct.pack_into(">Q", vmat, 1150, 1 << 63)
    vmat[1158:1158 + len(fp)] = fp
    vmgi = bytes(vmat) + lb_pad(tt) + lb_pad(atrt)
    assert len(vmgi) == vmg_lbs * SECTOR
    for ext in ("IFO", "BUP"):
        with open(os.path.join(d, f"HV000I01.{ext}"), "wb") as f:
            f.write(vmgi)


# ---- Advanced Content ----------------------------------------------------------------------------------------

PLAYLIST_NS = "http://www.dvdforum.org/2005/HDDVDVideo/Playlist"


def timecode(frames_2997):
    """A 29.97 Hz frame count as an "HH:MM:SS:FF" time on the 60fps Title Timeline (two frames each)."""
    f = frames_2997 * 2
    s, ff = divmod(f, 60)
    m, s = divmod(s, 60)
    h, m = divmod(m, 60)
    return f"{h:02}:{m:02}:{s:02}:{ff:02}"


def tmap(evob_index, title):
    entries = b"".join(struct.pack(">I", ((e.first_ref & 0xFFF) << 20) | ((e.frames * 2 * 4) << 11) | e.packs)
                       for e in title.evobus)
    d = bytearray(416)
    d[0:12] = b"HDDVD_TMAP00"
    struct.pack_into(">I", d, 12, 416 + len(entries) - 1)
    struct.pack_into(">H", d, 18, 0x10)
    struct.pack_into(">H", d, 20, 0x2000)
    struct.pack_into(">H", d, 55, 1)
    struct.pack_into(">I", d, 57, 0xFFFFFFFF)  # no interleaved units
    d[114:126] = b"HVA00001.VTI"
    struct.pack_into(">IHH", d, 384, 416, evob_index, len(title.evobus))
    return bytes(d) + entries


def vti(titles):
    """HVA00001.VTI: one attribute record, then the EVOB table."""
    rec = bytearray(1024)
    struct.pack_into(">HIIHH", rec, 0, 0, 0x2B08C000, 0, 0, 0)
    struct.pack_into(">H", rec, 14, 1)
    struct.pack_into(">I", rec, 16, 0x1C04C400)  # DD+, 48 kHz, 2 ch
    atrt = struct.pack(">HHII", 1, 0, 12 + len(rec) - 1, 12) + bytes(rec)
    ents = b""
    off = 8 + 4 * len(titles)
    sas = b""
    for i, t in enumerate(titles):
        e = bytearray(320)
        struct.pack_into(">H", e, 0, i + 1)
        name = (t.name + ".EVO").encode()
        e[2:2 + len(name)] = name
        struct.pack_into(">IIIIIH", e, 258, 0, 1, START_PTM, START_PTM + t.frames * FRAME_90K,
                         len(t.evob) // SECTOR, i + 1)
        sas += struct.pack(">I", off + len(ents))
        ents += e
    evobit = struct.pack(">II", len(titles), 8 + len(sas) + len(ents) - 1) + sas + ents
    mat = bytearray(SECTOR)
    mat[0:12] = b"ADVANCED-VTS"
    total = 1 + len(lb_pad(atrt)) // SECTOR + len(lb_pad(evobit)) // SECTOR
    struct.pack_into(">I", mat, 12, total - 1)
    struct.pack_into(">I", mat, 28, total - 1)
    struct.pack_into(">H", mat, 32, 0x0010)
    struct.pack_into(">I", mat, 184, 1)
    struct.pack_into(">I", mat, 188, 1 + len(lb_pad(atrt)) // SECTOR)
    return bytes(mat) + lb_pad(atrt) + lb_pad(evobit)


def playlist(intro, feature, disc_name, app_size):
    clip = lambda t: (
        f'<PrimaryAudioVideoClip titleTimeBegin="00:00:00:00" titleTimeEnd="{timecode(t.frames)}" '
        f'src="file:///dvddisc/HVDVD_TS/{t.name}.MAP" dataSource="Disc">'
        '<Video track="1" mediaAttr="1"/><Audio track="1" streamNumber="1" mediaAttr="1"/>'
        "</PrimaryAudioVideoClip>")
    chapters = "".join(f'<Chapter titleTimeBegin="{timecode(f)}" displayName="{s.label}"/>'
                       for f, s in zip(feature.chapter_frames(), feature.segments))
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Playlist xmlns="{PLAYLIST_NS}" majorVersion="1" minorVersion="0" displayName="{disc_name}">
 <Configuration><StreamingBuffer size="0"/><Aperture size="1920x1080"/><MainVideoDefaultColor color="108080"/></Configuration>
 <MediaAttributeList>
  <VideoAttributeItem index="1" codec="MPEG-2"/>
  <AudioAttributeItem index="1" codec="DD+" sampleFrequency="48" channels="2"/>
 </MediaAttributeList>
 <TitleSet timeBase="60fps" tickBase="60fps" defaultLanguage="en">
  <FirstPlayTitle titleDuration="{timecode(intro.frames)}">
   {clip(intro)}
  </FirstPlayTitle>
  <Title titleNumber="1" id="feature" displayName="Feature" titleDuration="{timecode(feature.frames)}">
   {clip(feature)}
   <ApplicationSegment id="chapters" src="file:///dvddisc/ADV_OBJ/CHAPTERS.ACA/CHAPTERS.XMF" titleTimeBegin="00:00:00:00" titleTimeEnd="{timecode(feature.frames)}" sync="hard" zOrder="1" language="en" autorun="true">
    <ApplicationResource src="file:///dvddisc/ADV_OBJ/CHAPTERS.ACA" size="{app_size}" priority="1" multiplexed="false"/>
   </ApplicationSegment>
   <ChapterList>{chapters}</ChapterList>
   <TrackNavigationList><VideoTrack track="1"/><AudioTrack track="1" langcode="en" description="Tones"/></TrackNavigationList>
  </Title>
 </TitleSet>
</Playlist>
"""


def app_files(n):
    """The chapter bar: a manifest, a markup page with a button per chapter, and its script, as (name, MIME
    type, text)."""
    manifest = """<?xml version="1.0" encoding="UTF-8"?>
<Application xmlns="http://www.dvdforum.org/2005/HDDVDVideo/Manifest" id="chapters">
 <Region x="0" y="0" width="1920" height="1080"/>
 <Script src="CHAPTERS.JS"/>
 <Markup src="CHAPTERS.XMU"/>
</Application>
"""
    w, gap = 160, 20
    x0 = (1920 - n * w - (n - 1) * gap) // 2
    buttons = "\n".join(
        f'  <button id="c{i}" style:position="absolute" style:x="{x0 + i * (w + gap)}px" style:y="20px" '
        f'style:width="{w}px" style:height="60px" style:backgroundColor="#404040"/>' for i in range(n))
    markup = f"""<?xml version="1.0" encoding="UTF-8"?>
<root xmlns="http://www.dvdforum.org/2005/ihd" xmlns:style="http://www.dvdforum.org/2005/ihd#style" xml:lang="en">
<body>
 <div style:position="absolute" style:x="0px" style:y="960px" style:width="1920px" style:height="100px" style:backgroundColor="rgba(0,0,0,160)">
{buttons}
 </div>
</body>
</root>
"""
    script = f"""// Highlights the chapter playing; Enter on a button jumps to its chapter.
var count = {n};
function show(n) {{
  for (var i = 0; i < count; i++) {{
    var b = document.getElementById("c" + i);
    if (b) b.style.backgroundColor = i == n ? "#e0a020" : "#404040";
  }}
}}
addEventListener("title_begin", function (e) {{ show(0); }}, false);
addEventListener("chapter", function (e) {{ show(e.newValue); }}, false);
addEventListener("controller_key_down", function (e) {{
  if (e.key != e.VK_ENTER || e.target === application) return;
  var n = parseInt(e.target.getAttribute("id").substring(1), 10);
  Player.playlist.currentTitle.chapters[n].jump("00:00:00:00", false);
}}, false);
"""
    return [("CHAPTERS.XMF", 0x02, manifest), ("CHAPTERS.XMU", 0x03, markup), ("CHAPTERS.JS", 0x07, script)]


def archive(files):
    """An .aca archive (Vol. 3 §6.5.4): a 32-byte header, an entry per file (offset, size, CRC, MIME type, name,
    32 reserved bytes), then the files."""
    data = [(name.encode(), mime, text.encode()) for name, mime, text in files]
    table_len = sum(14 + len(n) + 32 for n, _, _ in data)
    head = b"HDDVDACA" + struct.pack(">HHH", 0x10, 1, len(data)) + bytes(18)
    table = b""
    body = b""
    for name, mime, content in data:
        off = 32 + table_len + len(body)
        table += struct.pack(">IIIBB", off, len(content), zlib.crc32(content), mime, len(name)) + name + bytes(32)
        body += content
    return head + table + body


def disc_id():
    d = bytearray(64)
    d[0:12] = b"HDDVD-V_CONF"
    d[12:28] = b"\xff" * 16  # no disc ID
    d[28:44] = b"TEST-DISC-MAKER\x00"
    d[44:60] = bytes.fromhex("5e1f0c2a7b3d4e6f8091a2b3c4d5e6f7")
    d[60] = 1  # the playlist on the disc only
    return bytes(d)


def write_advanced(root, intro, feature, disc_name):
    adv = os.path.join(root, "ADV_OBJ")
    hv = os.path.join(root, "HVDVD_TS")
    os.makedirs(adv, exist_ok=True)
    os.makedirs(hv, exist_ok=True)
    titles = [intro, feature]
    for i, t in enumerate(titles):
        with open(os.path.join(hv, t.name + ".EVO"), "wb") as f:
            f.write(t.evob)
        with open(os.path.join(hv, t.name + ".MAP"), "wb") as f:
            f.write(tmap(i + 1, t))
    with open(os.path.join(hv, "HVA00001.VTI"), "wb") as f:
        f.write(vti(titles))
    with open(os.path.join(adv, "DISCID.DAT"), "wb") as f:
        f.write(disc_id())
    aca = archive(app_files(len(feature.segments)))
    with open(os.path.join(adv, "CHAPTERS.ACA"), "wb") as f:
        f.write(aca)
    with open(os.path.join(adv, "VPLST000.XPL"), "w", encoding="utf-8", newline="\n") as f:
        f.write(playlist(intro, feature, disc_name, len(aca)))


# ---- main ----------------------------------------------------------------------------------------------------


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("out", help="folder to create the discs in (OUT/standard, OUT/advanced)")
    ap.add_argument("--chapters", type=int, default=3)
    ap.add_argument("--chapter-seconds", type=float, default=10, help="rounded to whole EVOBUs (0.5 s)")
    ap.add_argument("--intro-seconds", type=float, default=5)
    ap.add_argument("--only", choices=["standard", "advanced"])
    ap.add_argument("--name", default="Test Disc", help="the Advanced Content playlist's display name")
    ap.add_argument("--font", help="a TrueType font for the captions")
    ap.add_argument("--ffmpeg", default="ffmpeg")
    ap.add_argument("--force", action="store_true", help="replace OUT/standard and OUT/advanced")
    args = ap.parse_args()

    ffmpeg = shutil.which(args.ffmpeg) or fail(f"{args.ffmpeg} not found")
    if not 1 <= args.chapters <= 8:
        fail("--chapters must be 1 to 8")
    font = args.font or next((f for f in FONTS if os.path.exists(f)), None)
    if not has_drawtext(ffmpeg):
        print("make_test_disc: ffmpeg has no drawtext filter: no captions", file=sys.stderr)
        font = None
    elif not font:
        print("make_test_disc: no font found (--font): no captions", file=sys.stderr)

    gops = lambda secs: max(1, round(secs * FPS[0] / FPS[1] / GOP))
    intro_segs = [Segment("Intro", gops(args.intro_seconds), "0x101010", 330)]
    feature_segs = [Segment(f"Chapter {i + 1}", gops(args.chapter_seconds), COLOURS[i % len(COLOURS)],
                            440 + 110 * i) for i in range(args.chapters)]
    kinds = [args.only] if args.only else ["standard", "advanced"]
    for k in kinds:
        p = os.path.join(args.out, k)
        if os.path.exists(p):
            if not args.force:
                fail(f"{p} exists (--force replaces it)")
            shutil.rmtree(p)

    with tempfile.TemporaryDirectory() as work:
        if font:  # by a relative name: a drive colon would need escaping in the filter graph
            shutil.copyfile(font, os.path.join(work, "font" + os.path.splitext(font)[1]))
            font = "font" + os.path.splitext(font)[1]
        cache = {}
        if "standard" in kinds:
            intro = make_title(ffmpeg, font, work, "INTRO", intro_segs, 1, 0, cache)
            feature = make_title(ffmpeg, font, work, "FEATURE", feature_segs, 2, len(intro.evob) // SECTOR, cache)
            write_standard(os.path.join(args.out, "standard"), [intro, feature])
        if "advanced" in kinds:
            intro = make_title(ffmpeg, font, work, "INTRO", intro_segs, 1, 0, cache)
            feature = make_title(ffmpeg, font, work, "FEATURE", feature_segs, 1, 0, cache)
            write_advanced(os.path.join(args.out, "advanced"), intro, feature, args.name)
    for k in kinds:
        print(os.path.join(args.out, k))


if __name__ == "__main__":
    main()
