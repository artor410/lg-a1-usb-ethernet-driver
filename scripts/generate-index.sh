#!/usr/bin/env bash
# Writes repo/apps.json (the index of this project's own Homebrew Channel repository)
# from the .ipk and manifest already in dist/. Does not rebuild the .ipk.
# Run from the project root:  bash scripts/generate-index.sh   (package-ipk.sh also calls it)
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$ROOT"
field() { python3 -c "import json,sys; print(json.load(open('app/appinfo.json'))[sys.argv[1]])" "$1"; }
ID=$(field id)
VERSION=$(field version)
REPO_URL=${REPO_URL:-https://github.com/artor410/webOS6-usbrealtek-driver}
IPK=${ID}_${VERSION}_all.ipk
[[ -r dist/$IPK && -r dist/$ID.manifest.json ]] || { echo "Missing dist/$IPK or its manifest (run package-ipk.sh)" >&2; exit 1; }
mkdir -p repo
# Homebrew Channel -> Settings -> Repositories -> Add repository:
# repo/apps.json, served from raw.githubusercontent.com/<owner>/<repo>/main/repo/apps.json
python3 - "$ID" "$VERSION" "$REPO_URL" "$IPK" "dist/$ID.manifest.json" "$(stat -c %s "dist/$IPK")" > repo/apps.json <<'EOF'
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
echo "Index:    repo/apps.json (v$VERSION)"
