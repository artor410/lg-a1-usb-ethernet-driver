#!/usr/bin/env bash
# Compila o r8152.ko para a TV LG OLED A1 (kernel 4.4.84, ARMv7, plataforma lm21u).
# Rode no Ubuntu (WSL), depois de scripts/extrair-fonte.sh e de extrair bsp_open/kernel:
#   bash scripts/compilar-r8152.sh
# Não acessa a TV. O resultado vai para build/ no projeto.
set -euo pipefail

PROJETO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
KSRC=${KSRC:-$HOME/lg/bsp_open/kernel}
OUT=${OUT:-$HOME/lg/build-kernel}
MOD=${MOD:-$HOME/lg/r8152}
CC_VER=${CC_VER:-9}
CROSS=arm-linux-gnueabihf-
VERMAGIC_ALVO="4.4.84 SMP preempt mod_unload ARMv7 "

for t in make bc flex bison "${CROSS}gcc-${CC_VER}" "${CROSS}ld" "${CROSS}nm" "${CROSS}readelf"; do
    command -v "$t" >/dev/null || { echo "Falta a ferramenta: $t" >&2; exit 1; }
done
[[ -f $KSRC/Makefile ]] || { echo "Kernel não encontrado em $KSRC" >&2; exit 1; }
[[ -f $PROJETO/diagnostico/config.gz ]] || { echo "Falta diagnostico/config.gz (rode o diagnóstico na TV)" >&2; exit 1; }

ARGS=(ARCH=arm CROSS_COMPILE=$CROSS CC=${CROSS}gcc-${CC_VER} O=$OUT LOCALVERSION=
      HOSTCFLAGS=-fcommon KCFLAGS="-Wno-error")

# 1. Configuração exata da TV + r8152 como módulo (só afeta o próprio driver).
mkdir -p "$OUT"
zcat "$PROJETO/diagnostico/config.gz" > "$OUT/.config"
cp "$OUT/.config" "$OUT/config-tv"
"$KSRC/scripts/config" --file "$OUT/.config" --module USB_RTL8152
make -C "$KSRC" "${ARGS[@]}" olddefconfig >/dev/null
echo "--- Diferenças entre a config da TV e a usada na compilação:"
diff <(grep -E '^(CONFIG_|# CONFIG_)' "$OUT/config-tv" | sort) \
     <(grep -E '^(CONFIG_|# CONFIG_)' "$OUT/.config" | sort) \
     | grep -E '^[<>]' | tee "$OUT/config-diferencas.txt" || true

# 2. Preparar o kernel para compilar módulos externos.
make -C "$KSRC" "${ARGS[@]}" modules_prepare
grep -Fqx '#define UTS_RELEASE "4.4.84"' "$OUT/include/generated/utsrelease.h" || {
    echo "Versão do kernel gerada não é 4.4.84:" >&2; cat "$OUT/include/generated/utsrelease.h" >&2; exit 1; }

# 3. Compilar só o r8152 (driver/r8152.c = drivers/net/usb/r8152.c do pacote da LG).
rm -rf "$MOD"; mkdir -p "$MOD"
cp "$PROJETO/driver/r8152.c" "$MOD/"   # cópia do r8152.c da árvore da LG
for p in "$PROJETO"/driver/patches/*.patch; do   # ajustes do projeto (ver cabeçalho de cada patch)
    [[ -e $p ]] || continue
    echo "Aplicando $(basename "$p")"
    patch -s -d "$MOD" -p1 < "$p"
done
echo 'obj-m := r8152.o' > "$MOD/Makefile"
make -C "$KSRC" "${ARGS[@]}" M="$MOD" modules

# 4. Conferências.
KO=$MOD/r8152.ko
"${CROSS}readelf" -h "$KO" | grep -q 'Machine:.*ARM' || { echo "Módulo não é ARM" >&2; exit 1; }
VM=$("${CROSS}readelf" -p .modinfo "$KO" | sed -n 's/.*vermagic=//p')
echo "vermagic: '$VM'"
[[ "$VM" == "$VERMAGIC_ALVO" ]] || { echo "vermagic diferente do alvo '$VERMAGIC_ALVO'" >&2; exit 1; }

mkdir -p "$PROJETO/build"
cp "$KO" "$PROJETO/build/r8152.ko"
"${CROSS}nm" -u "$KO" | awk '{print $2}' | sort > "$PROJETO/build/r8152-simbolos-externos.txt"
cp "$OUT/config-diferencas.txt" "$PROJETO/build/"
sha256sum "$PROJETO/build/r8152.ko"
echo "Pronto: build/r8152.ko ($(wc -l < "$PROJETO/build/r8152-simbolos-externos.txt") símbolos externos)"
