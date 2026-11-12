# CodeOS

**A Linux desktop for developers that feels familiar to Windows users.** Based on Ubuntu 24.04 LTS
(Xubuntu), with an Xfce desktop styled like Windows and developer tools ready out of the box.

*Uma distro Linux para desenvolvedores, com cara de Windows. Baseada no Ubuntu 24.04 LTS (Xubuntu).*

## Features

- **Windows-style desktop:** taskbar at the bottom, Start menu, pinned apps, window previews, Windows
  shortcuts (Super+E, Super+L, Super+Shift+S screenshot to clipboard, Super+V clipboard history),
  Fluent theme and Selawik font, 12 landscape wallpapers plus 10 with the CodeOS logo (flat and 3D).
- **Developer tools:** git, gh, ripgrep, fzf, bat, btop, mise (Node, Python, Go, Rust, Java per
  project), Docker on demand, Podman and Distrobox. The welcome screen sets up Git, SSH keys, GitHub,
  languages and editors.
- **Everyday apps:** Firefox, LibreOffice, VLC, archive manager, disks, printers and scanner;
  Windows programs (.exe/.msi) open with a double click through Wine.
- **Hardware:** NVIDIA driver from the welcome screen (Secure Boot ready), per-app GPU choice for
  laptops with Intel + NVIDIA, night light per monitor, two Bluetooth headphones playing together.
- **Updates:** system updates through apt, plus a signed CodeOS repository that brings new versions of
  the desktop configuration without overwriting your own changes.

## Install

