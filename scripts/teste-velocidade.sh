#!/bin/sh
# Mede a velocidade da rede na TV e mostra onde está o gargalo (CPU, USB, perdas).
# Rode NA TV, como root:
#   sh teste-velocidade.sh              # só mede
#   sh teste-velocidade.sh --ajustes    # mede, testa ajustes temporários e desfaz no fim
#   sh teste-velocidade.sh --iface eth0 # força uma interface (padrão: a da rota padrão)
# Não deixa nada alterado: os ajustes são desfeitos ao terminar (e somem ao reiniciar a TV).
# Resultado também em /tmp/velocidade.txt

OUT=/tmp/velocidade.txt
URL='https://speed.cloudflare.com/__down?bytes='
IFACE=""
AJUSTES=no
while [ $# -gt 0 ]; do
    case "$1" in
        --ajustes) AJUSTES=yes ;;
        --iface) IFACE=$2; shift ;;
    esac
    shift
done
[ -n "$IFACE" ] || IFACE=$(ip route show default | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}')
S=/sys/class/net/$IFACE/statistics
[ -d "$S" ] || { echo "interface '$IFACE' não encontrada"; exit 1; }

now() { cut -d' ' -f1 /proc/uptime; }
usb_irqs() { awk '/ehci|xhci|usb/ { for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+$/) s += $i; else break } END { print s + 0 }' /proc/interrupts; }

cpu_report() {
    paste -d' ' "$1" "$2" | awk '{
        n = NF / 2; tot = 0
        for (k = 2; k <= n; k++) { d[k] = $(k + n) - $k; tot += d[k] }
        if (tot <= 0) next
        idle = d[5] + d[6]
        printf "    %s: ocupado %3.0f%%  softirq %3.0f%%  irq %3.0f%%\n", $1, (tot - idle) * 100 / tot, d[8] * 100 / tot, d[7] * 100 / tot
    }'
}

# run_test NOME FLUXOS BYTES_POR_FLUXO
run_test() {
    grep '^cpu[0-9]' /proc/stat > /tmp/vt.c1
    rx1=$(cat $S/rx_bytes); dr1=$(cat $S/rx_dropped); er1=$(cat $S/rx_errors); ir1=$(usb_irqs); t1=$(now)
    : > /tmp/vt.codes
    i=0
    while [ $i -lt "$2" ]; do
        ( curl -s -o /dev/null --max-time 90 -w '%{http_code}
' "$URL$3" >> /tmp/vt.codes ) &
        i=$((i + 1))
    done
    wait
    falhas=$(grep -vc '^200$' /tmp/vt.codes)
    t2=$(now)
    grep '^cpu[0-9]' /proc/stat > /tmp/vt.c2
    rx2=$(cat $S/rx_bytes); dr2=$(cat $S/rx_dropped); er2=$(cat $S/rx_errors); ir2=$(usb_irqs)
    awk -v n="$1" -v b=$((rx2 - rx1)) -v t1="$t1" -v t2="$t2" 'BEGIN {
        dt = t2 - t1; printf "  %-22s %5.0f Mbit/s  (%.0f MB em %.1f s)\n", n, b * 8 / dt / 1e6, b / 1e6, dt }'
    [ "$falhas" -gt 0 ] && echo "    ATENÇÃO: $falhas download(s) recusados pelo servidor (resultado não vale)"
    echo "    descartados: $((dr2 - dr1))  erros: $((er2 - er1))  interrupções USB: $((ir2 - ir1))"
    cpu_report /tmp/vt.c1 /tmp/vt.c2
}

bateria() {
    run_test "1 download (50 MB)" 1 50000000
    run_test "1 download (50 MB)" 1 50000000
    run_test "4 downloads (4x25 MB)" 4 25000000
    sleep 3   # o servidor de teste limita pedidos seguidos
}

RPS=/sys/class/net/$IFACE/queues/rx-0/rps_cpus
FLOW=/sys/class/net/$IFACE/queues/rx-0/rps_flow_cnt
orig_rps=$(cat $RPS 2>/dev/null)
orig_flow=$(cat $FLOW 2>/dev/null)
orig_sock=$(cat /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null)
orig_rmem_max=$(cat /proc/sys/net/core/rmem_max)
orig_tcp_rmem=$(cat /proc/sys/net/ipv4/tcp_rmem)

desfazer() {
    [ -n "$orig_rps" ] && echo "$orig_rps" > $RPS 2>/dev/null
    [ -n "$orig_flow" ] && echo "$orig_flow" > $FLOW 2>/dev/null
    [ -n "$orig_sock" ] && echo "$orig_sock" > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null
    echo "$orig_rmem_max" > /proc/sys/net/core/rmem_max
    echo "$orig_tcp_rmem" > /proc/sys/net/ipv4/tcp_rmem
}

{
    echo "===== Teste de velocidade ($(date)) ====="
    echo "Interface: $IFACE  link: $(cat /sys/class/net/$IFACE/speed 2>/dev/null) Mbit/s  driver: $(basename "$(readlink /sys/class/net/$IFACE/device/driver 2>/dev/null)")"
    for u in /sys/class/net/$IFACE/device/..; do
        [ -r "$u/speed" ] && echo "Velocidade USB do adaptador: $(cat "$u/speed") Mbit/s"
    done
    echo "CPUs: $(grep -c ^processor /proc/cpuinfo)  carga: $(cat /proc/loadavg)"
    for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
        [ -r "$c/scaling_governor" ] && echo "  $(basename "$(dirname "$c")"): $(cat $c/scaling_governor) $(( $(cat $c/scaling_cur_freq) / 1000 )) MHz (máx $(( $(cat $c/scaling_max_freq) / 1000 )) MHz)"
    done
    echo "TCP: rmem_max=$orig_rmem_max  tcp_rmem=\"$orig_tcp_rmem\"  congestion=$(cat /proc/sys/net/ipv4/tcp_congestion_control)"
    echo "RPS atual: rps_cpus=$orig_rps"
    if [ "$(curl -s -o /dev/null -w '%{http_code}' "${URL}1000")" != 200 ]; then
        echo "Servidor de teste não respondeu (sem internet?)"; exit 1
    fi

    echo
    echo "--- Sem ajustes"
    bateria

    if [ $AJUSTES = yes ]; then
        trap desfazer EXIT INT TERM
        echo
        echo "--- Ajuste 1: RPS (processamento dos pacotes nos 4 núcleos)"
        echo f > $RPS
        echo 4096 > $FLOW 2>/dev/null
        echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null
        bateria

        echo
        echo "--- Ajuste 2: RPS + buffers de recepção TCP maiores (4 MB)"
        echo 4194304 > /proc/sys/net/core/rmem_max
        echo "4096 131072 4194304" > /proc/sys/net/ipv4/tcp_rmem
        bateria

        desfazer
        trap - EXIT INT TERM
        echo
        echo "Ajustes desfeitos (rps_cpus=$(cat $RPS), tcp_rmem=\"$(cat /proc/sys/net/ipv4/tcp_rmem)\")"
    fi
} 2>&1 | tee "$OUT"
