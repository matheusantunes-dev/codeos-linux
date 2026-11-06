# Guia de estilo dos ícones do CodeOS

Ícones planos, geométricos e com poucos detalhes, para ficarem legíveis em 16 px.
O tema herda do Papirus (`Inherits=Papirus,hicolor`): só desenhamos o que é identidade do CodeOS.

## Grade

| Tipo | viewBox | Área útil | Formato-base |
|---|---|---|---|
| App e lugares (colorido) | `0 0 48 48` | 4–44 (margem de 4) | quadrado 36×36 em (6,6) com `rx=7` e fundo `primary`, hexágono `r=19` (logo) ou pasta 40×30 |
| Bandeja e símbolos (`-symbolic`) | `0 0 16 16` | 1–15 | contorno de 1,5 px, uma cor |

- Coordenadas em números inteiros ou em .5, para os traços caírem no pixel em 24 e 48 px.
- Traço: 3 px em 48 px (1,5 px em 16 px), sempre com `stroke-linecap="round"` e `stroke-linejoin="round"`.
- Cantos: `rx=2` em retângulos internos e `rx=7` no quadrado de fundo dos apps.
- Sem degradê, sombra ou texto. A profundidade vem de 2 tons da mesma cor (frente mais clara, fundo mais escuro).
- Exceção: a lixeira (`places/user-trash*`) e os discos (`devices/drive-*`) não são desenhados aqui. São os do Mint-L
  recoloridos (`recolor_icons.py`), em PNG por tamanho: lixeira no azul do logo, discos em metal escovado aço-ciano,
  tons diferentes para não confundir.
- Só as cores do logo: azul (`primary` e variações), ciano (`accent`, `accent-light`) e branco (`paper`).

## Paleta

Cores amostradas do logo oficial (`assets/logo/source/codeos-logo-source.png`): azul `#1E54BC`, ciano `#05C0DF`, branco.

As fontes usam *tokens* (`{{primary}}`, …) que o `build.py` substitui pelos valores de `manifest.toml`.
Trocar a cor da marca = mudar uma linha e rodar o build.

| Token | Cor | Uso |
|---|---|---|
| `primary` | `#1E54BC` | marca, fundo de apps |
| `primary-dark` | `#17439A` | fundo da pasta, 2º tom |
| `primary-light` | `#3A6FD2` | frente da pasta |
| `glyph` | `#0E2A66` | glifo das pastas |
| `accent` | `#05C0DF` | destaques (arestas do logo, cursor) |
| `accent-light` | `#5FD8EC` | traços e 2º elemento sobre fundo azul |
| `paper` | `#FFFFFF` | branco da marca, folha da pasta |
| `symbolic` | `#2E3436` | ícones `-symbolic` (o GTK recolore conforme o tema) |

## Pastas

Um modelo (`src/folders/_template.svg`) e um glifo por pasta (`src/folders/glyphs/*.svg`).
O glifo é desenhado numa caixa de 12×12 e centralizado na frente da pasta pelo build.
Glifo: só traço de 2 px, cor `glyph` (o modelo já aplica traço, pontas e cor; o glifo traz só a geometria).

## Nomes

Seguir a *Icon Naming Specification* do freedesktop sempre que existir um nome padrão
(`folder`, `utilities-terminal`, `folder-download`…); ferramentas próprias usam o prefixo `codeos-`.
Nomes alternativos viram links simbólicos (`aliases` no `manifest.toml`).
