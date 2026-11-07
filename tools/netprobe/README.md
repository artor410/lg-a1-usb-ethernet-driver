# netprobe

Small measurement harness for A/B testing driver and kernel tweaks on the TV.

- `netprobe.c`: runs on the TV (static ARMv7 binary, libc only).
  - `sink PORT SECONDS [RCVBUF_BYTES]`: UDP receiver. Prints one JSON line:
    packets, bytes, mbps, lost, reordered, duplicates, loss_pct, jitter_us
    (RFC 3550 interarrival jitter), max_gap_us, rcvbuf (as reported by
    getsockopt, i.e. doubled by the kernel), and the deltas of `Udp InErrors`
    and `RcvbufErrors` from `/proc/net/snmp` over the run (system-wide).
    The timer starts at the first packet; it stops SECONDS later or after 2 s
    without packets. It exits with an error if nothing arrives within 60 s.
    RCVBUF_BYTES uses `SO_RCVBUFFORCE` (root) and falls back to `SO_RCVBUF`
    (capped by `net.core.rmem_max`).
  - `echo PORT`: UDP echo server, runs until killed.
  - `cpu SECONDS`: per-core busy%, irq%, softirq% (from `/proc/stat`) and
    NET_RX / NET_TX softirq counts per core (from `/proc/softirqs`), one JSON line.
  - `ethstats IFACE`: the driver's ethtool statistics as one JSON line (the TV
    has no `ethtool` binary). For r8152 these are the adapter's own tally
    counters: `rx_packets` counts frames the chip accepted, `rx_missed` frames it
    dropped because its receive FIFO was full (a 16-bit counter that wraps).
    Comparing them with what `sink` received shows where a burst was lost:
    before the adapter (switch/router), in the adapter (FIFO full), or after it
    (USB, driver, socket).
- `netprobe_pc.py`: runs on the PC (Python 3 standard library, Windows or Linux).
  - `udpsend HOST PORT --mbps N [--size 1400] --seconds S [--fps F]`: UDP
    sender. Without `--fps` packets are evenly paced; with `--fps` each frame
    (N/F Mbit) is sent as one back-to-back burst at the start of its frame
    interval, like a game-streaming encoder.
  - `rtt HOST PORT [--count 1000] [--interval-ms 10] [--size 64] [--timeout-ms 1000]`:
    UDP round-trip time against `netprobe echo`; prints min/avg/p50/p90/p99/max/stdev
    in microseconds and loss.

Payload format (both directions): big-endian `uint64 seq`, `uint64 sender
timestamp ns`, zero padding up to `--size`. Sender and TV clocks are never
compared directly; jitter only uses transit-time differences.

## Build (WSL, Ubuntu 24.04)

```sh
cd /mnt/e/lg-ethernet/tools/netprobe
arm-linux-gnueabihf-gcc-9 -O2 -static -Wall -Wextra -o netprobe-armv7 netprobe.c
gcc -O2 -Wall -Wextra -o netprobe-x86 netprobe.c   # optional, for local tests
```

Copy `netprobe-armv7` to the TV (e.g. `/tmp/netprobe`) and `chmod +x` it.

## Usage

TV IP in the examples: 192.168.1.141. Use the same ports every run.

UDP streaming at a set bitrate, video-like bursts (120 Mbit/s, 60 fps, 20 s):

```sh
# TV
/tmp/netprobe sink 5201 20 4194304
# PC
python netprobe_pc.py udpsend 192.168.1.141 5201 --mbps 120 --seconds 20 --fps 60
```

Idle RTT, then RTT under load:

```sh
# TV
/tmp/netprobe echo 5202 &
# PC, idle
python netprobe_pc.py rtt 192.168.1.141 5202 --count 2000 --interval-ms 5
# PC, under load: run in parallel with udpsend above, or with a TCP download
python netprobe_pc.py rtt 192.168.1.141 5202 --count 2000 --interval-ms 5
```

Per-core CPU and NET_RX during any test (start it right after the sender):

```sh
/tmp/netprobe cpu 10
```

Kernel drop counters worth snapshotting before/after each run (not collected by
netprobe except the UDP ones): `ip -s link show eth0` (rx dropped/overruns),
`/proc/net/softnet_stat` (column 2 = backlog drops, column 3 = time_squeeze),
`/proc/net/snmp` and `/proc/net/netstat` (TCP OFOQueue, TCPBacklogDrop).

## A/B procedure

For each variant (module build, sysctl, IRQ affinity, EEE on/off ...) run the
same sequence 3+ times and compare medians: idle rtt, sink at 50/100/150/200
Mbit/s with `--fps 60` and `--fps 120`, rtt while a sink run is active, and a
TCP download with `cpu` sampling. A variant only wins if loss stays 0 and
p99 RTT / jitter / max_gap do not get worse.

## Local self-test (loopback in WSL)

```sh
./netprobe-x86 sink 5201 3 4194304 & sleep 0.3
python3 netprobe_pc.py udpsend 127.0.0.1 5201 --mbps 50 --seconds 3; wait
./netprobe-x86 echo 5203 & sleep 0.3
python3 netprobe_pc.py rtt 127.0.0.1 5203 --count 200 --interval-ms 5; kill %1
```

Notes: on Windows, Python 3.11+ is recommended (high-resolution `time.sleep`);
the sender spins for the last 2 ms of every wait, so it keeps one PC core busy.
At very high rates a single Python sender may not keep up; check the achieved
rate it prints and the sink's `mbps`.
