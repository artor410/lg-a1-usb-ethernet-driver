#!/bin/sh
# lg-a1-usb-ethernet: controla o driver r8152 (RTL8152/RTL8153) na TV.
# Roda como root (chamado pelo app via Homebrew Channel, ou pelo SSH).
#
# Uso: usbeth.sh status | load | unload | autostart-on | autostart-off
#                | primary-on | primary-off | boot | log
#
# Só funciona no kernel para o qual o módulo foi compilado:
# LG webOS 6, plataforma lm21u (ex.: OLED A1), kernel 4.4.84, ARMv7.
#
# "primary": o webOS só considera conectada a interface eth0. Com primary ligado,
# o adaptador vira eth0 e a porta própria da TV fica como eth2; um vigia refaz a
# troca depois do modo de espera e devolve eth0 à porta própria se o adaptador sair.
# A troca de nomes foi adaptada do LG-USB-2-ETH0 (MIT, Copyright (c) 2025 OhMyBahGosh,
# github.com/ohmybahgosh/LG-USB-2-ETH0, commit 3ec818a81ea7) — ver THIRD_PARTY.md.

PATH=/usr/sbin:/usr/bin:/sbin:/bin
DIR=$(cd "$(dirname "$0")/.." && pwd)
SELF="$DIR/bin/usbeth.sh"
KO="$DIR/modules/r8152.ko"
MOD=r8152
STATE=/var/lib/lg-a1-usb-ethernet
LOG="$STATE/log.txt"
GUARD="$STATE/boot-pending"
PRIMARY="$STATE/primary"
WATCH_PID=/tmp/lg-a1-usb-ethernet.watch.pid
INITD=/var/lib/webosbrew/init.d/60-lg-a1-usb-ethernet
NET=/sys/class/net
PARK_NAME=eth2

# Adaptadores reconhecidos por este r8152 (tabela do driver da LG, kernel 4.4.84)
IDS="0bda:8050 0bda:8152 0bda:8153 045e:07ab 045e:07c6 04e8:a101 17ef:304f 17ef:3062
17ef:3069 17ef:7205 17ef:720c 17ef:7214 13b1:0041 0955:09ff 2357:0601"

log() {
    mkdir -p "$STATE"
    # No boot o relógio ainda não foi acertado; o tempo desde a inicialização ajuda a ler o log.
    echo "$(date '+%Y-%m-%d %H:%M:%S') [up $(cut -d' ' -f1 /proc/uptime)s] $*" >> "$LOG"
    if [ "$(wc -l < "$LOG")" -gt 400 ]; then
        tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    fi
}

say() { echo "$*"; log "$*"; }

check_compat() {
    rel=$(uname -r)
    arch=$(uname -m)
    plat=$(nyx-cmd DeviceInfo query device_name 2>/dev/null)
    case "$rel" in
        4.4.84-*) ;;
        *) echo "kernel $rel not supported (needs 4.4.84)"; return 1 ;;
    esac
    [ "$arch" = armv7l ] || { echo "architecture $arch not supported (needs armv7l)"; return 1; }
    [ "$plat" = lm21u ] || { echo "platform '$plat' not supported (needs lm21u)"; return 1; }
    if zcat /proc/config.gz 2>/dev/null | grep -q '^CONFIG_USB_RTL8152=y'; then
        echo "this kernel already has a built-in r8152"; return 1
    fi
    return 0
}

module_loaded() { grep -q "^$MOD " /proc/modules; }

# Imprime "caminho_sysfs vid:pid nome" do primeiro adaptador suportado encontrado.
find_adapter() {
    for d in /sys/bus/usb/devices/*; do
        [ -r "$d/idVendor" ] || continue
        id="$(cat "$d/idVendor"):$(cat "$d/idProduct")"
        for s in $IDS; do
            if [ "$id" = "$s" ]; then
                echo "$d $id $(cat "$d/manufacturer" 2>/dev/null) $(cat "$d/product" 2>/dev/null)"
                return 0
            fi
        done
    done
    return 1
}

adapter_iface() {
    ls -d "$1"/*/net/* 2>/dev/null | head -n 1 | xargs -r basename
}

# ---------- Troca de nomes (adaptador como eth0) ----------

sysval() { [ -r "$1" ] && IFS= read -r _v < "$1" 2>/dev/null && printf '%s\n' "$_v"; }
nic_driver() { _l=$(readlink "$NET/$1/device/driver" 2>/dev/null) && echo "${_l##*/}"; }
is_wifi() { [ -d "$NET/$1/wireless" ] || [ -e "$NET/$1/phy80211" ]; }

