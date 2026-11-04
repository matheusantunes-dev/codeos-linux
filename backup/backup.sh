#!/usr/bin/env bash
# NexoDev OS — Módulo 0: backup do /home com restic no disco externo.
# Independente do Ansible de propósito: o backup precisa funcionar (e ser restaurável)
# mesmo que o resto da automação quebre.
#
# Uso:
#   ./backup/backup.sh doctor        verifica destino, restic, senha e última verificação (somente leitura)
#   ./backup/backup.sh init [UUID]   escolhe o disco, instala o restic, gera a senha e cria o repositório
#   ./backup/backup.sh run           salva o estado dos pacotes e faz o snapshot do /home
#   ./backup/backup.sh verify        checa a integridade e restaura uma amostra para comparar
#   ./backup/backup.sh status        lista snapshots e estatísticas

set -uo pipefail
export LC_ALL=C.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="$HOME/.config/nexodev"
CONF="$CONF_DIR/backup.conf"
PASS_FILE="$CONF_DIR/restic-password"
STATE_DIR="$HOME/.local/state/nexodev"
VERIFIED_STAMP="$STATE_DIR/backup-verified"
EXCLUDES="$SCRIPT_DIR/excludes.txt"
REPO_SUBDIR="nexodev-backup/restic-home"
# Retenção: o suficiente para voltar a qualquer ponto da migração.
KEEP=(--keep-daily 7 --keep-weekly 4 --keep-monthly 12)
SAMPLE_SIZE=25
DEST_UUID=""
DEST_MNT=""

