#!/bin/sh
# webOS6-usbrealtek-driver: controls the r8152 driver (RTL8152/RTL8153) on the TV.
# Runs as root (called by the app through Homebrew Channel, or over SSH).
#
# Usage: usbeth.sh status | load | unload | autostart-on | autostart-off
#                | primary-on | primary-off | wififb-on | wififb-off | speedtest | clock | boot | log
#
# Only works on the kernel the module was built for:
# LG webOS 6, lm21u platform (e.g. OLED A1), kernel 4.4.84, ARMv7.
#
# "primary": webOS only treats eth0 as the wired connection. With primary on, the
# adapter becomes eth0 and the TV's built-in port is parked as eth2; a watcher redoes
# the swap after standby and gives eth0 back to the built-in port if the adapter goes away.
# "wififb" (Wi-Fi fallback): if the adapter's cable has no link for 60 s, Wi-Fi is turned
# on through webOS's connection manager, and off again once the cable is back for 30 s.
# The interface swap, the recovery after the swap and the Wi-Fi fallback are adapted from
# LG-USB-2-ETH0 (MIT, Copyright (c) 2025 OhMyBahGosh, github.com/ohmybahgosh/LG-USB-2-ETH0,
# commit 3ec818a81ea7); see THIRD_PARTY.md.
#
# Internal names (state directory, init.d hook) keep the project's original name
# "lg-a1-usb-ethernet" so existing installs keep their settings across updates.

PATH=/usr/sbin:/usr/bin:/sbin:/bin
DIR=$(cd "$(dirname "$0")/.." && pwd)
SELF="$DIR/bin/usbeth.sh"
KO="$DIR/modules/r8152.ko"
MOD=r8152
STATE=/var/lib/lg-a1-usb-ethernet
LOG="$STATE/log.txt"
GUARD="$STATE/boot-pending"
PRIMARY="$STATE/primary"
WIFIFB="$STATE/wifi-fallback"
WIFI_MARK="$STATE/wifi-by-us"
SPEED="$STATE/last_speed"
NOSWAP=/tmp/lg-a1-usb-ethernet.noswap
WATCH_PID=/tmp/lg-a1-usb-ethernet.watch.pid
# "05-" so run-parts starts this hook before other homebrew hooks; "60-" was used up to v0.6.1.
INITD=/var/lib/webosbrew/init.d/05-lg-a1-usb-ethernet
OLD_INITD=/var/lib/webosbrew/init.d/60-lg-a1-usb-ethernet
NET=/sys/class/net
PARK_NAME=eth2

# Adapters this r8152 recognizes (the device table of LG's driver, kernel 4.4.84)
IDS="0bda:8050 0bda:8152 0bda:8153 045e:07ab 045e:07c6 04e8:a101 17ef:304f 17ef:3062
17ef:3069 17ef:7205 17ef:720c 17ef:7214 13b1:0041 0955:09ff 2357:0601"

