#!/usr/bin/env bash
# Monta o pacote codeos_<versão>_all.deb a partir do repositório (não precisa de sudo).
#
#   ./packages/construir.sh            saída em packages/build/codeos_<versão>_all.deb
#
# Versão: <codeos_version de ansible/group_vars/all.yml>.<número de commits do git>, sempre crescente
# no main (CODEOS_VERSAO=... sobrepõe). O pacote leva:
#   /usr/share/codeos/ansible   os papéis (sem ansible/maquinas: são ajustes só do seu notebook)
#   /usr/share/codeos/assets    ícones e tema de boot já gerados, logo e papéis de parede
#   /usr/lib/codeos/            aplicar (sistema, como root) e sessao (padrões no login)
#   chave e endereço do repositório APT, quando packages/codeos-archive-keyring.asc existe
# Precisa: dpkg-deb, gpg, rsync, ansible-galaxy (ansible-core) e python3 com PIL, cairo e Rsvg
# (sudo apt install ansible-core gir1.2-rsvg-2.0 python3-pil python3-cairo).
set -euo pipefail
export LC_ALL=C.UTF-8

RAIZ=$(cd "$(dirname "$0")/.." && pwd)
PKG="$RAIZ/packages"
SAIDA="$PKG/build"
APT_URL=${CODEOS_APT_URL:-https://matheusantunes-dev.github.io/codeos-linux}
CHAVE="$PKG/codeos-archive-keyring.asc"

morrer() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }
passo() { printf '==> %s\n' "$*"; }

COLECAO=8.3.0  # a do pacote ansible 9.2.0 do Ubuntu 24.04, testada com o ansible-core 2.16

for p in dpkg-deb gpg rsync python3 git ansible-galaxy; do command -v "$p" >/dev/null || morrer "falta o programa $p"; done

base=$(sed -n 's/^codeos_version: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' "$RAIZ/ansible/group_vars/all.yml")
[ -n "$base" ] || morrer "não achei codeos_version em ansible/group_vars/all.yml"
VERSAO=${CODEOS_VERSAO:-$base.$(git -C "$RAIZ" rev-list --count HEAD)}

if [ "${CODEOS_SEM_GERAR:-}" = 1 ]; then
    passo "Usando os ícones e o tema de boot já gerados (CODEOS_SEM_GERAR=1)"
else
    passo "Gerando ícones e tema de boot"
    python3 -I "$RAIZ/assets/icons/build.py" >/dev/null
    python3 -I "$RAIZ/assets/boot/build_boot.py" >/dev/null
fi
[ -d "$RAIZ/assets/icons/build/CodeOS" ] || morrer "o gerador de ícones não criou assets/icons/build/CodeOS"
[ -d "$RAIZ/assets/boot/build/plymouth" ] || morrer "o gerador do boot não criou assets/boot/build/plymouth"

ST="$SAIDA/codeos_$VERSAO"
passo "Montando a árvore do pacote em $ST"
rm -rf "$ST"
mkdir -p "$ST/usr/share/codeos/assets/icons" "$ST/usr/share/codeos/assets/boot" "$ST/usr/share/codeos/assets/logo"
rsync -a "$PKG/codeos/raiz/" "$ST/"
rsync -a --exclude=/maquinas/ --exclude=__pycache__ --exclude='*.retry' "$RAIZ/ansible/" "$ST/usr/share/codeos/ansible/"
rsync -a "$RAIZ/assets/icons/build/" "$ST/usr/share/codeos/assets/icons/build/"
rsync -a "$RAIZ/assets/boot/build/plymouth" "$ST/usr/share/codeos/assets/boot/build/"
rsync -a "$RAIZ/assets/wallpapers" "$ST/usr/share/codeos/assets/"
install -m 644 "$RAIZ/assets/logo/codeos-greeter-logo.png" "$ST/usr/share/codeos/assets/logo/"
printf '%s\n' "$VERSAO" > "$ST/usr/share/codeos/VERSION"

# Só o ansible-core vira dependência (8 MB; o pacote "ansible" completo tem 287 MB): a única coleção que
# os papéis usam fora dele (community.general: ufw e flatpak_remote) vai junto, na versão do Ubuntu 24.04.
passo "Coleção community.general $COLECAO"
# --force: sem ele o ansible-galaxy pula a instalação quando a coleção já existe na máquina que monta
ansible-galaxy collection install "community.general:==$COLECAO" --no-deps --force \
    -p "$ST/usr/share/codeos/ansible/collections" >/dev/null 2>&1
COL="$ST/usr/share/codeos/ansible/collections/ansible_collections/community/general"
[ -f "$COL/plugins/modules/ufw.py" ] || morrer "a coleção community.general não foi instalada no pacote"
rm -rf "$COL/tests"

if [ -f "$CHAVE" ]; then
    passo "Repositório APT: $APT_URL"
    install -d "$ST/usr/share/keyrings" "$ST/etc/apt/sources.list.d"
    gpg --batch --yes --dearmor -o "$ST/usr/share/keyrings/codeos-archive-keyring.gpg" "$CHAVE"
    chmod 644 "$ST/usr/share/keyrings/codeos-archive-keyring.gpg"
    cat > "$ST/etc/apt/sources.list.d/codeos.sources" <<EOF
# CodeOS: atualizações da configuração do sistema (pacote codeos)
Types: deb
URIs: $APT_URL
Suites: stable
Components: main
Signed-By: /usr/share/keyrings/codeos-archive-keyring.gpg
EOF
else
    printf 'AVISO: sem %s — o pacote sai sem o repositório APT (rode packages/gerar-chave.sh).\n' "${CHAVE#$RAIZ/}" >&2
fi

passo "Controle do pacote"
install -d "$ST/DEBIAN"
for s in postinst prerm postrm; do install -m 755 "$PKG/codeos/DEBIAN/$s" "$ST/DEBIAN/$s"; done
tamanho=$(du -sk --exclude=DEBIAN "$ST" | cut -f1)
sed -e "s/@VERSAO@/$VERSAO/" -e "s/@TAMANHO@/$tamanho/" "$PKG/codeos/DEBIAN/control.in" > "$ST/DEBIAN/control"
( cd "$ST" && find etc -type f -printf '/%p\n' 2>/dev/null | sort ) > "$ST/DEBIAN/conffiles"
[ -s "$ST/DEBIAN/conffiles" ] || rm -f "$ST/DEBIAN/conffiles"
chmod -R u+rwX,go+rX,go-w "$ST"
chmod 755 "$ST/usr/lib/codeos/aplicar" "$ST/usr/lib/codeos/sessao"

DEB="$SAIDA/codeos_${VERSAO}_all.deb"
dpkg-deb --root-owner-group -Zxz --build "$ST" "$DEB" >/dev/null
rm -rf "$ST"
passo "Pronto: ${DEB#$RAIZ/} ($(du -h "$DEB" | cut -f1))"