# O adaptador: interface cabeada controlada por este r8152.
is_usb_nic() {
    [ -e "$NET/$1/device" ] && [ "$(sysval "$NET/$1/type")" = 1 ] || return 1
    is_wifi "$1" && return 1
    [ "$(nic_driver "$1")" = "$MOD" ]
}

# A porta própria da TV. Na MStar do A1 ela é um dispositivo "virtual"
# (/sys/devices/virtual/net/eth0, sem link "device"), então não dá para usar o
# critério do LG-USB-2-ETH0. Depois da primeira troca, reconhece pelo MAC salvo.
BUILTIN_MAC="$STATE/builtin_mac"
is_builtin_nic() {
    [ -e "$NET/$1" ] && [ "$(sysval "$NET/$1/type")" = 1 ] || return 1
    is_wifi "$1" && return 1
    is_usb_nic "$1" && return 1
    case "$(readlink -f "$NET/$1" 2>/dev/null)" in */usb[0-9]*) return 1 ;; esac
    { [ -d "$NET/$1/bridge" ] || [ -d "$NET/$1/bonding" ] || [ -e "$NET/$1/tun_flags" ]; } && return 1
    if [ -s "$BUILTIN_MAC" ]; then
        [ "$(sysval "$NET/$1/address")" = "$(cat "$BUILTIN_MAC")" ]
        return
    fi
    case "$1" in eth*) return 0 ;; esac
    return 1
}

find_usb_nic() {
    for _p in "$NET"/*; do is_usb_nic "${_p##*/}" && { echo "${_p##*/}"; return 0; }; done
    return 0
}

find_builtin_nic() {
    is_builtin_nic eth0 && { echo eth0; return 0; }
    for _p in "$NET"/eth*; do is_builtin_nic "${_p##*/}" && { echo "${_p##*/}"; return 0; }; done
    return 0
}

free_eth_name() {
    [ -e "$NET/$1" ] || { echo "$1"; return 0; }
    for _i in 1 2 3 4 5 6 7 8 9; do [ -e "$NET/eth$_i" ] || { echo "eth$_i"; return 0; }; done
    return 1
}

# Renomeia uma interface. Ela precisa estar parada, e o gerenciador de rede do webOS
# às vezes a religa na hora ("Device or resource busy"), então tenta de novo.
rename_if() {
    _try=1
    while :; do
        _err=""
        if ip link set dev "$1" down 2>/dev/null && _err=$(ip link set dev "$1" name "$2" 2>&1); then
            return 0
        fi
        [ "$_try" -ge 3 ] && break
        _try=$((_try + 1))
        sleep 1
    done
    say "rename $1 -> $2 failed after 3 tries${_err:+: $_err}"
    return 1
}

# Adaptador vira eth0; a porta própria fica estacionada como eth2.
# Se um passo falhar, devolve os nomes antigos: a TV nunca fica sem eth0.
swap_in() {
    _usb=$(find_usb_nic)
    [ -n "$_usb" ] || return 2
    [ "$_usb" = eth0 ] && return 0
    if [ -e "$NET/eth0" ] && ! is_builtin_nic eth0; then
        say "eth0 is neither the adapter nor the built-in port; leaving names alone"
        return 1
    fi
    _park=""
    if [ -e "$NET/eth0" ]; then
        [ -s "$BUILTIN_MAC" ] || sysval "$NET/eth0/address" > "$BUILTIN_MAC"
        _park=$(free_eth_name "$PARK_NAME") || { say "no free ethN name to park the built-in port"; return 1; }
        if ! rename_if eth0 "$_park"; then
            ip link set dev eth0 up 2>/dev/null
            return 1
        fi
    fi
    if ! rename_if "$_usb" eth0; then
        ip link set dev "$_usb" up 2>/dev/null
        if [ -n "$_park" ]; then
            ip link set dev "$_park" name eth0 2>/dev/null
            ip link set dev eth0 up 2>/dev/null
        fi
        say "could not rename the adapter; old names restored"
        return 1
    fi
    ip link set dev eth0 up
    [ -n "$_park" ] && ip link set dev "$_park" up
    say "adapter is now eth0${_park:+ (built-in port parked as $_park)}"
    return 0
}

