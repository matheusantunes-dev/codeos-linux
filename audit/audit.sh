#!/usr/bin/env bash
# CodeOS — Módulo 0: auditoria do sistema.
# Somente leitura: não instala, não altera e não grava nada fora do diretório de relatórios.
#
# Uso:
#   ./audit/audit.sh                 auditoria como usuário normal (recomendado)
#   ./audit/audit.sh --root-extras   + SMART, snapshots do Timeshift e LVM (pede sudo)
#   ./audit/audit.sh --out DIR       grava o relatório em DIR (padrão: audit/reports/)

set -uo pipefail
# Saída de comandos em inglês/C: deixa o parsing independente do idioma do sistema.
export LC_ALL=C.UTF-8

readonly AUDIT_VERSION="0.2.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/reports"
ROOT_EXTRAS=0
SESSION_TYPE=""
SESSION_DESKTOP=""
HOME_KB=0
BODY=""
declare -a FINDINGS=()
declare -a DISKS=()
declare -A DECISION=()

# ───────────────────────────── utilitários ─────────────────────────────

usage() { sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
has()   { command -v "$1" >/dev/null 2>&1; }
step()  { printf '  → %s\n' "$*" >&2; }
readf() { cat -- "$1" 2>/dev/null || true; }
# Oculta endereços MAC (Bluetooth/rede) em qualquer saída do relatório.
mask()  { sed -E 's/([0-9A-Fa-f]{2}[:_]){5}[0-9A-Fa-f]{2}/XX:XX:XX:XX:XX:XX/g'; }
# ver_ge A B → verdadeiro se a versão A >= B.
ver_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }
# pval CHAVE "linha do lsblk -P" → valor da chave.
pval()  { [[ $2 =~ (^|[[:space:]])$1=\"([^\"]*)\" ]] && printf '%s' "${BASH_REMATCH[2]}"; }

h2() { printf '\n## %s\n\n' "$1"; }
kv() { printf -- '- **%s:** %s\n' "$1" "${2:-—}"; }

# block "Título" função-ou-comando [args...] → bloco de código no relatório.
block() {
  local title=$1 out; shift
  printf '**%s**\n\n```\n' "$title"
  if ! declare -F "$1" >/dev/null && ! has "$1"; then
    out="($1 não instalado)"
  else
    out=$("$@" 2>&1 | mask | head -n 150)
  fi
  printf '%s\n```\n\n' "${out:-(sem saída)}"
}

# finding NÍVEL "texto" — NÍVEL: bloqueio | atencao | info | ok
finding() { FINDINGS+=("$1|$2"); }

# Emite "nome tipo" por disco: ssd | hdd (internos) ou externo (USB/removível).
list_disks() {
  local line name type tran rota rm
  while IFS= read -r line; do
    name=$(pval NAME "$line"); type=$(pval TYPE "$line"); tran=$(pval TRAN "$line")
    rota=$(pval ROTA "$line"); rm=$(pval RM "$line")
    [[ $type == disk && $name != zram* ]] || continue
    if [[ $tran == usb || $rm == 1 ]]; then echo "$name externo"
    elif [[ $rota == 1 ]]; then echo "$name hdd"
    else echo "$name ssd"; fi
  done < <(lsblk -dnP -e7 -o NAME,TYPE,TRAN,ROTA,RM)
}

# Quando rodado fora do terminal da sessão gráfica, recupera as variáveis da sessão.
setup_session_env() {
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$UID}"
  if [[ -z ${DBUS_SESSION_BUS_ADDRESS:-} && -S $XDG_RUNTIME_DIR/bus ]]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
  fi
  if [[ -z ${DISPLAY:-} && -S /tmp/.X11-unix/X0 ]]; then export DISPLAY=:0; fi
  SESSION_TYPE=${XDG_SESSION_TYPE:-}
  SESSION_DESKTOP=${XDG_CURRENT_DESKTOP:-}
  if [[ -z $SESSION_TYPE || $SESSION_TYPE == tty ]] && has loginctl; then
    local id t
    while read -r id _; do
      t=$(loginctl show-session "$id" -p Type --value 2>/dev/null)
      if [[ $t == x11 || $t == wayland ]]; then
        SESSION_TYPE=$t
        [[ -n $SESSION_DESKTOP ]] || SESSION_DESKTOP=$(loginctl show-session "$id" -p Desktop --value 2>/dev/null)
        break
      fi
    done < <(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$USER" '$3 == u')
  fi
}

# ───────────────────────────── 1. sistema ─────────────────────────────

sec_system() {
  step "Sistema"
  h2 "1. Sistema"
  local pretty base fw sb dm
  pretty=$(. /etc/os-release && echo "$PRETTY_NAME")
  if [[ -r /etc/upstream-release/lsb-release ]]; then
    base=$(. /etc/upstream-release/lsb-release && echo "$DISTRIB_DESCRIPTION ($DISTRIB_CODENAME)")
  else
    base=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-desconhecida}")
  fi
  if [[ -d /sys/firmware/efi ]]; then fw=UEFI; else fw="BIOS/Legacy"; fi
  sb=$(has mokutil && mokutil --sb-state 2>/dev/null | head -n1)
  dm=$(basename "$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null)" .service)

  kv "Distribuição" "$pretty"
  kv "Base upstream" "$base"
  kv "Kernel" "$(uname -r) ($(uname -m))"
  kv "Firmware" "$fw"
  kv "Secure Boot" "${sb:-não verificado (mokutil ausente)}"
  kv "Máquina" "$(readf /sys/class/dmi/id/sys_vendor) $(readf /sys/class/dmi/id/product_name)"
  kv "Sessão gráfica" "${SESSION_TYPE:-desconhecida}"
  kv "Desktop atual" "${SESSION_DESKTOP:-desconhecido}"
  kv "Display manager" "$dm"
  kv "Uptime" "$(uptime -p)"

  DECISION[base]="$pretty — $base"
  DECISION[desktop]="${SESSION_DESKTOP:-?} em ${SESSION_TYPE:-?}"
  case $SESSION_TYPE in
    x11)     finding ok "Sessão X11: luz noturna por monitor via XRandR é viável." ;;
    wayland) finding atencao "Sessão Wayland: o Módulo 4 exige X11 (a sessão Xfce já roda em X11)." ;;
    *)       finding info "Tipo de sessão não detectado: rode o script de um terminal da sessão gráfica." ;;
  esac
  [[ $sb == *enabled* ]] && finding info "Secure Boot ativo: manter kernel/shim assinados; módulos DKMS exigirão MOK."
}

