#!/usr/bin/env bash
# Auditoria de rastros do Linux Mint: o que aparece na sessão CodeOS, o que está instalado e a marca
# espalhada pelo sistema. Somente leitura. Relatório em audit/reports/ (fora do git).
# Cada item diz onde é resolvido: [sessão] = escondido já na sessão CodeOS deste notebook;
# [ISO] = some na reinstalação a partir da ISO (base Ubuntu 24.04, sem pacotes do Mint).
set -uo pipefail
cd "$(dirname "$0")"
mkdir -p reports
out="reports/rastros-mint-$(hostname)-$(date +%Y%m%d-%H%M%S).md"
codeos_apps=/usr/share/codeos/applications
codeos_autostart=/etc/xdg/xdg-codeos/autostart

# Pacotes instalados que vêm do repositório do Mint (listas do apt de packages.linuxmint.com).
mint_pkgs=$(mktemp)
trap 'rm -f "$mint_pkgs"' EXIT
sed -n 's/^Package: //p' /var/lib/apt/lists/packages.linuxmint.com_*_Packages 2>/dev/null | sort -u >"$mint_pkgs.all"
dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' | awk '$1=="ii"{print $2}' | sort -u \
    | comm -12 - "$mint_pkgs.all" >"$mint_pkgs"
rm -f "$mint_pkgs.all"

is_mint_pkg() { grep -qx "$1" "$mint_pkgs"; }

# Visível no Xfce? (sem NoDisplay/Hidden e permitido para XFCE por OnlyShowIn/NotShowIn)
visible_in_xfce() {
    local f=$1
    grep -qiE '^(NoDisplay|Hidden)=true' "$f" && return 1
    if grep -q '^OnlyShowIn=' "$f"; then grep -q '^OnlyShowIn=.*XFCE' "$f" || return 1; fi
    grep -q '^NotShowIn=.*XFCE' "$f" && return 1
    return 0
}

{
    printf '# Rastros do Linux Mint — %s (%s)\n\n' "$(hostname)" "$(date '+%Y-%m-%d %H:%M')"
    printf 'Pacotes do repositório do Mint instalados: **%s**. Todos somem na ISO (base Ubuntu 24.04).\n' "$(wc -l <"$mint_pkgs")"

    printf '\n## 1. Apps e configurações que aparecem no menu / Configurações do Xfce\n\n'
    printf '| Atalho | Nome | Pacote | Na sessão CodeOS |\n|---|---|---|---|\n'
    for f in /usr/share/applications/*.desktop; do
        id=$(basename "$f")
        pkg=$(dpkg -S "$f" 2>/dev/null | head -1 | cut -d: -f1)
        name=$(sed -n 's/^Name=//p' "$f" | head -1)
        mint=false
        { [ -n "$pkg" ] && is_mint_pkg "$pkg"; } && mint=true
        grep -qiE '(^Name=.*(mint|cinnamon))|(X-Cinnamon|cinnamon-settings)' "$f" && mint=true
        $mint || continue
        visible_in_xfce "$f" || continue
        if [ -f "$codeos_apps/$id" ]; then state="escondido [sessão]"; else state="**VISÍVEL**"; fi
        printf '| `%s` | %s | %s | %s |\n' "$id" "$name" "${pkg:-?}" "$state"
    done

    printf '\n## 2. Programas que iniciam com a sessão\n\n| Autostart | Pacote | Na sessão CodeOS |\n|---|---|---|\n'
    for f in /etc/xdg/autostart/*.desktop; do
        id=$(basename "$f")
        visible_in_xfce "$f" || continue
        pkg=$(dpkg -S "$f" 2>/dev/null | head -1 | cut -d: -f1)
        { [ -n "$pkg" ] && is_mint_pkg "$pkg"; } || grep -qiE 'mint|cinnamon|xapp' <<<"$id$pkg" || continue
        if [ -f "$codeos_autostart/$id" ] && grep -q '^Hidden=true' "$codeos_autostart/$id"; then
            state="escondido [sessão]"
        else
            state="**INICIA**"
        fi
        printf '| `%s` | %s | %s |\n' "$id" "${pkg:-?}" "$state"
    done

    printf '\n## 3. Scripts do Mint carregados em toda sessão gráfica\n\n```\n'
    for f in /etc/X11/Xsession.d/*; do
        pkg=$(dpkg -S "$f" 2>/dev/null | head -1 | cut -d: -f1)
        { [ -n "$pkg" ] && is_mint_pkg "$pkg"; } && printf '%s  (%s)  [ISO]\n' "$f" "$pkg"
    done
    printf '```\n'

    printf '\n## 4. Marca do Mint no sistema [ISO]\n\n```\n'
    grep -H '' /etc/os-release /etc/lsb-release 2>/dev/null | grep -iE 'name|id|description|codename'
    printf -- '--- /etc/issue: %s\n' "$(head -1 /etc/issue 2>/dev/null)"
    printf -- '--- GRUB_DISTRIBUTOR: %s\n' "$(grep -h '^GRUB_DISTRIBUTOR' /etc/default/grub /etc/default/grub.d/*.cfg 2>/dev/null | tail -1)"
    printf -- '--- Entradas do menu de boot com "Mint": %s\n' "$(grep -c "menuentry.*Mint" /boot/grub/grub.cfg 2>/dev/null)"
    printf -- '--- Tema do GRUB: %s\n' "$(grep -h '^GRUB_THEME' /etc/default/grub /etc/default/grub.d/*.cfg 2>/dev/null | tail -1)"
    printf -- '--- Tema do Plymouth (boot): %s\n' "$(readlink -f /etc/alternatives/default.plymouth 2>/dev/null)"
    printf -- '--- LightDM: %s\n' "$(ls /etc/lightdm/lightdm.conf.d/ 2>/dev/null | tr '\n' ' ')"
    printf -- '--- /etc/linuxmint: %s\n' "$(ls /etc/linuxmint 2>/dev/null | tr '\n' ' ')"
    printf -- '--- Temas, ícones e cursores do Mint: %s\n' "$(ls -d /usr/share/themes/Mint* /usr/share/icons/Mint* /usr/share/icons/Bibata* 2>/dev/null | tr '\n' ' ')"
    printf -- '--- Papéis de parede do Mint: %s pasta(s)\n' "$(ls -d /usr/share/backgrounds/linuxmint* 2>/dev/null | wc -l)"
    printf -- '--- Firefox: %s\n' "$(dpkg-query -W -f='${Version}' firefox 2>/dev/null)"
    printf -- '--- Repositórios do Mint: %s\n' "$(grep -rl 'linuxmint' /etc/apt/sources.list.d/ 2>/dev/null | tr '\n' ' ')"
    printf '```\n'

    printf '\n## 5. Rastros na sua pasta pessoal (não são apagados: o restic restaura o /home) \n\n```\n'
    ls -d "$HOME"/.linuxmint "$HOME"/.cinnamon "$HOME"/.local/share/cinnamon "$HOME"/.config/cinnamon* \
        "$HOME"/.config/mint* "$HOME"/.local/share/applications/*cinnamon-generated* 2>/dev/null
    printf '```\n'

    printf '\n## 6. Todos os pacotes instalados vindos do repositório do Mint [ISO]\n\n```\n'
    column -c 110 "$mint_pkgs"
    printf '```\n'
} >"$out"

echo "Relatório: $PWD/$out"
grep -c 'VISÍVEL\|INICIA' "$out" | xargs printf 'Itens do Mint ainda visíveis/iniciando na sessão CodeOS: %s\n'
