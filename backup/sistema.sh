#!/usr/bin/env bash
# CodeOS — Módulo 0: guarda o que fica fora do /home e se perde numa reinstalação, no mesmo disco do
# backup do restic: senhas do Wi-Fi, pareamentos Bluetooth e a identidade do AnyDesk (o mesmo ID).
#
# Uso:
#   ./backup/sistema.sh             salva em <disco>/codeos-backup/sistema/sistema-AAAA-MM-DD.tar.gz
#   ./backup/sistema.sh --restaurar ARQUIVO   devolve tudo ao lugar (no sistema novo)

set -uo pipefail
export LC_ALL=C.UTF-8

CONF="$HOME/.config/codeos/backup.conf"
ITENS=(etc/NetworkManager/system-connections var/lib/bluetooth etc/anydesk)

info() { printf '  → %s\n' "$*"; }
die()  { printf 'ERRO: %s\n' "$*" >&2; exit 1; }

((EUID != 0)) || die "rode como seu usuário; o sudo é pedido quando necessário."

if [[ ${1:-} == --restaurar ]]; then
  [[ -r ${2:-} ]] || die "informe o arquivo .tar.gz salvo."
  info "parando AnyDesk e Bluetooth enquanto os arquivos voltam"
  sudo systemctl stop anydesk bluetooth 2>/dev/null
  sudo tar -xzpf "$2" -C / || die "falha ao restaurar."
  sudo systemctl start bluetooth anydesk 2>/dev/null
  sudo nmcli connection reload
  info "restaurado: ${ITENS[*]}"
  exit 0
fi

[[ -r $CONF ]] || die "sem configuração: rode './backup/backup.sh init' primeiro."
UUID=$(sed -n 's/^DEST_UUID=//p' "$CONF")
[[ -e /dev/disk/by-uuid/$UUID ]] || die "disco de backup não está conectado."
MNT=$(findmnt -rn -S "UUID=$UUID" -o TARGET | head -n1)
if [[ -z $MNT ]]; then
  udisksctl mount -b "/dev/disk/by-uuid/$UUID" >/dev/null || die "não consegui montar o disco."
  MNT=$(findmnt -rn -S "UUID=$UUID" -o TARGET | head -n1)
fi
MNT=$(printf '%b' "$MNT")

DEST="$MNT/codeos-backup/sistema"
ARQ="$DEST/sistema-$(date +%F).tar.gz"
mkdir -p "$DEST" || die "não consegui criar $DEST."

presentes=()
for i in "${ITENS[@]}"; do sudo test -e "/$i" && presentes+=("$i"); done
((${#presentes[@]})) || die "nada para salvar."

# só root lê o arquivo: ele tem as senhas do Wi-Fi
sudo tar -czpf "$ARQ" -C / "${presentes[@]}" || die "falha ao criar $ARQ."
sudo chmod 600 "$ARQ"
info "salvo em $ARQ:"
sudo tar -tzf "$ARQ" | sed 's/^/      /'