# ───────────────────────────── 2. CPU, memória, energia ─────────────────────────────

swap_info() { swapon --show; echo; ls -d /sys/block/zram* 2>/dev/null || echo "sem zram"; }

mem_top() {
  ps -eo rss=,comm= |
    awk '{a[$2] += $1} END {for (k in a) printf "%8.1f MB  %s\n", a[k] / 1024, k}' |
    sort -rn | head -n 20
}

boot_blame() { systemd-analyze blame --no-pager 2>/dev/null | head -n 10; }

power_services() {
  local s
  for s in tlp power-profiles-daemon auto-cpufreq thermald earlyoom systemd-oomd; do
    printf '%-24s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null)"
  done
}

sec_cpu_mem() {
  step "CPU, memória e energia"
  h2 "2. CPU, memória e energia (Módulo 2)"
  local total avail used s
  local -a active=()
  total=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
  avail=$(awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo)
  used=$((total - avail))

  kv "CPU" "$(lscpu 2>/dev/null | awk -F: '/Model name/ {gsub(/^ +/, "", $2); print $2; exit}') — $(nproc) threads"
  kv "RAM total" "${total} MB"
  kv "RAM em uso (MemTotal − MemAvailable)" "${used} MB"
  kv "Governor da CPU" "$(readf /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
  kv "Bateria" "$(compgen -G '/sys/class/power_supply/BAT*' >/dev/null && echo sim || echo não)"
  block "Swap e zram" swap_info
  block "Top 20 processos por memória (RSS somado por nome)" mem_top
  block "Tempo de boot" systemd-analyze
  block "10 unidades mais lentas no boot" boot_blame
  block "Serviços de energia e OOM" power_services

  DECISION[ram]="${used} MB em uso de ${total} MB (referência para comparar com o Xfce)"
  for s in tlp power-profiles-daemon auto-cpufreq; do
    systemctl is-active --quiet "$s" 2>/dev/null && active+=("$s")
  done
  if ((${#active[@]} > 1)); then
    finding atencao "Gerenciadores de energia concorrentes ativos: ${active[*]} — manter apenas um."
  else
    finding ok "Gerenciador de energia: ${active[*]:-nenhum ativo}."
  fi
  compgen -G '/sys/block/zram*' >/dev/null || finding info "Sem zram: será configurado no Módulo 2."
}

# ───────────────────────────── 3. GPU e monitores ─────────────────────────────

gpu_info() { lspci -nnk 2>/dev/null | grep -A3 -Ei 'vga|3d controller|display controller'; }

# Monitores conectados: nome lido do EDID e um hash curto (identificador do perfil no Módulo 4).
edid_info() {
  python3 -I - <<'PY'
import glob, hashlib, os
found = False
for d in sorted(glob.glob('/sys/class/drm/card*-*')):
    try:
        if open(d + '/status').read().strip() != 'connected':
            continue
        edid = open(d + '/edid', 'rb').read()
    except OSError:
        continue
    found = True
    name = '?'
    for off in (54, 72, 90, 108):
        b = edid[off:off + 18]
        if len(b) == 18 and b[:3] == b'\0\0\0' and b[3] == 0xFC:
            name = b[5:].split(b'\n')[0].decode('ascii', 'replace').strip()
    ident = hashlib.sha1(edid).hexdigest()[:12] if edid else 'sem EDID'
    print(f"{os.path.basename(d):26} {name:20} edid:{ident}")
if not found:
    print('nenhum monitor conectado encontrado em /sys/class/drm')
PY
}

xrandr_info() {
  [[ -n ${DISPLAY:-} ]] || { echo "sem DISPLAY: rode dentro da sessão gráfica"; return; }
  xrandr --verbose 2>&1 | awk '
    /^[^ \t].* (connected|disconnected)/ { show = ($2 == "connected"); if (show) print $1 }
    show && /^[ \t]+(CRTC|Gamma|Brightness):/ { sub(/^[ \t]+/, "   "); print }'
}

backlight_info() {
  local b found=0
  for b in /sys/class/backlight/*; do
    [[ -e $b ]] || continue
    found=1
    printf '%s  atual=%s  máx=%s\n' "$(basename "$b")" "$(readf "$b/brightness")" "$(readf "$b/max_brightness")"
  done
  ((found)) || echo "nenhum backlight controlável"
}

ddc_info() {
  local grp="não existe"
  if getent group i2c >/dev/null; then
    if id -nG | grep -qw i2c; then grp="existe, você é membro"; else grp="existe, você NÃO é membro"; fi
  fi
  printf 'i2c-dev disponível: %s\n' "$([[ -d /sys/class/i2c-dev ]] && echo sim || echo não)"
  printf 'grupo i2c: %s\n' "$grp"
  if has ddcutil; then timeout 40 ddcutil detect --brief 2>&1
  else echo "ddcutil não instalado (entra no Módulo 4)"; fi
}

gamma_procs() {
  pgrep -a -x 'redshift|redshift-gtk|gammastep|gammastep-indicator|xiccd|colord|csd-color' || echo "nenhum"
}

sec_display() {
  step "GPU e monitores"
  h2 "3. GPU e monitores (Módulo 4)"
  local n_mon procs
  block "GPU e driver" gpu_info
  block "Monitores conectados (EDID)" edid_info
  block "Saídas XRandR (CRTC, gamma, brilho)" xrandr_info
  block "Backlight interno" backlight_info
  block "DDC/CI (brilho real de monitores externos)" ddc_info
  block "Processos que alteram gamma/cor" gamma_procs

  n_mon=$(grep -lx connected /sys/class/drm/card*-*/status 2>/dev/null | wc -l)
  DECISION[monitores]="$n_mon conectado(s) agora"
  ((n_mon < 2)) && finding info "Só $n_mon monitor conectado: conecte os externos e rode de novo para mapear os perfis."
  lsmod | grep -q '^nvidia ' && finding info "Driver NVIDIA proprietário: validar gamma por CRTC no Módulo 4."
  procs=$(pgrep -x 'redshift|redshift-gtk|gammastep|xiccd|csd-color' | wc -l)
  ((procs > 0)) && finding info "Há serviços de cor/gamma ativos: serão desligados na sessão CodeOS."
}

# ───────────────────────────── 4. áudio e Bluetooth ─────────────────────────────

audio_services() {
  local s
  for s in pipewire pipewire-pulse wireplumber pulseaudio; do
    printf '%-16s %s\n' "$s" "$(systemctl --user is-active "$s" 2>/dev/null)"
  done
}

bt_adapters() {
  local h name dev usb found=0
  for h in /sys/class/bluetooth/hci*; do
    name=$(basename "$h")
    [[ $name =~ ^hci[0-9]+$ ]] || continue
    found=1
    dev=$(readlink -f "$h/device")
    usb=$(dirname "$dev")
    if [[ -r $usb/idVendor ]]; then
      printf '%s  USB %s:%s  %s %s  driver=%s  porta=%s @ %s Mbps\n' "$name" "$(readf "$usb/idVendor")" \
        "$(readf "$usb/idProduct")" "$(readf "$usb/manufacturer")" "$(readf "$usb/product")" \
        "$(basename "$(readlink -f "$dev/driver")")" "$(basename "$usb")" "$(readf "$usb/speed")"
    else
      printf '%s  (não USB) %s\n' "$name" "$dev"
    fi
  done
  ((found)) || echo "nenhum adaptador Bluetooth"
}

bt_paired() {
  has bluetoothctl || { echo "bluetoothctl não instalado"; return; }
  timeout 5 bluetoothctl devices Paired 2>/dev/null || timeout 5 bluetoothctl paired-devices 2>/dev/null
}

bt_codecs() {
  find /usr/lib -path '*spa-0.2/bluez5/libspa-codec-bluez5-*.so' -printf '%f\n' 2>/dev/null |
    sed -E 's/^libspa-codec-bluez5-(.*)\.so$/\1/' | sort | tr '\n' ' '
  echo
}

combine_modules() { pactl list short modules 2>/dev/null | grep -i combine || echo "nenhum"; }

# Profundidade de hubs entre o adaptador Bluetooth e a porta do notebook (0 = direto).
bt_hub_depth() {
  local h usb dots
  for h in /sys/class/bluetooth/hci*; do
    [[ $(basename "$h") =~ ^hci[0-9]+$ ]] || continue
    usb=$(basename "$(dirname "$(readlink -f "$h/device")")")
    [[ $usb =~ ^[0-9]+-[0-9.]+$ ]] || continue
    dots=${usb//[^.]/}
    echo "${#dots} $usb"
  done
}

wpctl_status() { timeout 5 wpctl status 2>&1 | head -n 80; }

audio_overrides() {
  local d
  for d in "$HOME/.config/pipewire" "$HOME/.config/wireplumber" /etc/pipewire /etc/wireplumber; do
    if [[ -d $d ]]; then echo "$d:"; find "$d" -type f | sed 's/^/   /'
    else echo "$d: (não existe)"; fi
  done
}

sec_audio() {
  step "Áudio e Bluetooth"
  h2 "4. Áudio e Bluetooth (Módulo 3)"
  local pw wp n_bt codecs
  pw=$(pipewire --version 2>/dev/null | grep -oP 'Linked with libpipewire \K[0-9.]+')
  wp=$(wireplumber --version 2>/dev/null | grep -oP 'Linked with libwireplumber \K[0-9.]+')
  codecs=$(bt_codecs)
  n_bt=$(find /sys/class/bluetooth -maxdepth 1 -regex '.*/hci[0-9]+' 2>/dev/null | wc -l)

  kv "PipeWire" "${pw:-não encontrado}"
  kv "WirePlumber" "${wp:-não encontrado}"
  kv "Servidor de som (pactl)" "$(pactl info 2>/dev/null | awk -F': ' '/Server Name/ {print $2}')"
  kv "BlueZ" "$(bluetoothctl --version 2>/dev/null)"
  block "Serviços de áudio do usuário" audio_services
  block "Adaptadores Bluetooth" bt_adapters
  block "Dispositivos Bluetooth pareados" bt_paired
  block "Codecs Bluetooth do PipeWire" bt_codecs
  block "Módulos combine carregados em runtime" combine_modules
  block "Grafo de áudio (wpctl status)" wpctl_status
  block "Configurações locais de PipeWire/WirePlumber" audio_overrides

  if [[ -z $wp ]]; then
    finding bloqueio "WirePlumber não encontrado: o Módulo 3 depende dele."
    DECISION[wireplumber]="ausente"
  elif ver_ge "$wp" 0.5; then
    DECISION[wireplumber]="$wp → regras em SPA-JSON (wireplumber.conf.d/)"
  else
    DECISION[wireplumber]="$wp → regras em Lua (bluetooth.lua.d/)"
  fi
  [[ -n $pw ]] && ! ver_ge "$pw" 1.2 &&
    finding info "PipeWire $pw: sem compensação de latência no combine-stream; avaliar PPA/backport no Módulo 3."
  pgrep -x pulseaudio >/dev/null && finding atencao "PulseAudio ainda em execução: conflita com o pipewire-pulse."
  DECISION[bluetooth]="$n_bt adaptador(es); codecs: ${codecs:-nenhum}"
  if ((n_bt == 0)); then
    finding bloqueio "Nenhum adaptador Bluetooth detectado."
  elif ((n_bt == 1)); then
    finding info "1 adaptador Bluetooth: o modo duplo vai compartilhar um rádio; usar AAC/SBC-XQ e testar estabilidade."
  else
    finding ok "$n_bt adaptadores Bluetooth: dá para ligar um fone em cada."
  fi
  local depth port
  while read -r depth port; do
    ((depth > 0)) && finding atencao "Adaptador Bluetooth ($port) está atrás de $depth hub(s): ligue-o direto numa porta do notebook."
  done < <(bt_hub_depth)
  [[ -n $(combine_modules | grep -v '^nenhum$') || -n $(find "$HOME/.config/wireplumber" "$HOME/.config/pipewire" -type f 2>/dev/null) ]] &&
    finding info "Já existe configuração de áudio sua (combine em runtime e/ou regras locais): o Módulo 3 vai versioná-la e substituí-la por configuração declarativa."
}

# ───────────────────────────── 5. USB ─────────────────────────────

USB_SERIOUS_RE='usb .*(error|unable to enumerate|descriptor read|over-current|not accepting address)'

usb_hubs() {
  local d
  printf '%-10s %-10s %-7s %-6s %-6s %-7s %s\n' DEV VID:PID USBver Mbps Portas power Produto
  for d in /sys/bus/usb/devices/*; do
    [[ -r $d/bDeviceClass && $(readf "$d/bDeviceClass") == 09 ]] || continue
    printf '%-10s %-10s %-7s %-6s %-6s %-7s %s\n' "$(basename "$d")" \
      "$(readf "$d/idVendor"):$(readf "$d/idProduct")" "$(readf "$d/version" | tr -d ' ')" \
      "$(readf "$d/speed")" "$(readf "$d/maxchild")" "$(readf "$d/power/control")" "$(readf "$d/product")"
  done
}

# Dispositivos que provavelmente estão abaixo da velocidade possível.
# Detecção parcial: muitos dispositivos 3.x se anunciam como 2.10 ao cair para 2.0.
usb_slow() {
  local d ver spd storage found=0
  for d in /sys/bus/usb/devices/*; do
    [[ -r $d/version && -r $d/speed ]] || continue
    [[ $(basename "$d") == usb* || $(readf "$d/bDeviceClass") == 09 ]] && continue
    ver=$(readf "$d/version" | tr -d ' '); spd=$(readf "$d/speed")
    [[ $spd =~ ^(1\.5|12|480)$ ]] || continue
    storage=0
    grep -qx 08 "$d":*/bInterfaceClass 2>/dev/null && storage=1
    if ver_ge "$ver" 3.0 || ((storage)); then
      found=1
      printf '%-10s %s:%s  USB %s @ %s Mbps  %s%s\n' "$(basename "$d")" "$(readf "$d/idVendor")" \
        "$(readf "$d/idProduct")" "$ver" "$spd" "$(readf "$d/product")" "$( ((storage)) && echo '  [armazenamento]')"
    fi
  done
  ((found)) || echo "nenhum suspeito"
}

# Hubs externos que limitam a banda (ignora root hubs e hubs internos de rate-matching da Intel).
usb_hub_suspects() {
  local d name vid pid ver spd
  local -A ss=()
  local -a hs=()
  for d in /sys/bus/usb/devices/*; do
    name=$(basename "$d")
    [[ $name == usb* ]] && continue
    [[ -r $d/bDeviceClass && $(readf "$d/bDeviceClass") == 09 ]] || continue
    vid=$(readf "$d/idVendor"); pid=$(readf "$d/idProduct")
    [[ $vid == 8087 && $pid =~ ^(0020|0024|8000|8008)$ ]] && continue
    spd=$(readf "$d/speed")
    if [[ $spd =~ ^(1\.5|12|480)$ ]]; then hs+=("$vid|$name|$(readf "$d/version" | tr -d ' ')|$spd|$(readf "$d/product")")
    else ss[$vid]=1; fi
  done
  for d in "${hs[@]}"; do
    IFS='|' read -r vid name ver spd prod <<<"$d"
    if ! ver_ge "$ver" 2.0; then
      echo "$name $prod: hub USB $ver (12 Mbps) — gargalo para tudo o que estiver ligado depois dele"
    elif [[ $spd != 480 ]]; then
      echo "$name $prod: hub USB $ver negociando a $spd Mbps — limitado pelo hub/porta acima"
    elif [[ -z ${ss[$vid]:-} ]]; then
      echo "$name $prod: hub só USB 2.0 (sem lado SuperSpeed)"
    fi
  done
}

# Caminho USB que mais resetou no boot atual: "contagem caminho".
usb_top_reset() {
  journalctl -k -b 0 --no-pager -q 2>/dev/null | grep -oP 'usb \K[0-9.-]+(?=: reset)' |
    sort | uniq -c | sort -rn | head -n1
}

usb_params() {
  local p
  for p in autosuspend quirks use_both_schemes old_scheme_first initial_descriptor_timeout; do
    printf 'usbcore.%-28s %s\n' "$p" "$(readf "/sys/module/usbcore/parameters/$p")"
  done
  printf '\ncmdline: %s\n' "$(readf /proc/cmdline)"
  printf '\npower/control dos dispositivos USB: auto=%s on=%s\n' \
    "$(grep -lx auto /sys/bus/usb/devices/*/power/control 2>/dev/null | wc -l)" \
    "$(grep -lx on /sys/bus/usb/devices/*/power/control 2>/dev/null | wc -l)"
  if [[ -r /etc/tlp.conf ]]; then
    printf '\nTLP:\n'
    grep -hE '^[[:space:]]*USB_' /etc/tlp.conf /etc/tlp.d/*.conf 2>/dev/null || echo "sem ajustes USB no TLP"
  fi
}

usb_errors() {
  local b
  if ! journalctl -k -b 0 -n 1 -q >/dev/null 2>&1; then
    echo "sem acesso ao log do kernel (usuário fora dos grupos adm/systemd-journal)"; return
  fi
  for b in 0 -1; do
    echo "--- boot $b ---"
    journalctl -k -b "$b" --no-pager -q -o short-monotonic 2>/dev/null |
      grep -iE "$USB_SERIOUS_RE|usb .*reset|usb .*disconnect" | tail -n 25
  done
}

sec_usb() {
  step "USB"
  h2 "5. USB e hubs (Módulo 2)"
  local serious resets uas suspects
  block "Topologia (lsusb -t)" lsusb -t
  block "Hubs" usb_hubs
  block "Hubs que limitam a banda (heurística)" usb_hub_suspects
  block "Dispositivos possivelmente abaixo da velocidade" usb_slow
  block "Parâmetros do usbcore, cmdline e autosuspend" usb_params
  block "Eventos USB no kernel (boot atual e anterior)" usb_errors

  serious=$(journalctl -k -b 0 --no-pager -q 2>/dev/null | grep -ciE "$USB_SERIOUS_RE")
  resets=$(journalctl -k -b 0 --no-pager -q 2>/dev/null | grep -ciE 'usb .*reset')
  uas=$(lsusb -t 2>/dev/null | grep -c 'Driver=uas')
  suspects=$(usb_hub_suspects | grep -c .)
  DECISION[usb]="$serious erro(s) e $resets reset(s) neste boot; $uas dispositivo(s) UAS; $suspects hub(s) suspeito(s)"
  ((serious > 0)) && finding atencao "$serious erro(s) USB no kernel neste boot: candidatos a quirks no Módulo 2."
  ((suspects > 0)) && finding atencao "$suspects hub(s) limitando a banda USB (ver seção 5): gargalo físico, não resolvível por software."
  local top n path
  top=$(usb_top_reset)
  if [[ -n $top ]]; then
    read -r n path <<<"$top"
    ((n >= 3)) && finding atencao "Dispositivo USB $path ($(readf "/sys/bus/usb/devices/$path/product")) resetou $n vezes neste boot: conexão instável."
  fi
}

# ───────────────────────────── 6. armazenamento ─────────────────────────────

mounts_info() {
  local t
  for t in / /home /boot /boot/efi; do findmnt -n -o TARGET,SOURCE,FSTYPE,OPTIONS -M "$t"; done
}

io_sched() {
  local f n
  for f in /sys/block/*/queue/scheduler; do
    n=$(basename "$(dirname "$(dirname "$f")")")
    [[ $n == loop* || $n == zram* || $n == ram* ]] && continue
    printf '%-10s %s\n' "$n" "$(readf "$f")"
  done
}

folder_sizes() {
  local key dir
  for key in DOWNLOAD VIDEOS MUSIC PICTURES DOCUMENTS DESKTOP; do
    dir=$(xdg-user-dir "$key" 2>/dev/null)
    [[ -n $dir && -d $dir && $dir != "$HOME" ]] || continue
    printf '%-10s %8s  %s\n' "$key" "$(timeout 60 du -sh -- "$dir" 2>/dev/null | cut -f1)" "$dir"
  done
  for dir in "$HOME/.cache" "$HOME/.local/share/flatpak" "$HOME/.var" "$HOME/Android" "$HOME/.gradle" \
             "$HOME/.npm" "$HOME/snap" "$HOME/VirtualBox VMs"; do
    [[ -d $dir ]] && printf '%-10s %8s  %s\n' "dev/cache" "$(timeout 60 du -sh -- "$dir" 2>/dev/null | cut -f1)" "$dir"
  done
  printf '%-10s %8s  %s\n' "TOTAL" "$((HOME_KB / 1024 / 1024))G" "$HOME"
}

sec_storage() {
  step "Discos (o cálculo do tamanho do /home pode levar alguns minutos)"
  h2 "6. Armazenamento (Módulo 5)"
  local entry ssd=0 hdd=0 rootfs scenario
  mapfile -t DISKS < <(list_disks)
  for entry in "${DISKS[@]}"; do
    case ${entry#* } in ssd) ((++ssd)) ;; hdd) ((++hdd)) ;; esac
  done
  rootfs=$(findmnt -n -o FSTYPE /)
  HOME_KB=$(timeout 300 du -sxk -- "$HOME" 2>/dev/null | cut -f1)
  HOME_KB=${HOME_KB:-0}

  kv "Discos internos" "$ssd SSD, $hdd HDD"
  kv "Sistema de arquivos da raiz" "$rootfs"
  block "Discos físicos" lsblk -d -e7 -o NAME,TYPE,TRAN,ROTA,RM,SIZE,MODEL
  block "Partições e sistemas de arquivos" lsblk -e7 -o NAME,FSTYPE,FSVER,SIZE,FSUSE%,MOUNTPOINTS
  block "Montagens principais" mounts_info
  block "Agendador de I/O" io_sched
  block "Pastas pesadas" folder_sizes

  if ((ssd == 2 && hdd == 0)); then scenario="Cenário 1: 2 SSDs → Btrfs (dados single, metadados raid1)"
  elif ((ssd >= 1 && hdd >= 1)); then scenario="Cenário 2: SSD + HDD → pastas pesadas no HDD"
  elif ((ssd + hdd == 1)); then scenario="Disco único: sem ação de storage"
  else scenario="Combinação não prevista ($ssd SSD, $hdd HDD): decidir manualmente"; fi
  DECISION[storage]=$scenario
  DECISION[rootfs]=$rootfs
  [[ $scenario == "Cenário 1"* && $rootfs == ext4 ]] &&
    finding info "Raiz em ext4: o Cenário 1 usa migração por cópia (pendrive live) para Btrfs, como no plano."
  lsblk -nro TYPE | grep -qx crypt &&
    finding atencao "Há disco criptografado (LUKS): a migração do Módulo 5 terá de recriar a camada LUKS."
  lsblk -nro TYPE | grep -qx lvm && finding info "LVM em uso: o plano do Módulo 5 será adaptado a ele."
  ((ssd + hdd == 1 && ssd == 1)) && lsblk -dnP -e7 -o TRAN,ROTA | grep -q 'TRAN="usb" ROTA="1"' &&
    finding info "Há um HDD externo via USB: se ele for instalado internamente (ex.: caddy na baia do DVD), vale o Cenário 2."
}

# ───────────────────────────── 7. pacotes ─────────────────────────────

pkg_versions() {
  dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' \
    cinnamon xfce4-session xfce4-panel xfwm4 xfce4-whiskermenu-plugin lightdm pipewire wireplumber \
    bluez timeshift ubiquity live-installer linux-generic 2>/dev/null | awk '$1 ~ /^ii/ {print $2, $3}'
}

sec_packages() {
  step "Pacotes"
  h2 "7. Pacotes e desktop"
  kv "Pacotes .deb instalados" "$(dpkg-query -f '.\n' -W | wc -l)"
  kv "Instalados manualmente (apt-mark)" "$(apt-mark showmanual 2>/dev/null | wc -l)"
  kv "Flatpaks (apps)" "$(has flatpak && flatpak list --app --columns=application 2>/dev/null | wc -l || echo 0)"
  kv "Snaps" "$(has snap && snap list 2>/dev/null | tail -n +2 | wc -l || echo 0)"
  block "Versões-chave" pkg_versions
  block "Repositórios extras (sources.list.d)" ls -1 /etc/apt/sources.list.d
  block "Pacotes retidos (hold)" apt-mark showhold

  if dpkg-query -W -f='${db:Status-Abbrev}' xfce4-session 2>/dev/null | grep -q '^ii'; then
    finding info "Xfce já instalado: o Módulo 1 só configura."
  else
    finding info "Xfce não instalado: entra lado a lado com o Cinnamon no Módulo 1."
  fi
}

# ───────────────────────────── 8. dev ─────────────────────────────

dev_versions() {
  local c v
  for c in git docker podman node npm python3 uv go rustc cargo java flutter adb code ansible mise; do
    if ! has "$c"; then printf '%-8s —\n' "$c"; continue; fi
    case $c in
      go)      v=$(timeout 10 go version 2>&1) ;;
      java)    v=$(timeout 10 java -version 2>&1 | grep -v '^Picked up' | head -n1) ;;
      flutter) v="instalado em $(command -v flutter) (não executado: a 1ª execução baixa o SDK)" ;;
      *)       v=$(timeout 10 "$c" --version 2>&1 | head -n1) ;;
    esac
    printf '%-8s %s\n' "$c" "$v"
  done
}

