#!/usr/bin/env python3
"""Switch the RaptorEx CNC (FluidNC) between the office network and its own access point.

macOS port of cnc-wifi.ps1 (originally on the Windows Candle PC). No dependencies.

Usage:
  python3 cnc-wifi.py office   # join KorayBirand -> http://raptorex-012.local/  (tablet pendant offline)
  python3 cnc-wifi.py tablet   # be access point Raptorex_012 / 192.168.4.1      (tablet pendant works)
  python3 cnc-wifi.py status   # show current mode, no restart

Options:
  --port /dev/cu.usbserial-XXXX  serial device (default: the single /dev/cu.*usb* device found)
  --telnet [HOST]                use Wi-Fi (port 23) instead of USB. Default host raptorex-012.local;
                                 when the controller is in AP mode, join Raptorex_012 and use 192.168.4.1.

Notes:
  - Disconnect anything holding the port first (the app's Machine panel, Candle, a telnet session).
  - office/tablet restart the controller. With off_on_alarm:false in raptorex.yaml the spindle
    can twitch on restart - remove the bit or cut spindle power.
  - Station SSID/password stay stored in the controller; this only flips $WiFi/Mode.
  - Over --telnet the boot log cannot be watched ($Bye drops the connection), so the final
    state is not confirmed; over USB it is.
"""

import argparse
import fcntl
import glob
import os
import re
import select
import socket
import struct
import sys
import termios
import time


class SerialLink:
    """115200 8N1, raw. HUPCL cleared and DTR+RTS set together so the ESP32 is not
    reset on open/close (same approach as the app's SerialTransport)."""

    def __init__(self, path):
        self.fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        attrs = termios.tcgetattr(self.fd)
        attrs[0] = 0                                    # iflag
        attrs[1] = 0                                    # oflag
        attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL  # cflag, HUPCL cleared
        attrs[3] = 0                                    # lflag
        attrs[4] = termios.B115200                      # ispeed
        attrs[5] = termios.B115200                      # ospeed
        attrs[6][termios.VMIN] = 0
        attrs[6][termios.VTIME] = 0
        termios.tcsetattr(self.fd, termios.TCSANOW, attrs)
        bits = struct.pack('i', termios.TIOCM_DTR | termios.TIOCM_RTS)
        fcntl.ioctl(self.fd, termios.TIOCMSET, bits)
        time.sleep(0.4)
        termios.tcflush(self.fd, termios.TCIFLUSH)

    def send(self, cmd, wait_s):
        os.write(self.fd, (cmd + "\n").encode())
        end = time.monotonic() + wait_s
        buf = bytearray()
        while time.monotonic() < end:
            r, _, _ = select.select([self.fd], [], [], 0.08)
            if r:
                try:
                    chunk = os.read(self.fd, 4096)
                except OSError:
                    break
                if chunk:
                    buf += chunk
        return buf.decode(errors="replace")

    def close(self):
        os.close(self.fd)


class TelnetLink:
    def __init__(self, host):
        self.sock = socket.create_connection((host, 23), timeout=5)
        self.sock.settimeout(0.08)
        self.closed = False

    def send(self, cmd, wait_s):
        self.sock.sendall((cmd + "\n").encode())
        end = time.monotonic() + wait_s
        buf = bytearray()
        while time.monotonic() < end:
            try:
                chunk = self.sock.recv(4096)
                if not chunk:          # controller restarted and dropped us
                    self.closed = True
                    break
                buf += chunk
            except socket.timeout:
                pass
            except OSError:
                self.closed = True
                break
        return buf.decode(errors="replace")

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def find_port():
    candidates = []
    for pattern in ("/dev/cu.usbserial*", "/dev/cu.wchusbserial*",
                    "/dev/cu.SLAB*", "/dev/cu.usbmodem*"):
        candidates += glob.glob(pattern)
    return candidates


def main():
    ap = argparse.ArgumentParser(description="Flip the Raptorex's FluidNC $WiFi/Mode.")
    ap.add_argument("mode", choices=["office", "tablet", "status"])
    ap.add_argument("--port", help="serial device, e.g. /dev/cu.usbserial-0001")
    ap.add_argument("--telnet", nargs="?", const="raptorex-012.local", metavar="HOST",
                    help="use Wi-Fi (port 23) instead of USB")
    args = ap.parse_args()

    if args.telnet:
        try:
            link = TelnetLink(args.telnet)
        except OSError as e:
            sys.exit(f"Cannot reach {args.telnet}:23 ({e}). In AP mode join Raptorex_012 "
                     f"and use --telnet 192.168.4.1.")
    else:
        port = args.port
        if not port:
            found = find_port()
            if len(found) == 1:
                port = found[0]
            elif not found:
                sys.exit("No USB serial device found. Plug the machine in, pass --port, "
                         "or use --telnet.")
            else:
                sys.exit("Several serial devices found, pass --port:\n  " + "\n  ".join(found))
        try:
            link = SerialLink(port)
        except OSError as e:
            sys.exit(f"Cannot open {port} ({e}) - is the Machine panel, Candle or "
                     f"another sender still connected?")

    try:
        if args.mode == "status":
            print(link.send("$WiFi/Mode", 1.2).strip())
            print(link.send("[ESP420]", 2.5).strip())
            return

        target = "STA>AP" if args.mode == "office" else "AP"
        print(f"Setting $WiFi/Mode={target} ...")
        r = link.send(f"$WiFi/Mode={target}", 1.5)
        if "ok" not in r:
            sys.exit(f"Unexpected reply: {r!r}")

        print("Restarting controller (spindle may twitch) - watching boot log for 25 s ...")
        boot = link.send("$Bye", 25)

        ip = re.search(r"IP is (\d+\.\d+\.\d+\.\d+)", boot)
        ap_up = re.search(r"AP SSID (\S+) IP (\d+\.\d+\.\d+\.\d+)", boot)
        if ip:
            print(f"Joined office network. IP {ip.group(1)}  -  http://raptorex-012.local/")
        elif ap_up:
            print(f"Access point {ap_up.group(1)} up at {ap_up.group(2)}. "
                  f"Tablet pendant can connect.")
        elif args.telnet and getattr(link, "closed", False):
            where = ("join Raptorex_012, controller at 192.168.4.1" if target == "AP"
                     else "controller at http://raptorex-012.local/")
            print(f"Controller restarting (telnet dropped, boot log not visible): {where}")
        else:
            print("Could not confirm WiFi state from boot log:")
            print(boot)
    finally:
        link.close()


if __name__ == "__main__":
    main()
