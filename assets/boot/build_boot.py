#!/usr/bin/env python3
"""Animação de boot do CodeOS: o logo no fundo preto com um brilho neon no próprio contorno,
que esmaece e volta suavemente (sem piscar e sem linha em volta).

Gera as duas camadas que o tema Plymouth vai usar (logo.png e glow.png) e uma prévia
(MP4 e GIF) montada com exatamente as mesmas camadas e a mesma curva de brilho.
Nada é instalado: o tema Plymouth é outro passo, depois da aprovação da prévia.

Uso: python3 assets/boot/build_boot.py      (saída em assets/boot/build/)
"""
import math
import subprocess
import sys
import tomllib
from pathlib import Path

import cairo
import gi
from PIL import Image

gi.require_version("Rsvg", "2.0")
from gi.repository import Rsvg  # noqa: E402

ROOT = Path(__file__).resolve().parent
ICONS = ROOT.parent / "icons"
OUT = ROOT / "build"

W, H, FPS = 1920, 1080, 30
LOGO_PX = 300                  # o logo ocupa ~28% da altura da tela
FADE_IN = 1.5                  # logo e brilho surgem do preto, em s
LOOP = 3.6                     # período de um ciclo esmaece → brilha, em s
GLOW_MIN, GLOW_MAX = 0.15, 1.0 # faixa do brilho durante o ciclo
PREVIEW_SECONDS = FADE_IN + 3 * LOOP


def smooth(x):
    """Rampa suave 0→1 (sem trancos no começo e no fim)."""
    x = min(max(x, 0.0), 1.0)
    return x * x * (3 - 2 * x)


def logo_opacity(t):
    return smooth(t / FADE_IN)


def brightness(t):
    """Brilho do contorno (0–1) no instante t. O script do Plymouth reimplementa esta mesma curva."""
    if t < FADE_IN:
        return GLOW_MAX * smooth(t / FADE_IN)
    u = (t - FADE_IN) % LOOP
    # cosseno: começa no máximo, esmaece até GLOW_MIN no meio do ciclo e volta
    return GLOW_MIN + (GLOW_MAX - GLOW_MIN) * (0.5 + 0.5 * math.cos(2 * math.pi * u / LOOP))


def render(svg, width, height):
    handle = Rsvg.Handle.new_from_data(svg.encode())
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, width, height)
    viewport = Rsvg.Rectangle()
    viewport.x = viewport.y = 0
    viewport.width, viewport.height = width, height
    handle.render_document(cairo.Context(surface), viewport)
    # cairo guarda BGRA pré-multiplicado; o PIL converte com o modo "RGBa"
    return Image.frombuffer("RGBa", (width, height), bytes(surface.get_data()), "raw", "BGRa", 0, 1).convert("RGBA")


def hexagon(cx, cy, r):
    return " ".join(f"{cx + r * math.cos(math.radians(a)):.1f},{cy + r * math.sin(math.radians(a)):.1f}"
                    for a in (-90, -30, 30, 90, 150, 210))


def glow_svg(palette):
    # Só desfoques do próprio contorno do logo (hexágono externo, r = 20/48 do tamanho):
    # nenhum traço nítido, então não aparece linha em volta — a luz sai da borda ciano.
    edge = hexagon(W / 2, H / 2, LOGO_PX * 20 / 48)
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">
  <defs>
    <filter id="wide" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="34"/></filter>
    <filter id="mid" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="14"/></filter>
    <filter id="tight" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="5"/></filter>
  </defs>
  <g fill="none" stroke-linejoin="round">
    <polygon points="{edge}" stroke="{palette['primary']}" stroke-width="40" opacity="0.8" filter="url(#wide)"/>
    <polygon points="{edge}" stroke="{palette['accent']}" stroke-width="18" opacity="0.9" filter="url(#mid)"/>
    <polygon points="{edge}" stroke="{palette['accent-light']}" stroke-width="8" filter="url(#tight)"/>
  </g>
