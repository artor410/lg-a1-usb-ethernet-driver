#!/usr/bin/env python3
"""PC side of netprobe (Python 3 standard library only, works on Windows).

  netprobe_pc.py udpsend HOST PORT --mbps N [--size 1400] --seconds S [--fps F]
  netprobe_pc.py rtt HOST PORT [--count N] [--interval-ms M] [--size B]

Payload: big-endian uint64 sequence number + uint64 sender timestamp (ns),
padded to --size bytes. Matches `netprobe sink` / `netprobe echo` on the TV.
"""
import argparse
import math
import socket
import statistics
import struct
import sys
import time

HDR = struct.Struct("!QQ")
SPIN_NS = 2_000_000  # busy-wait the last 2 ms; OS sleep is too coarse


def wait_until(deadline_ns):
    """Sleep coarsely, then spin, until perf_counter_ns() >= deadline_ns."""
    while True:
        left = deadline_ns - time.perf_counter_ns()
        if left <= 0:
            return
        if left > SPIN_NS:
            time.sleep((left - SPIN_NS) / 1e9)


def udpsend(a):
    if a.size < HDR.size:
        sys.exit(f"--size must be >= {HDR.size}")
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 * 1024 * 1024)
    dest = (a.host, a.port)
    pad = bytes(a.size - HDR.size)
    pkt_per_s = a.mbps * 1e6 / 8 / a.size
    seq = sent_bytes = errors = 0

    def send_one():
        nonlocal seq, sent_bytes, errors
        try:
            sent_bytes += sock.sendto(HDR.pack(seq, time.perf_counter_ns()) + pad, dest)
        except OSError:
            errors += 1  # e.g. WSAENOBUFS; the sequence gap shows up as loss
        seq += 1

    start = time.perf_counter_ns()
    end = start + int(a.seconds * 1e9)
    if a.fps:
        # Video-like: each frame (mbps/fps bits) as one back-to-back burst.
        # Spread the fractional packet count over frames to hit the exact rate.
        frame_ns = 1e9 / a.fps
        frame = 0
        while True:
            t = start + int(frame * frame_ns)
            if t >= end:
                break
            wait_until(t)
            for _ in range(max(1, round((frame + 1) * pkt_per_s / a.fps) - seq)):
                send_one()
            frame += 1
    else:
        gap_ns = 1e9 / pkt_per_s
        while True:
            t = start + int(seq * gap_ns)
            if t >= end:
                break
            wait_until(t)
            send_one()
    dur = (time.perf_counter_ns() - start) / 1e9
    mode = f"burst {a.fps} fps" if a.fps else "paced"
    print(f"udpsend: {seq} packets, {sent_bytes} bytes in {dur:.3f} s = "
          f"{sent_bytes * 8 / dur / 1e6:.2f} Mbit/s ({mode}, {a.size} B), "
          f"send errors {errors}")


def pctl(sorted_vals, p):
    """Nearest-rank percentile."""
    k = max(0, math.ceil(p / 100 * len(sorted_vals)) - 1)
    return sorted_vals[k]


def rtt(a):
    if a.size < HDR.size:
        sys.exit(f"--size must be >= {HDR.size}")
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.connect((a.host, a.port))
    pad = bytes(a.size - HDR.size)
    timeout_ns = int(a.timeout_ms * 1e6)
    rtts = []
    lost = 0
    start = time.perf_counter_ns()
    for seq in range(a.count):
        wait_until(start + int(seq * a.interval_ms * 1e6))
        t0 = time.perf_counter_ns()
        try:
            sock.send(HDR.pack(seq, t0) + pad)
        except OSError:  # includes ICMP errors reported on send
            lost += 1
            continue
        while True:
            left = t0 + timeout_ns - time.perf_counter_ns()
            if left <= 0:
                lost += 1
                break
            sock.settimeout(left / 1e9)
            try:
                data = sock.recv(65536)
            except socket.timeout:
                lost += 1
                break
            except ConnectionError:
                # ICMP port unreachable (no echo server?): count as lost after timeout
                continue
            t1 = time.perf_counter_ns()
            if len(data) >= HDR.size and HDR.unpack_from(data)[0] == seq:
                rtts.append((t1 - t0) / 1000)
                break
            # else: late reply to an older probe, already counted as lost
    if not rtts:
        print(f"rtt: 0/{a.count} replies, loss 100%")
        return 1
    s = sorted(rtts)
    print(f"rtt: {len(s)}/{a.count} replies, loss {100 * lost / a.count:.2f}%, "
          f"size {a.size} B, interval {a.interval_ms} ms")
    print(f"rtt_us: min {s[0]:.1f} avg {statistics.fmean(s):.1f} "
          f"p50 {pctl(s, 50):.1f} p90 {pctl(s, 90):.1f} p99 {pctl(s, 99):.1f} "
          f"max {s[-1]:.1f} stdev {statistics.pstdev(s):.1f}")
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("udpsend", help="UDP sender for `netprobe sink`")
    s.add_argument("host")
    s.add_argument("port", type=int)
    s.add_argument("--mbps", type=float, required=True)
    s.add_argument("--size", type=int, default=1400, help="UDP payload bytes")
    s.add_argument("--seconds", type=float, required=True)
    s.add_argument("--fps", type=float, default=0,
                   help="send each frame as a burst at F frames/s (video-like)")

    r = sub.add_parser("rtt", help="UDP RTT against `netprobe echo`")
    r.add_argument("host")
    r.add_argument("port", type=int)
    r.add_argument("--count", type=int, default=1000)
    r.add_argument("--interval-ms", type=float, default=10)
    r.add_argument("--size", type=int, default=64)
    r.add_argument("--timeout-ms", type=float, default=1000)

    a = p.parse_args()
    if a.cmd == "udpsend":
        if a.mbps <= 0 or a.seconds <= 0 or a.fps < 0:
            sys.exit("--mbps and --seconds must be > 0, --fps >= 0")
        return udpsend(a)
    return rtt(a)


if __name__ == "__main__":
    sys.exit(main() or 0)
