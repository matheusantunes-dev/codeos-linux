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
| D1 | Toda personalização vira `.deb` com config de sistema; o `$HOME` só recebe `~/.config/nexodev/` | O mesmo artefato serve ao notebook e à ISO; remoção limpa com `apt remove` |
| D2 | Xfce 4.18 em X11, Cinnamon mantido até a validação final | Rollback = trocar de sessão no LightDM |
| D3 | Ansible local, um role por módulo, `--check --diff` + snapshot antes de cada um | Idempotência e reversibilidade |
| D4 | Regras do WirePlumber em **Lua** (0.4.17) | Versão instalada; migrar para SPA-JSON só se o WirePlumber for para 0.5 |
| D5 | Sink duplo declarativo (`module-combine-stream` em `pipewire.conf.d`) no lugar do combine criado em runtime | Sobrevive a reinícios e fica versionado; o existente (`fones_juntos_agora`) é a referência |
| D6 | Sem compensação de latência nativa (PipeWire 1.0.5); ajuste manual de atraso por fone, se necessário | Evita PPA de terceiros no PipeWire; reavaliar se houver eco perceptível |
| D7 | Luz noturna: daemon próprio com gamma por CRTC (XRandR), perfil por hash do EDID, brilho por DDC/CI | Hoje o `csd-color` aplica o mesmo gamma (0.44:1.0:2.0) nas duas saídas |
| D8 | USB: autosuspend desligado para hubs/áudio/BT, quirks por VID:PID e watchdog de reset | Erros `-71` e resets repetidos no log do kernel |
| D9 | Storage: nenhum cenário automático hoje (1 SSD interno); o Cenário 2 vale se o HDD for para a baia do DVD | O HDD está em gaveta USB, conta como externo |
| D10 | Backup fora do SSD: restic no HDD externo + Timeshift com destino que não seja o SSD do sistema | Snapshots do Timeshift estão no próprio SSD do sistema |
| D11 | ISO via Cubic sobre a ISO oficial Mint Xfce + repositório APT `nexodev` | Reproduzível e sem dados pessoais (nunca respin do notebook) |

## Limites físicos encontrados (não resolvíveis por software)

- Cadeia USB: hub USB 1.1 (`058f:9254`, 12 Mbps) → hubs USB 2.0 rodando a 12 Mbps → adaptador Bluetooth.
  Teclado, mouse, placa de som USB e o UB500 dividem 12 Mbps e passam por 3 níveis de hub.
- O UB500 resetou 5 vezes no boot auditado. Ligá-lo direto numa porta do notebook vem antes de qualquer ajuste de software.
- Porta xHCI SuperSpeed (bus 3, 5000 Mbps) está vazia: nada usa USB 3 hoje.