log() {
    mkdir -p "$STATE"
    # At boot the clock is not set yet; the uptime makes the log readable.
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

# Prints "sysfs_path vid:pid name" of the first supported adapter found.
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

# ---------- Interface swap (adapter as eth0) ----------

sysval() { [ -r "$1" ] && IFS= read -r _v < "$1" 2>/dev/null && printf '%s\n' "$_v"; }
nic_driver() { _l=$(readlink "$NET/$1/device/driver" 2>/dev/null) && echo "${_l##*/}"; }
is_wifi() { [ -d "$NET/$1/wireless" ] || [ -e "$NET/$1/phy80211" ]; }

# The adapter: a wired interface driven by this r8152.
is_usb_nic() {
    [ -e "$NET/$1/device" ] && [ "$(sysval "$NET/$1/type")" = 1 ] || return 1
    is_wifi "$1" && return 1
    [ "$(nic_driver "$1")" = "$MOD" ]
}

# The TV's built-in port. On the A1's MStar SoC it is a "virtual" device
# (/sys/devices/virtual/net/eth0, no "device" link), so LG-USB-2-ETH0's check does
# not work here. After the first swap it is recognized by its saved MAC address.
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

# Renames an interface. It has to be down first, and webOS's connection manager
# sometimes brings it straight back up ("Device or resource busy"), so retry.
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

# The adapter becomes eth0; the built-in port is parked as eth2.
# If a step fails, the old names are put back: the TV never ends up without eth0.
swap_in() {
    _usb=$(find_usb_nic)
    [ -n "$_usb" ] || return 2
    [ "$_usb" = eth0 ] && return 0
    if [ -e "$NET/eth0" ] && ! is_builtin_nic eth0; then
        say "eth0 is neither the adapter nor the built-in port; leaving names alone"
        return 1
    fi
    _hadip=""
    has_ipv4 "$_usb" && _hadip=1
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
    # Recovery: if the adapter had an address before and eth0 gets none after the swap,
    # take the link down and up; if that does not help, undo the swap until the next boot.
    [ -n "$_hadip" ] || return 0
    wait_ipv4 eth0 20 && return 0
    say "eth0 has no address 20 s after the swap: taking the link down and up"
    ip link set dev eth0 down
    sleep 2
    ip link set dev eth0 up
    if wait_ipv4 eth0 20; then say "eth0 is connected again"; return 0; fi
    say "still no address: giving eth0 back to the built-in port until the next boot or a new primary-on"
    touch "$NOSWAP"
    swap_out
    return 1
}

has_ipv4() { ip -4 addr show dev "$1" 2>/dev/null | grep -q 'inet '; }

# wait_ipv4 IFACE SECONDS
wait_ipv4() {
    _n=0
    while [ "$_n" -lt "$2" ]; do
        has_ipv4 "$1" && return 0
        sleep 2
        _n=$((_n + 2))
    done
    has_ipv4 "$1"
}

# Gives eth0 back to the built-in port; the adapter (if any) gets the first free ethN.
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

# Watcher: checks the names every 5 s. After standby the TV resets its USB ports
# and the adapter comes back as eth1; if the adapter goes away, eth0 goes back to
# the built-in port. It only reads a few /sys files, so it costs next to nothing.
want_watcher() { [ -e "$PRIMARY" ] || [ -e "$WIFIFB" ]; }

cmd_watch() {
    echo $$ > "$WATCH_PID"
    log "watcher started"
    _down=0 _up=0 _wifi_tried="" _ticks=0 _step=1 _ready=""
    while module_loaded && want_watcher; do
        if [ -e "$PRIMARY" ]; then
            _u=$(find_usb_nic)
            if [ -n "$_u" ] && [ "$_u" != eth0 ]; then
                [ -e "$NOSWAP" ] || swap_in
            elif [ "$_u" = eth0 ] && [ -z "$_ready" ] && has_ipv4 eth0; then
                _ready=1
                log "network ready: eth0 (adapter) has an address"
            elif [ -z "$_u" ]; then
                _b=$(find_builtin_nic)
                [ -n "$_b" ] && [ "$_b" != eth0 ] && swap_out
            fi
        fi
        if [ -e "$WIFIFB" ]; then
            _u=$(find_usb_nic)
            if [ -n "$_u" ] && [ "$(sysval "$NET/$_u/carrier")" = 1 ]; then
                _up=$((_up + _step)); _down=0; _wifi_tried=""
            else
                _down=$((_down + _step)); _up=0
            fi
            if [ "$_down" -ge 60 ] && [ -z "$_wifi_tried" ]; then
                _wifi_tried=1
                wifi_fallback
            fi
            [ "$_up" -ge 30 ] && [ -e "$WIFI_MARK" ] && wifi_back
        fi
        _ticks=$((_ticks + 1))
        [ "$_ticks" -ge 30 ] && _step=5
        sleep "$_step"
    done
    rm -f "$WATCH_PID"
    log "watcher stopped"
}

# ---------- Wi-Fi fallback ----------
# Turns Wi-Fi on/off through webOS's connection manager (the same switch as in Settings).
# Only works in the Homebrew Channel context (app/boot).
wifi_status() {
    _ws=$(luna-send -n 1 -w 3000 luna://com.webos.service.wifi/getstatus '{}' 2>/dev/null)
    case "$_ws" in
        *'"serviceDisabled"'*) echo disabled ;;
        *'"returnValue":true'*) echo enabled ;;
    esac
}

wifi_set() {
    case "$(luna-send -n 1 -w 5000 luna://com.webos.service.connectionmanager/setstate "{\"wifi\":\"$1\"}" 2>/dev/null)" in
        *'"returnValue":true'*) return 0 ;;
    esac
    return 1
}

