#!/usr/bin/env bash
# NexoDev OS — Módulo 0: aponta o Timeshift para o disco de backup e cria o snapshot "antes".
# Usa o mesmo disco definido em ./backup/backup.sh init.
#
# Uso:
#   ./backup/timeshift-dest.sh                 troca o destino e cria um snapshot sob demanda
#   ./backup/timeshift-dest.sh --no-snapshot   só troca o destino

set -uo pipefail
export LC_ALL=C.UTF-8

CONF="$HOME/.config/nexodev/backup.conf"
JSON=/etc/timeshift/timeshift.json
SNAPSHOT=1

has()  { command -v "$1" >/dev/null 2>&1; }
info() { printf '  → %s\n' "$*"; }
die()  { printf 'ERRO: %s\n' "$*" >&2; exit 1; }
confirm() { local a; read -r -p "$1 [s/N] " a; [[ $a =~ ^[sS]$ ]]; }
json_get() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$JSON" "$1"; }

case ${1:-} in
  --no-snapshot) SNAPSHOT=0 ;;
  -h|--help) sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) die "opção desconhecida: $1" ;;
esac

((EUID != 0)) || die "rode como seu usuário; o sudo é pedido quando necessário."
has timeshift || die "Timeshift não instalado."
[[ -r $JSON ]] || die "Timeshift nunca configurado ($JSON ausente): configure-o uma vez pela interface."
[[ -r $CONF ]] || die "rode './backup/backup.sh init' primeiro (ele define o disco de destino)."

uuid=$(sed -n 's/^DEST_UUID=//p' "$CONF")
[[ -e /dev/disk/by-uuid/$uuid ]] || die "disco de backup (UUID $uuid) não conectado."
[[ $uuid != "$(findmnt -n -o UUID /)" ]] || die "o destino configurado é o próprio SSD do sistema."
current=$(json_get backup_device_uuid)

if [[ $current == "$uuid" ]]; then
  info "O Timeshift já salva no disco de backup."
else
  info "Destino atual: ${current:-nenhum}$([[ $current == "$(findmnt -n -o UUID /)" ]] && echo ' (o SSD do sistema)')"
  info "Novo destino:  $uuid ($(lsblk -no NAME,SIZE,MODEL "/dev/disk/by-uuid/$uuid" | head -n1))"
  confirm "Trocar o destino do Timeshift?" || die "cancelado."
  bak="$JSON.nexodev-bak-$(date +%Y%m%d-%H%M%S)"
  sudo cp -a "$JSON" "$bak" || die "falha ao copiar $JSON."
  sudo python3 -I - "$JSON" "$uuid" <<'PY' || die "falha ao gravar $JSON (cópia original em $bak)."
import json, os, sys
path, uuid = sys.argv[1], sys.argv[2]
with open(path) as f:
    conf = json.load(f)
conf['backup_device_uuid'] = uuid
conf['parent_device_uuid'] = ''
tmp = path + '.tmp'
with open(tmp, 'w') as f:
    json.dump(conf, f, indent=2)
os.chmod(tmp, 0o644)
os.replace(tmp, path)
PY
  info "Destino trocado. Cópia da configuração anterior: $bak"
fi

info "Exclusões do Timeshift: $(json_get exclude) (o /home fica com o restic)"
info "Os snapshots antigos continuam em /timeshift no SSD; apague-os pela interface quando quiser liberar espaço."
info "Snapshots agendados são pulados enquanto o disco de backup estiver desconectado."

if ((SNAPSHOT)); then
  info "Criando snapshot sob demanda (o primeiro no disco novo copia o sistema inteiro)"
  sudo timeshift --create --comments "NexoDev M0: estado antes das mudanças" --tags O ||
    die "falha ao criar o snapshot."
  sudo timeshift --list
fi
