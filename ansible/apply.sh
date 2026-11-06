#!/usr/bin/env bash
# Roda o playbook pedindo a senha de administrador uma vez e conferindo no próprio sudo antes,
# para não confundir com a senha do backup no "BECOME password:" do Ansible.
# Uso: ./apply.sh site.yml --tags desktop [--check --diff]
set -euo pipefail
cd "$(dirname "$0")"

# Terminais dentro de outros apps (ex.: o do Claude) podem vir com "no new privileges": aí o sudo
# nunca funciona e a senha pareceria errada.
if grep -q '^NoNewPrivs:[[:space:]]*1' /proc/self/status; then
    echo "Este terminal não pode usar sudo (\"no new privileges\"). Abra um terminal pelo menu do sistema" >&2
    echo "(Super → Terminal ou Ctrl+Alt+T) e rode o comando lá." >&2
    exit 1
fi

read -rsp "Senha de administrador (a mesma do sudo, não a do backup): " pw
echo
if ! printf '%s\n' "$pw" | sudo -k -S -p '' true 2>/dev/null; then
    echo "O sudo recusou essa senha. Use a mesma que funciona em 'sudo -k true'." >&2
    exit 1
fi

pwfile=$(umask 077 && mktemp "${XDG_RUNTIME_DIR:-/tmp}/codeos-become.XXXXXX")
trap 'rm -f "$pwfile"' EXIT
printf '%s\n' "$pw" >"$pwfile"
unset pw

ANSIBLE_BECOME_ASK_PASS=False ansible-playbook --become-password-file "$pwfile" "$@"
