#!/usr/bin/env python3
"""Papéis de parede com o logo do CodeOS: fundos abstratos com o logo no centro, plano e em 3D.

O logo é desenhado direto dos polígonos do codeos-logo.svg (mesmas coordenadas). A versão 3D extruda
cada polígono (moldura, miolo e "</>"), gira, projeta em perspectiva e ilumina cada face (Lambert +
brilho), desenhando de trás para a frente; embaixo vão sombra e reflexo.

  python3 assets/wallpapers/build_logo_wallpapers.py   → assets/wallpapers/codeos/codeos-logo-*.jpg (3840x2160)

Saem direto em JPEG, porque o Ansible sincroniza os *.jpg da pasta para /usr/share/backgrounds/codeos.
"""
import math
import random
from pathlib import Path

import cairo
from PIL import Image, ImageFilter

HERE = Path(__file__).resolve().parent
OUT = HERE / "codeos"
W, H = 3840, 2160

CIANO = (0x05 / 255, 0xC0 / 255, 0xDF / 255)
AZUL = (0x1E / 255, 0x54 / 255, 0xBC / 255)
BRANCO = (1.0, 1.0, 1.0)

# polígonos do codeos-logo.svg, no espaço do original (centro 511.5,285.5; hexágono r=232.5)
CX, CY, R = 511.5, 285.5, 232.5
MOLDURA = [(511.5, 53), (712.85, 169.25), (712.85, 401.75), (511.5, 518), (310.15, 401.75), (310.15, 169.25)]
MIOLO = [(511.5, 53), (511.5, 91), (679.94, 188.25), (679.94, 382.75), (511.5, 480), (343.06, 382.75),
         (343.06, 188.25), (310.15, 169.25)]
MENOR = [(458, 228), (458, 257), (411.5, 285.5), (458, 314), (458, 343), (382, 299), (382, 272)]
MAIOR = [(565, 228), (641, 272), (641, 299), (565, 343), (565, 314), (611.5, 285.5), (565, 257)]
BARRA = [(524, 205), (551, 205), (499, 366), (472, 366)]


def normal(pts, escala, cx, cy):
    return [((x - CX) * escala + cx, (y - CY) * escala + cy) for x, y in pts]


def poligono(ctx, pts):
    ctx.move_to(*pts[0])
    for p in pts[1:]:
        ctx.line_to(*p)
    ctx.close_path()


# ── fundos ────────────────────────────────────────────────────────────────────────────────────

def radial(ctx, centro, borda, cx=W / 2, cy=H / 2, r=W * 0.75):
    g = cairo.RadialGradient(cx, cy, 0, cx, cy, r)
    g.add_color_stop_rgb(0, *centro)
    g.add_color_stop_rgb(1, *borda)
    ctx.set_source(g)
    ctx.paint()


def grade_hex(ctx, cor, alfa, lado=150):
    """Grade de hexágonos que some perto das bordas."""
    dx, dy = lado * math.sqrt(3), lado * 1.5
    linha = 0
    y = -lado
    while y < H + lado:
        x = -lado + (dx / 2 if linha % 2 else 0)
        while x < W + lado:
            d = math.hypot((x - W / 2) / W, (y - H / 2) / H)
            a = alfa * max(0.0, 1 - d * 1.6)
            if a > 0.002:
                pts = [(x + lado * math.cos(math.radians(30 + 60 * i)), y + lado * math.sin(math.radians(30 + 60 * i)))
                       for i in range(6)]
                poligono(ctx, pts)
                ctx.set_source_rgba(*cor, a)
                ctx.set_line_width(3)
                ctx.stroke()
            x += dx
        y += dy
        linha += 1


def ondas(ctx, cores, semente):
    """Faixas suaves e translúcidas atravessando a tela."""
    rnd = random.Random(semente)
    for i, (cor, alfa) in enumerate(cores):
        base = H * (0.35 + 0.1 * i) + rnd.uniform(-80, 80)
        amp = rnd.uniform(160, 320)
        fase = rnd.uniform(0, math.tau)
        larg = rnd.uniform(180, 420)
        ctx.move_to(-50, base)
        pts = [(x, base + amp * math.sin(x / W * math.tau * 0.8 + fase)) for x in range(-50, W + 100, 60)]
        for p in pts:
            ctx.line_to(*p)
        for x, y in reversed(pts):
            ctx.line_to(x, y + larg + 0.3 * amp * math.sin(x / W * math.tau * 1.3 + fase))
        ctx.close_path()
        g = cairo.LinearGradient(0, 0, W, 0)
        g.add_color_stop_rgba(0, *cor, 0)
        g.add_color_stop_rgba(0.5, *cor, alfa)
        g.add_color_stop_rgba(1, *cor, 0)
        ctx.set_source(g)
        ctx.fill()


