#!/usr/bin/env bash
# Monta o pacote .ipk do app e o manifesto .json do Homebrew Channel.
# Rode no Linux/WSL a partir da raiz do projeto:  bash scripts/empacotar-ipk.sh
# Saída: dist/<id>_<versão>_all.ipk e dist/<id>.manifest.json
set -euo pipefail

RAIZ=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$RAIZ"

campo() { python3 -c "import json,sys; print(json.load(open('app/appinfo.json'))[sys.argv[1]])" "$1"; }
ID=$(campo id)
VERSAO=$(campo version)
TITULO=$(campo title)
VENDOR=$(campo vendor)
REPO_URL=${REPO_URL:-https://github.com/artor410/lg-a1-usb-ethernet-driver}
KO=prebuilt/r8152-4.4.84-lm21u.ko

[[ -r $KO ]] || { echo "Falta $KO (rode scripts/compilar-r8152.sh e copie build/r8152.ko)" >&2; exit 1; }
(cd prebuilt && sha256sum -c r8152-4.4.84-lm21u.ko.sha256 >/dev/null) || { echo "SHA-256 do módulo não confere" >&2; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
APPDIR=$STAGE/data/usr/palm/applications/$ID
PKGDIR=$STAGE/data/usr/palm/packages/$ID
mkdir -p "$APPDIR/modules" "$PKGDIR" "$STAGE/control"

cp -r app/. "$APPDIR/"
cp "$KO" "$APPDIR/modules/r8152.ko"
find "$APPDIR" -type d -exec chmod 755 {} +
find "$APPDIR" -type f -exec chmod 644 {} +
chmod 755 "$APPDIR"/bin/*.sh

cat > "$PKGDIR/packageinfo.json" <<EOF
{
    "app": "$ID",
    "id": "$ID",
    "loc_name": "$TITULO",
    "package_format_version": 2,
    "vendor": "$VENDOR",
    "version": "$VERSAO"
}
EOF

TAMANHO=$(du -sk "$STAGE/data" | cut -f1)
cat > "$STAGE/control/control" <<EOF
Package: $ID
Version: $VERSAO
Section: misc
Priority: optional
Architecture: all
Installed-Size: $TAMANHO
Maintainer: $VENDOR
Description: $TITULO
webOS-Package-Format-Version: 2
webOS-Packager-Version: 1.0.0
EOF

echo "2.0" > "$STAGE/debian-binary"
TAR=(tar --owner=0 --group=0 --numeric-owner --sort=name --mtime="@${SOURCE_DATE_EPOCH:-$(date +%s)}" -czf)
(cd "$STAGE/control" && "${TAR[@]}" "$STAGE/control.tar.gz" .)
(cd "$STAGE/data" && "${TAR[@]}" "$STAGE/data.tar.gz" .)

mkdir -p dist
IPK=${ID}_${VERSAO}_all.ipk
rm -f "dist/$IPK"
# Formato ar clássico (como o dpkg-deb): nomes sem "/" no fim. O verificador de
# pacotes da LG recusa o formato GNU que o "ar" do binutils gera.
python3 - "$RAIZ/dist/$IPK" "$STAGE" <<'EOF'
import os, sys
saida, stage = sys.argv[1], sys.argv[2]
with open(saida, "wb") as f:
    f.write(b"!<arch>\n")
    for nome in ("debian-binary", "control.tar.gz", "data.tar.gz"):
        dados = open(os.path.join(stage, nome), "rb").read()
        cab = f"{nome:<16}{0:<12}{0:<6}{0:<6}{100644:<8}{len(dados):<10}`\n".encode()
        assert len(cab) == 60
        f.write(cab + dados + (b"\n" if len(dados) % 2 else b""))
EOF

SHA=$(sha256sum "dist/$IPK" | cut -d' ' -f1)
python3 - "$ID" "$VERSAO" "$TITULO" "$REPO_URL" "$IPK" "$SHA" > "dist/$ID.manifest.json" <<'EOF'
import json, sys
id_, ver, title, repo, ipk, sha = sys.argv[1:]
print(json.dumps({
    "id": id_,
    "version": ver,
    "type": "web",
    "title": title,
    "appDescription": "r8152 USB Ethernet driver for LG webOS 6 TVs (lm21u / OLED A1)",
    "iconUri": repo.replace("https://github.com/", "https://raw.githubusercontent.com/") + "/main/app/largeIcon.png",
    "sourceUrl": repo,
    "rootRequired": True,
    "ipkUrl": ipk,
    "ipkHash": {"sha256": sha},
}, indent=2))
EOF

bash "$RAIZ/scripts/gerar-indice.sh"

echo "Pacote:    dist/$IPK ($(du -h "dist/$IPK" | cut -f1))"
echo "Manifesto: dist/$ID.manifest.json"

echo "SHA-256:   $SHA"
