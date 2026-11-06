#!/bin/sh
# Measures network speed on the TV and shows where the bottleneck is (CPU, USB, drops).
# Run ON THE TV, as root:
#   sh speed-test.sh               # measure only
#   sh speed-test.sh --tuning      # measure, try temporary tuning, undo it at the end
#   sh speed-test.sh --iface eth0  # force an interface (default: the one with the default route)
# Leaves nothing changed: tuning is undone when it finishes (and is gone after a reboot anyway).
# The result is also saved to /tmp/speed-test.txt

OUT=/tmp/speed-test.txt
URL='https://speed.cloudflare.com/__down?bytes='
IFACE=""
TUNING=no
while [ $# -gt 0 ]; do
    case "$1" in
        --tuning) TUNING=yes ;;
        --iface) IFACE=$2; shift ;;
    esac
    shift
done
[ -n "$IFACE" ] || IFACE=$(ip route show default | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}')
S=/sys/class/net/$IFACE/statistics
[ -d "$S" ] || { echo "interface '$IFACE' not found"; exit 1; }

now() { cut -d' ' -f1 /proc/uptime; }
usb_irqs() { awk '/ehci|xhci|usb/ { for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+$/) s += $i; else break } END { print s + 0 }' /proc/interrupts; }

cpu_report() {
    paste -d' ' "$1" "$2" | awk '{
        n = NF / 2; tot = 0
        for (k = 2; k <= n; k++) { d[k] = $(k + n) - $k; tot += d[k] }
        if (tot <= 0) next
        idle = d[5] + d[6]
        printf "    %s: busy %3.0f%%  softirq %3.0f%%  irq %3.0f%%\n", $1, (tot - idle) * 100 / tot, d[8] * 100 / tot, d[7] * 100 / tot
    }'
}

# run_test NAME STREAMS BYTES_PER_STREAM
run_test() {
    grep '^cpu[0-9]' /proc/stat > /tmp/st.c1
    rx1=$(cat "$S/rx_bytes"); dr1=$(cat "$S/rx_dropped"); er1=$(cat "$S/rx_errors"); ir1=$(usb_irqs); t1=$(now)
    : > /tmp/st.codes
    i=0
    while [ $i -lt "$2" ]; do
        ( curl -s -o /dev/null --max-time 90 -w '%{http_code}\n' "$URL$3" >> /tmp/st.codes ) &
        i=$((i + 1))
    done
    wait
    failed=$(grep -vc '^200$' /tmp/st.codes)
    t2=$(now)
    grep '^cpu[0-9]' /proc/stat > /tmp/st.c2
    rx2=$(cat "$S/rx_bytes"); dr2=$(cat "$S/rx_dropped"); er2=$(cat "$S/rx_errors"); ir2=$(usb_irqs)
    awk -v n="$1" -v b=$((rx2 - rx1)) -v t1="$t1" -v t2="$t2" 'BEGIN {
        dt = t2 - t1; printf "  %-22s %5.0f Mbit/s  (%.0f MB in %.1f s)\n", n, b * 8 / dt / 1e6, b / 1e6, dt }'
    [ "$failed" -gt 0 ] && echo "    WARNING: the server refused $failed download(s) (this result does not count)"
    echo "    dropped: $((dr2 - dr1))  errors: $((er2 - er1))  USB interrupts: $((ir2 - ir1))"
    cpu_report /tmp/st.c1 /tmp/st.c2
}

run_set() {
    run_test "1 download (50 MB)" 1 50000000
    run_test "1 download (50 MB)" 1 50000000
    run_test "4 downloads (4x25 MB)" 4 25000000
    sleep 3   # the test server rate-limits back-to-back requests
}

RPS=/sys/class/net/$IFACE/queues/rx-0/rps_cpus
FLOW=/sys/class/net/$IFACE/queues/rx-0/rps_flow_cnt
orig_rps=$(cat "$RPS" 2>/dev/null)
orig_flow=$(cat "$FLOW" 2>/dev/null)
orig_sock=$(cat /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null)
orig_rmem_max=$(cat /proc/sys/net/core/rmem_max)
orig_tcp_rmem=$(cat /proc/sys/net/ipv4/tcp_rmem)

undo() {
    [ -n "$orig_rps" ] && echo "$orig_rps" > "$RPS" 2>/dev/null
    [ -n "$orig_flow" ] && echo "$orig_flow" > "$FLOW" 2>/dev/null
    [ -n "$orig_sock" ] && echo "$orig_sock" > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null
    echo "$orig_rmem_max" > /proc/sys/net/core/rmem_max
    echo "$orig_tcp_rmem" > /proc/sys/net/ipv4/tcp_rmem
}

{
    echo "===== Speed test ($(date)) ====="
    echo "Interface: $IFACE  link: $(cat "/sys/class/net/$IFACE/speed" 2>/dev/null) Mbit/s  driver: $(basename "$(readlink "/sys/class/net/$IFACE/device/driver" 2>/dev/null)")"
    u="/sys/class/net/$IFACE/device/.."
    [ -r "$u/speed" ] && echo "Adapter USB speed: $(cat "$u/speed") Mbit/s"
    echo "CPUs: $(grep -c ^processor /proc/cpuinfo)  load: $(cat /proc/loadavg)"
    for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
        [ -r "$c/scaling_governor" ] && echo "  $(basename "$(dirname "$c")"): $(cat "$c/scaling_governor") $(( $(cat "$c/scaling_cur_freq") / 1000 )) MHz (max $(( $(cat "$c/scaling_max_freq") / 1000 )) MHz)"
    done
    echo "TCP: rmem_max=$orig_rmem_max  tcp_rmem=\"$orig_tcp_rmem\"  congestion=$(cat /proc/sys/net/ipv4/tcp_congestion_control)"
    echo "Current RPS: rps_cpus=$orig_rps"
    if [ "$(curl -s -o /dev/null -w '%{http_code}' "${URL}1000")" != 200 ]; then
        echo "The test server did not answer (no internet, or rate-limited)"; exit 1
    fi

    echo
    echo "--- No tuning"
    run_set

    if [ $TUNING = yes ]; then
        trap undo EXIT INT TERM
        echo
        echo "--- Tuning 1: RPS (packet processing spread over all cores)"
        echo f > "$RPS"
        echo 4096 > "$FLOW" 2>/dev/null
        echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null
        run_set

        echo
        echo "--- Tuning 2: RPS + larger TCP receive buffers (4 MB)"
        echo 4194304 > /proc/sys/net/core/rmem_max
        echo "4096 131072 4194304" > /proc/sys/net/ipv4/tcp_rmem
        run_set

        undo
        trap - EXIT INT TERM
        echo
        echo "Tuning undone (rps_cpus=$(cat "$RPS"), tcp_rmem=\"$(cat /proc/sys/net/ipv4/tcp_rmem)\")"
    fi
} 2>&1 | tee "$OUT"