# wifi_fallback [REASON]
wifi_fallback() {
    _why=${1:-adapter cable without link for 60 s}
    [ "$(wifi_status)" = disabled ] || return 0   # already on (or no answer): leave it alone
    if wifi_set enabled; then
        echo on > "$WIFI_MARK"
        say "$_why: Wi-Fi turned on"
    else
        say "$_why, but Wi-Fi could not be turned on"
    fi
}

wifi_back() {
    if wifi_set disabled; then say "adapter cable is back: Wi-Fi turned off again"; else say "could not turn Wi-Fi off; turn it off in the TV settings"; fi
    rm -f "$WIFI_MARK"
}

cmd_wififb_on() {
    mkdir -p "$STATE"; touch "$WIFIFB"; sync
    say "Wi-Fi fallback enabled"
    module_loaded && start_watcher
    return 0
}

cmd_wififb_off() {
    rm -f "$WIFIFB"; sync
    [ -e "$WIFI_MARK" ] && wifi_back
    stop_watcher
    module_loaded && want_watcher && start_watcher
    say "Wi-Fi fallback disabled"
}

# ---------- Clock ----------
# webOS sets its clock from LG's servers once the network is up. When the network comes up
# late (the adapter only works once Homebrew Channel's startup hooks run), or those servers
# are blocked (e.g. by privacy hooks after a grace period), the TV keeps its factory time
# (2021): then every HTTPS connection on the TV fails with "certificate is not yet valid".
# If the clock is still invalid some time after the driver loads, set it from the Date
# header of a plain HTTP response, through webOS's own time service (which also updates
# the RTC). A valid clock is never touched.
CLOCK_URL=http://connectivitycheck.gstatic.com/generate_204
clock_ok() { [ "$(date +%Y)" -ge 2025 ]; }

fix_clock() {
    _d=$(curl -sI -m 10 "$CLOCK_URL" 2>/dev/null | sed -n 's/^[Dd]ate: *//p' | tr -d '\r')
    [ -n "$_d" ] || return 1
    _t=$(date -u -D '%a, %d %b %Y %H:%M:%S GMT' -d "$_d" +%s 2>/dev/null) || return 1
    [ "$_t" -gt 1735689600 ] || return 1   # sanity check: after 2025-01-01
    case "$(luna-send -n 1 -w 5000 luna://com.webos.service.systemservice/time/setSystemTime "{\"utc\":$_t}" 2>/dev/null)" in
        *'"returnValue":true'*) log "clock was invalid (factory time): set from the network to $_d"; return 0 ;;
    esac
    return 1
}

# Runs in the background after the driver loads.
cmd_clock() {
    sleep 45   # give webOS's own clock sync a chance first
    _n=0
    while ! clock_ok && [ "$_n" -lt 24 ]; do
        fix_clock && return 0
        sleep 5
        _n=$((_n + 1))
    done
    clock_ok || log "clock is still invalid: HTTPS on the TV will fail until webOS sets it"
}

# ---------- Speed test ----------
cmd_speedtest() {
    _if=$(ip route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}')
    _r=$(LC_ALL=C curl -s -o /dev/null --max-time 40 -w '%{http_code} %{size_download} %{time_total}' \
        'https://speed.cloudflare.com/__down?bytes=50000000')
    # shellcheck disable=SC2086
    set -- $_r
    if [ "$1" = 200 ] && [ "${2:-0}" -gt 1000000 ]; then
        _mbps=$(awk -v b="$2" -v t="$3" 'BEGIN { printf "%.0f", b * 8 / t / 1e6 }')
        mkdir -p "$STATE"
        echo "$_mbps Mbit/s via $_if ($(date '+%d/%m %H:%M'))" > "$SPEED"
        say "speed test: $_mbps Mbit/s download via $_if"
    else
        say "speed test failed (server answered ${1:-nothing}); try again in a few minutes"
        return 1
    fi
}

cmd_primary_on() {
    module_loaded || { say "load the driver first"; exit 1; }
    mkdir -p "$STATE"; touch "$PRIMARY"; sync
    rm -f "$NOSWAP"
    say "primary connection: adapter as eth0"
    swap_in
    start_watcher
}