</svg>"""


PLYMOUTH_THEME = """[Plymouth Theme]
Name=CodeOS
Description=Logo do CodeOS com brilho neon no contorno que esmaece e volta
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/codeos
ScriptFile=/usr/share/plymouth/themes/codeos/codeos.script
"""

# Mesma curva de logo_opacity() e brightness() acima; os números vêm das constantes deste arquivo.
PLYMOUTH_SCRIPT = """# CodeOS — tema de boot. Gerado por assets/boot/build_boot.py: edite lá, não aqui.

Window.SetBackgroundTopColor(0, 0, 0);
Window.SetBackgroundBottomColor(0, 0, 0);

FADE_IN = {fade_in};
LOOP = {loop};
GLOW_MIN = {glow_min};
GLOW_MAX = {glow_max};
FPS = 50;  # o Plymouth chama a função de refresh 50 vezes por segundo

# As camadas foram desenhadas para uma tela de {ref_h} px de altura.
scale = Window.GetHeight() / {ref_h};
logo.image = Image("logo.png");
logo.image = logo.image.Scale(logo.image.GetWidth() * scale, logo.image.GetHeight() * scale);
glow.image = Image("glow.png");
glow.image = glow.image.Scale(glow.image.GetWidth() * scale, glow.image.GetHeight() * scale);

cx = Window.GetX() + Window.GetWidth() / 2;
cy = Window.GetY() + Window.GetHeight() / 2;

glow.sprite = Sprite(glow.image);
glow.sprite.SetPosition(cx - glow.image.GetWidth() / 2, cy - glow.image.GetHeight() / 2, 1);
glow.sprite.SetOpacity(0);
logo.sprite = Sprite(logo.image);
logo.sprite.SetPosition(cx - logo.image.GetWidth() / 2, cy - logo.image.GetHeight() / 2, 2);
logo.sprite.SetOpacity(0);

frame = 0;
status = "normal";

fun smooth(x)
  {{
    if (x < 0) x = 0;
    if (x > 1) x = 1;
    return x * x * (3 - 2 * x);
  }}

fun glow_level(t)
  {{
    if (t < FADE_IN)
      return GLOW_MAX * smooth(t / FADE_IN);
    u = t - FADE_IN;
    u = u - Math.Int(u / LOOP) * LOOP;
    return GLOW_MIN + (GLOW_MAX - GLOW_MIN) * (0.5 + 0.5 * Math.Cos(2 * Math.Pi * u / LOOP));
  }}

fun refresh_callback()
  {{
    global.frame += 1;
    t = global.frame / FPS;
    logo.sprite.SetOpacity(smooth(t / FADE_IN));
    glow.sprite.SetOpacity(glow_level(t));
  }}

Plymouth.SetRefreshFunction(refresh_callback);

#------------------------------ senha (ex.: disco criptografado) ------------------------------

prompt.sprite = Sprite();
bullets.sprite = Sprite();

fun display_password_callback(text, count)
  {{
    global.status = "password";
    p = Image.Text(text, 1, 1, 1);
    prompt.sprite.SetImage(p);
    prompt.sprite.SetPosition(cx - p.GetWidth() / 2, cy + logo.image.GetHeight() * 0.8, 10);
    prompt.sprite.SetOpacity(1);
    s = " ";
    for (i = 0; i < count; i++)
      s = s + "*";
    b = Image.Text(s, 1, 1, 1);
    bullets.sprite.SetImage(b);
    bullets.sprite.SetPosition(cx - b.GetWidth() / 2, cy + logo.image.GetHeight() * 0.8 + p.GetHeight() * 1.5, 10);
    bullets.sprite.SetOpacity(1);
  }}

fun display_normal_callback()
  {{
    global.status = "normal";
    prompt.sprite.SetOpacity(0);
    bullets.sprite.SetOpacity(0);
  }}

Plymouth.SetDisplayPasswordFunction(display_password_callback);
Plymouth.SetDisplayNormalFunction(display_normal_callback);

#------------------------------ mensagens (ex.: verificação de disco) ------------------------------

message.sprite = Sprite();

