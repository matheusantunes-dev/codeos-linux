#!/usr/bin/env python3
"""Ícones em PNG do CodeOS: lixeira e discos do tema Mint-L (CC BY-SA 4.0) recoloridos.

- Lixeira: só o cinza do cesto vira o azul do CodeOS; símbolo e papéis continuam brancos.
- Disco e pendrive: o corpo claro vira metal escovado aço-ciano (reflexo e riscos finos),
  num tom diferente da lixeira para não confundir; etiqueta e detalhes brancos ficam.

O resultado fica versionado em src/raster/ (a ISO não tem o Mint-L), então este script
só precisa rodar de novo para mudar os tons. Créditos em CREDITS.md.

Uso: python3 assets/icons/recolor_icons.py   (precisa do pacote mint-l-icons instalado)
"""
import colorsys
import math
from pathlib import Path

from PIL import Image

MINT_L = Path("/usr/share/icons/Mint-L")
OUT = Path(__file__).resolve().parent / "src/raster"

# Tom "A" da lixeira: matiz do azul do logo, mais claro para não sumir no céu dos papéis de parede.
TRASH = dict(hue=219, saturation=0.78, gain=1.55)
# Tom "D1" dos discos: aço puxado para o ciano do logo.
DISK = dict(hue=196, saturation=0.85, base=0.72)


def recolor_trash(im, hue, saturation, gain):
    px = im.load()
    for y in range(im.height):
        for x in range(im.width):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            _, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            if s > 0.15:
                continue
            white = max(0.0, min(1.0, (v - 0.80) / 0.15))  # brancos ficam brancos
            nv = min(1.0, v * gain) * (1 - white) + v * white
            nr, ng, nb = colorsys.hsv_to_rgb(hue / 360, saturation * (1 - white), nv)
            px[x, y] = (round(nr * 255), round(ng * 255), round(nb * 255), a)
    return im


def recolor_metal(im, hue, saturation, base):
    px = im.load()
    for y in range(im.height):
        for x in range(im.width):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            _, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            if s > 0.15 or v > 0.975:  # cores e o branco puro (texto da etiqueta) ficam
                continue
            # coordenadas relativas, para o efeito ser igual em 16 px e em 256 px
            t, u = x / im.width, y / im.height
            sheen = 0.78 + 0.40 * math.exp(-((t - 0.30) / 0.14) ** 2) - 0.18 * abs(t - 0.5)
            brush = 1 + 0.05 * math.sin(u * 218) + 0.025 * math.sin(u * 68 + t * 6.4)
            nv = max(0.0, min(1.0, v * base * sheen * brush))
            ns = min(1.0, saturation * (1.15 - 0.35 * nv))
            nr, ng, nb = colorsys.hsv_to_rgb(hue / 360, ns, nv)
            px[x, y] = (round(nr * 255), round(ng * 255), round(nb * 255), a)
    return im


JOBS = [
    ("places", ("user-trash", "user-trash-full"), lambda im: recolor_trash(im, **TRASH)),
    ("devices", ("drive-harddisk", "drive-removable-media-usb"), lambda im: recolor_metal(im, **DISK)),
]


def main():
    count = 0
    for context, names, recolor in JOBS:
        src_root = MINT_L / context
        for size_dir in sorted(p for p in src_root.iterdir() if p.is_dir() and p.name != "symbolic"):
            for name in names:
                src = size_dir / f"{name}.png"
                if not src.exists():
                    continue
                dest = OUT / context / size_dir.name / f"{name}.png"
                dest.parent.mkdir(parents=True, exist_ok=True)
                recolor(Image.open(src).convert("RGBA")).save(dest, optimize=True)
                count += 1
    print(f"{count} PNGs em {OUT}")


if __name__ == "__main__":
    main()
