#!/usr/bin/env python3
"""Build do tema de ícones do CodeOS.

Aplica a paleta do manifest.toml, monta as pastas (modelo + glifo), valida cada SVG,
copia os ícones em PNG de src/raster/ (um por tamanho), cria os links de nomes alternativos,
o index.theme, uma folha de prévia em HTML
e exporta o logo (SVG + PNG) para assets/logo/.

Uso: python3 assets/icons/build.py      (saída em assets/icons/build/)
"""
import base64
import cairo
import gi
import html
import os
import re
import shutil
import sys
import tomllib
import xml.etree.ElementTree as ET
from pathlib import Path

gi.require_version("Rsvg", "2.0")
from gi.repository import Rsvg  # noqa: E402

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "build"
CONTEXTS = {"actions": "Actions", "apps": "Applications", "devices": "Devices", "places": "Places", "status": "Status"}
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9.\-]*$")
TOKEN_RE = re.compile(r"\{\{([a-z-]+)\}\}")
GLYPH_MARK = "<!-- GLYPH -->"
RASTER = ROOT / "src/raster"
RASTER_DIR_RE = re.compile(r"^(\d+)(@2x)?$")
SYMBOLIC_ON_DARK = "#EEEEEC"
LOGO_DIR = ROOT.parent / "logo"
LOGO_SIZES = (64, 128, 256, 512, 1024)


class Icon:
    def __init__(self, context, name, svg, aliases=(), symbolic=False):
        self.context, self.name, self.svg = context, name, svg
        self.aliases, self.symbolic = list(aliases), symbolic

    @property
    def subdir(self):
        return f"{self.context}/{'symbolic' if self.symbolic else 'scalable'}"


def fail(msg):
    sys.exit(f"ERRO: {msg}")


def apply_palette(text, palette, label):
    def sub(m):
        if m.group(1) not in palette:
            fail(f"{label}: token desconhecido {{{{{m.group(1)}}}}}")
        return palette[m.group(1)]
    return TOKEN_RE.sub(sub, text)


def validate(icon):
    label = f"{icon.subdir}/{icon.name}"
    for n in [icon.name, *icon.aliases]:
        if not NAME_RE.match(n):
            fail(f"{label}: nome inválido {n!r} (use minúsculas, números, '-' e '.')")
    if icon.context not in CONTEXTS:
        fail(f"{label}: contexto {icon.context!r} não existe ({', '.join(CONTEXTS)})")
    if icon.symbolic != icon.name.endswith("-symbolic"):
        fail(f"{label}: ícones simbólicos (e só eles) terminam em -symbolic")
    try:
        root = ET.fromstring(icon.svg)
    except ET.ParseError as e:
        fail(f"{label}: SVG inválido: {e}")
    want = "0 0 16 16" if icon.symbolic else "0 0 48 48"
    if root.get("viewBox") != want:
        fail(f"{label}: viewBox {root.get('viewBox')!r}, esperado {want!r}")


def load(manifest):
    palette = manifest["palette"]
    icons = []
    for entry in manifest.get("icon", []):
        src = ROOT / entry["src"]
        svg = apply_palette(src.read_text(), palette, entry["src"])
        icons.append(Icon(entry["context"], entry["name"], svg,
                          entry.get("aliases", ()), entry.get("symbolic", False)))
    template = (ROOT / "src/folders/_template.svg").read_text()
    for entry in manifest.get("folder", []):
        glyph = ""
        if entry["glyph"]:
            glyph = (ROOT / "src/folders/glyphs" / f"{entry['glyph']}.svg").read_text().strip()
        svg = apply_palette(template.replace(GLYPH_MARK, glyph), palette, f"pasta {entry['name']}")
        icons.append(Icon("places", entry["name"], svg, entry.get("aliases", ())))
    for entry in manifest.get("raster", []):
        name = entry["name"]
        if not list(RASTER.glob(f"{entry['context']}/*/{name}.png")):
            fail(f"{entry['context']}/{name}: nenhum PNG em src/raster/{entry['context']}/<tamanho>/")
    names = [n for i in icons for n in (i.name, *i.aliases)]
    names += [n for e in manifest.get("raster", []) for n in (e["name"], *e.get("aliases", ()))]
    dupes = {n for n in names if names.count(n) > 1}
    if dupes:
        fail(f"nomes repetidos: {', '.join(sorted(dupes))}")
    return icons


