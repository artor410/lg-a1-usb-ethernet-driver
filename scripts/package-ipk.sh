#!/usr/bin/env bash
# Builds the app's .ipk package, its Homebrew Channel manifest and repo/apps.json.
# Run on Linux/WSL from the project root:  bash scripts/package-ipk.sh
# Output: dist/<id>_<version>_all.ipk, dist/<id>.manifest.json and repo/apps.json
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$ROOT"

field() { python3 -c "import json,sys; print(json.load(open('app/appinfo.json'))[sys.argv[1]])" "$1"; }
ID=$(field id)
VERSION=$(field version)
TITLE=$(field title)
VENDOR=$(field vendor)
REPO_URL=${REPO_URL:-https://github.com/artor410/webOS6-usbrealtek-driver}
KO=prebuilt/r8152-4.4.84-lm21u.ko

[[ -r $KO ]] || { echo "Missing $KO (run scripts/build-r8152.sh and copy build/r8152.ko)" >&2; exit 1; }
(cd prebuilt && sha256sum -c r8152-4.4.84-lm21u.ko.sha256 >/dev/null) || { echo "Module SHA-256 does not match" >&2; exit 1; }

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
    "loc_name": "$TITLE",
    "package_format_version": 2,
    "vendor": "$VENDOR",
    "version": "$VERSION"
}
EOF

SIZE_KB=$(du -sk "$STAGE/data" | cut -f1)
cat > "$STAGE/control/control" <<EOF
Package: $ID
Version: $VERSION
Section: misc
Priority: optional
Architecture: all
Installed-Size: $SIZE_KB
Maintainer: $VENDOR
Description: $TITLE
webOS-Package-Format-Version: 2
webOS-Packager-Version: 1.0.0
EOF

echo "2.0" > "$STAGE/debian-binary"
TAR=(tar --owner=0 --group=0 --numeric-owner --sort=name --mtime="@${SOURCE_DATE_EPOCH:-$(date +%s)}" -czf)
(cd "$STAGE/control" && "${TAR[@]}" "$STAGE/control.tar.gz" .)
(cd "$STAGE/data" && "${TAR[@]}" "$STAGE/data.tar.gz" .)

mkdir -p dist
IPK=${ID}_${VERSION}_all.ipk
rm -f "dist/$IPK"
# Classic ar format (like dpkg-deb): member names without a trailing "/".
# LG's package verifier rejects the GNU format that binutils' "ar" writes.
python3 - "$ROOT/dist/$IPK" "$STAGE" <<'EOF'
import os, sys
out, stage = sys.argv[1], sys.argv[2]
with open(out, "wb") as f:
    f.write(b"!<arch>\n")
    for name in ("debian-binary", "control.tar.gz", "data.tar.gz"):
        data = open(os.path.join(stage, name), "rb").read()
        header = f"{name:<16}{0:<12}{0:<6}{0:<6}{100644:<8}{len(data):<10}`\n".encode()
        assert len(header) == 60
        f.write(header + data + (b"\n" if len(data) % 2 else b""))
EOF

SHA=$(sha256sum "dist/$IPK" | cut -d' ' -f1)
python3 - "$ID" "$VERSION" "$TITLE" "$REPO_URL" "$IPK" "$SHA" > "dist/$ID.manifest.json" <<'EOF'
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

REPO_URL=$REPO_URL bash "$ROOT/scripts/generate-index.sh"

echo "Package:  dist/$IPK ($(du -h "dist/$IPK" | cut -f1))"
echo "Manifest: dist/$ID.manifest.json"
echo "SHA-256:  $SHA"
