#!/usr/bin/env bash
# CodeOS — instala o tema de boot (Plymouth) gerado por build_boot.py.
#
# Uso:
#   ./assets/boot/install.sh test [s]    mostra a animação numa janela por s segundos (padrão 12), sem mexer no boot
#   ./assets/boot/install.sh install     instala o tema, torna padrão e atualiza o initramfs
#   ./assets/boot/install.sh uninstall   volta ao tema anterior (o do Mint)

set -uo pipefail
export LC_ALL=C.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/build/plymouth"
DEST=/usr/share/plymouth/themes/codeos
THEME="$DEST/codeos.plymouth"
LINK=/usr/share/plymouth/themes/default.plymouth
PREVIOUS="$HOME/.local/state/codeos/plymouth-previous"
MINT_THEME=/usr/share/plymouth/themes/mint-logo/mint-logo.plymouth
FILES=(codeos.plymouth codeos.script logo.png glow.png)

info() { printf '  → %s\n' "$*"; }
die()  { printf 'ERRO: %s\n' "$*" >&2; exit 1; }
current_theme() { update-alternatives --query default.plymouth 2>/dev/null | sed -n 's/^Value: //p'; }

# Copia os arquivos e registra o tema como alternativa padrão (sem tocar no initramfs).
activate_theme() {
  local f
  for f in "${FILES[@]}"; do
    [[ -f $SRC/$f ]] || die "falta $SRC/$f: rode antes 'python3 assets/boot/build_boot.py'."
  done
  sudo install -d -m 755 "$DEST" || die "não consegui criar $DEST."
  for f in "${FILES[@]}"; do sudo install -m 644 "$SRC/$f" "$DEST/$f" || die "falha ao copiar $f."; done
  sudo update-alternatives --install "$LINK" default.plymouth "$THEME" 250 >/dev/null || die "falha no update-alternatives."
  sudo update-alternatives --set default.plymouth "$THEME" >/dev/null || die "falha ao definir o tema padrão."
}

# Volta o padrão para $1 e remove o tema do sistema (sem tocar no initramfs).
deactivate_theme() {
  sudo update-alternatives --set default.plymouth "$1" >/dev/null
  sudo update-alternatives --remove default.plymouth "$THEME" >/dev/null 2>&1
  sudo rm -rf -- "$DEST"
}

cmd_install() {
  local prev
  prev=$(current_theme)
  if [[ -n $prev && $prev != "$THEME" ]]; then
    mkdir -p "$(dirname "$PREVIOUS")"
    printf '%s\n' "$prev" >"$PREVIOUS"
    info "Tema atual guardado para desfazer: $prev"
  fi
  info "Copiando o tema para $DEST (pede sudo)"
  activate_theme
  info "Atualizando o initramfs (o boot lê o tema de lá; leva ~1 min)"
  sudo update-initramfs -u || die "falha no update-initramfs: rode '$0 uninstall' antes de reiniciar."
  info "Pronto. Reinicie para ver no boot."
}

# Com a sessão gráfica aberta o Xorg segura a placa de vídeo: o renderizador normal (drm) não
# consegue desenhar e o Plymouth cai no console de texto. Por isso o teste usa o renderizador X11
# (pacote plymouth-x11), que mostra o tema numa janela, e grava um log para diagnóstico.
# Se o tema não estiver instalado, ele é ativado só durante o teste: o initramfs (o boot) não muda.
cmd_test() {
  local secs=${1:-12} log=/tmp/codeos-plymouth-test.log prev
  if [[ -n ${DISPLAY:-} ]] && ! compgen -G '/usr/lib/*/plymouth/renderers/x11.so' >/dev/null; then
    die "dentro da sessão gráfica o teste precisa do renderizador X11: 'sudo apt install plymouth-x11'."
  fi
  prev=$(current_theme)
  if [[ $prev != "$THEME" ]]; then
    info "Ativando o tema só para o teste (o boot continua com $(basename "$prev" .plymouth))"
    activate_theme
    trap 'deactivate_theme "$prev"; info "Tema de teste removido; boot inalterado."' EXIT
  fi
  info "A animação aparece por $secs s e some sozinha. Log: $log"
  sudo plymouth --ping 2>/dev/null && sudo plymouth quit
  sudo env DISPLAY="${DISPLAY:-}" XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}" \
    plymouthd --debug --debug-file="$log" || die "falha ao iniciar o plymouthd."
  sudo plymouth --show-splash
  sleep "$secs"
  sudo plymouth quit
  sudo chmod a+r "$log"
  grep -qiE 'script.*(error|fail)|could not load' "$log" && info "O log tem erros do tema: veja $log"
}

cmd_uninstall() {
  local prev
  prev=$(cat "$PREVIOUS" 2>/dev/null)
  [[ -n $prev && -f $prev ]] || prev=$MINT_THEME
  info "Voltando para $prev (pede sudo)"
  deactivate_theme "$prev"
  [[ $(current_theme) == "$prev" ]] || die "falha ao restaurar o tema."
  sudo update-initramfs -u || die "falha no update-initramfs."
  rm -f "$PREVIOUS"
  info "Tema anterior restaurado."
}

((EUID != 0)) || die "rode como seu usuário; o sudo é pedido quando necessário."
case ${1:-} in
  install)   cmd_install ;;
  test)      cmd_test "${2:-}" ;;
  uninstall) cmd_uninstall ;;
  *) sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
