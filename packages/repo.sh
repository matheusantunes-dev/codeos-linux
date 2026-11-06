#!/usr/bin/env bash
# Monta o repositório APT do CodeOS (assinado) com os .deb de packages/build/.
#
#   CODEOS_GPG_KEY=<id ou e-mail da chave> ./packages/repo.sh
#
# Saída: packages/build/repo/ — é o que vai para o GitHub Pages (o workflow .github/workflows/pacotes.yml
# faz isso sozinho a cada push no main). Estrutura de um repositório APT comum:
#   pool/main/c/codeos/*.deb
#   dists/stable/{Release,InRelease,Release.gpg}
#   dists/stable/main/binary-amd64/Packages{,.gz}
#   codeos-archive-keyring.asc  (a chave pública, para quem configurar à mão)
set -euo pipefail
export LC_ALL=C.UTF-8

RAIZ=$(cd "$(dirname "$0")/.." && pwd)
BUILD="$RAIZ/packages/build"
REPO="$BUILD/repo"
CHAVE_PUB="$RAIZ/packages/codeos-archive-keyring.asc"

morrer() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }

command -v apt-ftparchive >/dev/null || morrer "falta o apt-ftparchive (sudo apt install apt-utils)"
[ -n "${CODEOS_GPG_KEY:-}" ] || morrer "defina CODEOS_GPG_KEY com a chave que assina o repositório"
gpg --batch --list-secret-keys "$CODEOS_GPG_KEY" >/dev/null 2>&1 || morrer "a chave $CODEOS_GPG_KEY não está no gpg"
shopt -s nullglob
debs=("$BUILD"/*.deb)
((${#debs[@]})) || morrer "nenhum .deb em packages/build (rode packages/construir.sh)"

rm -rf "$REPO"
mkdir -p "$REPO/pool/main/c/codeos" "$REPO/dists/stable/main/binary-amd64"
cp "${debs[@]}" "$REPO/pool/main/c/codeos/"

cd "$REPO"
apt-ftparchive packages pool > dists/stable/main/binary-amd64/Packages
gzip -9kn dists/stable/main/binary-amd64/Packages
apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=CodeOS \
    -o APT::FTPArchive::Release::Label=CodeOS \
    -o APT::FTPArchive::Release::Suite=stable \
    -o APT::FTPArchive::Release::Codename=stable \
    -o APT::FTPArchive::Release::Architectures=amd64 \
    -o APT::FTPArchive::Release::Components=main \
    -o APT::FTPArchive::Release::Description="CodeOS: configuração do sistema" \
    release dists/stable > dists/stable/Release.tmp
mv dists/stable/Release.tmp dists/stable/Release

gpg --batch --yes --local-user "$CODEOS_GPG_KEY" --clearsign -o dists/stable/InRelease dists/stable/Release
gpg --batch --yes --local-user "$CODEOS_GPG_KEY" --armor --detach-sign -o dists/stable/Release.gpg dists/stable/Release

if [ -f "$CHAVE_PUB" ]; then
    cp "$CHAVE_PUB" codeos-archive-keyring.asc
else
    gpg --batch --armor --export "$CODEOS_GPG_KEY" > codeos-archive-keyring.asc
fi
# o GitHub Pages ignora pastas que começam com "_" sem isto; e uma página simples na raiz
touch .nojekyll
# endereço fixo da versão mais nova: o pacote já traz a chave e o repositório, então instalar ele uma vez
# basta para receber as próximas pelo apt
ultimo=$(printf '%s\n' pool/main/c/codeos/codeos_*_all.deb | sort -V | tail -1)
cp "$ultimo" codeos_latest_all.deb
cat > index.html <<'EOF'
<!doctype html><meta charset="utf-8"><title>CodeOS APT</title>
<h1>Repositório APT do CodeOS</h1>
<p>Quem instalou o CodeOS pela ISO já recebe as atualizações pelo Gerenciador de Atualizações.
Num CodeOS instalado antes do repositório existir, uma vez:</p>
<pre>wget https://matheusantunes-dev.github.io/codeos-linux/codeos_latest_all.deb
sudo apt install ./codeos_latest_all.deb</pre>
EOF

printf 'Repositório pronto em %s (%d pacote(s))\n' "${REPO#$RAIZ/}" "${#debs[@]}"
