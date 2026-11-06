#!/usr/bin/env python3
"""Logo da tela de login (slick-greeter): ícone + "CodeOS" numa faixa de 40 px.

O slick-greeter desenha a logo sem redimensionar, com o canto de cima a 2 quadrados da grade (80 px)
do fundo e colado na borda esquerda; ele espera uma marca horizontal baixa, com a margem dentro da
imagem (como a do Mint). Uma logo quadrada de 128 px descia além da tela e ficava cortada.

  python3 assets/logo/build_greeter_logo.py   → assets/logo/codeos-greeter-logo.png
"""
import io
from pathlib import Path

import gi

gi.require_version("Rsvg", "2.0")
from gi.repository import Rsvg  # noqa: E402
from PIL import Image, ImageDraw, ImageFont  # noqa: E402
import cairo  # noqa: E402

HERE = Path(__file__).resolve().parent
SVG = HERE / "codeos-logo.svg"
OUT = HERE / "codeos-greeter-logo.png"
FONT = "/usr/local/share/fonts/selawik/selawksb.ttf"  # Selawik Semibold (role 10_desktop)

GRID = 40          # quadrado da grade do slick-greeter
MARGEM = GRID      # mesma margem esquerda da grade
ICONE = 30         # altura do ícone dentro da faixa
TEXTO = 22         # tamanho da fonte de "CodeOS"
ESPACO = 10        # entre o ícone e o texto


def icone():
    handle = Rsvg.Handle.new_from_file(str(SVG))
    lado = 512
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, lado, lado)
    ctx = cairo.Context(surface)
    area = Rsvg.Rectangle()
    area.x, area.y, area.width, area.height = 0, 0, lado, lado
    handle.render_document(ctx, area)
    buf = io.BytesIO()
    surface.write_to_png(buf)
    im = Image.open(buf).convert("RGBA")
    im = im.crop(im.split()[3].getbbox())
    return im.resize((round(im.width * ICONE / im.height), ICONE), Image.LANCZOS)


def main():
    ic = icone()
    fonte = ImageFont.truetype(FONT, TEXTO)
    esq, topo, dir_, base = fonte.getbbox("CodeOS")
    largura = MARGEM + ic.width + ESPACO + (dir_ - esq) + 4
    im = Image.new("RGBA", (largura, GRID), (0, 0, 0, 0))
    im.alpha_composite(ic, (MARGEM, (GRID - ICONE) // 2))
    d = ImageDraw.Draw(im)
    # sombra leve para o texto ler em qualquer papel de parede
    y = (GRID - (base - topo)) // 2 - topo
    x = MARGEM + ic.width + ESPACO - esq
    d.text((x, y + 1), "CodeOS", font=fonte, fill=(0, 0, 0, 110))
    d.text((x, y), "CodeOS", font=fonte, fill=(255, 255, 255, 255))
    im.save(OUT)
    print(f"{OUT.relative_to(HERE.parent.parent)}: {im.width}x{im.height}")


if __name__ == "__main__":
    main()
