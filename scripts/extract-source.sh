#!/usr/bin/env bash
# Extracts the kernel source from LG's GPL package ("webOS 6.0 LMUA 1.0").
# Run on Linux/WSL:  bash scripts/extract-source.sh /path/to/the/downloads/folder
set -euo pipefail

DOWNLOADS=${1:?give the folder that holds the "webOS 6.0 LMUA_1.0_*.tar.gz" files}
PACKAGE="$DOWNLOADS/webOS 6.0 LMUA_1.0_2.tar.gz"
DEST=~/lg

mkdir -p "$DEST"
cd "$DEST"

if [[ ! -f common/bsp_open3.tar.gz ]]; then
    echo "Extracting common/bsp_open3.tar.gz from: $PACKAGE"
    tar -xzf "$PACKAGE" common/bsp_open3.tar.gz
fi
ls -la common

if [[ ! -f bsp_open/kernel/Makefile ]]; then
    echo "Extracting bsp_open/kernel from common/bsp_open3.tar.gz"
    tar -xzf common/bsp_open3.tar.gz bsp_open/kernel
fi
head -4 bsp_open/kernel/Makefile
echo "Kernel source ready in $DEST/bsp_open/kernel"
