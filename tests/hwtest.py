#!/usr/bin/env python3
"""Hardware test suite for Anti-Symphony.

Needs the Symphony connected, symphonyd installed and running, and these loopback cables
(see tests/README.md):

    Headphone 1  -> Analog In 1     Headphone 2 -> Analog In 2
    Analog Out 3 -> (compressor) -> Analog In 3

It plays tones on all 16 DAW channels (a different frequency on each) and measures the inputs,
so every check is made on real audio. All settings are snapshotted first and restored at the
end, even when a test fails. Mixer inputs are fed from DAW channels during the run so that no
setting can create a feedback loop through the cables.

Run: make test   (results also go to build/test-results.md)
"""
import json
import os
import socket
import struct
import subprocess
import sys
import time
import traceback

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "build")
SYMCTL = os.path.join(BUILD, "symctl")
SYMTEST = os.path.join(BUILD, "symtest")
OSC_PORT = 7100

# One frequency per DAW channel 1-16 (primes, about 100 Hz apart, no harmonic overlaps).
FREQS = [263, 359, 457, 541, 647, 743, 857, 953, 1061, 1151, 1259, 1361, 1459, 1567, 1663, 1777]
TONE_DB = -24.0
PRESENT = -75.0          # a tone louder than this at an input counts as present
HP_INPUT = {1: 0, 2: 1}  # input index fed by each headphone
LOOP_INPUT = 2           # Analog In 3, fed by Analog Out 3 through the compressor
PROBE_INPUT = 8          # To Mac 9: used for digital loopback checks (normally Optical In 1)
PROBE_DEST = 0xD8        # its routing destination
SETTLE = 0.45


# ---------------------------------------------------------------- OSC client

def _pad(b):
    return b + b"\0" * (4 - len(b) % 4)


def osc_msg(path, *args):
    tags = "," + "".join("f" if isinstance(a, float) else "i" if isinstance(a, int) else "s" for a in args)
    out = _pad(path.encode()) + _pad(tags.encode())
    for a in args:
        if isinstance(a, float):
            out += struct.pack(">f", a)
        elif isinstance(a, int):
            out += struct.pack(">i", a)
        else:
            out += _pad(a.encode())
    return out


def osc_parse(d):
    e = d.index(b"\0")
    path = d[:e].decode()
    p = (e + 4) & ~3
    if p >= len(d):
        return path, []
    e = d.index(b"\0", p)
    tags = d[p + 1:e].decode()
    p = (e + 4) & ~3
    args = []
    for t in tags:
        if t == "i":
            args.append(struct.unpack_from(">i", d, p)[0]); p += 4
        elif t == "f":
            args.append(struct.unpack_from(">f", d, p)[0]); p += 4
        elif t == "s":
            e = d.index(b"\0", p); args.append(d[p:e].decode()); p = (e + 4) & ~3
    return path, args


class Osc:
    def __init__(self, port=OSC_PORT):
        self.addr = ("127.0.0.1", port)
        self.values = {}
        self.errors = []
        self.seen = {}           # path -> time of last message
        self.meters_last = None
        self.new_socket()

    def new_socket(self):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.settimeout(0.05)
        self.last_sub = 0

    def send(self, path, *args):
        if time.time() - self.last_sub > 15 and path != "/symphony/subscribe":
            self.sock.sendto(osc_msg("/symphony/renew"), self.addr)
            self.last_sub = time.time()
        self.sock.sendto(osc_msg(path, *args), self.addr)

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            try:
                data = self.sock.recv(4096)
            except socket.timeout:
                continue
            except ConnectionRefusedError:
                time.sleep(0.05)
                continue
            try:
                path, args = osc_parse(data)
            except (ValueError, struct.error):
                continue
            self.seen[path] = time.time()
            if path == "/symphony/meters/in":
                self.meters_last = args
                self.values[path] = args[0] if args else None
                continue
            if path == "/symphony/error":
                self.errors.append(tuple(args))
            elif args:
                self.values[path] = args[0]

    def subscribe(self, wait=2.0):
        self.last_sub = time.time()
        self.sock.sendto(osc_msg("/symphony/subscribe"), self.addr)
        self.pump(wait)

    def get(self, path, timeout=1.5):
        t0 = time.time()
        self.send(path)
        end = t0 + timeout
        while time.time() < end:
            self.pump(0.05)
            if self.seen.get(path, 0) >= t0:
                return self.values.get(path)
        return None

    def set(self, path, value, wait=0.1):
        self.send(path, value)
        self.pump(wait)


# ---------------------------------------------------------------- audio

