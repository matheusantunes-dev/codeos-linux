#!/usr/bin/env bash
# Inventário do que precisa sobreviver à reinstalação (Mint → CodeOS): apps instalados à mão,
# repositórios, flatpaks, snaps, serviços e configurações próprias em /etc, cron, Docker e Ollama.
# Somente leitura. Relatório em audit/reports/ (fora do git: tem nomes de apps e caminhos pessoais).
set -uo pipefail
cd "$(dirname "$0")"
mkdir -p reports
out="reports/inventario-$(hostname)-$(date +%Y%m%d-%H%M%S).md"

section() { printf '\n## %s\n\n```\n' "$1"; }
end() { printf '```\n'; }

{
    printf '# Inventário para reinstalação — %s (%s)\n' "$(hostname)" "$(date '+%Y-%m-%d %H:%M')"

    section "Pacotes instalados à mão (fora da instalação padrão)"
    comm -23 <(apt-mark showmanual | sort -u) \
        <(zcat -f /var/log/installer/initial-status.gz 2>/dev/null | sed -n 's/^Package: //p' | sort -u)
    end

    section "Pacotes de fora dos repositórios oficiais (origem do apt)"
    apt list --installed 2>/dev/null | grep -vE 'ubuntu|linuxmint|noble|zena|now ' | sed 's/,.*//' | tail -n +2
    end

    section "Repositórios extras"
    grep -rhvE '^\s*(#|$)' /etc/apt/sources.list.d/ 2>/dev/null
    end

    section "Flatpaks"
    flatpak list --app --columns=application,origin 2>/dev/null
    end

    section "Snaps"
    snap list 2>/dev/null
    end

    section "AppImages e binários próprios"
    find "$HOME" /opt -maxdepth 3 \( -iname '*.AppImage' -o -path '/opt/*' -type d \) 2>/dev/null | head -50
    ls "$HOME/.local/bin" 2>/dev/null
    end

    section "Atalhos de apps do usuário (~/.local/share/applications)"
    ls "$HOME/.local/share/applications" 2>/dev/null
    end

    section "Serviços systemd próprios (/etc/systemd/system)"
    find /etc/systemd/system -maxdepth 1 -type f -name '*.service' -printf '%f\n' 2>/dev/null
    systemctl --user list-unit-files --state=enabled --no-legend 2>/dev/null
    end

    section "Configurações de /etc mudadas em relação aos pacotes"
    if command -v debsums >/dev/null; then debsums -ce 2>/dev/null; else echo "(instale debsums para listar)"; fi
    end

    section "Cron"
    crontab -l 2>/dev/null
    ls /etc/cron.d 2>/dev/null
    end

    section "Docker (imagens e volumes)"
    docker images --format '{{.Repository}}:{{.Tag}}  {{.Size}}' 2>/dev/null
    docker volume ls -q 2>/dev/null
    end

    section "Modelos do Ollama"
    ollama list 2>/dev/null
    end

    section "Grupos do usuário"
    id -nG
    end

    section "Pastas grandes do /home (o backup restic já cobre o /home)"
    du -xsh "$HOME"/* "$HOME"/.[!.]* 2>/dev/null | sort -rh | head -25
    end
} >"$out"

echo "Inventário: $PWD/$out"