1. Download the ISO from the [latest release](https://github.com/matheusantunes-dev/codeos-linux/releases/latest)
   and check it against the `SHA256SUMS` file published with it.
2. Write it to a USB drive (8 GB or more) with [Ventoy](https://www.ventoy.net), balenaEtcher or Rufus.
3. Boot from the USB drive. Try the live session, then click **Install CodeOS** on the desktop.

**Requirements:** 64-bit PC (UEFI with or without Secure Boot, or legacy BIOS), 2 GB of RAM (8 GB
recommended) and 20 GB of disk.

**Advanced:** on an existing Linux Mint 22 or Xubuntu 24.04 install, the `codeos` package applies the
CodeOS configuration without reinstalling ([packages/README.md](packages/README.md), in Portuguese).

## Status

CodeOS is a personal project in **beta**: it is used daily on two laptops (Intel, and Intel +
NVIDIA) and the ISO is tested in virtual machines. Bug reports and suggestions are welcome in
[Issues](https://github.com/matheusantunes-dev/codeos-linux/issues).

---

## Desenvolvimento

A mesma fonte (Ansible) configura as máquinas do autor e gera a ISO. O resto deste documento é para
quem desenvolve o CodeOS.

### Estrutura

| Pasta | Conteúdo |
|---|---|
| `audit/` | `audit.sh` — Módulo 0, auditoria somente leitura. Relatórios em `audit/reports/` (fora do git). |
| `backup/` | Módulo 0: `backup.sh` (restic do `/home`) e `timeshift-dest.sh` (Timeshift no HDD). Sem dependência do Ansible. |
| `ansible/` | Playbook local, um role por módulo (`--tags` por módulo, sempre `--check --diff` antes). |
| `packages/` | Pacote `codeos` e repositório APT assinado: as atualizações chegam a quem já instalou ([packages/README.md](packages/README.md)). |
| `assets/` | Logo, ícones e papéis de parede (`wallpapers/codeos`: com o logo; `wallpapers/landscapes`: fotos). |
| `iso/` | `construir.sh`: monta a ISO a partir da do Xubuntu 24.04 (instalador Calamares). |
| `docs/` | Decisões de arquitetura. |

### Auditoria

Rode de um terminal da sua sessão gráfica, sem sudo:

```bash
./audit/audit.sh
```

`--root-extras` acrescenta SMART, lista de snapshots do Timeshift e LVM (pede sudo só para isso).

### Backup (Módulo 0)

Pré-requisito de todos os outros módulos. Com o HDD externo conectado, uma vez:

```bash
./backup/backup.sh init
./backup/backup.sh run
./backup/backup.sh verify
./backup/timeshift-dest.sh
./backup/backup.sh doctor
```

Depois, antes de cada módulo: `run` + `verify`. Como restaurar: [docs/restauracao.md](docs/restauracao.md).

### Módulos (Ansible)

Uma vez: `sudo apt install ansible-core`. Todo módulo exige backup verificado nas últimas 24 h e cria
um snapshot do Timeshift antes de mudar qualquer coisa (o HDD externo precisa estar conectado).
O `apply.sh` pede a senha de administrador uma vez, confere no sudo e só então roda o playbook.

```bash
./ansible/apply.sh site.yml --tags desktop,system --check --diff
```

```bash
./ansible/apply.sh site.yml --tags desktop,system,dev,maquina
```

| Tag | Módulo | O que faz |
|---|---|---|
| `desktop` | 1 | Xfce estilo Windows numa sessão "CodeOS", a única da tela de login (o Cinnamon e a sessão Xfce simples saem): barra embaixo, menu iniciar com o logo, tema Fluent, fonte Selawik, ícones CodeOS, atalhos do Windows, programas fixados na barra de tarefas (botão direito → Pin to taskbar), prévia das janelas ao passar o mouse e marcação dos programas abertos, histórico da área de transferência (Super+V), seletor de cor (Super+Shift+C), copiar texto da tela (Super+Shift+T), janela sempre por cima (Ctrl+Super+T), terminal que desce do topo (Super+`), recorte de tela direto para o Ctrl+V (Super+Shift+S), tela de boas-vindas com extras opcionais, programas do Windows (.exe/.msi) com dois cliques pelo Wine, .rar e .7z no botão direito, fontes com as medidas das do Office, efeitos suaves (picom) e 22 papéis de parede: 12 paisagens com luz quente e 10 com o logo do CodeOS (plano e 3D) |
| `system` | 2 | Boot centralizado nas duas telas desde o primeiro quadro (driver de vídeo no initramfs), USB sem economia de energia nos hubs, vigia que reconecta o adaptador Bluetooth quando ele trava, dois fones Bluetooth tocando juntos e reconectados sem sobrecarregar o rádio, Wake-on-LAN na placa certa, zram e limites de arquivos para IDEs; firewall ligado, SSH fechado e atualizações de segurança automáticas |
| `dev` | 6 | Ferramentas de desenvolvimento para todo usuário: git, gh, jq, fd, fzf, bat, ripgrep, cmake, sqlite3, meld, pipx, btop; mise (versões de Node, Python, Go, Rust e Java por projeto); Docker ligado só no primeiro uso, Podman e Distrobox (outras distros integradas, como o WSL); earlyoom. Na tela de boas-vindas, a página "Developer" configura Git, chave SSH, GitHub, linguagens e editores |
| `maquina` | — | Ajustes só de uma máquina, em `ansible/maquinas/<nome do computador>.yml` (este notebook: tela interna desligada, regras de dispositivos, ventoinha, AnyDesk). Em outra máquina e na ISO, nada dele vale |

Para montar o sistema da ISO (num chroot, sem sessão e sem conta de pessoa): `ansible-playbook site.yml -e codeos_imagem=true --tags desktop,system,dev`.

Para ver a sessão CodeOS sem sair da sua (por exemplo, pelo AnyDesk): `./ansible/testar-sessao.sh`.

### Identidade visual

```bash
python3 assets/icons/build.py
python3 assets/boot/build_boot.py
python3 assets/logo/build_greeter_logo.py
```

O primeiro gera o tema de ícones, a prévia e o logo em SVG/PNG (`assets/logo/`). O segundo gera a prévia
da animação de boot (`assets/boot/build/boot-preview.gif`) e o tema Plymouth a partir das mesmas camadas.
O terceiro gera a marca horizontal da tela de login (`assets/logo/codeos-greeter-logo.png`).
Para usar o tema no boot (pede sudo; `uninstall` volta ao tema do Mint):

```bash
./assets/boot/install.sh install
./assets/boot/install.sh test
```

## Licença

O CodeOS é software livre sob a [GNU GPL 3.0 ou posterior](LICENSE): pode usar, estudar, modificar e
redistribuir, desde que as versões redistribuídas sigam a mesma licença e tragam o código-fonte.

Obras de terceiros mantêm as próprias licenças:

- Papéis de parede: as fotos são do Wikimedia Commons sob CC0, CC BY ou CC BY-SA, com autor e licença de cada uma em [assets/wallpapers/landscapes/CREDITS.md](assets/wallpapers/landscapes/CREDITS.md); os com o logo do CodeOS são do próprio projeto (GPL-3.0).
- Ícones: o tema herda o Papirus (GPL-3.0); os ícones de lixeira e discos são do mint-l-icons (CC BY-SA 4.0), recoloridos ([assets/icons/CREDITS.md](assets/icons/CREDITS.md)).
- Tema Fluent (GPL-3.0) e fonte Selawik (OFL 1.1) são baixados das fontes oficiais durante a instalação, em versões fixadas e conferidas por checksum.
