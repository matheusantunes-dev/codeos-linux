#!/usr/bin/env bash
# Cria a chave GPG que assina o repositório APT do CodeOS. Rode uma vez só, na sua conta.
#
#   ./packages/gerar-chave.sh
#
# - A chave fica num chaveiro só dela: ~/.local/share/codeos/chave-apt (fora do repositório).
# - A parte pública vai para packages/codeos-archive-keyring.asc (entra no git e no pacote codeos).
# - A parte secreta vai para o segredo CODEOS_GPG_PRIVATE_KEY do GitHub (pelo gh), que o workflow usa
#   para assinar. Guarde também uma cópia offline: sem ela, quem já instalou não aceita uma chave nova.
set -euo pipefail

RAIZ=$(cd "$(dirname "$0")/.." && pwd)
export GNUPGHOME="$HOME/.local/share/codeos/chave-apt"
NOME="CodeOS Archive Signing Key"
PUB="$RAIZ/packages/codeos-archive-keyring.asc"

if [ -d "$GNUPGHOME" ] && gpg --batch --list-secret-keys "$NOME" >/dev/null 2>&1; then
    echo "A chave já existe em $GNUPGHOME:"
else
    install -d -m 700 "$GNUPGHOME"
    # sem senha: quem assina é o GitHub Actions; a proteção é o segredo do repositório e esta pasta (700)
    gpg --batch --passphrase '' --quick-generate-key "$NOME" ed25519 sign 5y
    echo "Chave criada em $GNUPGHOME:"
fi
gpg --batch --list-keys --keyid-format long "$NOME"
gpg --batch --armor --export "$NOME" > "$PUB"
echo "Chave pública: ${PUB#$RAIZ/} (faça commit dela)."

if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    read -r -p "Enviar a chave secreta para o segredo CODEOS_GPG_PRIVATE_KEY do GitHub? [s/N] " r
    if [ "$r" = s ]; then
        gpg --batch --armor --export-secret-keys "$NOME" | gh secret set CODEOS_GPG_PRIVATE_KEY -R matheusantunes-dev/codeos-linux
        echo "Segredo enviado."
    fi
else
    echo "Para o GitHub Actions assinar: gh secret set CODEOS_GPG_PRIVATE_KEY (com a saída de"
    echo "  GNUPGHOME=$GNUPGHOME gpg --armor --export-secret-keys \"$NOME\")"
fi
echo "Cópia offline (pendrive, gerenciador de senhas): GNUPGHOME=$GNUPGHOME gpg --armor --export-secret-keys \"$NOME\""
