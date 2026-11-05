"""Gera app/icon.png (80x80) e app/largeIcon.png (130x130): uma porta RJ45 estilizada."""
import sys
from PIL import Image, ImageDraw

def icon(size):
    s = 4  # supersampling
    W = size * s
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, W - 1, W - 1], radius=W // 5, fill=(26, 115, 232, 255))
    # corpo da porta RJ45
    m = W * 0.2
    top = W * 0.28
    bottom = W * 0.78
    d.rounded_rectangle([m, top, W - m, bottom], radius=W // 22, fill=(255, 255, 255, 255))
    # trava (encaixe inferior)
    cw = W * 0.22
    d.rectangle([W / 2 - cw / 2, bottom - W * 0.12, W / 2 + cw / 2, bottom], fill=(26, 115, 232, 255))
    # 8 contatos
    inner_l, inner_r = m + W * 0.06, W - m - W * 0.06
    step = (inner_r - inner_l) / 8
    for i in range(8):
        x = inner_l + i * step + step * 0.2
        d.rectangle([x, top + W * 0.06, x + step * 0.6, top + W * 0.2], fill=(26, 115, 232, 255))
    return img.resize((size, size), Image.LANCZOS)

out = sys.argv[1]
icon(80).save(f"{out}/icon.png")
icon(130).save(f"{out}/largeIcon.png")
print("ícones gerados em", out)
