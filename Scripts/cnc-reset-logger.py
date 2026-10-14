#!/usr/bin/env python3
"""Log the Raptorex's USB serial output with timestamps to catch spontaneous resets.

The ESP32 prints its reset reason on the serial port at every boot
(`rst:0x..`), so one captured reset tells us WHY the controller rebooted:

  rst:0x1  POWERON / EN pin   -> something toggled the USB lines or power
                                 (host opening the port, USB suspend, cable)
  rst:0xf  BROWNOUT           -> 3.3 V dipped: PSU / regulator / connector
  rst:0xc  SW_CPU_RESET       -> firmware panic (often the Wi-Fi stack at idle)
  rst:0x3  SW_RESET           -> firmware-requested restart ($Bye, $CD, crash)
  rst:0x7 / rst:0x9 / rst:0x10 -> watchdog (TG0WDT / RTCWDT / TG1WDT)

Usage:
  python3 cnc-reset-logger.py                  # auto-detect port, log to ~/cnc-serial.log
  python3 cnc-reset-logger.py --port /dev/cu.usbserial-0001 --log /path/file.log

Leave it running for days. It opens the port with DTR+RTS held steady and
HUPCL cleared (same as the app's SerialTransport), so starting and stopping
the logger does NOT reset the board. It only reads — commands are never sent —
so Candle or the app streaming over Wi-Fi are unaffected. Every line is
timestamped; reset banners are also echoed to the terminal and marked
`*** RESET ***` in the log. If the port vanishes (cable pulled, host sleep)
it says so and keeps retrying, since those events are themselves clues.
"""

import argparse
import datetime
import fcntl
import glob
import os
import select
import struct
import sys
import termios
import time

MARKERS = ("rst:", "boot:", "Grbl ", "ets ", "MSG:INFO: FluidNC")


def find_port():
    for pattern in ("/dev/cu.usbserial*", "/dev/cu.wchusbserial*",
                    "/dev/cu.SLAB*", "/dev/cu.usbmodem*"):
        hits = glob.glob(pattern)
        if hits:
            return hits[0]
    return None


def open_port(path):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0
    attrs[1] = 0
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL   # HUPCL cleared
    attrs[3] = 0
    attrs[4] = termios.B115200
    attrs[5] = termios.B115200
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    bits = struct.pack('i', termios.TIOCM_DTR | termios.TIOCM_RTS)
    fcntl.ioctl(fd, termios.TIOCMSET, bits)
    return fd


def main():
    ap = argparse.ArgumentParser(description="Timestamped serial log to catch controller resets.")
    ap.add_argument("--port", help="serial device; default: first /dev/cu.*usb* found")
    ap.add_argument("--log", default=os.path.expanduser("~/cnc-serial.log"))
    args = ap.parse_args()

    log = open(args.log, "a", buffering=1)

    def note(text, echo=False):
        stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        log.write(f"{stamp}  {text}\n")
        if echo:
            print(f"{stamp}  {text}", flush=True)

    note("--- logger started ---", echo=True)
    fd = None
    buf = b""
    while True:
        if fd is None:
            path = args.port or find_port()
            if path:
                try:
                    fd = open_port(path)
                    note(f"--- port open: {path} (DTR+RTS held, read-only) ---", echo=True)
                except OSError as e:
                    note(f"--- cannot open {path}: {e}; retrying ---", echo=True)
                    time.sleep(5)
            else:
                time.sleep(5)
            continue
        try:
            r, _, _ = select.select([fd], [], [], 1.0)
            if not r:
                continue
            chunk = os.read(fd, 4096)
        except OSError as e:
            note(f"--- port lost ({e}) — cable/USB event? retrying ---", echo=True)
            try: os.close(fd)
            except OSError: pass
            fd = None
            buf = b""
            time.sleep(2)
            continue
        if not chunk:
            continue
        buf += chunk
        while b"\n" in buf:
            raw, buf = buf.split(b"\n", 1)
            line = raw.decode(errors="replace").rstrip("\r")
            if not line.strip():
                continue
            hot = any(m in line for m in MARKERS)
            note(("*** RESET *** " if "rst:" in line else "") + line, echo=hot)


if __name__ == "__main__":
    main()
