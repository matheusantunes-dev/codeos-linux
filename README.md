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

## Módulos (Ansible)

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
| `desktop` | 1 | Xfce estilo Windows numa sessão "CodeOS", a única da tela de login (o Cinnamon e a sessão Xfce simples saem): barra embaixo, menu iniciar com o logo, tema Fluent, fonte Selawik, ícones CodeOS, atalhos do Windows, programas fixados na barra de tarefas (botão direito → Pin to taskbar), prévia das janelas ao passar o mouse e marcação dos programas abertos, histórico da área de transferência (Super+V), seletor de cor (Super+Shift+C), copiar texto da tela (Super+Shift+T), janela sempre por cima (Ctrl+Super+T), terminal que desce do topo (Super+`), recorte de tela direto para o Ctrl+V (Super+Shift+S), tela de boas-vindas com extras opcionais, programas do Windows (.exe/.msi) com dois cliques pelo Wine, .rar e .7z no botão direito, fontes com as medidas das do Office, efeitos suaves (picom) e 12 papéis de parede de paisagens com luz quente |
| `system` | 2 | Boot centralizado nas duas telas desde o primeiro quadro (driver de vídeo no initramfs), USB sem economia de energia nos hubs, vigia que reconecta o adaptador Bluetooth quando ele trava, dois fones Bluetooth tocando juntos e reconectados sem sobrecarregar o rádio, Wake-on-LAN na placa certa, zram e limites de arquivos para IDEs; firewall ligado, SSH fechado e atualizações de segurança automáticas |
| `dev` | 6 | Ferramentas de desenvolvimento para todo usuário: git, gh, jq, fd, fzf, bat, ripgrep, cmake, sqlite3, meld, pipx, btop; mise (versões de Node, Python, Go, Rust e Java por projeto); Docker ligado só no primeiro uso, Podman e Distrobox (outras distros integradas, como o WSL); earlyoom. Na tela de boas-vindas, a página "Developer" configura Git, chave SSH, GitHub, linguagens e editores |
| `maquina` | — | Ajustes só de uma máquina, em `ansible/maquinas/<nome do computador>.yml` (este notebook: tela interna desligada, regras de dispositivos, ventoinha, AnyDesk). Em outra máquina e na ISO, nada dele vale |

Para montar o sistema da ISO (num chroot, sem sessão e sem conta de pessoa): `ansible-playbook site.yml -e codeos_imagem=true --tags desktop,system,dev`.

Para ver a sessão CodeOS sem sair da sua (por exemplo, pelo AnyDesk): `./ansible/testar-sessao.sh`.

## Identidade visual

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