# Devolve eth0 à porta própria; o adaptador (se houver) fica com o primeiro ethN livre.
swap_out() {
    _bi=$(find_builtin_nic)
    [ -n "$_bi" ] || return 2
    [ "$_bi" = eth0 ] && return 0
    _tmp=""
    if [ -e "$NET/eth0" ]; then
        if ! rename_if eth0 ethusbtmp; then
            ip link set dev eth0 up 2>/dev/null
            return 1
        fi
        _tmp=ethusbtmp
    fi
    if ! rename_if "$_bi" eth0; then
        ip link set dev "$_bi" up 2>/dev/null
        if [ -n "$_tmp" ]; then
            ip link set dev "$_tmp" name eth0 2>/dev/null
            ip link set dev eth0 up 2>/dev/null
        fi
        say "could not give eth0 back to the built-in port; old names restored"
        return 1
    fi
    ip link set dev eth0 up
    if [ -n "$_tmp" ]; then
        _new=$(free_eth_name eth1) || _new=ethusb
        ip link set dev "$_tmp" name "$_new" && ip link set dev "$_new" up
    fi
    say "built-in port is eth0 again${_tmp:+ (adapter is $_new)}"
    return 0
}

watcher_running() {
    [ -r "$WATCH_PID" ] && kill -0 "$(cat "$WATCH_PID")" 2>/dev/null
}

start_watcher() {
    watcher_running && return 0
    nohup sh "$SELF" watch > /dev/null 2>&1 &
}

stop_watcher() {
    watcher_running && kill "$(cat "$WATCH_PID")" 2>/dev/null
    rm -f "$WATCH_PID"
}

# Vigia: a cada 5 s confere os nomes. Depois do modo de espera a TV reinicia as
# portas USB e o adaptador volta como eth1; se o adaptador sair, eth0 volta à
# porta própria. Só lê alguns arquivos de /sys, quase não custa nada.
cmd_watch() {
    echo $$ > "$WATCH_PID"
    log "watcher started"
    while [ -e "$PRIMARY" ] && module_loaded; do
        _u=$(find_usb_nic)
        if [ -n "$_u" ] && [ "$_u" != eth0 ]; then
            swap_in
        elif [ -z "$_u" ]; then
            _b=$(find_builtin_nic)
            [ -n "$_b" ] && [ "$_b" != eth0 ] && swap_out
        fi
        sleep 5
    done
    rm -f "$WATCH_PID"
    log "watcher stopped"
}

cmd_primary_on() {
    module_loaded || { say "load the driver first"; exit 1; }
    mkdir -p "$STATE"; touch "$PRIMARY"; sync
    say "primary connection: adapter as eth0"
    swap_in
    start_watcher
}

cmd_primary_off() {
    rm -f "$PRIMARY"; sync
    stop_watcher
    say "primary connection: built-in port as eth0"
    swap_out
    return 0
}

