#!/usr/bin/env bash
# Abre a sessão CodeOS numa janela (Xephyr) dentro da sessão atual, sem logout — útil pelo AnyDesk.
# Fechar a janela encerra o teste. Se ~/.config/xfce4 não existia antes, a configuração que o teste
# criar vai para ~/.cache/codeos/ ao fechar, para não passar por cima dos padrões no primeiro login de verdade.
set -u
display=:2
if pgrep -x Xephyr >/dev/null; then
    echo "Já tem um teste aberto (Xephyr). Feche a janela \"CodeOS (teste)\" antes." >&2
    exit 1
fi
had_config=false
[ -d "$HOME/.config/xfce4" ] && had_config=true
cleanup() {
    kill "$xephyr" 2>/dev/null
    if ! $had_config && [ -d "$HOME/.config/xfce4" ]; then
        sleep 1
        mkdir -p "$HOME/.cache/codeos"
        mv "$HOME/.config/xfce4" "$HOME/.cache/codeos/xfce4-teste-$(date +%Y%m%d-%H%M%S)"
    fi
}
Xephyr "$display" -screen "${1:-1400x860}" -title "CodeOS (teste)" -resizeable -no-host-grab &
xephyr=$!
trap cleanup EXIT
sleep 2
env -u SESSION_MANAGER -u XDG_SESSION_ID DISPLAY="$display" DESKTOP_SESSION=codeos \
    XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_DESKTOP=codeos XDG_CONFIG_DIRS=/etc/xdg/xdg-codeos:/etc/xdg \
    dbus-run-session startxfce4
