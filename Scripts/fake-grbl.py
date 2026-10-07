#!/usr/bin/env python3
"""fake-grbl.py — a FluidNC 3.9 / Grbl 1.1 controller simulator on a TCP port.

Dev-only stand-in for the user's machine so the Machine window, the job
streamer, probing and the height map can be exercised headlessly (plan
"Verification 3"). It speaks the telnet-style protocol of a FluidNC
controller: raw bytes, realtime characters acted on the moment they arrive
(even in the middle of a line), one `ok`/`error:N` per line, broadcast
alarms/[MSG] lines, `?` status reports with MPos/WPos, WCO, Bf, FS, Ov, Pn
and A fields, and simulated motion that takes real time (a move finishes
after length / feed minutes; MPos is interpolated meanwhile).

Usage:
    Scripts/fake-grbl.py [options]

Options:
    --port N            TCP port to listen on (default 2323, 127.0.0.1 only
                        unless --bind is given)
    --bind ADDR         interface to bind (default 127.0.0.1)
    --log FILE          append every received line to FILE; realtime bytes
                        other than '?' are written as '<0x85>' on their own
                        line (add --log-polls to record '?' too)
    --verbose           print all traffic to stdout ('<<' received, '>>' sent)
    --error-at N        answer `error:20` to the Nth received line (counted
                        over all clients, empty lines included)
    --alarm N           raise an alarm when the Nth line is received
                        (code from --alarm-code, default 1 = hard limit; a
                        critical code (1/2/3) also drops that line's reply
                        and flushes everything, like a real controller)
    --alarm-code C      alarm number for --alarm (default 1)
    --probe-fail        every G38.2/G38.4 fails: ALARM:5, then after 0.5 s
                        [PRB:x,y,z:0] + ok (G38.3/.5 just report :0)
    --surface Z         machine Z of the synthetic probe surface (default -3;
                        the surface ripples by 0.05*sin(x/10)+0.03*cos(y/8));
                        honoured by G38.2/.3 going down and G38.4/.5 going up
    --wco X,Y,Z         initial G54 offset, i.e. the machine point that is work
                        zero at boot (default 0,0,0; reported by `$#` and the
                        `WCO:` field). The app's built-in Simulator uses
                        `--wco 11,71,-81 --surface -82`, so the sample boards
                        fit the travel and the probe surface sits 1 mm below
                        work Z0.
    --parent-pid N      exit when process N is gone (the app passes its own
                        pid so a simulator it launched never outlives it)
    --wpos              report WPos instead of MPos in status reports
    --clamp-jog         clamp `$J=` targets to the travel limits instead of
                        rejecting them (a clamped jog that goes nowhere is
                        answered `ok` with no motion and no Jog state).
                        FluidNC mode clamps by default (as 3.9 does with
                        soft limits on); this flag makes --grbl clamp too.
    --grbl              pretend to be Grbl 1.1h: banner `Grbl 1.1h ['$' for
                        help]`, `$I` -> [VER:1.1h.20190825:] [OPT:V,15,128],
                        M6 -> error:20, `$/...` -> error:3, jogs beyond
                        travel -> error:15, cancelled jogs still run
                        (no in-flight cancel), lines > 80 chars -> error:14,
                        `\\r` ends a line (so `\\r\\n` yields an extra `ok`)
    --must-home         boot in ALARM:14 (FluidNC must-home); `$H` or `$X`
                        clears it
    --no-soft-limits    report `soft_limits=false` and never raise ALARM:2 or
                        bound a jog (moves may leave the machine range)
    --banner-on-connect send the welcome banner to each new client (a USB
                        Grbl resets on open; FluidNC over Wi-Fi does not)
    --jog-cancel-ok     answer an in-flight jog cancelled by 0x85 with `ok`
                        (FluidNC >= 3.9.x) instead of `error:130` +
                        `[MSG:ERR: Jog Cancelled]` (FluidNC 3.7/3.8)
    --home-seconds S    how long `$H` takes (default 2)

Machine model:
    Travel X 310, Y 360, Z 145 (`$/axes/<a>/max_travel_mm`). FluidNC mode
    homes like a typical router: X and Y to machine 0 at the negative end
    (`homing/positive_direction=false`, range 0..travel) and Z to machine 0
    at the top (`positive_direction=true`, range -145..0), 1 mm pull-off, so
    the position after boot/homing is (1, 1, -1) and a program in positive
    work coordinates runs with WCO 0,0,0. `--grbl` uses Grbl's convention
    instead: every axis in [-travel, 0], homed at (-1, -1, -1). WCO is 0,0,0
    (or `--wco`) until G10 L20 / G10 L2 / G92 / G54..G59 change it. Rapids run at
    2000 mm/min, feed moves at the modal F, probes at their own F, jogs at
    the `$J=` F. The planner holds 15 blocks: a motion line is answered
    `ok` when it is planned, immediately while fewer than 15 blocks are
    queued, otherwise when a block frees. Synchronising commands (G4, M0/M1,
    M2/M30, M3/M4/M5, M7/M8/M9, G38.x, $H) answer after the queue drains.

Protocol summary:
    ?      status report (to the asker only)       !      feed hold
    ~      cycle start / resume                     0x18   soft reset
    0x84   safety door                              0x85   jog cancel
    0x90-0x94 feed override, 0x95-0x97 rapid override, 0x99-0x9D spindle
    override, 0x9E spindle stop toggle (Hold:0 only), 0xA0/0xA1 coolant
    $I $G $# $$ $C $X $H $SLP $J= $/path[=value]  (see `cmd_system`)
    ok / error:N go to the sending client only; ALARM:N, [MSG:...] and
    the banner are broadcast to every client.

Example (run in the background, then):
    python3 -c "import socket; s=socket.create_connection(('127.0.0.1',2323));
                s.sendall(b'?\\n\\$I\\nG0 X10 F100\\n'); print(s.recv(4096))"
"""

import argparse
import math
import queue
import re
import socket
import sys
import threading
import time
import random
from collections import deque

# ---------------------------------------------------------------------------
# Machine constants
# ---------------------------------------------------------------------------

AXES = ("X", "Y", "Z")
TRAVEL = {"X": 310.0, "Y": 360.0, "Z": 145.0}   # mm
PULL_OFF = 1.0                                  # mm off the switch after homing
# Homing direction per axis: True = switch at the positive end, machine range
# [-travel, 0]; False = switch at the negative end, range [0, travel].
FLUIDNC_POSITIVE = {"X": False, "Y": False, "Z": True}
GRBL_POSITIVE = {"X": True, "Y": True, "Z": True}
RAPID_FEED = 2000.0                             # mm/min for G0 and $H moves
PLANNER_BLOCKS = 15
RX_BYTES = 128
MOTION_TICK = 0.005                             # s between motion updates
HOLD_DECEL = 0.1                                # s from Hold:1 to Hold:0
PROBE_FAIL_PRB_DELAY = 0.5                      # s between ALARM:5 and [PRB]
GRBL_MAX_LINE = 80

FLUIDNC_VERSION = "3.9.9"
FLUIDNC_BANNER = "Grbl 3.9 [FluidNC v%s (wifi) '$' for help]" % FLUIDNC_VERSION
GRBL_BANNER = "Grbl 1.1h ['$' for help]"