def write_theme(theme, icons, rasters):
    base = OUT / theme["name"]
    if base.exists():
        shutil.rmtree(base)
    for icon in icons:
        d = base / icon.subdir
        d.mkdir(parents=True, exist_ok=True)
        (d / f"{icon.name}.svg").write_text(icon.svg)
        for alias in icon.aliases:
            os.symlink(f"{icon.name}.svg", d / f"{alias}.svg")

    fixed = []
    for entry in rasters:
        for png in sorted(RASTER.glob(f"{entry['context']}/*/{entry['name']}.png")):
            m = RASTER_DIR_RE.match(png.parent.name)
            if not m:
                fail(f"{png}: pasta de tamanho inválida (use 48 ou 48@2x)")
            subdir = f"{entry['context']}/{png.parent.name}"
            (base / subdir).mkdir(parents=True, exist_ok=True)
            shutil.copy2(png, base / subdir / png.name)
            for alias in entry.get("aliases", ()):
                os.symlink(png.name, base / subdir / f"{alias}.png")
            fixed.append((subdir, int(m.group(1)), 2 if m.group(2) else 1))

    dirs = sorted({i.subdir for i in icons} | {d for d, _, _ in fixed})
    lines = [
        "[Icon Theme]",
        f"Name={theme['name']}",
        f"Comment={theme['comment']}",
        f"Inherits={theme['inherits']}",
        f"Directories={','.join(dirs)}",
        "",
    ]
    sizes = {d: (size, scale) for d, size, scale in fixed}
    for d in dirs:
        context, kind = d.split("/")
        if d in sizes:
            size, scale = sizes[d]
            lines += [f"[{d}]", f"Context={CONTEXTS[context]}", f"Size={size}", f"Scale={scale}", "Type=Fixed", ""]
            continue
        lines += [f"[{d}]", f"Context={CONTEXTS[context]}", f"Size={16 if kind == 'symbolic' else 48}",
                  "MinSize=16", "MaxSize=512", "Type=Scalable", ""]
    (base / "index.theme").write_text("\n".join(lines))
    return base


def render_png(svg, size, path):
    handle = Rsvg.Handle.new_from_data(svg.encode())
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, size, size)
    viewport = Rsvg.Rectangle()
    viewport.x = viewport.y = 0
    viewport.width = viewport.height = size
    handle.render_document(cairo.Context(surface), viewport)
    surface.write_to_png(str(path))


def write_logo(icons):
    """Exporta o logo (SVG com a paleta aplicada + PNGs transparentes) para assets/logo/."""
    logo = next(i for i in icons if i.name == "codeos")
    LOGO_DIR.mkdir(exist_ok=True)
    (LOGO_DIR / "codeos-logo.svg").write_text(logo.svg)
    for size in LOGO_SIZES:
        render_png(logo.svg, size, LOGO_DIR / f"codeos-logo-{size}.png")


def data_uri(svg):
    return "data:image/svg+xml;base64," + base64.b64encode(svg.encode()).decode()


def img(icon, size, dark=False, symbolic_color=""):
    svg = icon.svg
    if icon.symbolic and dark:
        svg = svg.replace(symbolic_color, SYMBOLIC_ON_DARK)
    return f'<img src="{data_uri(svg)}" width="{size}" height="{size}" alt="{html.escape(icon.name)}">'