cmd_primary_off() {
    rm -f "$PRIMARY"; sync
    stop_watcher
    say "primary connection: built-in port as eth0"
    swap_out
    want_watcher && start_watcher
    return 0
}

# The wired connection state according to webOS (what Settings and apps see).
# Only answers in the Homebrew Channel context (app/boot); empty over SSH without a terminal.
webos_wired() {
    _o=$(luna-send -n 1 -w 3000 luna://com.webos.service.connectionmanager/getStatus '{}' 2>/dev/null)
    # "wired" has nested objects (proxyinfo): strip the inner {...} before extracting.
    _w=$(echo "$_o" | sed -e 's/.*"wired":{//' -e ':a' -e 's/{[^{}]*}//' -e 'ta' -e 's/}.*//')
    echo "$_w" | sed -n 's/.*"state":"\([^"]*\)".*/\1/p'
}

# Facts that cannot change until the next boot (compatibility, kernel, platform, webOS
# version), cached in /tmp: the app asks for the status every 10 s, and the nyx-cmd calls
# behind these facts were about 40% of each status run.
STATIC=/tmp/lg-a1-usb-ethernet.static
static_info() {
    if [ ! -s "$STATIC" ]; then
        {
            if msg=$(check_compat); then echo "compat=ok"; else echo "compat=$msg"; fi
            echo "kernel=$(uname -r)"
            echo "platform=$(nyx-cmd DeviceInfo query device_name 2>/dev/null)"
            echo "webos=$(nyx-cmd OSInfo query webos_release 2>/dev/null)"
        } > "$STATIC.tmp" && mv "$STATIC.tmp" "$STATIC"
    fi
    cat "$STATIC"
}

cmd_status() {
    static_info
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
    [ -e "$NOSWAP" ] && echo "noswap=yes"
    if [ -e "$WIFIFB" ]; then echo "wififb=on"; else echo "wififb=off"; fi
    if [ -e "$WIFI_MARK" ]; then echo "wifi_by_us=yes"; else echo "wifi_by_us=no"; fi
    echo "last_speed=$(cat "$SPEED" 2>/dev/null)"
    if clock_ok; then echo "clock=ok"; else echo "clock=invalid"; fi
    if watcher_running; then echo "watcher=running"; else echo "watcher=stopped"; fi
    if is_usb_nic eth0; then echo "eth0_is=adapter"; elif is_builtin_nic eth0; then echo "eth0_is=builtin"; else echo "eth0_is=none"; fi
    echo "builtin_iface=$(find_builtin_nic)"
    echo "webos_wired=$(webos_wired)"
    if [ -e "$INITD" ] || [ -e "$OLD_INITD" ]; then echo "autostart=on"; else echo "autostart=off"; fi
    [ -e "$STATE/autostart-disabled-by-guard" ] && echo "guard=tripped"
    echo "default_route=$(ip route show default 2>/dev/null | head -n 1)"
}

# Game-streaming clients ask for large UDP receive buffers (Moonlight about 2.75 MiB),
# but webOS caps them at net.core.rmem_max = 512 KiB. Raise the cap while the driver is
# loaded (it only allows bigger buffers to apps that ask for them) and restore it on unload.
RMEM_MAX=4194304
RMEM_SAVE=/tmp/lg-a1-usb-ethernet.rmem_max
tune_net() {
    # cat, not sysval: BusyBox's read gets only the first byte of a /proc/sys file.
    _cur=$(cat /proc/sys/net/core/rmem_max 2>/dev/null)
    case "$_cur" in ''|*[!0-9]*) return 0 ;; esac
    [ "$_cur" -lt "$RMEM_MAX" ] || return 0
    [ -e "$RMEM_SAVE" ] || echo "$_cur" > "$RMEM_SAVE"
    echo "$RMEM_MAX" > /proc/sys/net/core/rmem_max && log "net.core.rmem_max $_cur -> $RMEM_MAX"
}
untune_net() {
    [ -r "$RMEM_SAVE" ] || return 0
    cat "$RMEM_SAVE" > /proc/sys/net/core/rmem_max && rm -f "$RMEM_SAVE"
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
    tune_net
    # Start the watcher at once: it does the eth0 swap as soon as the interface appears.
    want_watcher && start_watcher
    clock_ok || nohup sh "$SELF" clock > /dev/null 2>&1 &
    sleep 3
    dmesg | grep -iE 'r8152|rtl815|usb 1-' | tail -n 10 | while read -r l; do log "dmesg: $l"; done
    a=$(find_adapter) && say "adapter: $(echo "$a" | cut -d' ' -f2-) iface=$(adapter_iface "$(echo "$a" | cut -d' ' -f1)")"
    return 0
}