# Realtime bytes (Grbl 1.1 / FluidNC)
RT_STATUS = 0x3F
RT_FEED_HOLD = 0x21
RT_CYCLE_START = 0x7E
RT_RESET = 0x18
RT_DOOR = 0x84
RT_JOG_CANCEL = 0x85
RT_OVERRIDES = {
    0x90: ("feed", "reset"), 0x91: ("feed", 10), 0x92: ("feed", -10),
    0x93: ("feed", 1), 0x94: ("feed", -1),
    0x95: ("rapid", 100), 0x96: ("rapid", 50), 0x97: ("rapid", 25),
    0x99: ("spindle", "reset"), 0x9A: ("spindle", 10), 0x9B: ("spindle", -10),
    0x9C: ("spindle", 1), 0x9D: ("spindle", -1),
}
RT_SPINDLE_STOP = 0x9E
RT_FLOOD = 0xA0
RT_MIST = 0xA1
REALTIME_BYTES = {RT_STATUS, RT_FEED_HOLD, RT_CYCLE_START, RT_RESET, RT_DOOR,
                  RT_JOG_CANCEL, RT_SPINDLE_STOP, RT_FLOOD, RT_MIST} | set(RT_OVERRIDES)

# Error codes (Grbl 1.1 numbering, shared by FluidNC)
ERR_EXPECTED_LETTER = 1
ERR_BAD_NUMBER = 2
ERR_INVALID_STATEMENT = 3
ERR_IDLE = 8
ERR_GCODE_LOCK = 9
ERR_LINE_OVERFLOW = 14
ERR_TRAVEL_EXCEEDED = 15
ERR_UNSUPPORTED = 20
ERR_MODAL_GROUP = 21
ERR_NO_FEED = 22
ERR_INVALID_JOG = 23
ERR_NO_ARC_OFFSET = 31
ERR_JOG_CANCELLED = 130

# Alarm codes
ALARM_HARD_LIMIT = 1
ALARM_SOFT_LIMIT = 2
ALARM_ABORT_CYCLE = 3
ALARM_PROBE_FAIL = 5
ALARM_MUST_HOME = 14
CRITICAL_ALARMS = {ALARM_HARD_LIMIT, ALARM_SOFT_LIMIT, ALARM_ABORT_CYCLE}

WCO_REFRESH_IDLE = 10          # WCO every 10th report (FluidNC idle count)
OV_REFRESH_IDLE = 10

_NUMBER = re.compile(r"[-+]?(?:\d+\.?\d*|\.\d+)")


def fmt(v):
    return "%.3f" % v


def fmt3(p):
    return ",".join(fmt(c) for c in p)


class LineError(Exception):
    """A per-line error:N reply."""

    def __init__(self, code):
        super().__init__(code)
        self.code = code


class Flushed(Exception):
    """The line was discarded by a reset/alarm while it was waiting (no reply)."""


# ---------------------------------------------------------------------------
# Planner blocks
# ---------------------------------------------------------------------------

class Block:
    """One planned motion. `kind` is move / jog / probe; `feed` in mm/min."""

    def __init__(self, kind, start, end, feed, client, rapid=False, probe=None):
        self.kind = kind
        self.start = tuple(start)
        self.end = tuple(end)
        self.feed = feed
        self.rapid = rapid
        self.client = client
        self.probe = probe          # dict(mode, toward) for probe blocks
        self.length = math.dist(self.start, self.end)
        self.progress = 0.0         # mm travelled so far
        self.done = False
        self.triggered = None       # probe: machine position at contact


# ---------------------------------------------------------------------------
# The controller
# ---------------------------------------------------------------------------