def low_poly(ctx, c1, c2, semente, passo=260):
    """Malha de triângulos (grade com pontos deslocados), cor pela posição + variação."""
    rnd = random.Random(semente)
    cols, lins = W // passo + 5, H // passo + 5
    pts = [[(i * passo - passo + rnd.uniform(-0.38, 0.38) * passo, j * passo - passo + rnd.uniform(-0.38, 0.38) * passo)
            for i in range(cols)] for j in range(lins)]
    for j in range(lins - 1):
        for i in range(cols - 1):
            a, b, c, d = pts[j][i], pts[j][i + 1], pts[j + 1][i], pts[j + 1][i + 1]
            for tri in ((a, b, d), (a, d, c)) if rnd.random() < 0.5 else ((a, b, c), (b, d, c)):
                mx = sum(p[0] for p in tri) / 3
                my = sum(p[1] for p in tri) / 3
                t = max(0, min(1, (mx / W) * 0.6 + (my / H) * 0.4 + rnd.uniform(-0.08, 0.08)))
                dist = math.hypot(mx - W / 2, my - H / 2) / (W / 2)
                luz = 1.0 + 0.25 * max(0, 1 - dist) + rnd.uniform(-0.05, 0.05)
                cor = tuple(min(1, (c1[k] * (1 - t) + c2[k] * t) * luz) for k in range(3))
                poligono(ctx, tri)
                ctx.set_source_rgb(*cor)
                ctx.fill_preserve()
                ctx.set_line_width(1.2)
                ctx.stroke()


