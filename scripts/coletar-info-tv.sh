#!/bin/sh
# Diagnóstico para a TV LG OLED A1 (webOS).
# Rode NA TV (via SSH, de preferência como root):
#   sh coletar-info-tv.sh
# Gera /tmp/lg-ethernet-info.txt com tudo que precisamos para escolher/compilar o driver.
# Só lê informações; não altera nada na TV.

SAIDA="${1:-/tmp/lg-ethernet-info.txt}"

secao() { printf '\n===== %s =====\n' "$1"; }

# Tabela VID:PID -> chip / módulo do kernel Linux
chip_por_id() {
    case "$1" in
        0bda:8152) echo "Realtek RTL8152 (100M) -> r8152" ;;
        0bda:8153) echo "Realtek RTL8153 (1G) -> r8152" ;;
        0bda:8156) echo "Realtek RTL8156 (2.5G) -> r8152 (kernel recente)" ;;
        17ef:7205|045e:07c6|13b1:0041) echo "Realtek RTL8153 (rebrand) -> r8152" ;;
        0b95:1790) echo "ASIX AX88179/AX88178A (1G) -> ax88179_178a" ;;
        0b95:7720|0b95:772a|0b95:772b) echo "ASIX AX88772 (100M) -> asix" ;;
        0b95:1780) echo "ASIX AX88178 (1G) -> asix" ;;
        0424:ec00) echo "SMSC LAN9512/9514 -> smsc95xx" ;;
        0424:7500) echo "SMSC LAN7500 -> smsc75xx" ;;
        0424:7800) echo "Microchip LAN7800 -> lan78xx" ;;
        0fe6:9700) echo "CoreChips SR9700 (adaptador barato) -> sr9700" ;;
        0a46:9601) echo "Davicom DM9601 -> dm9601" ;;
        *) echo "desconhecido" ;;
    esac
}

{
    secao "Data"
    date

    secao "Usuário"
    id

    secao "Kernel"
    uname -a
    cat /proc/version

    secao "Versão do webOS"
    for f in /etc/starfish-release /etc/os-release /var/run/nyx/os_info.json; do
        [ -r "$f" ] && { echo "--- $f"; cat "$f"; }
    done
    command -v nyx-cmd >/dev/null 2>&1 && {
        nyx-cmd OSInfo query webos_release webos_build_id 2>/dev/null
        nyx-cmd DeviceInfo query device_name hardware_id 2>/dev/null
    }

    secao "Dispositivos USB conectados"
    for d in /sys/bus/usb/devices/*; do
        [ -r "$d/idVendor" ] || continue
        vid=$(cat "$d/idVendor"); pid=$(cat "$d/idProduct")
        nome="$(cat "$d/manufacturer" 2>/dev/null) $(cat "$d/product" 2>/dev/null)"
        drivers=""
        for i in "$d"/*:*; do
            [ -e "$i/driver" ] && drivers="$drivers $(basename "$(readlink "$i/driver")")"
        done
        echo "$(basename "$d")  $vid:$pid  [$nome]  driver:${drivers:- nenhum}"
        echo "    chip provável: $(chip_por_id "$vid:$pid")"
    done
    command -v lsusb >/dev/null 2>&1 && { echo "--- lsusb"; lsusb; }

    secao "Configuração do kernel (rede USB e módulos)"
    if [ -r /proc/config.gz ]; then
        zcat /proc/config.gz | grep -E 'CONFIG_(MODULES|MODULE_SIG[A-Z_]*|MODVERSIONS|LOCALVERSION[A-Z_]*|USB_USBNET|USB_NET_[A-Z0-9_]+|USB_RTL8152|USB_LAN78XX|MII)[= ]'
    else
        echo "/proc/config.gz não disponível"
    fi

    secao "Módulos de rede USB já presentes no sistema"
    KREL=$(uname -r)
    for base in "/lib/modules/$KREL" /lib/modules; do
        [ -d "$base" ] || continue
        find "$base" -name '*.ko*' 2>/dev/null | grep -iE 'usbnet|r8152|asix|ax88|smsc|lan78|cdc_ether|cdc_ncm|sr9700|dm9601|mii'
        break
    done

    secao "Vermagic de um módulo existente (para compilar compatível)"
    KO=$(find "/lib/modules/$KREL" -name '*.ko' 2>/dev/null | head -n 1)
    if [ -n "$KO" ]; then
        echo "$KO"
        if command -v modinfo >/dev/null 2>&1; then
            modinfo "$KO" | grep -E '^(vermagic|signer|sig_)'
        else
            grep -ao 'vermagic=[^[:cntrl:]]*' "$KO" | head -n 1
        fi
    else
        echo "nenhum .ko encontrado em /lib/modules/$KREL"
    fi

    secao "Módulos carregados"
    lsmod 2>/dev/null || cat /proc/modules

    secao "Interfaces de rede"
    ip link 2>/dev/null || ifconfig -a

    secao "Mensagens recentes do kernel sobre USB/rede"
    dmesg 2>/dev/null | grep -iE 'usb|eth|r8152|asix|ax88|usbnet' | tail -n 60
} > "$SAIDA" 2>&1

echo "Pronto: $SAIDA"
echo "Copie esse arquivo para o PC e coloque em E:\\lg-ethernet\\diagnostico\\"
