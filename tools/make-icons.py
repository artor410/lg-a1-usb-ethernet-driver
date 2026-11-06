"""Draws app/icon.png (80x80) and app/largeIcon.png (130x130): a stylized RJ45 port."""
import sys
from PIL import Image, ImageDraw


def icon(size):
    s = 4  # supersampling
    W = size * s
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, W - 1, W - 1], radius=W // 5, fill=(26, 115, 232, 255))
    # RJ45 port body
    m = W * 0.2
    top = W * 0.28
    bottom = W * 0.78
    d.rounded_rectangle([m, top, W - m, bottom], radius=W // 22, fill=(255, 255, 255, 255))
    # latch notch at the bottom
    cw = W * 0.22
    d.rectangle([W / 2 - cw / 2, bottom - W * 0.12, W / 2 + cw / 2, bottom], fill=(26, 115, 232, 255))
    # 8 contacts
    inner_l, inner_r = m + W * 0.06, W - m - W * 0.06
    step = (inner_r - inner_l) / 8
    for i in range(8):
        x = inner_l + i * step + step * 0.2
        d.rectangle([x, top + W * 0.06, x + step * 0.6, top + W * 0.2], fill=(26, 115, 232, 255))
    return img.resize((size, size), Image.LANCZOS)


out = sys.argv[1]
icon(80).save(f"{out}/icon.png")
icon(130).save(f"{out}/largeIcon.png")
print("icons written to", out)