def brilho(img, cor, raio, intensidade, cx=W // 2, cy=H // 2):
    """Halo desfocado atrás do logo."""
    camada = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    s = cairo.ImageSurface(cairo.FORMAT_ARGB32, W, H)
    c = cairo.Context(s)
    g = cairo.RadialGradient(cx, cy, 0, cx, cy, raio)
    g.add_color_stop_rgba(0, *cor, intensidade)
    g.add_color_stop_rgba(1, *cor, 0)
    c.set_source(g)
    c.paint()
    camada = superficie_pil(s)
    return Image.alpha_composite(img, camada)


def superficie_pil(s):
    s.flush()
    # cairo guarda o alfa pré-multiplicado (BGRa); o PIL desfaz isso ao ler
    return Image.frombuffer("RGBA", (s.get_width(), s.get_height()), bytes(s.get_data()), "raw", "BGRa", 0, 1).copy()


# ── logo plano ────────────────────────────────────────────────────────────────────────────────

def logo_plano(ctx, cx, cy, altura, sombra=True):
    escala = altura / (2 * R)
    partes = [(MOLDURA, CIANO), (MIOLO, AZUL), (MENOR, BRANCO), (MAIOR, BRANCO), (BARRA, BRANCO)]
    for pts, cor in partes:
        poligono(ctx, normal(pts, escala, cx, cy))
        ctx.set_source_rgb(*cor)
        ctx.fill()


# ── logo 3D ───────────────────────────────────────────────────────────────────────────────────

def girar(p, yaw, pitch):
    x, y, z = p
    cy_, sy = math.cos(yaw), math.sin(yaw)
    x, z = x * cy_ + z * sy, -x * sy + z * cy_
    cp, sp = math.cos(pitch), math.sin(pitch)
    y, z = y * cp - z * sp, y * sp + z * cp
    return x, y, z


def logo_3d(ctx, cx, cy, altura, yaw=-0.42, pitch=-0.20, luz=(-0.45, -0.6, -0.66), espelho=False):
    """Extrusão de cada polígono; z negativo = para a frente (na direção da câmera)."""
    escala = altura / (2 * R)
    dist = 2600.0  # distância da câmera, no espaço do logo
    lx, ly, lz = luz
    n = math.sqrt(lx * lx + ly * ly + lz * lz)
    luz = (lx / n, ly / n, lz / n)
    # as peças ficam empilhadas de trás para a frente (moldura, miolo um pouco à frente, "</>" saltado);
    # cada peça é desenhada inteira (lados e depois a frente) por cima das anteriores
    pecas = [(MOLDURA, CIANO, 0, 90), (MIOLO, AZUL, -14, 20), (MENOR, BRANCO, -46, 32),
             (MAIOR, BRANCO, -46, 32), (BARRA, BRANCO, -46, 32)]
    for pts, cor, zf, prof in pecas:
        desenhar_peca(ctx, pts, cor, zf, prof, cx, cy, escala, dist, yaw, pitch, luz, espelho)


def desenhar_peca(ctx, pts, cor, zf, prof, cx, cy, escala, dist, yaw, pitch, luz, espelho):
    faces = []
    frente = [(x - CX, y - CY, zf) for x, y in pts]
    tras = [(x - CX, y - CY, zf + prof) for x, y in pts]
    frente_g = [girar(p, yaw, pitch) for p in frente]
    tras_g = [girar(p, yaw, pitch) for p in tras]
    k = len(pts)
    for i in range(k):
        j = (i + 1) % k
        quad = [frente_g[i], frente_g[j], tras_g[j], tras_g[i]]
        faces.append((quad, cor, "lado"))
    faces.append((frente_g, cor, "frente"))
    proj = []
    for quad, cor, tipo in faces:
        # normal da face (produto vetorial) e profundidade média
        (ax, ay, az), (bx, by, bz), (cx3, cy3, cz3) = quad[0], quad[1], quad[2]
        ux, uy, uz = bx - ax, by - ay, bz - az
        vx, vy, vz = cx3 - ax, cy3 - ay, cz3 - az
        nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
        nn = math.sqrt(nx * nx + ny * ny + nz * nz) or 1
        nx, ny, nz = nx / nn, ny / nn, nz / nn
        if nz > 0:  # normal virada para longe da câmera: inverte (faces sem orientação fixa)
            nx, ny, nz = -nx, -ny, -nz
        lamb = max(0.0, nx * luz[0] + ny * luz[1] + nz * luz[2])
        meio = sum(p[2] for p in quad) / len(quad)
        tela = []
        for x, y, z in quad:
            f = dist / (dist + z)
            px, py = x * f * escala, y * f * escala
            if espelho:
                py = -py
            tela.append((cx + px, cy + py))
        if tipo == "frente":
            fator = 0.78 + 0.32 * lamb
        else:
            fator = 0.42 + 0.55 * lamb
        proj.append((meio, tela, cor, fator, tipo))
    # lados de trás para a frente, a face da frente por último
    proj.sort(key=lambda f: (f[4] == "frente", -f[0]))
    for _, tela, cor, fator, tipo in proj:
        poligono(ctx, tela)
        r, g, b = (min(1, c * fator) for c in cor)
        if tipo == "frente":
            xs = [p[0] for p in tela]
            ys = [p[1] for p in tela]
            grad = cairo.LinearGradient(min(xs), min(ys), max(xs), max(ys))
            grad.add_color_stop_rgb(0, min(1, r * 1.12 + 0.04), min(1, g * 1.12 + 0.04), min(1, b * 1.12 + 0.04))
            grad.add_color_stop_rgb(1, r * 0.86, g * 0.86, b * 0.86)
            ctx.set_source(grad)
        else:
            ctx.set_source_rgb(r, g, b)
        ctx.fill_preserve()
        ctx.set_line_width(1.0)
        ctx.set_source_rgba(r * 0.9, g * 0.9, b * 0.9, 0.9)
        ctx.stroke()


def camada_logo_3d(cx, cy, altura, **kw):
    s = cairo.ImageSurface(cairo.FORMAT_ARGB32, W, H)
    logo_3d(cairo.Context(s), cx, cy, altura, **kw)
    return superficie_pil(s)


def compor_3d(fundo, cx, cy, altura, cor_sombra=(0, 0, 0), chao=True):
    img = fundo
    logo = camada_logo_3d(cx, cy, altura)
    a = logo.split()[3]
    if chao:
        # sombra no "chão": a silhueta achatada, desfocada, abaixo do logo
        base = cy + altura * 0.56
        silhueta = a.resize((W, max(1, int(H * 0.16)))).filter(ImageFilter.GaussianBlur(40))
        sombra = Image.new("RGBA", (W, H), (*cor_sombra, 0))
        caixa = Image.new("RGBA", silhueta.size, (*cor_sombra, 255))
        caixa.putalpha(silhueta.point(lambda v: int(v * 0.55)))
        sombra.alpha_composite(caixa, (0, int(base - silhueta.size[1] * 0.5)))
        img = Image.alpha_composite(img, sombra)
        # reflexo: o logo espelhado, apagando para baixo
        refl = camada_logo_3d(cx, base * 2 - cy - altura * 0.12, altura, espelho=True)
        mascara = Image.new("L", (1, H))
        for y in range(H):
            t = (y - base) / (altura * 0.7)
            mascara.putpixel((0, y), int(70 * max(0, 1 - t)) if y > base else 0)
        mascara = mascara.resize((W, H))
        ra = refl.split()[3]
        refl.putalpha(Image.composite(mascara, Image.new("L", (W, H), 0), ra))
        img = Image.alpha_composite(img, refl.filter(ImageFilter.GaussianBlur(3)))
    return Image.alpha_composite(img, logo)


# ── papéis de parede ──────────────────────────────────────────────────────────────────────────

def fundo(desenho):
    s = cairo.ImageSurface(cairo.FORMAT_ARGB32, W, H)
    desenho(cairo.Context(s))
    return superficie_pil(s)


def navy(ctx):
    radial(ctx, (0.09, 0.19, 0.42), (0.02, 0.05, 0.13))
    grade_hex(ctx, CIANO, 0.07)


def ondas_azuis(ctx):
    g = cairo.LinearGradient(0, 0, W, H)
    g.add_color_stop_rgb(0, 0.03, 0.09, 0.25)
    g.add_color_stop_rgb(1, 0.02, 0.33, 0.50)
    ctx.set_source(g)
    ctx.paint()
    ondas(ctx, [(CIANO, 0.16), (AZUL, 0.30), ((0.4, 0.75, 1.0), 0.10), (CIANO, 0.10)], semente=7)


def poligonos(ctx):
    low_poly(ctx, (0.04, 0.10, 0.28), (0.03, 0.42, 0.62), semente=3)


def claro(ctx):
    radial(ctx, (0.96, 0.97, 0.99), (0.78, 0.84, 0.92))
    grade_hex(ctx, AZUL, 0.08)


def meia_noite(ctx):
    radial(ctx, (0.05, 0.06, 0.10), (0.0, 0.0, 0.02))
    ondas(ctx, [(CIANO, 0.07), (AZUL, 0.12)], semente=11)


def salvar(img, nome):
    # Qualidade alta e sem subamostragem de cor: degradês e bordas do logo sem faixas nem serrilhado.
    img.convert("RGB").save(OUT / nome, quality=92, subsampling=0, optimize=True, progressive=True)


def main():
    fundos = {"navy": (navy, CIANO, 0.35), "waves": (ondas_azuis, CIANO, 0.25),
              "lowpoly": (poligonos, CIANO, 0.25), "light": (claro, AZUL, 0.18),
              "midnight": (meia_noite, CIANO, 0.30)}
    for nome, (desenho, cor_halo, halo) in fundos.items():
        base = fundo(desenho)
        base = brilho(base, cor_halo, H * 0.42, halo)
        # plano
        s = cairo.ImageSurface(cairo.FORMAT_ARGB32, W, H)
        logo_plano(cairo.Context(s), W / 2, H / 2, H * 0.30)
        logo = superficie_pil(s)
        sombra = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        sombra.putalpha(logo.split()[3].point(lambda v: int(v * 0.45)))
        sombra = sombra.filter(ImageFilter.GaussianBlur(28))
        plano = Image.alpha_composite(Image.alpha_composite(base, sombra.transform(
            (W, H), Image.AFFINE, (1, 0, 0, 0, 1, -24))), logo)
        salvar(plano, f"codeos-logo-{nome}.jpg")
        # 3D
        cor_sombra = (10, 20, 50) if nome == "light" else (0, 0, 0)
        tres = compor_3d(base, W / 2, H * 0.46, H * 0.40, cor_sombra=cor_sombra)
        salvar(tres, f"codeos-logo-{nome}-3d.jpg")
        print("ok:", nome)


if __name__ == "__main__":
    main()
