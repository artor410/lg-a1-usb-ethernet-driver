#!/usr/bin/env bash
# Builds r8152.ko for the LG lm21u platform (e.g. OLED A1): kernel 4.4.84, ARMv7.
# Run on Linux/WSL after scripts/extract-source.sh:
#   bash scripts/build-r8152.sh
# Does not touch the TV. The result goes to build/ in the project.
set -euo pipefail

PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
KSRC=${KSRC:-$HOME/lg/bsp_open/kernel}
OUT=${OUT:-$HOME/lg/build-kernel}
MOD=${MOD:-$HOME/lg/r8152}
CC_VER=${CC_VER:-9}
CROSS=arm-linux-gnueabihf-
TARGET_VERMAGIC="4.4.84 SMP preempt mod_unload ARMv7 "

for t in make bc flex bison patch "${CROSS}gcc-${CC_VER}" "${CROSS}ld" "${CROSS}nm" "${CROSS}readelf"; do
    command -v "$t" >/dev/null || { echo "Missing tool: $t" >&2; exit 1; }
done
[[ -f $KSRC/Makefile ]] || { echo "Kernel source not found in $KSRC" >&2; exit 1; }
[[ -f $PROJECT/diagnostics/config.gz ]] || { echo "Missing diagnostics/config.gz (the TV's /proc/config.gz)" >&2; exit 1; }

ARGS=(ARCH=arm "CROSS_COMPILE=$CROSS" "CC=${CROSS}gcc-${CC_VER}" "O=$OUT" LOCALVERSION=
      HOSTCFLAGS=-fcommon KCFLAGS="-Wno-error")

# 1. The TV's exact config, plus r8152 as a module (this only affects the driver itself).
mkdir -p "$OUT"
zcat "$PROJECT/diagnostics/config.gz" > "$OUT/.config"
cp "$OUT/.config" "$OUT/config-tv"
"$KSRC/scripts/config" --file "$OUT/.config" --module USB_RTL8152
make -C "$KSRC" "${ARGS[@]}" olddefconfig >/dev/null
echo "--- Differences between the TV's config and the one used for the build:"
diff <(grep -E '^(CONFIG_|# CONFIG_)' "$OUT/config-tv" | sort) \
     <(grep -E '^(CONFIG_|# CONFIG_)' "$OUT/.config" | sort) \
     | grep -E '^[<>]' | tee "$OUT/config-differences.txt" || true

# 2. Prepare the kernel tree for building external modules.
make -C "$KSRC" "${ARGS[@]}" modules_prepare
grep -Fqx '#define UTS_RELEASE "4.4.84"' "$OUT/include/generated/utsrelease.h" || {
    echo "Generated kernel release is not 4.4.84:" >&2; cat "$OUT/include/generated/utsrelease.h" >&2; exit 1; }

# 3. Build r8152 only (driver/r8152.c = drivers/net/usb/r8152.c from LG's package).
rm -rf "$MOD"; mkdir -p "$MOD"
cp "$PROJECT/driver/r8152.c" "$MOD/"
for p in "$PROJECT"/driver/patches/*.patch; do   # project changes (see each patch header)
    [[ -e $p ]] || continue
    echo "Applying $(basename "$p")"
    patch -s -d "$MOD" -p1 < "$p"
done
echo 'obj-m := r8152.o' > "$MOD/Makefile"
make -C "$KSRC" "${ARGS[@]}" M="$MOD" modules

# 4. Checks.
KO=$MOD/r8152.ko
"${CROSS}readelf" -h "$KO" | grep -q 'Machine:.*ARM' || { echo "Module is not ARM" >&2; exit 1; }
VM=$("${CROSS}readelf" -p .modinfo "$KO" | sed -n 's/.*vermagic=//p')
echo "vermagic: '$VM'"
[[ "$VM" == "$TARGET_VERMAGIC" ]] || { echo "vermagic differs from the target '$TARGET_VERMAGIC'" >&2; exit 1; }

mkdir -p "$PROJECT/build"
cp "$KO" "$PROJECT/build/r8152.ko"
"${CROSS}nm" -u "$KO" | awk '{print $2}' | sort > "$PROJECT/build/r8152-undefined-symbols.txt"
cp "$OUT/config-differences.txt" "$PROJECT/build/"
sha256sum "$PROJECT/build/r8152.ko"
echo "Done: build/r8152.ko ($(wc -l < "$PROJECT/build/r8152-undefined-symbols.txt") undefined symbols)"
