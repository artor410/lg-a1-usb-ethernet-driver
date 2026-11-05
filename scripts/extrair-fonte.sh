#!/usr/bin/env bash
# Extrai o código-fonte do kernel do pacote GPL da LG ("webOS 6.0 LMUA 1.0").
# Rode no Linux/WSL:  bash scripts/extrair-fonte.sh /caminho/da/pasta/com/os/downloads
set -euo pipefail

DOWNLOADS=${1:?informe a pasta onde estão os arquivos "webOS 6.0 LMUA_1.0_*.tar.gz"}
PACOTE="$DOWNLOADS/webOS 6.0 LMUA_1.0_2.tar.gz"
DESTINO=~/lg

mkdir -p "$DESTINO"
cd "$DESTINO"

if [[ ! -f common/bsp_open3.tar.gz ]]; then
    echo "Extraindo common/bsp_open3.tar.gz de: $PACOTE"
    tar -xzf "$PACOTE" common/bsp_open3.tar.gz
fi
ls -la common

if [[ ! -f bsp_open/kernel/Makefile ]]; then
    echo "Extraindo bsp_open/kernel de common/bsp_open3.tar.gz"
    tar -xzf common/bsp_open3.tar.gz bsp_open/kernel
fi
head -4 bsp_open/kernel/Makefile
echo "Kernel pronto em $DESTINO/bsp_open/kernel"
