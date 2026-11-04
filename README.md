# CodeOS

Distro para desenvolvedores construída por cima do Linux Mint: Xfce no estilo Windows, áudio Bluetooth duplo,
luz noturna por monitor, USB estável e storage inteligente. A mesma fonte gera a configuração do notebook e a ISO.

## Estrutura

| Pasta | Conteúdo |
|---|---|
| `audit/` | `audit.sh` — Módulo 0, auditoria somente leitura. Relatórios em `audit/reports/` (fora do git). |
| `backup/` | Módulo 0: `backup.sh` (restic do `/home`) e `timeshift-dest.sh` (Timeshift no HDD). Sem dependência do Ansible. |
| `ansible/` | Playbook local, um role por módulo (`--tags` por módulo, sempre `--check --diff` antes). |
| `packages/` | Fontes dos `.deb` `codeos-*` (configuração em nível de sistema: `/etc/xdg`, `/etc/skel`, `/usr/share`). |
| `assets/` | Logo, ícones e wallpapers em SVG. |
| `iso/` | Receita do Cubic e testes em QEMU. |
| `docs/` | Decisões de arquitetura. |

## Auditoria

Rode de um terminal da sua sessão gráfica, sem sudo:

```bash
./audit/audit.sh
```

`--root-extras` acrescenta SMART, lista de snapshots do Timeshift e LVM (pede sudo só para isso).

## Backup (Módulo 0)

Pré-requisito de todos os outros módulos. Com o HDD externo conectado, uma vez:

```bash
./backup/backup.sh init
./backup/backup.sh run
./backup/backup.sh verify
./backup/timeshift-dest.sh
./backup/backup.sh doctor
```

Depois, antes de cada módulo: `run` + `verify`. Como restaurar: [docs/restauracao.md](docs/restauracao.md).

## Identidade visual

```bash
python3 assets/icons/build.py
python3 assets/boot/build_boot.py
```

O primeiro gera o tema de ícones, a prévia e o logo em SVG/PNG (`assets/logo/`). O segundo gera a prévia
da animação de boot (`assets/boot/build/boot-preview.gif`) e o tema Plymouth a partir das mesmas camadas.
Para usar o tema no boot (pede sudo; `uninstall` volta ao tema do Mint):

```bash
./assets/boot/install.sh install
./assets/boot/install.sh test
```
