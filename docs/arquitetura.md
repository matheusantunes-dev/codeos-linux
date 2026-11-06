# Decisões de arquitetura

Registro curto das decisões e do porquê. A primeira auditoria (2026-11-03) ajustou várias delas ao hardware real.

## Máquina de referência (auditoria 2026-11-03)

- ASUS K45A, i5-3210M (Ivy Bridge), 16 GB RAM, Intel HD 4000 (i915), UEFI, Secure Boot desligado.
- Linux Mint 22.3 (base Ubuntu 24.04 noble), kernel 7.0, Cinnamon em X11, LightDM.
- Tela do notebook desligada no boot (`video=LVDS-1:d`); monitores externos em HDMI-1 e VGA-1.
- 1 SSD interno (Kingston A400 480 GB, ext4) + HDD WD 320 GB em gaveta USB (`/media/matheusdev/sec`).
- PipeWire 1.0.5, WirePlumber 0.4.17, BlueZ 5.72, adaptador TP-Link UB500 (único).

## Decisões

| # | Decisão | Motivo |
|---|---|---|
| D1 | Toda personalização vira `.deb` com config de sistema; o `$HOME` só recebe `~/.config/codeos/` | O mesmo artefato serve ao notebook e à ISO; remoção limpa com `apt remove` |
| D2 | Xfce 4.18 em X11; o Cinnamon, o Muffin e o Nemo saem depois da validação (`tasks/cinnamon.yml`). Também saem os temas, ícones, sons e papéis de parede do Mint. Ficam `mintsystem` e `mint-info-cinnamon`, de que o Firefox do Mint depende, até a reinstalação pela ISO | Rollback = backup (restic) e Timeshift; a sessão Xfce simples saiu da tela de login (D2h) |
| D2b | Sessão própria `codeos` (`/usr/share/xsessions/codeos.desktop`); os padrões do Xfce ficam em `/etc/xdg/xdg-codeos`, que o Xsession do Ubuntu põe na frente do `XDG_CONFIG_DIRS` só nessa sessão | Não sobrescreve arquivo de pacote nem toca no Cinnamon; xsettings e atalhos partem dos arquivos exatos dos pacotes 4.18 |
| D2c | Tema Fluent (GPL-3, versão fixada por sha256) compilado como usuário em `~/.cache/codeos` e só o resultado copiado para `/usr/share/themes`; fonte Selawik (OFL) | Script de terceiros nunca roda como root |
| D2d | Compositor **picom** (sombras, cantos de 8 px, fade) no lugar do compositor do xfwm4; Super+V abre o `xfce4-clipman-history`. Ambos iniciam por `/etc/xdg/xdg-codeos/autostart` | O xfwm4 não tem fade nem cantos arredondados; tudo continua editável (Sessão e inicialização, `~/.config/picom/picom.conf`) |
| D2e | Papéis de parede: fotos "blue hour" do Wikimedia Commons só com CC0/CC BY/CC BY-SA, redimensionadas para 2560 px, créditos em `assets/wallpapers/CREDITS.md` | Licenças que permitem redistribuir na ISO; Unsplash/Pexels proíbem montar coleções |
| D2g | Uma barra por monitor (`output-name` = `Primary` e a saída secundária do host), cada uma com as janelas do próprio monitor; layout minimalista (sem ícone de bateria) | Sem `output-name` a barra ficava na primeira saída do xrandr, não na principal |
| D2i | Padrões novos chegam à conta por **mesclagem** (`codeos-xfconf-merge`): só volta ao padrão o que ainda está no padrão anterior do CodeOS; o que o usuário mudou e o que só existe na conta ficam. Atalhos têm tratamento próprio (o xfsettingsd copia tudo para `/<provedor>/custom`) | A versão anterior (`codeos-layout`) trocava canais inteiros e apagou a Pasta pessoal que o usuário tinha ligado na área de trabalho |
| D2j | Super sozinha abre o menu pelo `xcape` (toque = Ctrl+Esc), não por um atalho `Super_L`; no xfwm4 uma tecla por ação | O atalho `Super_L` prendia a tecla no xfsettingsd e quebrava Super+←/→/D do xfwm4; ações com duas teclas tinham uma descartada (Super+D e Super+→ não funcionavam) |
| D2h | Bloqueio pelo `light-locker` (a própria tela de login do CodeOS) | Mesmo visual em bloquear, trocar de usuário e voltar da suspensão; boot e desligar usam a mesma animação |
| D3 | Ansible local, um role por módulo, `--check --diff` + snapshot antes de cada um | Idempotência e reversibilidade |
| D4 | Regras do WirePlumber em **Lua** (0.4.17) | Versão instalada; migrar para SPA-JSON só se o WirePlumber for para 0.5 |
| D5 | Sink duplo declarativo (`module-combine-stream` em `pipewire.conf.d`) no lugar do combine criado em runtime | Sobrevive a reinícios e fica versionado; o existente (`fones_juntos_agora`) é a referência |
| D5b | O áudio duplo é uma função do **Blueman** (2.4.4), não um app: plugin de manager (item "Adicionar ao áudio duplo" no menu do dispositivo, grupo `ACTIONS`) + plugin de applet (liga/desliga no menu da bandeja, ícone `codeos-dual-audio-symbolic`) | Fica onde o usuário já gerencia os fones; os plugins só chamam o `codeos-audio dual on/off` do Módulo 3 |
| D6 | Sem compensação de latência nativa (PipeWire 1.0.5); ajuste manual de atraso por fone, se necessário | Evita PPA de terceiros no PipeWire; reavaliar se houver eco perceptível |
| D7 | Luz noturna: daemon próprio com gamma por CRTC (XRandR), perfil por hash do EDID, brilho por DDC/CI | Hoje o `csd-color` aplica o mesmo gamma (0.44:1.0:2.0) nas duas saídas |
| D8b | Driver `i915` no initramfs (KMS cedo) e tema Plymouth que refaz escala e centro quando a resolução muda | Sem isso o Plymouth começava no `simpledrm` do firmware (uma resolução para as duas telas) e o i915 só carregava aos 7,3 s, descentralizando o logo |
| D8 | USB: autosuspend desligado para hubs/áudio/BT, quirks por VID:PID e watchdog de reset | Erros `-71` e resets repetidos no log do kernel |
| D9 | Storage: nenhum cenário automático hoje (1 SSD interno); o Cenário 2 vale se o HDD for para a baia do DVD | O HDD está em gaveta USB, conta como externo |
| D10 | Backup fora do SSD: restic no HDD externo + Timeshift com destino que não seja o SSD do sistema | Snapshots do Timeshift estão no próprio SSD do sistema |
| D11 | ISO **sobre Ubuntu 24.04 LTS** (não sobre o Mint) + repositório APT `codeos`, identidade própria (`os-release`, logo, instalador) | Distribuível sem a marca Linux Mint e sem pacotes `+mint`; mesmas versões já testadas no notebook (Xfce 4.18, PipeWire 1.0.5), suporte até 2029. Reprodutível e sem dados pessoais |
| D11b | O notebook deixa de ser Mint **reinstalando a partir da ISO do CodeOS no SSD interno inteiro** (o Mint é apagado; o HDD externo, com os backups, fica intacto), não convertendo o Mint no lugar; antes, inventário de apps/repositórios e backup restic verificado do `/home` | Converter Mint → Ubuntu no lugar deixa pacotes, repositórios e ferramentas do Mint; a reinstalação é o único jeito de não sobrar rastro sem perder dados |
| D2f | Sessão padrão = CodeOS (`/etc/lightdm/lightdm.conf.d/90-codeos.conf`, depois do `70-linuxmint.conf`, + última sessão da conta no AccountsService); tela de login com papel de parede, logo e tema do CodeOS | Ao reiniciar, o login já abre no CodeOS; o seletor mostra só o CodeOS |
| D2h | Só a sessão CodeOS na tela de login: `/usr/share/xsessions/xfce.desktop` desviado com dpkg-divert | A sessão "Xfce" simples usa as mesmas configurações da conta sem os padrões do CodeOS e gravou por cima deles a barra e o tema das janelas do Xfce puro (2026-11-05). Emergência: terminal (Ctrl+Alt+F3) ou modo de recuperação |
| D12 | Logo oficial = `assets/logo/source/codeos-logo-source.png`, vetorizado em `assets/icons/src/apps/codeos.svg` (erro médio 1/255 contra o original); só as cores dele (azul `#1E54BC`, ciano `#05C0DF`, branco) em todos os ícones; `build.py` exporta SVG + PNG | Uma paleta só, trocável no `manifest.toml`; o PNG `codeos-logo-original.png` é o original sem fundo |
| D13 | Boot: tema Plymouth *script* com 2 camadas (logo + brilho neon no próprio contorno, sem linha em volta), surgindo do preto e depois esmaecendo e brilhando em ciclos suaves de 3,6 s, sem piscar; a prévia (`assets/boot/build_boot.py`) usa as mesmas camadas e a mesma curva de brilho | O que foi aprovado na prévia é o que aparece no boot; instalar o tema só depois da aprovação |
| D14 | Consumo de RAM: os plugins da barra (volume, notificações, genmon) rodam dentro do processo dela (descrições desviadas com dpkg-divert, `X-XFCE-Internal=true`); a bandeja continua fora, porque dentro da barra ela não recebe os ícones XEmbed, e o menu iniciar também, porque guarda a configuração numa variável única e os dois menus (um por tela) se sobrescreviam. Docker ligado pelo `docker.socket` no primeiro uso; sem ibus (português e inglês funcionam pelo GTK e pelo X) | Barra de 7 processos e ~256 MB para 3 e ~87 MB; −120 MB do Docker parado; −60 MB do ibus. Como no Windows (barra num processo só) e no Docker Desktop (sob demanda) |
| D15 | Ferramentas de dev no role `30_dev` (tag `dev`), do Ubuntu e de repositórios oficiais (GitHub CLI, mise, VS Code); o que é pessoal (Git, SSH, linguagens) é feito por cada usuário na página "Developer" da tela de boas-vindas | Mesma divisão do macOS (Command Line Tools no sistema) e do Dev Home do Windows (configuração da conta) |
| D16 | `/usr/local/bin/xfdesktop` espera a barra reservar o espaço dela (`_NET_WORKAREA` menor que a tela, até 5 s) antes de abrir a área de trabalho | O xfdesktop guarda a posição dos ícones por tamanho da área livre; abrindo junto com a barra, às vezes media antes do espaço dela e os ícones caíam noutra grade, embaralhados (2026-11-05). Como no Windows, onde a barra e os ícones são o mesmo programa |
| D17 | fluidsynth (sintetizador MIDI) fora da sessão: `systemctl --global disable` (20_system/tasks/audio.yml) | Subia em toda sessão com um banco de sons (~160 MB parado); como no Windows, MIDI só quando um programa usa (`systemctl --user start fluidsynth`) |
| D18 | Segurança de sistema de mesa (20_system/tasks/security.yml): ufw ligado (entrada bloqueada; da rede local só wsdd e KDE Connect), servidor SSH desligado (`system_ssh_server`), `unattended-upgrades` diário, regras de sudo inseguras tiradas por host (`system_sudoers_remove`); Iriun Webcam com `nofail` no PipeWire | Auditoria de 2026-11-05: firewall desligado, SSH na porta 22 de todas as redes, sem atualizações automáticas, `tee` sem senha que aceitava qualquer caminho, PipeWire caindo 5 vezes no boot |
| D19 | Ajustes de uma máquina em `ansible/maquinas/<hostname>.yml` + pasta com os arquivos, aplicados pelo papel `90_maquina` (tag `maquina`) | A reinstalação não perde o que foi feito à mão (tela interna, udev, ventoinha NBFC compilada da versão fixada, sudo do AnyDesk), e nada disso vai para a ISO ou para outra máquina |
| D20 | Modo imagem (`codeos_imagem=true`): sem trava de backup, sem tarefas da conta e da sessão, serviços só habilitados, firewall ligado pelo arquivo, ajustes de máquina fora | Os mesmos papéis montam o sistema da ISO num chroot |
| D21 | Sessão não é salva ao sair e o Thunar não sobe no login (padrão do sistema; a escolha da conta continua valendo) | Como no Windows: cada login começa limpo; o Thunar abre sob demanda |
| D22 | Na ISO, Firefox do repositório apt da Mozilla com prioridade 1000 | O `firefox` do Ubuntu é transição para o snap; o do Mint fica só nesta máquina até a reinstalação |

## Limites físicos encontrados (não resolvíveis por software)

- Cadeia USB: hub USB 1.1 (`058f:9254`, 12 Mbps) → hubs USB 2.0 rodando a 12 Mbps → adaptador Bluetooth.
  Teclado, mouse, placa de som USB e o UB500 dividem 12 Mbps e passam por 3 níveis de hub.
- O UB500 resetou 5 vezes no boot auditado. Ele fica num gabinete, colado nos hubs, e as duas portas do notebook
  têm hubs; por isso o sistema tem que conviver com a cadeia. As quedas da porta ("disabled by hub (EMI?)") e as
  falhas de firmware dispararam em 2026-11-03, quando um script provisório passou a chamar os fones desligados a
  cada 5 s (rádio transmitindo quase sem parar). O `codeos-bt-audio` só chama quem caiu, com intervalo crescente
  até 5 min, e o `codeos-bt-watchdog` reconecta o adaptador com intervalo de 1 a 5 min.
- Porta xHCI SuperSpeed (bus 3, 5000 Mbps) está vazia: nada usa USB 3 hoje.