def write_preview(theme, icons, palette):
    sym = palette["symbolic"]
    by_name = {i.name: i for i in icons}
    rows = []
    for icon in icons:
        cells = []
        for dark in (False, True):
            sizes = "".join(f"<span>{img(icon, s, dark, sym)}<small>{s}</small></span>"
                            for s in (16, 24, 32, 48, 96))
            cells.append(f'<div class="swatch {"dark" if dark else "light"}">{sizes}</div>')
        aliases = f"<div class='aliases'>{html.escape(', '.join(icon.aliases))}</div>" if icon.aliases else ""
        rows.append(f"<section><h2>{html.escape(icon.name)}<em>{icon.subdir}</em></h2>{aliases}"
                    f"<div class='pair'>{''.join(cells)}</div></section>")

    def bar_icon(name, size=24, dark=True):
        return img(by_name[name], size, dark, sym) if name in by_name else ""

    taskbar = (
        '<div class="taskbar">'
        f'<span class="start">{bar_icon("codeos")}</span>'
        f'<span class="task active">{bar_icon("utilities-terminal")}</span>'
        f'<span class="task">{bar_icon("folder-projects")}</span>'
        f'<span class="task">{bar_icon("codeos-nightlight")}</span>'
        f'<span class="tray">{bar_icon("codeos-dual-audio-symbolic", 16)}<b>23:40</b></span>'
        "</div>"
    )
    desktop = "".join(
        f'<figure>{bar_icon(n, 48)}<figcaption>{label}</figcaption></figure>'
        for n, label in (("folder", "Pasta"), ("folder-projects", "Projetos"),
                         ("folder-download", "Downloads"), ("utilities-terminal", "Terminal"),
                         ("codeos-nightlight", "Luz noturna"))
        if n in by_name
    )
    page = f"""<!doctype html>
<html lang="pt-BR"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(theme['name'])} — prévia dos ícones</title>
<style>
  :root {{ --bg:#F1F5F9; --card:#FFFFFF; --ink:#0F172A; --soft:#64748B; --line:#E2E8F0; }}
  * {{ box-sizing: border-box; }}
  body {{ margin:0; padding:24px 16px 48px; background:var(--bg); color:var(--ink);
         font:14px/1.45 system-ui, "Segoe UI", sans-serif; }}
  main {{ max-width:1080px; margin:0 auto; }}
  h1 {{ margin:0 0 4px; font-size:22px; }}
  p.lead {{ margin:0 0 20px; color:var(--soft); }}
  h3 {{ margin:28px 0 10px; font-size:13px; text-transform:uppercase; letter-spacing:.06em; color:var(--soft); }}
  .desk {{ display:flex; flex-wrap:wrap; gap:8px; padding:20px; border-radius:12px;
          background:linear-gradient(135deg,#1E293B,#0F172A); }}
  figure {{ margin:0; width:96px; text-align:center; color:#E2E8F0; font-size:12px; }}
  figure img {{ display:block; margin:0 auto 6px; }}
  .taskbar {{ display:flex; align-items:center; gap:4px; height:44px; padding:0 8px; margin-top:8px;
             border-radius:10px; background:#1F2937; color:#E5E7EB; }}
  .taskbar span {{ display:grid; place-items:center; width:40px; height:36px; border-radius:6px; }}
  .taskbar .active {{ background:#374151; box-shadow: inset 0 -2px 0 #06B6D4; }}
  .taskbar .tray {{ margin-left:auto; width:auto; display:flex; gap:10px; padding:0 6px; }}
  .taskbar b {{ font-weight:500; font-size:12px; }}
  section {{ background:var(--card); border:1px solid var(--line); border-radius:12px; padding:14px 16px; margin-bottom:12px; }}
  h2 {{ margin:0; font-size:15px; display:flex; gap:10px; align-items:baseline; flex-wrap:wrap; }}
  h2 em {{ font-style:normal; font-weight:400; font-size:12px; color:var(--soft); }}
  .aliases {{ font-size:12px; color:var(--soft); margin-top:2px; }}
  .pair {{ display:grid; grid-template-columns:repeat(auto-fit, minmax(300px, 1fr)); gap:10px; margin-top:10px; }}
  .swatch {{ display:flex; align-items:flex-end; gap:14px; padding:14px; border-radius:8px; overflow-x:auto; }}
  .swatch.light {{ background:#F8FAFC; border:1px solid var(--line); }}
  .swatch.dark {{ background:#111827; color:#9CA3AF; }}
  .swatch span {{ display:flex; flex-direction:column; align-items:center; gap:4px; }}
  .swatch small {{ font-size:11px; color:inherit; opacity:.7; }}
</style></head>
<body><main>
<h1>{html.escape(theme['name'])} — piloto de ícones</h1>
<p class="lead">{len(icons)} ícones · herda de {html.escape(theme['inherits'])} · gerado por build.py</p>
<h3>Em contexto</h3>
<div class="desk">{desktop}</div>
{taskbar}
<h3>Ícone por ícone (16 · 24 · 32 · 48 · 96 px, fundo claro e escuro)</h3>
{''.join(rows)}
</main></body></html>
"""
    path = OUT / "preview.html"
    path.write_text(page)
    return path


def main():
    manifest = tomllib.loads((ROOT / "manifest.toml").read_text())
    icons = load(manifest)
    for icon in icons:
        validate(icon)
    OUT.mkdir(exist_ok=True)
    rasters = manifest.get("raster", [])
    base = write_theme(manifest["theme"], icons, rasters)
    preview = write_preview(manifest["theme"], icons, manifest["palette"])
    write_logo(icons)
    links = sum(len(i.aliases) for i in icons) + sum(len(e.get("aliases", ())) for e in rasters)
    print(f"{len(icons)} ícones, {len(rasters)} em PNG e {links} links em {base}")
    print(f"prévia: {preview}")
    print(f"logo: {LOGO_DIR} (SVG + PNG {', '.join(map(str, LOGO_SIZES))} px)")


if __name__ == "__main__":
    main()