# Estado da conexão cabeada segundo o webOS (o que as Configurações e os apps veem).
# Só responde no contexto do Homebrew Channel (app/boot); pelo SSH sem terminal fica vazio.
webos_wired() {
    _o=$(luna-send -n 1 -w 3000 luna://com.webos.service.connectionmanager/getStatus '{}' 2>/dev/null)
    # "wired" tem sub-objetos (proxyinfo); tira os {...} internos antes de extrair.
    _w=$(echo "$_o" | sed -e 's/.*"wired":{//' -e ':a' -e 's/{[^{}]*}//' -e 'ta' -e 's/}.*//')
    echo "$_w" | sed -n 's/.*"state":"\([^"]*\)".*/\1/p'
}

cmd_status() {
    if msg=$(check_compat); then echo "compat=ok"; else echo "compat=$msg"; fi
    echo "kernel=$(uname -r)"
    echo "platform=$(nyx-cmd DeviceInfo query device_name 2>/dev/null)"
    echo "webos=$(nyx-cmd OSInfo query webos_release 2>/dev/null)"
    if a=$(find_adapter); then
        set -- $a
        path=$1; shift
        echo "adapter=$*"
        drv=""
        for i in "$path"/*:*; do
            [ -e "$i/driver" ] && drv="$drv $(basename "$(readlink "$i/driver")")"
        done
        echo "adapter_driver=${drv# }"
        echo "adapter_config=$(cat "$path/bConfigurationValue" 2>/dev/null)"
        ifc=$(adapter_iface "$path")
        echo "iface=$ifc"
        if [ -n "$ifc" ]; then
            echo "iface_state=$(cat /sys/class/net/$ifc/operstate 2>/dev/null)"
            echo "iface_carrier=$(cat /sys/class/net/$ifc/carrier 2>/dev/null)"
            echo "iface_speed=$(cat /sys/class/net/$ifc/speed 2>/dev/null)"
            echo "iface_ip=$(ip -4 -o addr show dev "$ifc" 2>/dev/null | awk '{print $4}' | head -n 1)"
        fi
    else
        echo "adapter="
    fi
    if module_loaded; then echo "module=loaded"; else echo "module=not-loaded"; fi
    if [ -e "$PRIMARY" ]; then echo "primary=on"; else echo "primary=off"; fi
    if watcher_running; then echo "watcher=running"; else echo "watcher=stopped"; fi
    if is_usb_nic eth0; then echo "eth0_is=adapter"; elif is_builtin_nic eth0; then echo "eth0_is=builtin"; else echo "eth0_is=none"; fi
    echo "builtin_iface=$(find_builtin_nic)"
    echo "webos_wired=$(webos_wired)"
    if [ -e "$INITD" ]; then echo "autostart=on"; else echo "autostart=off"; fi
    [ -e "$STATE/autostart-disabled-by-guard" ] && echo "guard=tripped"
    echo "default_route=$(ip route show default 2>/dev/null | head -n 1)"
}

cmd_load() {
    if ! msg=$(check_compat); then say "load refused: $msg"; exit 1; fi
    if module_loaded; then say "driver already loaded"; return 0; fi
    [ -r "$KO" ] || { say "module file missing: $KO"; exit 1; }
    sync
    if ! out=$(insmod "$KO" 2>&1); then
        say "insmod failed: $out"
        exit 1
    fi
    say "driver loaded"
    sleep 3
    dmesg | grep -iE 'r8152|rtl815|usb 1-' | tail -n 10 | while read -r l; do log "dmesg: $l"; done
    a=$(find_adapter) && say "adapter: $(echo "$a" | cut -d' ' -f2-) iface=$(adapter_iface "$(echo "$a" | cut -d' ' -f1)")"
    [ -e "$PRIMARY" ] && start_watcher   # o vigia faz a troca para eth0 assim que a interface aparece
    return 0
}

cmd_unload() {
    if ! module_loaded; then say "driver not loaded"; return 0; fi
    stop_watcher
    is_usb_nic eth0 && swap_out   # devolve eth0 à porta própria antes de o adaptador sumir
    if out=$(rmmod "$MOD" 2>&1); then say "driver unloaded"; else say "rmmod failed: $out"; exit 1; fi
}

cmd_autostart_on() {
    if ! msg=$(check_compat); then say "autostart refused: $msg"; exit 1; fi
    mkdir -p "$(dirname "$INITD")"
    cat > "$INITD" <<EOF
#!/bin/sh
# Created by lg-a1-usb-ethernet: loads the USB-Ethernet driver at boot.
[ -r "$DIR/bin/usbeth.sh" ] || { rm -f "$INITD"; exit 0; }
sh "$DIR/bin/usbeth.sh" boot
EOF
    chmod 755 "$INITD"
    rm -f "$STATE/autostart-disabled-by-guard"
    say "autostart enabled"
}

cmd_autostart_off() {
    rm -f "$INITD"
    say "autostart disabled"
}

# Chamado no boot pelo script em init.d. Se o boot anterior não terminou depois
# de carregar o driver (TV travou/reiniciou), desliga o autostart por segurança.
cmd_boot() {
    mkdir -p "$STATE"
    if [ -e "$GUARD" ]; then
        rm -f "$GUARD" "$INITD"
        touch "$STATE/autostart-disabled-by-guard"
        log "previous boot did not finish after loading the driver: autostart disabled for safety"
        exit 1
    fi
    touch "$GUARD"; sync
    if ( cmd_load ); then
        ( sleep 120; rm -f "$GUARD"; sync ) > /dev/null 2>&1 &
    else
        rm -f "$GUARD"   # falhou sem travar: não é motivo para desligar o autostart
    fi
}

case "$1" in
    status) cmd_status ;;
    load) cmd_load ;;
    unload) cmd_unload ;;
    autostart-on) cmd_autostart_on ;;
    autostart-off) cmd_autostart_off ;;
    primary-on) cmd_primary_on ;;
    primary-off) cmd_primary_off ;;
    watch) cmd_watch ;;
    boot) cmd_boot ;;
    log) tail -n "${2:-40}" "$LOG" 2>/dev/null ;;
    *) echo "usage: $0 status|load|unload|autostart-on|autostart-off|primary-on|primary-off|boot|log"; exit 2 ;;
esac
