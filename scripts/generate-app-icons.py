#!/usr/bin/env python3
"""Generate the installed-app icons from the Satima Farmhouse logo (app/icons/satima-logo-source.jpg).

- "any" icons: the full logo with a small white margin.
- "maskable" icons: the logo inside Android's adaptive-icon safe zone (centre 80% circle), so Samsung's
  squircle/circle masks never cut off the horns or the wordmark.
Requires Pillow: python3 -m pip install pillow
"""
from pathlib import Path
from PIL import Image, ImageChops

root = Path(__file__).resolve().parents[1]
src = Image.open(root / 'app/icons/satima-logo-source.jpg').convert('RGB')
# Trim the white border so every size uses the same proportions.
bg = Image.new('RGB', src.size, (255, 255, 255))
box = ImageChops.difference(src, bg).convert('L').point(lambda v: 255 if v > 24 else 0).getbbox()
logo = src.crop(box)
out = root / 'app/public'

def icon(size, fill):
    canvas = Image.new('RGB', (size, size), (255, 255, 255))
    w, h = logo.size
    scale = fill * size / max(w, h)
    art = logo.resize((max(1, round(w * scale)), max(1, round(h * scale))), Image.LANCZOS)
    canvas.paste(art, ((size - art.width) // 2, (size - art.height) // 2))
    return canvas

for size in (192, 512):
    icon(size, 0.90).save(out / f'icon-{size}.png', optimize=True)
    icon(size, 0.66).save(out / f'icon-maskable-{size}.png', optimize=True)
icon(180, 0.86).save(out / 'apple-touch-icon.png', optimize=True)
icon(32, 0.96).save(out / 'favicon-32.png', optimize=True)
icon(64, 0.96).save(out / 'favicon.ico', sizes=[(16, 16), (32, 32), (48, 48)])
print('Icons written to app/public/')