cmd_unload() {
    if ! module_loaded; then say "driver not loaded"; return 0; fi
    stop_watcher
    is_usb_nic eth0 && swap_out   # give eth0 back to the built-in port before the adapter goes away
    if out=$(rmmod "$MOD" 2>&1); then untune_net; say "driver unloaded"; else say "rmmod failed: $out"; exit 1; fi
}

cmd_autostart_on() {
    if ! msg=$(check_compat); then say "autostart refused: $msg"; exit 1; fi
    mkdir -p "$(dirname "$INITD")"
    cat > "$INITD" <<EOF
#!/bin/sh
# Created by webOS6-usbrealtek-driver: loads the USB Ethernet driver at boot.
[ -r "$DIR/bin/usbeth.sh" ] || { rm -f "$INITD"; exit 0; }
sh "$DIR/bin/usbeth.sh" boot
EOF
    chmod 755 "$INITD"
    rm -f "$OLD_INITD" "$STRIKES" "$STATE/autostart-disabled-by-guard"
    say "autostart enabled"
}

cmd_autostart_off() {
    rm -f "$INITD" "$OLD_INITD"
    say "autostart disabled"
}

# Called at boot by the init.d hook.
# Boot-loop guard: the guard file exists from just before the driver loads until
# GUARD_SECS after it loaded. If a boot finds it, the previous boot ended inside that
# window: either the driver froze the TV, or the TV was simply switched off or
# restarted early. One such boot is not enough to tell them apart, so startup loading
# is only turned off after GUARD_STRIKES of them in a row. (Up to v0.6.1 a single one
# turned it off, with a 120 s window, so switching the TV off within 2 minutes of
# switching it on left it without a network on the next boot.)
GUARD_SECS=30
GUARD_STRIKES=2
STRIKES="$STATE/boot-strikes"
cmd_boot() {
    mkdir -p "$STATE"
    log "boot hook started"
    if [ -e "$GUARD" ]; then
        _s=$(( $(cat "$STRIKES" 2>/dev/null || echo 0) + 1 ))
        if [ "$_s" -ge "$GUARD_STRIKES" ]; then
            rm -f "$GUARD" "$STRIKES" "$INITD" "$OLD_INITD"
            touch "$STATE/autostart-disabled-by-guard"
            log "$_s boots in a row did not get past the first ${GUARD_SECS}s after loading the driver: autostart disabled for safety"
            # Without the driver the adapter has no network: fall back to Wi-Fi if allowed.
            [ -e "$WIFIFB" ] && wifi_fallback "driver not loaded at startup"
            exit 1
        fi
        echo "$_s" > "$STRIKES"
        log "previous boot ended within ${GUARD_SECS}s of loading the driver (strike $_s of $GUARD_STRIKES); loading it again"
    fi
    touch "$GUARD"; sync
    # Migrate the hook from the old "60-" name to "05-" (takes effect from the next boot).
    [ -e "$OLD_INITD" ] && cmd_autostart_on > /dev/null
    # The rest runs in the background, so the boot (and Homebrew Channel's failsafe
    # timer) does not wait for the driver to load.
    nohup sh "$SELF" boot-worker > /dev/null 2>&1 &
}

cmd_boot_worker() {
    if ( cmd_load ); then
        sleep "$GUARD_SECS"
        rm -f "$GUARD" "$STRIKES"; sync
    else
        rm -f "$GUARD"   # failed without freezing: no reason to turn startup loading off
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
    wififb-on) cmd_wififb_on ;;
    wififb-off) cmd_wififb_off ;;
    speedtest) cmd_speedtest ;;
    clock) cmd_clock ;;
    boot-worker) cmd_boot_worker ;;
    watch) cmd_watch ;;
    boot) cmd_boot ;;
    log) tail -n "${2:-40}" "$LOG" 2>/dev/null ;;
    *) echo "usage: $0 status|load|unload|autostart-on|autostart-off|primary-on|primary-off|wififb-on|wififb-off|speedtest|boot|log"; exit 2 ;;
esac