fun display_message_callback(text)
  {{
    m = Image.Text(text, 0.7, 0.7, 0.7);
    message.sprite.SetImage(m);
    message.sprite.SetPosition(cx - m.GetWidth() / 2, Window.GetY() + Window.GetHeight() * 0.9, 10);
    message.sprite.SetOpacity(1);
  }}

fun hide_message_callback(text)
  {{
    message.sprite.SetOpacity(0);
  }}

Plymouth.SetDisplayMessageFunction(display_message_callback);
Plymouth.SetHideMessageFunction(hide_message_callback);

fun quit_callback()
  {{
    logo.sprite.SetOpacity(1);
  }}

Plymouth.SetQuitFunction(quit_callback);
"""


def write_plymouth_theme(directory):
    (directory / "codeos.plymouth").write_text(PLYMOUTH_THEME)
    (directory / "codeos.script").write_text(PLYMOUTH_SCRIPT.format(
        fade_in=FADE_IN, loop=LOOP, glow_min=GLOW_MIN, glow_max=GLOW_MAX, ref_h=H))


def scaled_alpha(layer, level, cache):
    key = round(level * 100)
    if key not in cache:
        r, g, b, a = layer.split()
        a = a.point(lambda v: v * key // 100)
        cache[key] = Image.merge("RGBA", (r, g, b, a))
    return cache[key]


def main():
    manifest = tomllib.loads((ICONS / "manifest.toml").read_text())
    palette = manifest["palette"]
    logo_svg = (ROOT.parent / "logo" / "codeos-logo.svg")
    if not logo_svg.exists():
        sys.exit("ERRO: rode antes python3 assets/icons/build.py (ele gera assets/logo/codeos-logo.svg).")

    OUT.mkdir(exist_ok=True)
    plymouth = OUT / "plymouth"
    plymouth.mkdir(exist_ok=True)

    logo = render(logo_svg.read_text(), LOGO_PX, LOGO_PX)
    glow = render(glow_svg(palette), W, H)
    logo.save(plymouth / "logo.png")
    bbox = glow.getbbox()
    glow.crop(bbox).save(plymouth / "glow.png")
    if (bbox[0] + bbox[2]) / 2 != W / 2 or (bbox[1] + bbox[3]) / 2 != H / 2:
        sys.exit(f"ERRO: o brilho recortado {bbox} não está centrado; o script do Plymouth assume que está.")
    write_plymouth_theme(plymouth)
    print(f"tema Plymouth em {plymouth} (glow recortado em {bbox})")

    logo_pos = ((W - LOGO_PX) // 2, (H - LOGO_PX) // 2)
    black = Image.new("RGB", (W, H), (0, 0, 0))
    cache = {}
    mp4 = OUT / "boot-preview.mp4"
    ffmpeg = subprocess.Popen(
        ["ffmpeg", "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}",
         "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18",
         "-movflags", "+faststart", str(mp4)],
        stdin=subprocess.PIPE)
    frames = int(PREVIEW_SECONDS * FPS)
    logo_cache = {}
    for n in range(frames):
        t = n / FPS
        frame = black.copy()
        layer = scaled_alpha(glow, brightness(t), cache)
        frame.paste(layer, (0, 0), layer)
        shown = scaled_alpha(logo, logo_opacity(t), logo_cache)
        frame.paste(shown, logo_pos, shown)
        ffmpeg.stdin.write(frame.tobytes())
        if n == int(FADE_IN * FPS):
            frame.save(OUT / "boot-still.png")
    ffmpeg.stdin.close()
    if ffmpeg.wait() != 0:
        sys.exit("ERRO: ffmpeg falhou ao gerar o MP4.")

    gif = OUT / "boot-preview.gif"
    subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-y", "-i", str(mp4), "-vf",
         "fps=20,scale=720:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse", str(gif)],
        check=True)
    print(f"prévia: {mp4} ({frames} quadros, {PREVIEW_SECONDS:.1f} s) e {gif}")


if __name__ == "__main__":
    main()