has()  { command -v "$1" >/dev/null 2>&1; }
info() { printf '  → %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
die()  { printf 'ERRO: %s\n' "$*" >&2; exit 1; }
confirm() { local a; read -r -p "$1 [s/N] " a; [[ $a =~ ^[sS]$ ]]; }
pval() { [[ $2 =~ (^|[[:space:]])$1=\"([^\"]*)\" ]] && printf '%s' "${BASH_REMATCH[2]}"; }

usage() { sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

load_conf() {
  [[ -r $CONF ]] || die "sem configuração: rode '$0 init' primeiro."
  DEST_UUID=$(sed -n 's/^DEST_UUID=//p' "$CONF")
  [[ -n $DEST_UUID ]] || die "DEST_UUID vazio em $CONF."
}

# Define DEST_MNT com o ponto de montagem do disco de backup; monta via udisks se preciso.
dest_mount() {
  local dev="/dev/disk/by-uuid/$DEST_UUID"
  [[ -e $dev ]] || die "disco de backup (UUID $DEST_UUID) não está conectado."
  DEST_MNT=$(findmnt -rn -S "UUID=$DEST_UUID" -o TARGET | head -n1)
  if [[ -z $DEST_MNT ]]; then
    udisksctl mount -b "$dev" >/dev/null || die "não consegui montar $dev."
    DEST_MNT=$(findmnt -rn -S "UUID=$DEST_UUID" -o TARGET | head -n1)
  fi
  DEST_MNT=$(printf '%b' "$DEST_MNT")
  [[ -n $DEST_MNT ]] || die "disco de backup não montado."
}

open_repo() {
  load_conf
  has restic || die "restic não instalado: rode '$0 init'."
  [[ -s $PASS_FILE ]] || die "senha ausente em $PASS_FILE (restaure-a de onde você a guardou)."
  dest_mount
  export RESTIC_REPOSITORY="$DEST_MNT/$REPO_SUBDIR"
  export RESTIC_PASSWORD_FILE="$PASS_FILE"
  [[ -f $RESTIC_REPOSITORY/config ]] || die "repositório não inicializado em $RESTIC_REPOSITORY."
}

# Partições candidatas: "UUID nome tamanho" (ext4/btrfs/xfs em discos USB).
detect_dest() {
  local line part
  while IFS= read -r line; do
    [[ $(pval TRAN "$line") == usb && $(pval TYPE "$line") == disk ]] || continue
    while IFS= read -r part; do
      [[ $(pval FSTYPE "$part") =~ ^(ext4|btrfs|xfs)$ ]] &&
        echo "$(pval UUID "$part") $(pval NAME "$part") $(pval SIZE "$part")"
    done < <(lsblk -nP -o NAME,UUID,FSTYPE,SIZE "/dev/$(pval NAME "$line")")
  done < <(lsblk -dnP -e7 -o NAME,TYPE,TRAN)
}

# Lista de pacotes, repositórios e serviços: vai para dentro do /home e, portanto, do backup.
save_system_state() {
  local d="$STATE_DIR/system-state"
  info "Salvando pacotes, repositórios e serviços em $d"
  mkdir -p "$d"
  rm -rf "$d/sources.list.d" "$d/keyrings"
  dpkg --get-selections >"$d/dpkg-selections.txt"
  apt-mark showmanual >"$d/apt-manual.txt"
  cp -r /etc/apt/sources.list.d "$d/"
  [[ -d /etc/apt/keyrings ]] && cp -r /etc/apt/keyrings "$d/" 2>/dev/null
  cp /etc/fstab "$d/fstab"
  has flatpak && flatpak list --app --columns=application,origin >"$d/flatpak.txt"
  crontab -l >"$d/crontab.txt" 2>/dev/null || : >"$d/crontab.txt"
  systemctl list-unit-files --state=enabled --no-legend >"$d/system-units.txt"
  systemctl --user list-unit-files --state=enabled --no-legend >"$d/user-units.txt"
  uname -r >"$d/kernel.txt"
  date -Is >"$d/saved-at.txt"
}

cmd_init() {
  local uuid=${1:-} base
  local -a cands=()
  if [[ -z $uuid ]]; then
    mapfile -t cands < <(detect_dest)
    if ((${#cands[@]} != 1)); then
      echo "Partições candidatas (ext4/btrfs/xfs em disco USB):"
      printf '  %s\n' "${cands[@]:-nenhuma}"
      die "escolha uma explicitamente: $0 init <UUID>"
    fi
    uuid=${cands[0]%% *}
    confirm "Usar ${cands[0]#* } (UUID $uuid) como destino do backup?" || die "cancelado."
  fi
  [[ $uuid != "$(findmnt -n -o UUID /)" ]] || die "o destino não pode ser a partição do sistema."

  if ! has restic; then
    info "Instalando restic (pede sudo)"
    sudo apt-get install -y restic || die "falha ao instalar o restic."
  fi

  mkdir -p "$CONF_DIR" && chmod 700 "$CONF_DIR"
  printf 'DEST_UUID=%s\n' "$uuid" >"$CONF"
  DEST_UUID=$uuid
  dest_mount
  base="$DEST_MNT/${REPO_SUBDIR%/*}"
  if [[ ! -d $base ]]; then
    if [[ -w $DEST_MNT ]]; then mkdir -m 700 "$base"
    else sudo install -d -o "$USER" -g "$(id -gn)" -m 700 "$base" || die "não consegui criar $base."; fi
  fi
  export RESTIC_REPOSITORY="$DEST_MNT/$REPO_SUBDIR"
  export RESTIC_PASSWORD_FILE="$PASS_FILE"

  if [[ -f $RESTIC_REPOSITORY/config ]]; then
    [[ -s $PASS_FILE ]] || die "o repositório já existe, mas a senha local sumiu: restaure $PASS_FILE."
    info "Repositório já existe em $RESTIC_REPOSITORY."
    return 0
  fi

  if [[ ! -s $PASS_FILE ]]; then
    (umask 077 && head -c 32 /dev/urandom | base64 | tr -d '\n=' >"$PASS_FILE")
    cat <<EOF

  ── SENHA DO BACKUP ─────────────────────────────────────────────
  Guarde num gerenciador de senhas ou no papel: sem ela o backup é ilegível.
  Uma cópia fica em $PASS_FILE,
  mas ela some junto com o SSD se ele falhar.
  ────────────────────────────────────────────────────────────────

      $(cat "$PASS_FILE")

EOF
    local a=""
    until [[ $a == salvei ]]; do read -r -p "Digite 'salvei' depois de guardar a senha: " a; done
    clear 2>/dev/null || true
  fi

  restic init || die "falha ao criar o repositório."
  info "Pronto. Próximo passo: $0 run"
}

cmd_run() {
  open_repo
  save_system_state
  local avail_gb
  avail_gb=$(($(df -Pk "$DEST_MNT" | awk 'NR == 2 {print $4}') / 1024 / 1024))
  ((avail_gb >= 10)) || warn "só ${avail_gb} GB livres no destino."
  info "Snapshot de $HOME → $RESTIC_REPOSITORY (o primeiro demora; os seguintes só enviam diferenças)"
  nice -n 10 ionice -c3 restic backup "$HOME" \
    --one-file-system --exclude-caches --exclude-file "$EXCLUDES" \
    --tag nexodev --host "$(hostname -s)" || die "o backup falhou."
  info "Aplicando retenção (${KEEP[*]})"
  restic forget --tag nexodev "${KEEP[@]}" --prune || warn "retenção falhou (o snapshot novo está salvo)."
  info "Próximo passo: $0 verify"
}

# Lê "restic ls --json" e escolhe arquivos que não mudaram desde o snapshot.
pick_sample() {
  local code
  # O código vai por -c porque o stdin traz a saída do restic.
  read -r -d '' code <<'PY'
import json, os, random, re, sys
from datetime import datetime
ts = datetime.fromisoformat(re.sub(r'\.\d+', '', sys.argv[1])).timestamp()
n = int(sys.argv[2])
files = []
for line in sys.stdin:
    try:
        o = json.loads(line)
    except ValueError:
        continue
    p = o.get('path', '')
    # restore --include usa glob: pula nomes com caracteres especiais
    if o.get('type') != 'file' or not 0 < o.get('size', 0) < 50 * 2**20 or re.search(r'[*?\[\]\\]', p):
        continue
    try:
        st = os.stat(p)
    except OSError:
        continue
    if st.st_mtime < ts and st.st_size == o['size']:
        files.append(p)
random.shuffle(files)
print('\n'.join(files[:n]))
PY
  python3 -I -c "$code" "$1" "$SAMPLE_SIZE"
}

cmd_verify() {
  open_repo
  local latest id time tmp f ok=0
  local -a sample=() inc=()
  info "Checando estrutura e 10% dos dados do repositório"
  restic check --read-data-subset=10% || die "restic check falhou: NÃO siga para os próximos módulos."

  latest=$(restic snapshots --tag nexodev --json | python3 -I -c '
import json, sys
s = sorted(json.load(sys.stdin), key=lambda x: x["time"])
print(s[-1]["short_id"], s[-1]["time"]) if s else None')
  [[ -n $latest ]] || die "nenhum snapshot encontrado: rode '$0 run'."
  read -r id time <<<"$latest"

  info "Escolhendo $SAMPLE_SIZE arquivos do snapshot $id para restaurar e comparar"
  mapfile -t sample < <(restic ls --json "$id" | pick_sample "$time")
  ((${#sample[@]} > 0)) || die "amostra vazia: nada a comparar."
  for f in "${sample[@]}"; do inc+=(--include "$f"); done

  tmp=$(mktemp -d "$DEST_MNT/${REPO_SUBDIR%/*}/verify.XXXXXX")
  trap 'rm -rf -- "$tmp"' EXIT
  restic restore "$id" --target "$tmp" "${inc[@]}" >/dev/null || die "falha ao restaurar a amostra."
  for f in "${sample[@]}"; do
    if cmp -s -- "$f" "$tmp$f"; then ((++ok)); else warn "diferente após restaurar: $f"; fi
  done
  info "Amostra: $ok/${#sample[@]} arquivos idênticos"
  ((ok == ${#sample[@]})) || die "a verificação falhou."

  mkdir -p "$STATE_DIR"
  printf 'snapshot=%s\nverified_at=%s\nsample=%s\n' "$id" "$(date -Is)" "$ok" >"$VERIFIED_STAMP"
  info "Backup verificado. Registro em $VERIFIED_STAMP (o Ansible exige um com menos de 24 h)."
}

cmd_status() {
  open_repo
  restic snapshots --tag nexodev
  restic stats --mode raw-data
  [[ -r $VERIFIED_STAMP ]] && { echo; cat "$VERIFIED_STAMP"; }
}

# Somente leitura: nunca monta, instala ou cria nada.
cmd_doctor() {
  local fails=0 mnt age ts_uuid
  check() { if eval "$2"; then printf '  [OK]    %s\n' "$1"; else printf '  [FALTA] %s\n' "$1"; ((++fails)); fi; }

  check "configuração ($CONF)" '[[ -r $CONF ]]'
  DEST_UUID=$(sed -n 's/^DEST_UUID=//p' "$CONF" 2>/dev/null)
  check "disco de backup conectado" '[[ -n $DEST_UUID && -e /dev/disk/by-uuid/$DEST_UUID ]]'
  mnt=$(findmnt -rn -S "UUID=$DEST_UUID" -o TARGET 2>/dev/null | head -n1)
  mnt=$(printf '%b' "$mnt")
  check "disco de backup montado${mnt:+ em $mnt}" '[[ -n $mnt ]]'
  check "restic instalado" 'has restic'
  check "senha com permissão 600" '[[ -s $PASS_FILE && $(stat -c %a "$PASS_FILE") == 600 ]]'
  check "repositório inicializado" '[[ -n $mnt && -f $mnt/$REPO_SUBDIR/config ]]'
  age=-1
  [[ -r $VERIFIED_STAMP ]] && age=$(( ($(date +%s) - $(date -d "$(sed -n 's/^verified_at=//p' "$VERIFIED_STAMP")" +%s)) / 3600 ))
  check "backup verificado nas últimas 24 h$( ((age >= 0)) && echo " (há ${age} h)")" '((age >= 0 && age < 24))'
  ts_uuid=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("backup_device_uuid",""))' \
    /etc/timeshift/timeshift.json 2>/dev/null)
  check "Timeshift salvando fora do SSD do sistema" '[[ -n $ts_uuid && $ts_uuid != "$(findmnt -n -o UUID /)" ]]'

  ((fails == 0)) && echo "Módulo 0 completo." || echo "$fails item(ns) pendente(s)."
  ((fails == 0))
}

main() {
  ((EUID != 0)) || die "rode como seu usuário; o sudo é pedido só quando necessário."
  local cmd=${1:-}
  shift || true
  case $cmd in
    doctor) cmd_doctor ;;
    init)   cmd_init "$@" ;;
    run)    cmd_run ;;
    verify) cmd_verify ;;
    status) cmd_status ;;
    -h|--help|"") usage ;;
    *) usage >&2; exit 2 ;;
  esac
}

main "$@"
