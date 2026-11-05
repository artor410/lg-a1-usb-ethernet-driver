#!/bin/sh
# lg-a1-usb-ethernet: controla o driver r8152 (RTL8152/RTL8153) na TV.
# Roda como root (chamado pelo app via Homebrew Channel, ou pelo SSH).
#
# Uso: usbeth.sh status | load | unload | autostart-on | autostart-off | boot | log
#
# Só funciona no kernel para o qual o módulo foi compilado:
# LG webOS 6, plataforma lm21u (ex.: OLED A1), kernel 4.4.84, ARMv7.

PATH=/usr/sbin:/usr/bin:/sbin:/bin
DIR=$(cd "$(dirname "$0")/.." && pwd)
KO="$DIR/modules/r8152.ko"
MOD=r8152
STATE=/var/lib/lg-a1-usb-ethernet
LOG="$STATE/log.txt"
GUARD="$STATE/boot-pending"
INITD=/var/lib/webosbrew/init.d/60-lg-a1-usb-ethernet

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
    return 0
}

cmd_unload() {
    if ! module_loaded; then say "driver not loaded"; return 0; fi
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
    boot) cmd_boot ;;
    log) tail -n "${2:-40}" "$LOG" 2>/dev/null ;;
    *) echo "usage: $0 status|load|unload|autostart-on|autostart-off|boot|log"; exit 2 ;;
esac
