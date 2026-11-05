#!/usr/bin/env bash
# Gera repo/apps.json (índice do repositório próprio para o Homebrew Channel) a partir
# do .ipk e do manifesto já gerados em dist/. Não recria o .ipk.
# Rode na raiz do projeto:  bash scripts/gerar-indice.sh   (chamado também por empacotar-ipk.sh)
set -euo pipefail
RAIZ=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$RAIZ"
campo() { python3 -c "import json,sys; print(json.load(open('app/appinfo.json'))[sys.argv[1]])" "$1"; }
ID=$(campo id)
VERSAO=$(campo version)
REPO_URL=${REPO_URL:-https://github.com/artor410/lg-a1-usb-ethernet-driver}
IPK=${ID}_${VERSAO}_all.ipk
[[ -r dist/$IPK && -r dist/$ID.manifest.json ]] || { echo "Falta dist/$IPK ou o manifesto (rode empacotar-ipk.sh)" >&2; exit 1; }
mkdir -p repo
# Índice do repositório próprio (Homebrew Channel → Settings → Add repository):
# repo/apps.json, servido em raw.githubusercontent.com/<dono>/<repo>/main/repo/apps.json
python3 - "$ID" "$VERSAO" "$REPO_URL" "$IPK" "dist/$ID.manifest.json" "$(stat -c %s "dist/$IPK")" > repo/apps.json <<'EOF'
import json, sys
id_, ver, repo, ipk, manifest_path, size = sys.argv[1:]
manifest = json.load(open(manifest_path))
manifest["ipkUrl"] = f"{repo}/releases/download/v{ver}/{ipk}"
manifest["ipkSize"] = int(size)
pkg = {
    "id": id_,
    "title": manifest["title"],
    "iconUri": manifest["iconUri"],
    "manifestUrl": f"{repo}/releases/latest/download/{id_}.manifest.json",
    "manifest": manifest,
    "pool": "main",
    "requirements": {"webosRelease": ">=6.0"},
    "shortDescription": "r8152 driver for Realtek RTL8152/RTL8153 USB Ethernet adapters on LG webOS 6 TVs (lm21u, e.g. OLED A1). Root required.",
    "fullDescriptionUrl": f"apps/{id_}/full_description.html",
}
print(json.dumps({
    "paging": {"page": 1, "count": 1, "maxPage": 1, "itemsTotal": 1, "prevUrl": None, "nextUrl": None},
    "packages": [pkg],
}, indent=2, ensure_ascii=False))
EOF
echo "Índice: repo/apps.json (v$VERSAO)"