class Machine:
    def __init__(self, opts):
        self.steps_per_mm = {"X": 800.0, "Y": 800.0, "Z": 800.0}
        self.config_filename = "raptorex.yaml"
        self.config_saved_to = None
        self.opts = opts
        self.lock = threading.RLock()
        self.cond = threading.Condition(self.lock)
        self.clients = []
        self.generation = 0         # bumped by every flush; waiters abandon their line
        self.line_count = 0         # received lines, all clients
        self.log_file = open(opts.log, "a") if opts.log else None
        self.reset_runtime(boot=True)

    # -- state ---------------------------------------------------------------

    def reset_runtime(self, boot=False):
        """What a soft reset clears. The parser's modal state and offsets survive."""
        self.queue = deque()
        self.state = "Idle"
        self.hold_sub = 0
        self.hold_started = 0.0
        self.door_sub = 0
        self.alarm_code = None
        self.check_mode = False
        self.sleeping = False
        self.needs_reset = False    # Grbl after a critical alarm: dead until 0x18
        self.jog_cancel_serial = 0
        self.jog_cancel_time = 0.0
        self.wco_counter = 0        # 0 -> next report carries WCO
        self.ov_counter = 1
        self.ov = {"feed": 100, "rapid": 100, "spindle": 100}
        self.spindle_stopped_in_hold = False
        self.probe_pin = False
        if boot:
            self.mpos = self.home_position()
            self.homed = not self.opts.must_home
            self.modal = {
                "motion": "G0", "wcs": 0, "plane": "G17", "units": "G21",
                "distance": "G90", "feed_mode": "G94", "spindle": "M5",
                "flood": False, "mist": False, "tool": 0, "F": 0.0, "S": 0.0,
            }
            self.wcs_offsets = [[0.0, 0.0, 0.0] for _ in range(6)]
            self.wcs_offsets[0] = list(self.opts.wco)
            self.g92 = [0.0, 0.0, 0.0]
            self.g28 = [0.0, 0.0, 0.0]
            self.g30 = [0.0, 0.0, 0.0]
            self.tlo = 0.0
            self.probe_last = ([0.0, 0.0, 0.0], False)
            if self.opts.must_home:
                self.state = "Alarm"
                self.alarm_code = ALARM_MUST_HOME
        self.planned = list(self.mpos)   # parser position: end of the queue

    @property
    def is_grbl(self):
        return self.opts.grbl

    def banner(self):
        return GRBL_BANNER if self.is_grbl else FLUIDNC_BANNER

    def wco(self):
        base = self.wcs_offsets[self.modal["wcs"]]
        return [base[i] + self.g92[i] + (self.tlo if i == 2 else 0.0) for i in range(3)]

    def in_motion(self):
        return self.state in ("Run", "Jog", "Home") or (self.state == "Hold" and self.hold_sub == 1)

    def surface_z(self, x, y):
        return self.opts.surface + 0.05 * math.sin(x / 10.0) + 0.03 * math.cos(y / 8.0)

    @property
    def positive(self):
        return GRBL_POSITIVE if self.is_grbl else FLUIDNC_POSITIVE

    def axis_range(self, a):
        return (-TRAVEL[a], 0.0) if self.positive[a] else (0.0, TRAVEL[a])

    def home_position(self):
        return [-PULL_OFF if self.positive[a] else PULL_OFF for a in AXES]

    @property
    def soft_limits(self):
        return not self.opts.no_soft_limits

    def within_travel(self, p):
        if not self.soft_limits:
            return True
        return all(self.axis_range(a)[0] - 1e-6 <= p[i] <= self.axis_range(a)[1] + 1e-6
                   for i, a in enumerate(AXES))

    def clamp_travel(self, p):
        return [min(self.axis_range(a)[1], max(self.axis_range(a)[0], p[i])) for i, a in enumerate(AXES)]

    # -- I/O -----------------------------------------------------------------

    def log(self, text):
        if self.log_file:
            self.log_file.write(text + "\n")
            self.log_file.flush()

    def broadcast(self, text):
        for c in list(self.clients):
            c.send_line(text)

    def msg(self, text, client=None):
        """A [MSG:...] line. FluidNC prefixes its level; Grbl does not."""
        line = "[MSG:%s]" % text if self.is_grbl else "[MSG:INFO: %s]" % text
        self.broadcast(line)

    def alarm(self, code, flush=True):
        """Broadcast ALARM:n, enter Alarm. Critical codes flush everything."""
        self.alarm_code = code
        self.state = "Alarm"
        self.broadcast("ALARM:%d" % code)
        if code in CRITICAL_ALARMS:
            self.homed = False if code != ALARM_SOFT_LIMIT else self.homed
            if flush:
                self.flush()
            if self.is_grbl and code != ALARM_ABORT_CYCLE:
                self.broadcast("[MSG:Reset to continue]")
                self.needs_reset = True

    def flush(self):
        """Drop every planned block and every line still waiting for the planner."""
        self.queue.clear()
        self.planned = list(self.mpos)
        self.generation += 1
        for c in list(self.clients):
            c.drop_pending()
        self.cond.notify_all()

    # -- waiting helpers (lock held) ------------------------------------------

    def wait_until(self, predicate):
        """Block (releasing the lock) until predicate() holds. Raises Flushed
        if a reset/alarm discarded the waiting line meanwhile."""
        gen = self.generation
        while not predicate():
            if self.generation != gen:
                raise Flushed()
            self.cond.wait(0.05)
        if self.generation != gen:
            raise Flushed()

    def sync(self):
        """protocol_buffer_synchronize: wait for the queue to drain."""
        self.wait_until(lambda: not self.queue and self.state not in ("Run", "Jog", "Home"))

    def plan(self, block):
        """Append a block once the planner has room; the caller sends ok after."""
        self.wait_until(lambda: len(self.queue) < PLANNER_BLOCKS)
        self.queue.append(block)
        self.planned = list(block.end)
        if self.state == "Idle":
            self.state = "Jog" if block.kind == "jog" else "Run"
        elif self.state == "Jog" and block.kind != "jog":
            self.state = "Run"
        self.cond.notify_all()

    # -- motion thread -------------------------------------------------------

    def motion_loop(self):
        last = time.monotonic()
        while True:
            time.sleep(MOTION_TICK)
            now = time.monotonic()
            dt, last = now - last, now
            with self.lock:
                self.tick(dt, now)

    def tick(self, dt, now):
        if self.state == "Hold" and self.hold_sub == 1 and now - self.hold_started >= HOLD_DECEL:
            self.hold_sub = 0
            self.cond.notify_all()
        if self.state not in ("Run", "Jog") or not self.queue:
            if self.state in ("Run", "Jog") and not self.queue:
                self.state = "Idle"
                self.cond.notify_all()
            return
        block = self.queue[0]
        if block.length <= 1e-9:
            self.finish(block)
            return
        if block.kind == "probe":
            speed = block.feed
        elif block.rapid:
            speed = RAPID_FEED * self.ov["rapid"] / 100.0
        elif block.kind == "jog":
            speed = block.feed
        else:
            speed = block.feed * self.ov["feed"] / 100.0
        step = speed / 60.0 * dt
        target = min(block.length, block.progress + step)
        if block.kind == "probe":
            hit = self.probe_contact(block, block.progress, target)
            if hit is not None:
                self.mpos = list(hit)
                block.triggered = tuple(hit)
                self.probe_pin = True
                self.finish(block)
                return
        block.progress = target
        f = target / block.length
        self.mpos = [block.start[i] + (block.end[i] - block.start[i]) * f for i in range(3)]
        if target >= block.length - 1e-9:
            self.finish(block)

    def finish(self, block):
        self.mpos = list(block.end) if block.triggered is None else list(block.triggered)
        block.done = True
        if self.queue and self.queue[0] is block:
            self.queue.popleft()
        if not self.queue:
            self.planned = list(self.mpos)
            if self.state in ("Run", "Jog"):
                self.state = "Idle"
        self.cond.notify_all()

    def probe_contact(self, block, from_mm, to_mm):
        """Where a probe block meets the synthetic surface between two
        progress values, or None. Only Z travel can trigger: toward (G38.2/.3)
        when descending onto the surface, away (G38.4/.5) when rising off it."""
        dz = block.end[2] - block.start[2]
        if abs(dz) < 1e-9 or self.opts.probe_fail:
            return None
        start_z = block.start[2] + dz * (from_mm / block.length)
        end_z = block.start[2] + dz * (to_mm / block.length)
        x = block.start[0] + (block.end[0] - block.start[0]) * (to_mm / block.length)
        y = block.start[1] + (block.end[1] - block.start[1]) * (to_mm / block.length)
        surface = self.surface_z(x, y)
        toward = block.probe["toward"]
        if toward and dz < 0 and start_z > surface >= end_z:
            return (x, y, surface)
        if not toward and dz > 0 and start_z < surface <= end_z:
            return (x, y, surface)
        return None

    # -- status report -------------------------------------------------------

    def state_text(self):
        if self.state == "Hold":
            return "Hold:%d" % self.hold_sub
        if self.state == "Door":
            return "Door:%d" % self.door_sub
        return self.state

    def status_report(self):
        parts = [self.state_text()]
        if self.opts.wpos:
            w = self.wco()
            parts.append("WPos:" + fmt3([self.mpos[i] - w[i] for i in range(3)]))
        else:
            parts.append("MPos:" + fmt3(self.mpos))
        rx = RX_BYTES - sum(c.pending_bytes() for c in self.clients)
        parts.append("Bf:%d,%d" % (PLANNER_BLOCKS - len(self.queue), max(0, rx)))
        parts.append("FS:%d,%d" % (self.current_feed(), self.current_spindle()))
        pins = ""
        if self.probe_pin:
            pins += "P"
        if pins:
            parts.append("Pn:" + pins)
        if self.wco_counter > 0:
            self.wco_counter -= 1
        else:
            self.wco_counter = WCO_REFRESH_IDLE - 1
            if self.ov_counter == 0:
                self.ov_counter = 1
            parts.append("WCO:" + fmt3(self.wco()))
        if self.ov_counter > 0:
            self.ov_counter -= 1
        else:
            self.ov_counter = OV_REFRESH_IDLE - 1
            parts.append("Ov:%d,%d,%d" % (self.ov["feed"], self.ov["rapid"], self.ov["spindle"]))
            acc = self.accessories()
            if acc:
                parts.append("A:" + acc)
        return "<" + "|".join(parts) + ">"

    def accessories(self):
        acc = ""
        if self.modal["spindle"] == "M3" and not self.spindle_stopped_in_hold:
            acc += "S"
        elif self.modal["spindle"] == "M4" and not self.spindle_stopped_in_hold:
            acc += "C"
        if self.modal["flood"]:
            acc += "F"
        if self.modal["mist"]:
            acc += "M"
        return acc

    def current_feed(self):
        if self.state not in ("Run", "Jog") or not self.queue:
            return 0
        b = self.queue[0]
        if b.kind == "probe" or b.kind == "jog":
            return int(round(b.feed))
        if b.rapid:
            return int(round(RAPID_FEED * self.ov["rapid"] / 100.0))
        return int(round(b.feed * self.ov["feed"] / 100.0))

    def current_spindle(self):
        if self.modal["spindle"] == "M5" or self.spindle_stopped_in_hold:
            return 0
        return int(round(self.modal["S"] * self.ov["spindle"] / 100.0))

    # -- realtime bytes ------------------------------------------------------

    def realtime(self, client, byte):
        with self.lock:
            if byte == RT_STATUS:
                client.send_line(self.status_report())
            elif byte == RT_RESET:
                self.soft_reset()
            elif self.sleeping:
                return
            elif byte == RT_FEED_HOLD:
                self.feed_hold()
            elif byte == RT_CYCLE_START:
                self.cycle_start()
            elif byte == RT_DOOR:
                self.door()
            elif byte == RT_JOG_CANCEL:
                self.jog_cancel()
            elif byte in RT_OVERRIDES:
                self.override(*RT_OVERRIDES[byte])
            elif byte == RT_SPINDLE_STOP:
                if self.state == "Hold" and self.hold_sub == 0 and self.modal["spindle"] != "M5":
                    self.spindle_stopped_in_hold = not self.spindle_stopped_in_hold
            elif byte == RT_FLOOD:
                if self.state in ("Idle", "Run", "Hold"):
                    self.modal["flood"] = not self.modal["flood"]
            elif byte == RT_MIST:
                if self.state in ("Idle", "Run", "Hold"):
                    self.modal["mist"] = not self.modal["mist"]

    def soft_reset(self):
        was_moving = self.in_motion()
        lost = self.state in ("Alarm",) and self.alarm_code in CRITICAL_ALARMS
        keep_alarm = self.alarm_code if (lost or self.alarm_code == ALARM_MUST_HOME) else None
        self.flush()
        if was_moving:
            self.alarm(ALARM_ABORT_CYCLE, flush=False)
            keep_alarm = ALARM_ABORT_CYCLE
        self.reset_runtime()
        # gc_init: parser modes back to defaults, G92 cleared; G54..G59 and
        # G28/G30 are persistent and survive.
        self.modal.update({"motion": "G0", "wcs": 0, "plane": "G17", "units": "G21",
                           "distance": "G90", "feed_mode": "G94", "spindle": "M5",
                           "flood": False, "mist": False, "tool": 0, "F": 0.0, "S": 0.0})
        self.g92 = [0.0, 0.0, 0.0]
        self.broadcast(self.banner())
        if keep_alarm is not None:
            self.state = "Alarm"
            self.alarm_code = keep_alarm
            self.broadcast("[MSG:'$H'|'$X' to unlock]" if self.is_grbl
                           else "[MSG:INFO: '$H'|'$X' to unlock]")
        self.cond.notify_all()

    def feed_hold(self):
        if self.state in ("Run",):
            self.state, self.hold_sub, self.hold_started = "Hold", 1, time.monotonic()
        elif self.state == "Idle":
            self.state, self.hold_sub = "Hold", 0
        elif self.state == "Jog":
            # A feed hold during a jog cancels the jog (Grbl 1.1 / FluidNC).
            self.jog_cancel()
        self.cond.notify_all()

    def cycle_start(self):
        if self.state == "Hold" and self.hold_sub == 0:
            self.spindle_stopped_in_hold = False
            self.state = "Run" if self.queue else "Idle"
        elif self.state == "Door" and self.door_sub == 0:
            self.state = "Run" if self.queue else "Idle"
        self.cond.notify_all()

    def door(self):
        if self.state in ("Idle", "Run", "Hold", "Jog"):
            if self.state == "Jog":
                self.jog_cancel()
            self.state, self.door_sub = "Door", 0
        self.cond.notify_all()

    def jog_cancel(self):
        self.jog_cancel_serial += 1
        self.jog_cancel_time = time.monotonic()
        if self.state == "Jog":
            self.queue.clear()
            self.planned = list(self.mpos)
            self.state = "Idle"
        self.cond.notify_all()

    def override(self, which, change):
        if change == "reset":
            self.ov[which] = 100
        elif which == "rapid":
            self.ov[which] = change
        else:
            self.ov[which] = max(10, min(200, self.ov[which] + change))
        self.ov_counter = 0     # report Ov on the next status

    # -- lines ---------------------------------------------------------------

    def execute_line(self, client, raw):
        """Process one received line on the client's worker thread. Replies
        (ok/error) go to the client; may block on the planner or a sync."""
        with self.lock:
            self.line_count += 1
            n = self.line_count
            self.log(raw)
            if self.opts.verbose:
                print("[%s] << %s" % (client.name, raw), flush=True)
            try:
                if self.opts.alarm and n == self.opts.alarm:
                    # A critical alarm flushes the RX buffer: no reply at all.
                    # A non-critical one is followed by the line's own ok.
                    self.alarm(self.opts.alarm_code)
                    if self.opts.alarm_code in CRITICAL_ALARMS:
                        raise Flushed()
                    client.send_line("ok")
                    return
                if self.sleeping or self.needs_reset:
                    return
                if self.opts.error_at and n == self.opts.error_at:
                    raise LineError(ERR_UNSUPPORTED)
                if self.is_grbl and len(raw) > GRBL_MAX_LINE:
                    raise LineError(ERR_LINE_OVERFLOW)
                line = strip_comments(raw)
                if line == "":
                    client.send_line("ok")
                elif line.startswith("$"):
                    self.cmd_system(client, line)
                else:
                    self.cmd_gcode(client, line)
            except LineError as e:
                client.send_line("error:%d" % e.code)
            except Flushed:
                pass

    # -- $ commands ------------------------------------------------------------

    def require_idle(self):
        if self.state not in ("Idle", "Alarm"):
            raise LineError(ERR_IDLE)

    def cmd_system(self, client, line):
        if line.startswith("$J="):
            return self.cmd_jog(client, line[3:])
        cmd = line[1:]
        if cmd in ("", "$"):
            if self.state in ("Run", "Hold", "Jog"):
                raise LineError(ERR_IDLE)
            if cmd == "":
                for h in ("[HLP:$$ $# $G $I $N $x=val $Nx=line $J=line $SLP $C $X $H ~ ! ? ctrl-x]",):
                    client.send_line(h)
            else:
                for s in self.settings_list():
                    client.send_line(s)
            client.send_line("ok")
        elif cmd == "I":
            if not self.is_grbl:
                self.require_idle()
                client.send_line("[VER:3.9 FluidNC v%s (wifi):]" % FLUIDNC_VERSION)
                client.send_line("[OPT:MPHSEW]")
                client.send_line("[MSG:Machine: Raptorex Mini V2]")
                client.send_line("[MSG:Mode=STA:SSID=shop:Status=Connected:IP=127.0.0.1:MAC=00-00-00-00-00-00]")
            else:
                self.require_idle()
                client.send_line("[VER:1.1h.20190825:]")
                client.send_line("[OPT:V,15,128]")
            client.send_line("ok")
        elif cmd == "G":
            client.send_line(self.parser_state())
            client.send_line("ok")
        elif cmd == "#":
            self.require_idle()
            for i in range(6):
                client.send_line("[G%d:%s]" % (54 + i, fmt3(self.wcs_offsets[i])))
            client.send_line("[G28:%s]" % fmt3(self.g28))
            client.send_line("[G30:%s]" % fmt3(self.g30))
            client.send_line("[G92:%s]" % fmt3(self.g92))
            client.send_line("[TLO:%s]" % fmt(self.tlo))
            client.send_line("[PRB:%s:%d]" % (fmt3(self.probe_last[0]), 1 if self.probe_last[1] else 0))
            client.send_line("ok")
        elif cmd == "C":
            if self.check_mode:
                self.broadcast("[MSG:Disabled]")
                client.send_line("ok")
                self.check_mode = False
                self.soft_reset()
            else:
                if self.state != "Idle":
                    raise LineError(ERR_IDLE)
                self.check_mode = True
                self.state = "Check"
                self.broadcast("[MSG:Enabled]")
                client.send_line("ok")
        elif cmd == "X":
            if self.state == "Alarm":
                self.state = "Idle"
                self.alarm_code = None
                self.needs_reset = False
                if not self.is_grbl:
                    self.homed = True       # FluidNC marks the axes homed on unlock
                self.msg("Caution: Unlocked")
            client.send_line("ok")
        elif cmd == "H":
            self.require_idle()
            self.cmd_home(client)
        elif cmd == "SLP":
            self.require_idle()
            self.msg("Sleeping")
            client.send_line("ok")
            self.sleeping = True
            self.state = "Sleep"
        elif cmd.startswith("/"):
            if self.is_grbl:
                raise LineError(ERR_INVALID_STATEMENT)
            self.cmd_setting(client, cmd)
        elif cmd.upper().startswith("CONFIG/FILENAME"):
            # $Config/Filename reports the boot config; =name changes it.
            if self.is_grbl:
                raise LineError(ERR_INVALID_STATEMENT)
            _, _, value = cmd.partition("=")
            if value:
                self.config_filename = value.strip()
            client.send_line("$Config/Filename=%s" % self.config_filename)
            client.send_line("ok")
        elif cmd.upper() == "CD" or cmd.upper().startswith("CD="):
            # $CD dumps the running config; $CD=<file> writes it to that file.
            if self.is_grbl:
                raise LineError(ERR_INVALID_STATEMENT)
            _, _, value = cmd.partition("=")
            if value:
                self.config_saved_to = value.strip()
                self.log("config dumped to %s (steps %s)" % (value.strip(), self.steps_per_mm))
            else:
                for axis in AXES:
                    client.send_line("[MSG:INFO: axes/%s/steps_per_mm: %g]" % (axis.lower(), self.steps_per_mm[axis]))
            client.send_line("ok")
        elif re.fullmatch(r"\d+=.*", cmd):
            self.require_idle()
            client.send_line("ok")
        elif cmd.startswith("N"):
            self.require_idle()
            if cmd == "N":
                client.send_line("$N0=")
                client.send_line("$N1=")
            client.send_line("ok")
        else:
            raise LineError(ERR_INVALID_STATEMENT)

    def settings_list(self):
        mask = 2 if self.opts.wpos else 3
        yield "$0=10"
        yield "$1=255"
        yield "$2=0"
        yield "$3=0"
        yield "$4=0"
        yield "$5=0"
        yield "$6=0"
        yield "$10=%d" % mask
        yield "$11=0.010"
        yield "$12=0.002"
        yield "$13=0"
        yield "$20=%d" % (1 if self.soft_limits else 0)
        yield "$21=1"
        yield "$22=1"
        yield "$23=0"
        yield "$24=200.000"
        yield "$25=2000.000"
        yield "$26=250"
        yield "$27=%s" % fmt(PULL_OFF)
        yield "$30=12000.000"
        yield "$31=6000.000"
        yield "$32=0"
        for i in range(3):
            yield "$10%d=800.000" % i
        for i in range(3):
            yield "$11%d=%s" % (i, fmt(RAPID_FEED))
        for i in range(3):
            yield "$12%d=200.000" % i
        for i, a in enumerate(AXES):
            yield "$13%d=%s" % (i, fmt(TRAVEL[a]))

    def cmd_setting(self, client, cmd):
        """FluidNC `$/path` reads (and `$/path=value` writes, accepted silently)."""
        path, _, value = cmd.partition("=")
        key = path.lower()
        m = re.fullmatch(r"/axes/([xyz])/(.+)", key)
        values = {}
        if m:
            axis = m.group(1).upper()
            values = {
                "max_travel_mm": "%g" % TRAVEL[axis],
                "soft_limits": "true" if self.soft_limits else "false",
                "homing/mpos_mm": "0",
                "homing/positive_direction": "true" if self.positive[axis] else "false",
                "homing/cycle": {"X": "2", "Y": "2", "Z": "1"}[axis],
                "homing/feed_mm_per_min": "100",
                "homing/seek_mm_per_min": "800",
                "homing/mm_per_retract": "%g" % PULL_OFF,
                "steps_per_mm": "%g" % self.steps_per_mm[axis],
                "max_rate_mm_per_min": "%g" % RAPID_FEED,
                "acceleration_mm_per_sec2": "200",
            }
            value_now = values.get(m.group(2))
        elif key == "/axes/shared/stepping/engine":
            value_now = "RMT"
        elif key == "/name":
            value_now = "Raptorex Mini V2"
        elif key == "/start/must_home":
            value_now = "true" if self.opts.must_home else "false"
        else:
            value_now = None
        if value_now is None:
            raise LineError(ERR_INVALID_STATEMENT)
        if value == "" and "=" not in cmd:
            client.send_line("$%s=%s" % (key, value_now))
        else:
            self.require_idle()
            if m and m.group(2) == "steps_per_mm":
                try:
                    self.steps_per_mm[m.group(1).upper()] = float(value)
                except ValueError:
                    raise LineError(ERR_INVALID_STATEMENT)
        client.send_line("ok")

    def parser_state(self):
        m = self.modal
        words = [m["motion"], "G%d" % (54 + m["wcs"]), m["plane"], m["units"],
                 m["distance"], m["feed_mode"], m["spindle"]]
        if m["flood"] and m["mist"]:
            words += ["M7", "M8"]
        elif m["flood"]:
            words.append("M8")
        elif m["mist"]:
            words.append("M7")
        else:
            words.append("M9")
        words.append("T%d" % m["tool"])
        words.append("F%d" % int(round(m["F"])))
        words.append("S%d" % int(round(m["S"])))
        return "[GC:%s]" % " ".join(words)

    def cmd_home(self, client):
        if self.check_mode:
            client.send_line("ok")
            return
        self.state = "Home"
        self.alarm_code = None
        self.needs_reset = False
        deadline = time.monotonic() + self.opts.home_seconds
        gen = self.generation
        while time.monotonic() < deadline:
            if self.generation != gen or self.state != "Home":
                raise Flushed()
            self.cond.wait(0.05)
        self.mpos = self.home_position()
        self.planned = list(self.mpos)
        self.homed = True
        self.state = "Idle"
        self.cond.notify_all()
        client.send_line("ok")

    # -- jogging ---------------------------------------------------------------

    def cmd_jog(self, client, text):
        if self.state not in ("Idle", "Jog"):
            raise LineError(ERR_IDLE)
        words = parse_words(text)
        distance = self.modal["distance"]
        units = self.modal["units"]
        machine_coords = False
        feed = None
        target = {}
        for letter, value in words:
            if letter == "G":
                if value == 90:
                    distance = "G90"
                elif value == 91:
                    distance = "G91"
                elif value == 20:
                    units = "G20"
                elif value == 21:
                    units = "G21"
                elif value == 53:
                    machine_coords = True
                else:
                    raise LineError(ERR_INVALID_JOG)
            elif letter == "F":
                feed = value
            elif letter in AXES:
                target[letter] = value
            elif letter == "N":
                pass
            else:
                raise LineError(ERR_INVALID_JOG)
        if feed is None or feed <= 0:
            raise LineError(ERR_NO_FEED)
        if not target:
            raise LineError(ERR_INVALID_JOG)
        scale = 25.4 if units == "G20" else 1.0
        feed *= scale
        start = list(self.planned)
        end = list(start)
        wco = self.wco()
        for i, a in enumerate(AXES):
            if a not in target:
                continue
            v = target[a] * scale
            if distance == "G91":
                end[i] = start[i] + v
            elif machine_coords:
                end[i] = v
            else:
                end[i] = v + wco[i]
        if not self.within_travel(end):
            if self.opts.clamp_jog or (not self.is_grbl):
                end = self.clamp_travel(end)
            else:
                raise LineError(ERR_TRAVEL_EXCEEDED)
        if self.check_mode:
            client.send_line("ok")
            return
        if math.dist(start, end) < 1e-9:
            client.send_line("ok")       # clamped at the limit: nothing to do
            return
        serial = self.jog_cancel_serial
        block = Block("jog", start, end, feed, client)
        self.plan(block)
        cancelled = (self.jog_cancel_serial != serial
                     or time.monotonic() - self.jog_cancel_time < 0.03)
        if cancelled and not self.is_grbl:
            # FluidNC cancels the jog that was blocked in the planner.
            if block in self.queue:
                self.queue.remove(block)
            self.planned = list(self.mpos) if not self.queue else list(self.queue[-1].end)
            if not self.queue and self.state == "Jog":
                self.state = "Idle"
            if self.opts.jog_cancel_ok:
                client.send_line("ok")
            else:
                client.send_line("error:%d" % ERR_JOG_CANCELLED)
                self.broadcast("[MSG:ERR: Jog Cancelled]")
            return
        client.send_line("ok")

    # -- G-code ----------------------------------------------------------------

    def cmd_gcode(self, client, line):
        if self.state == "Alarm":
            raise LineError(ERR_GCODE_LOCK)
        words = parse_words(line)
        m = self.modal
        motion = None
        non_modal = None            # G4 / G10 / G28 / G30 / G53 / G92 ...
        probe = None
        mcodes = []
        axis_words = {}
        offsets = {}
        radius = None
        P = L = None
        feed = None
        for letter, value in words:
            if letter == "G":
                code = round(value, 1)
                if code in (0, 1, 2, 3):
                    motion = "G%d" % int(code)
                elif code in (38.2, 38.3, 38.4, 38.5):
                    motion = "G38"
                    probe = {"mode": code, "toward": code in (38.2, 38.3)}
                elif code == 80:
                    motion = "G80"
                elif code in (4, 10, 28, 28.1, 30, 30.1, 53, 92, 92.1):
                    non_modal = code
                elif code in (17, 18, 19):
                    m["plane"] = "G%d" % int(code)
                elif code in (20, 21):
                    m["units"] = "G%d" % int(code)
                elif code in (90, 91):
                    m["distance"] = "G%d" % int(code)
                elif code in (90.1, 91.1):
                    pass
                elif code in (93, 94):
                    m["feed_mode"] = "G%d" % int(code)
                elif 54 <= code <= 59 and code == int(code):
                    m["wcs"] = int(code) - 54
                    self.wco_counter = 0
                elif code in (43.1, 49):
                    non_modal = code
                else:
                    raise LineError(ERR_UNSUPPORTED)
            elif letter == "M":
                code = int(value)
                if code in (0, 1, 2, 30, 3, 4, 5, 7, 8, 9):
                    mcodes.append(code)
                elif code == 6:
                    if self.is_grbl:
                        raise LineError(ERR_UNSUPPORTED)
                    mcodes.append(6)
                elif code in (56, 62, 63, 64, 65, 67, 68):
                    mcodes.append(code)
                else:
                    raise LineError(ERR_UNSUPPORTED)
            elif letter in AXES:
                axis_words[letter] = value
            elif letter in ("I", "J", "K"):
                offsets[letter] = value
            elif letter == "R":
                radius = value
            elif letter == "F":
                feed = value
            elif letter == "S":
                m["S"] = max(0.0, value)
            elif letter == "T":
                m["tool"] = int(value)
            elif letter == "P":
                P = value
            elif letter == "L":
                L = value
            elif letter == "N":
                pass
            else:
                raise LineError(ERR_UNSUPPORTED)

        scale = 25.4 if m["units"] == "G20" else 1.0
        if feed is not None:
            if feed <= 0 and (motion in ("G1", "G2", "G3", "G38") or
                              (motion is None and m["motion"] in ("G1", "G2", "G3") and axis_words)):
                raise LineError(ERR_NO_FEED)
            m["F"] = feed * scale

        if self.check_mode:
            # Check mode validates and answers at once; nothing moves.
            if motion in ("G0", "G1", "G2", "G3"):
                m["motion"] = motion
            self.apply_sync_mcodes(mcodes, check=True)
            client.send_line("ok")
            return

        # Synchronising M-codes act before the line's motion (spindle/coolant),
        # or after it (M0/M1/M2/M30) — Grbl order.
        if any(c in (3, 4, 5, 7, 8, 9) for c in mcodes):
            self.sync()
            self.apply_sync_mcodes([c for c in mcodes if c in (3, 4, 5, 7, 8, 9)])

        if non_modal == 43.1:
            self.tlo = axis_words.get("Z", 0.0) * scale
            self.wco_counter = 0
            axis_words = {}
        elif non_modal == 49:
            self.tlo = 0.0
            self.wco_counter = 0
        if non_modal == 4:
            if P is None:
                raise LineError(ERR_BAD_NUMBER)
            self.sync()
            if P > 0:
                self.dwell(P)
        elif non_modal == 10:
            self.set_offsets(L, P, axis_words, scale)
        elif non_modal in (28.1, 30.1):
            store = self.g28 if non_modal == 28.1 else self.g30
            store[:] = list(self.planned)
        elif non_modal in (28, 30):
            dest = self.g28 if non_modal == 28 else self.g30
            self.move(client, "G0", list(dest), rapid=True)
            motion = None
        elif non_modal == 92:
            for i, a in enumerate(AXES):
                if a in axis_words:
                    self.g92[i] = self.planned[i] - self.wcs_offsets[m["wcs"]][i] - axis_words[a] * scale
            self.wco_counter = 0
        elif non_modal == 92.1:
            self.g92 = [0.0, 0.0, 0.0]
            self.wco_counter = 0

        if motion == "G80":
            m["motion"] = "G80"
        elif motion == "G38":
            if not axis_words:
                raise LineError(ERR_UNSUPPORTED)
            if m["F"] <= 0:
                raise LineError(ERR_NO_FEED)
            self.probe(client, probe, axis_words, scale, non_modal == 53)
        elif motion is not None or (axis_words and non_modal not in (10, 92, 28.1, 30.1)):
            if motion is not None:
                m["motion"] = motion
            if axis_words and m["motion"] in ("G0", "G1", "G2", "G3"):
                target = self.target_from(axis_words, scale, non_modal == 53)
                if m["motion"] == "G0":
                    self.move(client, "G0", target, rapid=True)
                elif m["motion"] == "G1":
                    if m["F"] <= 0:
                        raise LineError(ERR_NO_FEED)
                    self.move(client, "G1", target)
                else:
                    if m["F"] <= 0:
                        raise LineError(ERR_NO_FEED)
                    if not offsets and radius is None:
                        raise LineError(ERR_NO_ARC_OFFSET)
                    self.arc(client, target, offsets, radius, scale, m["motion"] == "G2")

        if any(c in (0, 1, 2, 30) for c in mcodes):
            self.sync()
            self.apply_sync_mcodes([c for c in mcodes if c in (0, 1, 2, 30)])
        client.send_line("ok")

    def apply_sync_mcodes(self, codes, check=False):
        m = self.modal
        for c in codes:
            if c == 3:
                m["spindle"] = "M3"
            elif c == 4:
                m["spindle"] = "M4"
            elif c == 5:
                m["spindle"] = "M5"
            elif c == 7:
                m["mist"] = True
            elif c == 8:
                m["flood"] = True
            elif c == 9:
                m["flood"] = m["mist"] = False
            elif c in (0, 1) and not check:
                self.state, self.hold_sub = "Hold", 0
                self.cond.notify_all()
            elif c in (2, 30):
                m.update({"motion": "G1", "wcs": 0, "plane": "G17", "distance": "G90",
                          "feed_mode": "G94", "spindle": "M5", "flood": False, "mist": False})
                if c == 30 and not check:
                    pass

    def dwell(self, seconds):
        deadline = time.monotonic() + seconds
        gen = self.generation
        while time.monotonic() < deadline:
            if self.generation != gen:
                raise Flushed()
            self.cond.wait(min(0.05, max(0.001, deadline - time.monotonic())))

    def set_offsets(self, L, P, axis_words, scale):
        if L not in (2, 20) or P is None:
            raise LineError(ERR_UNSUPPORTED)
        idx = int(P)
        if idx == 0:
            idx = self.modal["wcs"]
        else:
            idx -= 1
        if not 0 <= idx < 6:
            raise LineError(ERR_UNSUPPORTED)
        for i, a in enumerate(AXES):
            if a not in axis_words:
                continue
            v = axis_words[a] * scale
            if L == 20:
                # Make the current position read as v: offset = planned - g92 - v.
                self.wcs_offsets[idx][i] = self.planned[i] - self.g92[i] - v
            else:
                self.wcs_offsets[idx][i] = v
        self.wco_counter = 0

    def target_from(self, axis_words, scale, machine_coords):
        start = self.planned
        end = list(start)
        wco = self.wco()
        for i, a in enumerate(AXES):
            if a not in axis_words:
                continue
            v = axis_words[a] * scale
            if self.modal["distance"] == "G91":
                end[i] = start[i] + v
            elif machine_coords:
                end[i] = v
            else:
                end[i] = v + wco[i]
        return end

    def move(self, client, motion, target, rapid=False):
        start = list(self.planned)
        if self.homed and not self.within_travel(target):
            self.alarm(ALARM_SOFT_LIMIT)
            raise Flushed()
        self.plan(Block("move", start, target, self.modal["F"], client, rapid=rapid))

    def arc(self, client, target, offsets, radius, scale, clockwise):
        """An arc is one block whose length is the true arc length; MPos
        follows the chord (good enough for a simulator)."""
        start = list(self.planned)
        plane = {"G17": (0, 1), "G18": (0, 2), "G19": (1, 2)}[self.modal["plane"]]
        a, b = plane
        if radius is not None:
            r = radius * scale
            chord = math.hypot(target[a] - start[a], target[b] - start[b])
            if chord > 2 * abs(r) + 1e-6 or chord < 1e-9:
                raise LineError(33)
            h = math.sqrt(max(0.0, r * r - (chord / 2) ** 2))
            mx, my = (start[a] + target[a]) / 2, (start[b] + target[b]) / 2
            ux, uy = (target[a] - start[a]) / chord, (target[b] - start[b]) / chord
            sign = -1 if (clockwise) == (r > 0) else 1
            cx, cy = mx + sign * h * -uy, my + sign * h * ux
        else:
            ci = {0: "I", 1: "J", 2: "K"}
            cx = start[a] + offsets.get(ci[a], 0.0) * scale
            cy = start[b] + offsets.get(ci[b], 0.0) * scale
            r = math.hypot(start[a] - cx, start[b] - cy)
        a0 = math.atan2(start[b] - cy, start[a] - cx)
        a1 = math.atan2(target[b] - cy, target[a] - cx)
        sweep = a1 - a0
        if clockwise:
            if sweep >= -1e-9:
                sweep -= 2 * math.pi
        else:
            if sweep <= 1e-9:
                sweep += 2 * math.pi
        length = math.hypot(abs(sweep) * abs(r), target[3 - a - b] - start[3 - a - b])
        if self.homed and not self.within_travel(target):
            self.alarm(ALARM_SOFT_LIMIT)
            raise Flushed()
        block = Block("move", start, target, self.modal["F"], client)
        block.length = max(length, 1e-9)
        self.plan(block)

    def probe(self, client, probe, axis_words, scale, machine_coords):
        target = self.target_from(axis_words, scale, machine_coords)
        self.sync()
        start = list(self.planned)
        if self.homed and not self.within_travel(target):
            self.alarm(ALARM_SOFT_LIMIT)
            raise Flushed()
        block = Block("probe", start, target, self.modal["F"], client, probe=probe)
        self.plan(block)
        self.wait_until(lambda: block.done)
        self.probe_pin = False
        hit = block.triggered
        if hit is not None:
            self.probe_last = (list(hit), True)
            client.send_line("[PRB:%s:1]" % fmt3(hit))
            return
        self.probe_last = (list(self.mpos), False)
        if probe["mode"] in (38.2, 38.4):
            self.alarm(ALARM_PROBE_FAIL)
            self.dwell_unconditional(PROBE_FAIL_PRB_DELAY)
        client.send_line("[PRB:%s:0]" % fmt3(self.mpos))

    def dwell_unconditional(self, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            self.cond.wait(min(0.05, max(0.001, deadline - time.monotonic())))


# ---------------------------------------------------------------------------
# Parsing helpers
# ---------------------------------------------------------------------------

def strip_comments(raw):
    """Remove ( ) and ; comments and all whitespace; upper-case the rest."""
    out = []
    depth = 0
    for ch in raw:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth = max(0, depth - 1)
        elif ch == ";" and depth == 0:
            break
        elif depth == 0 and not ch.isspace():
            out.append(ch.upper())
    return "".join(out)


def parse_words(text):
    """'G91X-0.1F500' -> [('G', 91.0), ('X', -0.1), ('F', 500.0)]."""
    words = []
    i = 0
    n = len(text)
    while i < n:
        letter = text[i]
        if not letter.isalpha():
            raise LineError(ERR_EXPECTED_LETTER)
        m = _NUMBER.match(text, i + 1)
        if not m:
            raise LineError(ERR_BAD_NUMBER)
        try:
            value = float(m.group(0))
        except ValueError:
            raise LineError(ERR_BAD_NUMBER)
        words.append((letter, value))
        i = m.end()
    return words


# ---------------------------------------------------------------------------
# Clients and server
# ---------------------------------------------------------------------------

class Client:
    def __init__(self, machine, sock, addr):
        self.machine = machine
        self.sock = sock
        self.name = "%s:%d" % addr
        self.send_lock = threading.Lock()
        self.lines = queue.Queue()
        self.closed = False
        self._pending_bytes = 0

    def send_line(self, text):
        if self.machine.opts.verbose:
            print("[%s] >> %s" % (self.name, text), flush=True)
        data = (text + "\r\n").encode("utf-8", "replace")
        jitter = getattr(self.machine.opts, "jitter", 0)
        if jitter:
            time.sleep(random.uniform(0, jitter / 1000.0))   # Wi-Fi-like reply latency
        with self.send_lock:
            try:
                self.sock.sendall(data)
            except OSError:
                self.closed = True

    def pending_bytes(self):
        return self._pending_bytes

    def drop_pending(self):
        """A reset/alarm empties the RX buffer: queued lines vanish unanswered."""
        try:
            while True:
                self.lines.get_nowait()
        except queue.Empty:
            pass
        self._pending_bytes = 0

    def reader(self):
        buf = bytearray()
        grbl = self.machine.is_grbl
        try:
            while not self.closed:
                data = self.sock.recv(4096)
                if not data:
                    break
                for b in data:
                    if b in REALTIME_BYTES:
                        if b != RT_STATUS or self.machine.opts.log_polls:
                            self.machine.log("<0x%02x>" % b)
                        self.machine.realtime(self, b)
                    elif b == 0x0A or (b == 0x0D and grbl):
                        line = buf.decode("utf-8", "replace")
                        buf = bytearray()
                        self._pending_bytes += len(line) + 1
                        self.lines.put(line)
                    elif b == 0x0D:
                        continue
                    elif b >= 0x80:
                        continue        # other extended realtime bytes: ignored
                    else:
                        buf.append(b)
        except OSError:
            pass
        finally:
            self.closed = True
            self.lines.put(None)

    def worker(self):
        while True:
            line = self.lines.get()
            if line is None:
                break
            self._pending_bytes = max(0, self._pending_bytes - len(line) - 1)
            self.machine.execute_line(self, line)


def watch_parent(pid):
    """Exit once the process that launched us is gone (it cannot always
    terminate us itself: a crash or a bare exit() skips its handlers)."""
    import os
    while True:
        time.sleep(1.0)
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            os._exit(0)
        except PermissionError:
            pass          # alive, owned by someone else


def parse_wco(text):
    parts = text.split(",")
    if len(parts) != 3:
        raise argparse.ArgumentTypeError("expected X,Y,Z (e.g. 11,71,-81)")
    try:
        return [float(v) for v in parts]
    except ValueError:
        raise argparse.ArgumentTypeError("expected three numbers: %r" % text)


def serve(opts):
    machine = Machine(opts)
    threading.Thread(target=machine.motion_loop, daemon=True).start()
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((opts.bind, opts.port))
    srv.listen(5)
    mode = "Grbl 1.1h" if opts.grbl else "FluidNC %s" % FLUIDNC_VERSION
    print("fake-grbl: %s on %s:%d%s%s" % (mode, opts.bind, opts.port,
          " wco %s" % fmt3(opts.wco) if any(opts.wco) else "",
          " (ALARM:14, must home)" if opts.must_home else ""), flush=True)
    if opts.parent_pid:
        threading.Thread(target=watch_parent, args=(opts.parent_pid,), daemon=True).start()
    while True:
        sock, addr = srv.accept()
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        client = Client(machine, sock, addr)
        with machine.lock:
            machine.clients.append(client)
        if opts.verbose:
            print("[%s] connected" % client.name, flush=True)
        if opts.banner_on_connect:
            client.send_line(machine.banner())

        def run_client(c=client):
            t = threading.Thread(target=c.worker, daemon=True)
            t.start()
            c.reader()
            t.join(timeout=1)
            with machine.lock:
                if c in machine.clients:
                    machine.clients.remove(c)
            try:
                c.sock.close()
            except OSError:
                pass
            if opts.verbose:
                print("[%s] disconnected" % c.name, flush=True)

        threading.Thread(target=run_client, daemon=True).start()


def main(argv=None):
    p = argparse.ArgumentParser(description="FluidNC / Grbl controller simulator (TCP).",
                                formatter_class=argparse.RawDescriptionHelpFormatter,
                                epilog=__doc__.split("Options:")[0])
    p.add_argument("--port", type=int, default=2323)
    p.add_argument("--bind", default="127.0.0.1")
    p.add_argument("--log", metavar="FILE")
    p.add_argument("--log-polls", action="store_true", help="also log '?' polls")
    p.add_argument("--verbose", action="store_true")
    p.add_argument("--jitter", type=float, default=0, metavar="MS", help="random 0..MS ms delay before every reply")
    p.add_argument("--error-at", type=int, default=0, metavar="N")
    p.add_argument("--alarm", type=int, default=0, metavar="N")
    p.add_argument("--alarm-code", type=int, default=ALARM_HARD_LIMIT, metavar="C")
    p.add_argument("--probe-fail", action="store_true")
    p.add_argument("--surface", type=float, default=-3.0, metavar="Z")
    p.add_argument("--wco", type=parse_wco, default=[0.0, 0.0, 0.0], metavar="X,Y,Z",
                   help="initial G54 offset (machine point of work zero)")
    p.add_argument("--parent-pid", type=int, default=0, metavar="N",
                   help="exit when process N is gone")
    p.add_argument("--wpos", action="store_true")
    p.add_argument("--clamp-jog", action="store_true")
    p.add_argument("--grbl", action="store_true")
    p.add_argument("--must-home", action="store_true")
    p.add_argument("--no-soft-limits", action="store_true")
    p.add_argument("--banner-on-connect", action="store_true")
    p.add_argument("--jog-cancel-ok", action="store_true")
    p.add_argument("--home-seconds", type=float, default=2.0, metavar="S")
    opts = p.parse_args(argv)
    try:
        serve(opts)
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