virt_info() {
  printf 'virtualização na CPU (vmx/svm): %s\n' "$(grep -qE 'vmx|svm' /proc/cpuinfo && echo sim || echo não)"
  printf '/dev/kvm: %s\n' "$(if [[ -e /dev/kvm ]]; then ls -l /dev/kvm; else echo ausente; fi)"
  printf 'seus grupos: %s\n' "$(id -nG)"
}

sysctl_info() {
  local k
  for k in fs/inotify/max_user_watches fs/inotify/max_user_instances vm/max_map_count vm/swappiness; do
    printf '%-32s %s\n' "${k//\//.}" "$(readf "/proc/sys/$k")"
  done
}

sec_dev() {
  step "Ferramentas de desenvolvimento"
  h2 "8. Ferramentas de desenvolvimento (Módulo 6)"
  block "Versões" dev_versions
  block "Virtualização e grupos" virt_info
  block "Limites do kernel" sysctl_info
  (($(readf /proc/sys/fs/inotify/max_user_watches) < 524288)) &&
    finding info "inotify.max_user_watches baixo para IDEs/watchers: ajustado no Módulo 2."
}

# ───────────────────────────── 9. backup ─────────────────────────────

external_info() {
  local entry found=0
  for entry in "${DISKS[@]}"; do
    [[ ${entry#* } == externo ]] || continue
    found=1
    lsblk -e7 -o NAME,SIZE,FSTYPE,FSAVAIL,MOUNTPOINTS,MODEL "/dev/${entry%% *}"
  done
  ((found)) || echo "nenhum disco externo/USB conectado"
}

# Maior espaço livre (bytes) entre partições montadas de discos externos.
ext_free_bytes() {
  local entry line v max=0
  for entry in "${DISKS[@]}"; do
    [[ ${entry#* } == externo ]] || continue
    while IFS= read -r line; do
      v=$(pval FSAVAIL "$line")
      [[ -n $v ]] && ((v > max)) && max=$v
    done < <(lsblk -bnP -o FSAVAIL "/dev/${entry%% *}")
  done
  echo "$max"
}

timeshift_info() {
  has timeshift || { echo "Timeshift não instalado"; return; }
  if [[ -r /etc/timeshift/timeshift.json ]]; then
    python3 -I - /etc/timeshift/timeshift.json <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
print('modo:', 'btrfs' if c.get('btrfs_mode') == 'true' else 'rsync')
print('dispositivo de backup (uuid):', c.get('backup_device_uuid') or 'não configurado')
sched = [k[len('schedule_'):] for k, v in c.items() if k.startswith('schedule_') and v == 'true']
print('agendamentos:', ', '.join(sched) or 'nenhum')
PY
  else
    echo "Timeshift nunca configurado (sem /etc/timeshift/timeshift.json)"
  fi
}

sec_backup() {
  step "Prontidão para backup"
  h2 "9. Prontidão para backup (Módulo 0)"
  local t n_ext=0 entry free need
  for t in restic borg rsync timeshift; do kv "$t" "$(has "$t" && echo instalado || echo 'não instalado')"; done
  kv "Tamanho do seu /home" "$((HOME_KB / 1024)) MB"
  block "Discos externos conectados" external_info
  block "Timeshift" timeshift_info

  for entry in "${DISKS[@]}"; do [[ ${entry#* } == externo ]] && ((++n_ext)); done
  free=$(ext_free_bytes)
  need=$((HOME_KB * 1024 * 11 / 10))
  if ((n_ext == 0)); then
    finding bloqueio "Nenhum disco externo conectado: o backup do /home precisa de um (espaço ≥ $((need / 1024 ** 3 + 1)) GB)."
    DECISION[backup]="sem destino de backup conectado"
  elif ((free < need)); then
    finding atencao "Disco externo com $((free / 1024 ** 3)) GB livres (montado); o /home pede ~$((need / 1024 ** 3 + 1)) GB."
    DECISION[backup]="destino insuficiente ou desmontado"
  else
    finding ok "Disco externo com espaço suficiente para o backup do /home."
    DECISION[backup]="destino OK ($((free / 1024 ** 3)) GB livres)"
  fi
  has restic || has borg || finding info "restic será instalado no Módulo 0 para o backup do /home."
  if [[ -r /etc/timeshift/timeshift.json ]]; then
    local ts_uuid
    ts_uuid=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("backup_device_uuid",""))' /etc/timeshift/timeshift.json)
    [[ -n $ts_uuid && $ts_uuid == "$(findmnt -n -o UUID /)" ]] &&
      finding atencao "Snapshots do Timeshift ficam no mesmo SSD do sistema: protegem contra configuração errada, não contra falha do disco."
  else
    finding atencao "Timeshift não configurado: é o rollback do sistema em cada módulo."
  fi
}

# ───────────────────────────── 10. extras com sudo ─────────────────────────────

smart_info() {
  local entry
  has smartctl || { echo "smartmontools não instalado"; return; }
  for entry in "${DISKS[@]}"; do
    [[ ${entry#* } == externo ]] && continue
    echo "--- /dev/${entry%% *} ---"
    sudo -n smartctl -H -i "/dev/${entry%% *}" 2>&1 |
      grep -E 'Model|Capacity|Rotation|overall-health|SMART Health|Percentage Used|Power_On_Hours'
  done
}

sec_root_extras() {
  ((ROOT_EXTRAS)) || return 0
  step "Extras com sudo"
  h2 "10. Extras (sudo)"
  if ! sudo -v; then echo "sudo negado: extras ignorados."; return; fi
  block "Saúde SMART dos discos internos" smart_info
  block "Snapshots do Timeshift" sudo -n timeshift --list
  block "LVM" sudo -n pvs
}

# ───────────────────────────── resumo ─────────────────────────────

tag() {
  case $1 in bloqueio) echo BLOQUEIO ;; atencao) echo ATENÇÃO ;; info) echo INFO ;; *) echo OK ;; esac
}

print_findings() {
  local lvl item
  for lvl in bloqueio atencao info ok; do
    for item in "${FINDINGS[@]}"; do
      [[ ${item%%|*} == "$lvl" ]] && printf -- '- [%s] %s\n' "$(tag "$lvl")" "${item#*|}"
    done
  done
}

write_summary() {
  local k
  local -A label=(
    [base]="Sistema" [desktop]="Desktop atual" [ram]="RAM (referência)" [monitores]="Monitores"
    [wireplumber]="WirePlumber" [bluetooth]="Bluetooth" [usb]="USB" [storage]="Storage"
    [rootfs]="FS da raiz" [backup]="Backup"
  )
  printf '# Auditoria CodeOS — %s\n\n' "$(hostname -s)"
  printf '_Gerado em %s por audit.sh v%s. Somente leitura; endereços MAC ocultados._\n' \
    "$(date '+%Y-%m-%d %H:%M')" "$AUDIT_VERSION"
  h2 "Resumo"
  printf '| Item | Valor |\n|---|---|\n'
  for k in base desktop ram monitores wireplumber bluetooth usb storage rootfs backup; do
    [[ -n ${DECISION[$k]:-} ]] && printf '| %s | %s |\n' "${label[$k]}" "${DECISION[$k]//|//}"
  done
  printf '\n### Achados\n\n'
  print_findings
}

main() {
  while (($#)); do
    case $1 in
      --root-extras) ROOT_EXTRAS=1 ;;
      --out) OUT_DIR=${2:?--out exige um diretório}; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Opção desconhecida: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
  done
  if ((EUID == 0)); then
    echo "Rode como seu usuário normal, sem sudo: áudio, monitores e pastas dependem da sua sessão." >&2
    echo "Para os itens que exigem root, use --root-extras (o sudo é pedido só para eles)." >&2
    exit 1
  fi

  setup_session_env
  mkdir -p "$OUT_DIR"
  local report
  report="$OUT_DIR/audit-$(hostname -s)-$(date +%Y%m%d-%H%M%S).md"
  BODY=$(mktemp "$OUT_DIR/.body.XXXXXX")
  trap 'rm -f "$BODY"' EXIT

  echo "Auditoria CodeOS v$AUDIT_VERSION (somente leitura)" >&2
  {
    sec_system
    sec_cpu_mem
    sec_display
    sec_audio
    sec_usb
    sec_storage
    sec_packages
    sec_dev
    sec_backup
    sec_root_extras
  } >"$BODY"
  { write_summary; cat "$BODY"; } >"$report"
  chmod 600 "$report"

  printf '\nAchados:\n' >&2
  print_findings >&2
  printf '\nRelatório completo: %s\n' "$report" >&2
}

main "$@"