class Audio:
    def __init__(self):
        self.p = subprocess.Popen([SYMTEST], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
        first = json.loads(self.p.stdout.readline())
        if "error" in first:
            raise RuntimeError("symtest: " + first["error"])
        self.rate = first["rate"]
        self.playing = set()

    def cmd(self, line):
        self.p.stdin.write(line + "\n")
        self.p.stdin.flush()
        out = json.loads(self.p.stdout.readline())
        if "error" in out:
            raise RuntimeError("symtest: " + out["error"])
        return out

    def play(self, chans, db=TONE_DB):
        self.cmd("alloff")
        for c in chans:
            self.cmd("tone %d %d %.1f" % (c, FREQS[c - 1], db))
        self.playing = set(chans)

    def measure(self, ms=300, settle=SETTLE):
        return Measurement(self.cmd("measure %d %d" % (ms, int(settle * 1000))))

    def reopen(self):
        out = self.cmd("reopen")
        self.rate = out.get("rate", self.rate)
        chans = sorted(self.playing)
        self.play(chans)
        self.measure(200, 1.5)   # let the stream start

    def close(self):
        try:
            self.cmd("alloff")
            self.p.stdin.write("quit\n")
            self.p.stdin.flush()
            self.p.wait(timeout=5)
        except Exception:
            self.p.kill()


class Measurement:
    def __init__(self, d):
        self.rms = d["rms"]
        self.tones = {int(k): v for k, v in d["tones"].items()}

    def level(self, inp, daw):
        return self.tones.get(FREQS[daw - 1], [-240.0] * 16)[inp]

    def present(self, inp):
        return sorted(daw for daw in range(1, 17) if self.level(inp, daw) > PRESENT)


# ---------------------------------------------------------------- helpers

def symctl(*args):
    r = subprocess.run([SYMCTL] + [str(a) for a in args], capture_output=True, text=True, timeout=10)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def read_route(dest):
    rc, out, _ = symctl("read", "0x31", hex(dest), "1")
    return int(out, 16) if rc == 0 and out else None


def write_routes(pairs):
    hexs = "".join("%02x%02x" % (d, s) for d, s in pairs)
    rc, _, err = symctl("write", "0x31", "0", hexs)
    if rc:
        raise RuntimeError("route write failed: " + err)


def approx(a, b, tol):
    return abs(a - b) <= tol


def fmt(v):
    return "%.1f" % v


# ---------------------------------------------------------------- test runner

class Suite:
    def __init__(self):
        self.results = []
        self.notes = []
        self.osc = None
        self.audio = None
        self.snapshot = {}
        self.mixer_routes = {}

    def record(self, name, status, detail):
        self.results.append((name, status, detail))
        print("%-5s %-38s %s" % (status, name, detail), flush=True)

    def run(self, name, fn):
        try:
            out = fn()
            if isinstance(out, tuple):
                status, detail = out
            else:
                status, detail = ("PASS", out or "")
            self.record(name, status, detail)
        except AssertionError as e:
            self.record(name, "FAIL", str(e))
        except Exception as e:
            self.record(name, "ERROR", "%s: %s" % (type(e).__name__, e))
            traceback.print_exc()

    # ---- setup / teardown

    def setup(self):
        self.osc = Osc()
        self.osc.subscribe()
        if self.osc.values.get("/symphony/connected") != 1:
            raise SystemExit("symphonyd isn't answering on port %d, or the Symphony isn't connected" % OSC_PORT)
        self.snapshot = {k: v for k, v in self.osc.values.items()
                         if k.startswith("/symphony/") and "/clock/" not in k and k != "/symphony/connected"}
        self.rate = self.osc.values.get("/symphony/clock/rate")
        # Mixer inputs: feed them from DAW channels so no setting can loop the cables back.
        for base in (0x40, 0x60):
            for i in range(16):
                self.mixer_routes[base + i] = read_route(base + i)
        write_routes([(base + i, 0xC0 + i) for base in (0x40, 0x60) for i in range(16)])
        self.audio = Audio()
        self.audio.play(range(1, 17))
        self.audio.measure(200, 1.5)    # stream start-up

    def teardown(self):
        if self.audio:
            self.audio.close()
        if not self.osc:
            return
        try:
            self.osc.new_socket()
            self.osc.subscribe()
            if self.rate and self.osc.values.get("/symphony/clock/rate") != self.rate:
                self.osc.set("/symphony/clock/rate", float(self.rate), wait=2.0)
            changed = 0
            for path, v in self.snapshot.items():
                if self.osc.values.get(path) != v:
                    self.osc.set(path, v, wait=0.05)
                    changed += 1
            if self.mixer_routes:
                write_routes([(d, s) for d, s in self.mixer_routes.items() if s is not None])
            time.sleep(3)
            self.osc.subscribe()
            left = [p for p, v in self.snapshot.items() if self.osc.values.get(p) != v]
            mix_ok = all(read_route(d) == s for d, s in self.mixer_routes.items() if s is not None)
            status = "PASS" if not left and mix_ok else "FAIL"
            self.record("restore all settings", status,
                        "%d settings put back; %s" % (changed, "all match the snapshot" if not left and mix_ok
                                                      else "still different: %s%s" % (left[:6], "" if mix_ok else " + mixer routes")))
        except Exception as e:
            self.record("restore all settings", "ERROR", str(e))

    # ---- tests

    def t_handshake(self):
        rc, out, _ = symctl("read", "0xdd", "0", "1")
        assert rc == 0 and out == "00", "host ready lock reads %r, expected 00" % out
        rc, out, _ = symctl("read", "0xff", "0", "4")
        assert out == "dae5c4a1", "system ready reads %r" % out
        return "host ready set, box booted"

    def t_osc_state(self):
        n = len([k for k in self.snapshot if k.startswith("/symphony/")])
        assert n >= 240, "only %d settings in the state dump" % n
        return "%d settings in the state dump" % n

    def t_osc_errors(self):
        self.osc.errors.clear()
        self.osc.set("/symphony/no/such/thing", 1, wait=0.4)
        self.osc.set("/symphony/clock/source", 1, wait=0.4)
        self.osc.set("/symphony/monitor/main/level/toggle", 1, wait=0.4)
        reasons = [e[1] for e in self.osc.errors if len(e) > 1]
        assert any("unknown" in r for r in reasons), "no error for an unknown address"
        assert any("read-only" in r for r in reasons), "no error for a read-only setting"
        assert any("toggle" in r for r in reasons), "no error for toggling a level"
        return "unknown address, read-only and bad toggle all rejected"

    def t_osc_garbage(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        for junk in (b"", b"\x00", b"hello", b"/x\0\0,iii\0\0\0\0", os.urandom(512), b"/" + b"a" * 3000):
            s.sendto(junk, ("127.0.0.1", OSC_PORT))
        time.sleep(0.3)
        v = self.osc.get("/symphony/monitor/main/level")
        assert v is not None, "symphonyd stopped answering after malformed packets"
        return "survived 6 malformed packets"

    def t_osc_ops(self):
        p = "/symphony/monitor/hp/2/level"
        start = self.osc.get(p)
        self.osc.set(p, -30.0, wait=0.3)
        assert self.osc.get(p) == -30.0, "set failed"
        self.osc.set(p + "/inc", 2.0, wait=0.3)
        assert self.osc.get(p) == -28.0, "inc gave %s" % self.osc.get(p)
        self.osc.set(p + "/dec", 5.0, wait=0.3)
        assert self.osc.get(p) == -33.0, "dec gave %s" % self.osc.get(p)
        self.osc.set(p, 10.0, wait=0.3)
        assert self.osc.get(p) == 0.0, "level above 0 dB wasn't clamped"
        self.osc.set(p, -200.0, wait=0.3)
        assert self.osc.get(p) == -64.0, "level below -64 dB wasn't clamped"
        m = "/symphony/monitor/hp/2/mute"
        before = self.osc.get(m)
        self.osc.set(m + "/toggle", 1, wait=0.3)
        assert self.osc.get(m) == (0 if before else 1), "toggle didn't flip mute"
        self.osc.set(m + "/toggle", 1, wait=0.3)
        assert self.osc.get(m) == before, "second toggle didn't flip it back"
        self.osc.set(p, start, wait=0.3)
        rc, out, _ = symctl("read", "0x23", "1", "1")
        assert int(out, 16) == int(-start), "box holds %s, expected %d" % (out, -start)
        return "set, inc, dec, clamping and toggle all correct; box agrees"

    def t_follow_external(self):
        p = "/symphony/monitor/hp/2/level"
        start = self.osc.get(p)
        symctl("write", "0x23", "1", "%02x" % 37)       # someone turns the knob: -37 dB
        t0 = time.time()
        while time.time() - t0 < 4:
            self.osc.pump(0.1)
            if self.osc.values.get(p) == -37.0:
                break
        took = time.time() - t0
        got = self.osc.values.get(p)
        self.osc.set(p, start, wait=0.3)
        assert got == -37.0, "subscriber never saw the change (still %s)" % got
        return "change made outside symphonyd reached subscribers in %.1f s" % took

    def t_audio_paths(self):
        m = self.audio.measure()
        loop = m.present(LOOP_INPUT)
        hp1, hp2 = m.present(HP_INPUT[1]), m.present(HP_INPUT[2])
        assert 3 in loop, "Analog In 3 doesn't hear DAW 3 through the loop (hears %s)" % loop
        assert hp1 == [1, 2] and hp2 == [1, 2], "headphones hear %s / %s, expected DAW 1-2" % (hp1, hp2)
        return "HP1 -> In 1 and HP2 -> In 2 carry DAW 1-2 (%s dB); loop Out 3 -> In 3 carries DAW 3 (%s dB)" % (
            fmt(m.level(0, 1)), fmt(m.level(LOOP_INPUT, 3)))

    def hp_feed(self, hp, left_src):
        d = 0xE0 + 2 * (hp - 1)
        self.osc.set("/symphony/route/%d" % d, left_src)
        self.osc.set("/symphony/route/%d" % (d + 1), left_src + 1, wait=0.2)

    def t_hp_own_feed(self):
        self.hp_feed(1, 0xC0 + 12)     # DAW 13-14
        self.hp_feed(2, 0xC0 + 4)      # DAW 5-6
        m = self.audio.measure()
        self.hp_feed(1, 0xC0)
        self.hp_feed(2, 0xC0)
        back = self.audio.measure()
        assert m.present(0) == [13, 14], "HP1 own feed DAW 13-14: hears %s" % m.present(0)
        assert m.present(1) == [5, 6], "HP2 own feed DAW 5-6: hears %s" % m.present(1)
        assert m.present(2) == [3], "headphone change affected Analog Out 3 (In 3 hears %s)" % m.present(2)
        assert back.present(0) == [1, 2] and back.present(1) == [1, 2], "headphones didn't return to DAW 1-2"
        return "HP1 ← DAW 13-14 and HP2 ← DAW 5-6 independently; outputs untouched"

    def t_hp_mirror(self):
        mp, out5 = "/symphony/monitor/hp/1/mirror", "/symphony/route/36"   # 36 = Analog Out 5
        start5 = self.osc.get(out5)
        try:
            self.osc.set(mp, 0x24, wait=0.4)                 # mirror Analog Out 5-6
            a = self.audio.measure().present(0)
            self.osc.set(out5, 0xC0 + 10, wait=0.4)          # reroute Analog Out 5 to DAW 11
            b = self.audio.measure().present(0)
            self.osc.set(out5, start5, wait=0.4)
            c = self.audio.measure().present(0)
            assert a == [5, 6], "mirroring Analog Out 5-6: HP1 hears %s" % a
            assert b == [6, 11], "after rerouting Out 5 to DAW 11, HP1 hears %s (should follow)" % b
            assert c == [5, 6], "after restoring Out 5, HP1 hears %s" % c
            self.hp_feed(1, 0xC0 + 14)                       # choosing an own feed ends mirroring
            assert self.osc.get(mp) == -1, "own feed didn't end mirroring"
        finally:
            self.osc.set(out5, start5)
            self.osc.set(mp, -1)
            self.hp_feed(1, 0xC0)
        return "HP1 mirrors Analog Out 5-6 and follows when that output is rerouted; own feed ends mirroring"

    def t_hp_level(self):
        p = "/symphony/monitor/hp/1/level"
        start = self.osc.get(p)
        self.osc.set(p, -20.0)
        a = self.audio.measure().level(0, 1)
        self.osc.set(p, -30.0)
        b = self.audio.measure().level(0, 1)
        self.osc.set(p, -64.0)
        c = self.audio.measure().level(0, 1)
        self.osc.set(p, start)
        assert approx(a - b, 10, 1.0), "10 dB step measured %.1f dB" % (a - b)
        assert a - c > 40, "-64 dB only dropped %.1f dB" % (a - c)
        self.notes.append("Headphone level: -20 dB setting -> %.1f dBFS at In 1 (tone %.0f dBFS); -30 -> %.1f; -64 -> %.1f" % (a, TONE_DB, b, c))
        return "-20 → -30 dB measured %.1f dB; -64 dB is %.1f dB down" % (a - b, a - c)

    def t_hp_mute_dim_mono(self):
        base = "/symphony/monitor/hp/1/"
        # Mute, dim and mono all fade over about 1 s, so give every step time to settle.
        ref = self.audio.measure(settle=1.3).level(0, 1)
        out = []
        self.osc.set(base + "mute", 1)
        mute = ref - self.audio.measure(settle=1.3).level(0, 1)    # mute fades out over about 1 s
        self.osc.set(base + "mute", 0)
        self.osc.set(base + "dim", 1)
        dim = ref - self.audio.measure(settle=1.3).level(0, 1)
        self.osc.set(base + "dim", 0)
        self.osc.set(base + "mono", 1)
        mono = self.audio.measure(settle=1.3)
        self.osc.set(base + "mono", 0)
        back = self.audio.measure(settle=1.3).level(0, 1)
        assert mute > 40, "mute only dropped %.1f dB" % mute
        assert 6 < dim < 40, "dim dropped %.1f dB" % dim
        assert approx(back, ref, 1.0), "level didn't come back after mono (%.1f vs %.1f)" % (back, ref)
        # The cable is balanced (tip - ring = L - R), so mono (L = R) cancels at the input.
        mono_drop = ref - mono.level(0, 1)
        out.append("mute -%.0f dB, dim -%.1f dB, mono cancels L-R by %.0f dB" % (mute, dim, mono_drop))
        assert mono_drop > 15, "mono didn't make L = R (only %.1f dB change on the balanced loop)" % mono_drop
        return "; ".join(out)

    def t_main_level(self):
        p = "/symphony/monitor/main/level"
        start = self.osc.get(p)
        self.osc.set(p, -20.0)
        a = self.audio.measure()
        self.osc.set(p, -30.0)
        b = self.audio.measure()
        self.osc.set(p, start)
        d_hp = a.level(0, 1) - b.level(0, 1)
        d_out3 = a.level(LOOP_INPUT, 3) - b.level(LOOP_INPUT, 3)
        self.notes.append("Main level -20 → -30 dB: headphone mirror of Analog 1-2 changes %.1f dB, Analog Out 3 changes %.1f dB" % (d_hp, d_out3))
        assert abs(d_out3) < 1, "main level changed Analog Out 3 by %.1f dB" % d_out3
        return "INFO", "headphone mirror of Out 1-2 moved %.1f dB, Out 3 moved %.1f dB (Out 3 unaffected, as expected)" % (d_hp, d_out3)

    def t_route_output(self):
        p = "/symphony/route/34"     # Analog Out 3
        start = self.osc.get(p)
        self.osc.set(p, 0xC0 + 11)   # DAW 12
        m = self.audio.measure()
        self.osc.set(p, start)
        back = self.audio.measure()
        assert m.present(LOOP_INPUT) == [12], "Out 3 <- DAW 12: In 3 hears %s" % m.present(LOOP_INPUT)
        assert back.present(LOOP_INPUT) == [3], "after restore In 3 hears %s" % back.present(LOOP_INPUT)
        return "Analog Out 3 rerouted to DAW 12 and back, confirmed at In 3"

    def t_route_record(self):
        p = "/symphony/route/%d" % PROBE_DEST
        start = self.osc.get(p)
        self.osc.set(p, 0xC0 + 6)    # DAW 7, straight back to the Mac
        m = self.audio.measure()
        self.osc.set(p, start)
        lvl = m.level(PROBE_INPUT, 7)
        assert m.present(PROBE_INPUT) == [7], "To Mac 9 <- DAW 7: input 9 hears %s" % m.present(PROBE_INPUT)
        assert approx(lvl, TONE_DB, 0.5), "digital loopback level %.2f dBFS, expected %.0f" % (lvl, TONE_DB)
        self.digital_probe = True
        return "DAW 7 routed back to recording channel 9 at %.2f dBFS (bit-exact level)" % lvl

    def t_ref_levels(self):
        """Measure what each reference level code does, on an input and an output."""
        res = {}
        # Input: Analog In 3, fed by the loop.  Output: Analog Out 3, measured at In 3 with a quiet
        # tone so the compressor in the loop stays below its threshold.
        for label, path, quiet in (("in 3", "/symphony/io/analog/in/3/ref", False),
                                   ("out 3", "/symphony/io/analog/out/3/ref", True)):
            start = self.osc.get(path)
            if quiet:
                self.audio.play([3], db=-44.0)
            levels = {}
            for code in (0, 1, 2):
                self.osc.set(path, code, wait=0.3)
                assert self.osc.get(path) == code, "%s: box didn't accept code %d" % (label, code)
                levels[code] = self.audio.measure(settle=0.8).level(LOOP_INPUT, 3)
            self.osc.set(path, start, wait=0.3)
            if quiet:
                self.audio.play(range(1, 17))
            res[label] = levels
        desc = "; ".join("%s: %s" % (k, ", ".join("code %d %.1f dBFS" % (c, l) for c, l in v.items())) for k, v in res.items())
        self.notes.append("Reference levels measured through the Out 3 -> In 3 loop: " + desc)
        d_in = res["in 3"][1] - res["in 3"][2]      # -10 dBV input reads louder than +4 dBu
        d_out = res["out 3"][2] - res["out 3"][1]   # +4 dBu output is louder than -10 dBV
        assert approx(d_in, 11.8, 1.0), "input: code 1 vs 2 differ by %.1f dB, expected 11.8 (+4 dBu vs -10 dBV)" % d_in
        assert approx(d_out, 11.8, 1.0), "output: code 2 vs 1 differ by %.1f dB, expected 11.8" % d_out
        return "+4 dBu vs -10 dBV: inputs %.1f dB, outputs %.1f dB apart (expected 11.8)" % (d_in, d_out)

    def t_meters(self):
        """The box's input meters (streamed by symphonyd) agree with levels measured on the Mac."""
        self.osc.send("/symphony/meters/subscribe")
        self.osc.pump(1.5)
        got = []
        for _ in range(3):
            m = self.audio.measure(400, 0.3)
            self.osc.send("/symphony/meters/subscribe")
            self.osc.values.pop("/symphony/meters/in", None)
            t0 = time.time()
            while time.time() - t0 < 1 and "/symphony/meters/in" not in self.osc.values:
                self.osc.pump(0.05)
            got.append((m, self.osc.meters_last))
        m, meter = got[-1]
        assert meter and len(meter) == 32, "no meter data from symphonyd"
        d1 = meter[0] - m.rms[0]          # In 1: headphone, a clean sine pair
        silent = meter[3]                  # In 4: nothing connected
        assert abs(d1) < 1.5, "In 1 meter %.1f dBFS vs measured %.1f" % (meter[0], m.rms[0])
        assert silent < -60, "In 4 (nothing connected) meters %.1f dBFS" % silent
        return "In 1 meter %.1f vs measured %.1f dBFS; In 3 %.1f vs %.1f; empty In 4 %.0f dBFS" % (
            meter[0], m.rms[0], meter[2], m.rms[2], silent)

    def t_softlimit(self):
        p = "/symphony/io/analog/in/3/softlimit"
        start = self.osc.get(p)
        self.osc.set(p, 1 - int(start), wait=0.3)
        flipped = self.osc.get(p)
        self.osc.set(p, start, wait=0.3)
        assert flipped == 1 - int(start) and self.osc.get(p) == start, "soft limit didn't toggle"
        return "toggles and reads back"

    def t_optical_format(self):
        p = "/symphony/io/optical/spdif"
        start = self.osc.get(p)
        self.osc.set(p, 1 - int(start), wait=0.3)
        flipped = self.osc.get(p)
        self.osc.set(p, start, wait=0.3)
        assert flipped == 1 - int(start) and self.osc.get(p) == start, "optical format didn't toggle"
        return "ADAT/S-PDIF toggles and reads back"

    def mixer_tests(self, mix):
        """Mixer M output L/R -> recording channels 9/10, fed by DAW 5-7 only."""
        src_l, src_r = (0x40, 0x41) if mix == 1 else (0x60, 0x61)
        base = "/symphony/mixer/%d/" % mix
        r9, r10 = "/symphony/route/%d" % PROBE_DEST, "/symphony/route/%d" % (PROBE_DEST + 1)
        s9, s10 = self.osc.get(r9), self.osc.get(r10)
        self.audio.play([5, 6, 7])
        self.osc.set(r9, src_l)
        self.osc.set(r10, src_r, wait=0.3)
        try:
            m0 = self.audio.measure()
            heard = m0.present(PROBE_INPUT)
            assert heard == [5, 6, 7], "mixer %d L carries %s, expected DAW 5-7" % (mix, heard)
            ref5, ref6, ref7 = (m0.level(PROBE_INPUT, d) for d in (5, 6, 7))
            facts = []

            self.osc.set(base + "in/5/fader", -20.0)
            m = self.audio.measure()
            d5, d6 = ref5 - m.level(PROBE_INPUT, 5), ref6 - m.level(PROBE_INPUT, 6)
            self.osc.set(base + "in/5/fader", 0.0)
            assert approx(d5, 20, 1.0) and abs(d6) < 0.5, "fader -20 dB: in 5 dropped %.1f, in 6 moved %.1f" % (d5, d6)
            facts.append("fader -20 dB → %.1f dB" % d5)

            self.osc.set(base + "in/5/mute", 1)
            m = self.audio.measure()
            self.osc.set(base + "in/5/mute", 0)
            assert ref5 - m.level(PROBE_INPUT, 5) > 40, "mute didn't silence input 5"
            facts.append("mute ok")

            self.osc.set(base + "in/7/solo", 1)
            m = self.audio.measure()
            self.osc.set(base + "in/7/solo", 0)
            assert m.present(PROBE_INPUT) == [7], "solo 7: hears %s" % m.present(PROBE_INPUT)
            facts.append("solo ok")

            self.osc.set(base + "in/5/pan", 1.0)
            m = self.audio.measure()
            self.osc.set(base + "in/5/pan", 0.0)
            l, r = m.level(PROBE_INPUT, 5), m.level(PROBE_INPUT + 1, 5)
            assert r - l > 20, "pan right: L %.1f, R %.1f" % (l, r)
            facts.append("pan right L %.0f / R %.1f dBFS" % (l, r))

            self.osc.set(base + "master/fader", -10.0)
            m = self.audio.measure()
            self.osc.set(base + "master/fader", 0.0)
            d = ref6 - m.level(PROBE_INPUT, 6)
            assert approx(d, 10, 1.0), "master -10 dB measured %.1f" % d
            facts.append("master -10 dB → %.1f dB" % d)
            self.notes.append("Mixer %d at 0 dB faders, centre pan: DAW 5 at %.1f dBFS on L (tone %.0f)" % (mix, ref5, TONE_DB))
            return ", ".join(facts)
        finally:
            self.osc.set(r9, s9)
            self.osc.set(r10, s10)
            self.audio.play(range(1, 17))

    def t_mixer1(self):
        return self.mixer_tests(1)

    def t_mixer2(self):
        return self.mixer_tests(2)

    def t_sample_rate(self):
        found = []
        try:
            for rate in (96000, 44100, 88200, 48000):
                self.osc.set("/symphony/clock/rate", float(rate), wait=2.5)
                box = self.osc.get("/symphony/clock/rate")
                self.audio.reopen()
                m = self.audio.measure()
                ok = self.audio.rate == rate and box == rate and 3 in m.present(LOOP_INPUT)
                found.append("%d: %s" % (rate, "ok" if ok else "core audio %s, box %s, loop %s" % (self.audio.rate, box, m.present(LOOP_INPUT))))
                assert ok, "; ".join(found)
        finally:
            if self.audio.rate != 48000:
                self.osc.set("/symphony/clock/rate", 48000.0, wait=2.5)
                self.audio.reopen()
        return "44.1/48/88.2/96 kHz: Mac, box and audio loop all agree"

    def t_handshake_drop(self):
        symctl("release")
        t0 = time.time()
        while time.time() - t0 < 6:
            rc, out, _ = symctl("read", "0xdd", "0", "1")
            if out == "00":
                break
            time.sleep(0.2)
        took = time.time() - t0
        assert out == "00", "symphonyd didn't re-send host ready"
        return "dropped handshake restored in %.1f s" % took

    def daemon_pid(self):
        r = subprocess.run(["launchctl", "print", "gui/%d/ca.arraymusic.symphonyd" % os.getuid()], capture_output=True, text=True)
        for line in r.stdout.splitlines():
            if line.strip().startswith("pid ="):
                return int(line.split("=")[1])
        return None

    def wait_connected(self, timeout):
        t0 = time.time()
        while time.time() - t0 < timeout:
            self.osc.new_socket()
            self.osc.subscribe(wait=0.8)
            if self.osc.values.get("/symphony/connected") == 1 and self.osc.seen.get("/symphony/connected", 0) > t0:
                return time.time() - t0
        return None

    def t_daemon_crash(self):
        pid = self.daemon_pid()
        assert pid, "symphonyd isn't running under launchd"
        self.osc.set("/symphony/monitor/hp/2/mirror", 0x2A, wait=0.4)   # remembered across restarts?
        os.kill(pid, 9)
        took = self.wait_connected(20)
        new = self.daemon_pid()
        assert took is not None and new and new != pid, "symphonyd didn't come back after being killed"
        kept = self.osc.get("/symphony/monitor/hp/2/mirror")
        self.osc.set("/symphony/monitor/hp/2/mirror", -1)
        self.hp_feed(2, 0xC0)
        assert kept == 0x2A, "headphone mirror not remembered (%s)" % kept
        return "killed pid %d; launchd restarted it (pid %d), OSC back in %.1f s, headphone mirror remembered" % (pid, new, took)

    def t_usb_reset(self):
        rc, out, err = symctl("usb-reset")
        assert rc == 0, "usb-reset failed: " + err
        time.sleep(2)
        took = self.wait_connected(25)
        assert took is not None, "symphonyd didn't reconnect after the USB reset"
        rc, out, _ = symctl("read", "0xdd", "0", "1")
        assert out == "00", "handshake not re-sent after reconnect"
        self.audio.reopen()
        m = self.audio.measure()
        assert 3 in m.present(LOOP_INPUT), "audio didn't come back (In 3 hears %s)" % m.present(LOOP_INPUT)
        return "unplug/replug equivalent: reconnected, handshake re-sent, audio back (%.1f s)" % took

    def t_soak(self, seconds=120):
        """Keep changing settings and measuring while watching for the box hanging."""
        import random
        rnd = random.Random(7)
        log = os.path.expanduser("~/Library/Logs/symphonyd.log")
        start_size = os.path.getsize(log)
        p1, p2 = "/symphony/monitor/hp/2/level", "/symphony/mixer/2/in/16/pan"
        s1, s2 = self.osc.get(p1), self.osc.get(p2)
        t0, n, bad = time.time(), 0, 0
        while time.time() - t0 < seconds:
            self.osc.set(p1, float(rnd.randint(-40, -20)), wait=0.02)
            self.osc.set(p2, rnd.choice([-1.0, -0.5, 0.0, 0.5, 1.0]), wait=0.02)
            m = self.audio.measure(150, 0.15)
            if 3 not in m.present(LOOP_INPUT):
                bad += 1
            n += 1
        self.osc.set(p1, s1)
        self.osc.set(p2, s2, wait=0.3)
        with open(log) as f:
            f.seek(start_size)
            tail = f.read()
        hangs = tail.count("not responding") + tail.count("failed requests")
        assert hangs == 0, "box stopped answering during the soak (%d log entries)" % hangs
        assert bad == 0, "audio loop dropped out in %d of %d checks" % (bad, n)
        return "%d rounds in %d s: no dropouts, no hangs" % (n, seconds)

    def t_profiles(self):
        name = "hwtest profile"
        lvl, mirror, soft = "/symphony/monitor/hp/2/level", "/symphony/monitor/hp/2/mirror", "/symphony/io/analog/in/5/softlimit"
        s_lvl, s_soft = self.osc.get(lvl), self.osc.get(soft)
        try:
            self.osc.set(lvl, -31.0)
            self.osc.set(mirror, 0x26)
            self.osc.set(soft, 1 - int(s_soft), wait=0.4)
            self.osc.set("/symphony/profile/save", name, wait=0.6)
            assert name in self.osc.values.get("/symphony/profiles", ""), "profile not listed after saving"
            self.osc.set(lvl, -45.0)                     # change everything...
            self.osc.set(mirror, -1)
            self.osc.set(soft, int(s_soft), wait=0.4)
            self.hp_feed(2, 0xC0)
            self.osc.set("/symphony/profile/load", name, wait=1.0)   # ...and load it back
            got = (self.osc.get(lvl), self.osc.get(mirror), self.osc.get(soft))
            heard = self.audio.measure().present(HP_INPUT[2])
            assert got == (-31.0, 0x26, 1 - int(s_soft)), "after loading: level/mirror/soft limit = %s" % (got,)
            assert heard == [7, 8], "HP2 should mirror Analog Out 7-8 after loading, hears %s" % heard
            self.osc.errors.clear()
            self.osc.set("/symphony/profile/save", "../escape", wait=0.4)
            assert self.osc.errors, "unsafe profile name accepted"
        finally:
            self.osc.set("/symphony/profile/delete", name, wait=0.5)
            self.osc.set(mirror, -1)
            self.hp_feed(2, 0xC0)
            self.osc.set(lvl, s_lvl)
            self.osc.set(soft, s_soft, wait=0.3)
        assert name not in self.osc.values.get("/symphony/profiles", ""), "profile not deleted"
        return "save, load (incl. headphone mirror, checked by ear-equivalent), unsafe name rejected, delete"

    def t_restore_after_reboot(self):
        """symphonyd puts back settings the box lost while it wasn't watching."""
        soft = "/symphony/io/analog/in/6/softlimit"
        want = self.osc.get(soft)
        uid = os.getuid()
        plist = os.path.expanduser("~/Library/LaunchAgents/ca.arraymusic.symphonyd.plist")
        subprocess.run(["launchctl", "bootout", "gui/%d/ca.arraymusic.symphonyd" % uid], capture_output=True)
        time.sleep(1)
        symctl("write", "0x22", "5", "%02x" % (1 - int(want)))   # the box "forgets"
        subprocess.run(["launchctl", "bootstrap", "gui/%d" % uid, plist], capture_output=True)
        took = self.wait_connected(20)
        time.sleep(1)
        rc, out, _ = symctl("read", "0x22", "5", "1")
        assert took is not None, "symphonyd didn't come back"
        assert int(out, 16) == int(want), "soft limit 6 is %s on the box, saved value was %d" % (out, want)
        return "setting changed behind symphonyd's back was put back on reconnect"

    def t_app(self):
        app = os.path.expanduser("~/Applications/Symphony Control.app")
        assert os.path.isdir(app), "app not installed"
        subprocess.run(["open", app])
        time.sleep(4)
        r = subprocess.run(["pgrep", "-x", "SymphonyControl"], capture_output=True, text=True)
        assert r.stdout.strip(), "app didn't stay running"
        shot = os.path.join(BUILD, "test-app.png")
        subprocess.run(["screencapture", "-x", shot])
        return "launched and running (screenshot: build/test-app.png)"


def main():
    s = Suite()
    started = time.strftime("%Y-%m-%d %H:%M:%S")
    try:
        s.setup()
        tests = [
            ("handshake", s.t_handshake),
            ("OSC state dump", s.t_osc_state),
            ("OSC error handling", s.t_osc_errors),
            ("OSC malformed packets", s.t_osc_garbage),
            ("OSC set/inc/dec/toggle/clamp", s.t_osc_ops),
            ("follows changes made elsewhere", s.t_follow_external),
            ("audio loopback paths", s.t_audio_paths),
            ("headphone own feed", s.t_hp_own_feed),
            ("headphone mirror", s.t_hp_mirror),
            ("headphone level", s.t_hp_level),
            ("headphone mute/dim/mono", s.t_hp_mute_dim_mono),
            ("main level", s.t_main_level),
            ("routing: output", s.t_route_output),
            ("routing: recording channel", s.t_route_record),
            ("analog reference levels", s.t_ref_levels),
            ("input meters", s.t_meters),
            ("soft limit", s.t_softlimit),
            ("optical format", s.t_optical_format),
            ("mixer 1", s.t_mixer1),
            ("mixer 2", s.t_mixer2),
            ("sample rates", s.t_sample_rate),
            ("dropped handshake", s.t_handshake_drop),
            ("profiles", s.t_profiles),
            ("restore after box reboot", s.t_restore_after_reboot),
            ("symphonyd crash recovery", s.t_daemon_crash),
            ("USB reset recovery", s.t_usb_reset),
            ("soak (2 min)", s.t_soak),
            ("control app", s.t_app),
        ]
        only = sys.argv[1:]
        for name, fn in tests:
            if only and not any(o.lower() in name.lower() for o in only):
                continue
            s.run(name, fn)
    finally:
        s.teardown()

    counts = {}
    for _, st, _ in s.results:
        counts[st] = counts.get(st, 0) + 1
    summary = ", ".join("%d %s" % (v, k) for k, v in sorted(counts.items()))
    print("\n" + summary)
    for n in s.notes:
        print("note: " + n)
    os.makedirs(BUILD, exist_ok=True)
    with open(os.path.join(BUILD, "test-results.md"), "w") as f:
        f.write("# Hardware test results\n\nRun %s. %s.\n\n| Result | Test | Detail |\n| --- | --- | --- |\n" % (started, summary))
        for name, st, detail in s.results:
            f.write("| %s | %s | %s |\n" % (st, name, detail.replace("|", "/")))
        if s.notes:
            f.write("\n## Measurements\n\n" + "\n".join("- " + n.replace("\n", "\n  ") for n in s.notes) + "\n")
    sys.exit(0 if all(st in ("PASS", "INFO") for _, st, _ in s.results) else 1)


if __name__ == "__main__":
    main()
