#!/usr/bin/env bash
# Monta a ISO do CodeOS a partir da ISO oficial do Xubuntu 24.04 (mínima), do jeito das derivadas do
# Ubuntu (o que o Cubic faz por dentro, só que repetível e no git):
#
#   1. abre a camada do sistema da ISO base (casper/minimal.squashfs) numa pasta;
#   2. atualiza, tira a marca do Xubuntu, o snap e o instalador snap;
#   3. roda os papéis do Ansible nela em modo imagem (codeos_imagem=true) por conexão chroot;
#   4. acrescenta a sessão "live" (casper) e o instalador Calamares com a marca do CodeOS;
#   5. fecha tudo numa camada só (casper/filesystem.squashfs, como o Lubuntu) e grava a ISO nova
#      reaproveitando o boot da original (UEFI com Secure Boot e BIOS).
#
# Uso (precisa de administrador; leva uns 30–60 min):
#   sudo ./iso/construir.sh              do zero
#   sudo ./iso/construir.sh --continuar  reaproveita o sistema já aberto, atualizado e com kernel
#                                        (depois de corrigir algo que parou no Ansible ou adiante)
# Precisa: xorriso, squashfs-tools, ansible (com community.general) e a ISO base em iso/build/base/
# (baixada e conferida pela soma SHA256 assinada do Ubuntu). Saída: iso/build/codeos-1.0-amd64.iso
set -euo pipefail

RAIZ=$(cd "$(dirname "$0")/.." && pwd)
BASE_NOME=xubuntu-24.04.5-minimal-amd64.iso
BASE="$RAIZ/iso/build/base/$BASE_NOME"
TRAB="$RAIZ/iso/build/trabalho"
ROOTFS="$TRAB/rootfs"
NOVOS="$TRAB/iso"
VERSAO=1.0
SAIDA="$RAIZ/iso/build/codeos-$VERSAO-amd64.iso"

CONTINUAR=false
[ "${1:-}" = "--continuar" ] && CONTINUAR=true
feito() {
    [ -f "$TRAB/.feito-$1" ] && return 0
    # montagens anteriores à marca: o kernel instalado na imagem já mostra que essa parte acabou
    [ "$1" = kernel ] && compgen -G "$ROOTFS/boot/vmlinuz-*" >/dev/null
}
marcar() { touch "$TRAB/.feito-$1"; }

passo() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
morrer() { printf '\033[1;31mERRO: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || morrer "rode com sudo: sudo $0"
[ -n "${SUDO_USER:-}" ] || morrer "rode pelo sudo a partir da sua conta (o script usa ela para gerar os arquivos do projeto)"
for p in xorriso unsquashfs mksquashfs ansible-playbook; do
    command -v "$p" >/dev/null || morrer "falta o programa $p (sudo apt install xorriso squashfs-tools ansible)"
done
[ -f "$BASE" ] || morrer "falta a ISO base: $BASE"
( cd "$(dirname "$BASE")" && grep " \*$BASE_NOME\$" SHA256SUMS | sha256sum -c --quiet - ) \
    || morrer "a ISO base não confere com a soma SHA256 do Ubuntu"

# ── montagens do chroot (desfeitas em qualquer saída) ──────────────────────────────────────────
MONTADOS=()
montar() { mount "$@"; MONTADOS+=("${@: -1}"); }
desmontar() {
    for ((i=${#MONTADOS[@]}-1; i>=0; i--)); do umount -l "${MONTADOS[i]}" 2>/dev/null || true; done
    MONTADOS=()
}
trap desmontar EXIT
no_chroot() { chroot "$ROOTFS" /usr/bin/env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin \
                  DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 "$@"; }

passo "Arquivos gerados do projeto (ícones e tema de boot), com a conta $SUDO_USER"
sudo -u "$SUDO_USER" python3 -I "$RAIZ/assets/icons/build.py" >/dev/null
sudo -u "$SUDO_USER" python3 -I "$RAIZ/assets/boot/build_boot.py" >/dev/null

if $CONTINUAR && feito kernel; then
    passo "Continuando com o sistema já aberto em $ROOTFS"
else
    passo "Pasta de trabalho limpa"
    rm -rf "$TRAB"
    mkdir -p "$NOVOS/casper" "$NOVOS/boot/grub" "$NOVOS/.disk"

    passo "Abrindo a camada do sistema da ISO base"
    xorriso -osirrox on -indev "$BASE" -extract /casper/minimal.squashfs "$TRAB/minimal.squashfs" >/dev/null 2>&1
    unsquashfs -q -d "$ROOTFS" "$TRAB/minimal.squashfs"
    rm -f "$TRAB/minimal.squashfs"
fi

passo "Preparando o chroot"
montar --bind /dev "$ROOTFS/dev"
montar -t devpts devpts "$ROOTFS/dev/pts"
montar -t proc proc "$ROOTFS/proc"
montar -t sysfs sysfs "$ROOTFS/sys"
montar -t tmpfs tmpfs "$ROOTFS/run"
# rede: o resolv.conf da imagem aponta para o systemd-resolved, que não roda no chroot (o original fica
# guardado uma vez só; numa continuação ele já está guardado)
[ -e "$TRAB/resolv.conf.original" ] || [ -L "$TRAB/resolv.conf.original" ] || mv "$ROOTFS/etc/resolv.conf" "$TRAB/resolv.conf.original"
rm -f "$ROOTFS/etc/resolv.conf"
cat /etc/resolv.conf > "$ROOTFS/etc/resolv.conf"
# nenhum serviço sobe durante a montagem
printf '#!/bin/sh\nexit 101\n' > "$ROOTFS/usr/sbin/policy-rc.d"
chmod 755 "$ROOTFS/usr/sbin/policy-rc.d"
# o projeto no mesmo caminho dentro do chroot (as tarefas usam arquivos dele: papéis de parede, temas)
mkdir -p "$ROOTFS$RAIZ"
montar --bind -o ro "$RAIZ" "$ROOTFS$RAIZ"

if ! feito kernel; then
passo "Atualizando o sistema base"
no_chroot apt-get update
no_chroot apt-get -y full-upgrade

# Nesta ISO base o kernel, os firmwares, o microcódigo e o carregador de boot ficam na camada "live" (o
# instalador snap do Ubuntu os põe no disco na hora). No CodeOS o sistema é uma camada só, então eles
# entram nela: os mesmos pacotes da camada live do Xubuntu 24.04.5.
passo "Kernel, firmwares, microcódigo e carregador de boot"
no_chroot apt-get -y install linux-generic-hwe-24.04 linux-firmware firmware-sof-signed \
    intel-microcode amd64-microcode thermald \
    grub-pc grub-efi-amd64-signed shim-signed efibootmgr mokutil \
    cryptsetup cryptsetup-initramfs lvm2 btrfs-progs xfsprogs
marcar kernel
fi

passo "Ansible: CodeOS em modo imagem (desktop, system, dev)"
# o caminho vai em JSON: no formato chave=valor o Ansible corta no espaço de "SO NOVO"
( cd "$RAIZ/ansible" && ANSIBLE_BECOME_ASK_PASS=False \
    ansible-playbook site.yml -i codeos-imagem, -c community.general.chroot \
    -e codeos_alvo=codeos-imagem -e "$(printf '{"ansible_host": "%s"}' "$ROOTFS")" \
    -e codeos_imagem=true -e ansible_python_interpreter=/usr/bin/python3 \
    -e codeos_home=/root -e codeos_user=root --tags desktop,system,dev )

passo "Tirando a marca do Xubuntu, o snap e o que não é do CodeOS"
# tudo o que está instalado fica marcado como escolhido, para tirar os metapacotes sem levar junto o resto
no_chroot sh -c 'apt-mark manual $(dpkg-query -W -f="\${Package}\n") >/dev/null'
no_chroot apt-get -y purge xubuntu-desktop-minimal xubuntu-default-settings xubuntu-artwork xubuntu-wallpapers \
    plymouth-theme-xubuntu-logo plymouth-theme-xubuntu-text lightdm-gtk-greeter \
    snapd ubuntu-pro-client ubuntu-pro-client-l10n ubuntu-advantage-desktop-daemon \
    apport apport-symptoms apport-core-dump-handler python3-apport || true
cat > "$ROOTFS/etc/apt/preferences.d/codeos-sem-snap.pref" <<'EOF'
# CodeOS: programas por apt e Flatpak; o snapd não volta por dependência
Package: snapd
Pin: release a=*
Pin-Priority: -10
EOF
rm -rf "$ROOTFS/snap" "$ROOTFS/var/snap" "$ROOTFS/var/lib/snapd" "$ROOTFS/var/cache/snapd"

passo "Sessão live e instalador (Calamares)"
no_chroot apt-get -y install --no-install-recommends casper calamares calamares-settings-ubuntu-common \
    language-pack-en language-pack-pt language-pack-gnome-pt hunspell-pt-br
install -d "$ROOTFS/etc/calamares/modules" "$ROOTFS/etc/calamares/branding/codeos"
install -m 644 "$RAIZ/iso/calamares/settings.conf" "$ROOTFS/etc/calamares/settings.conf"
install -m 644 "$RAIZ/iso/calamares/modules/"*.conf "$ROOTFS/etc/calamares/modules/"
install -m 644 "$RAIZ/iso/calamares/branding/codeos/"* "$ROOTFS/etc/calamares/branding/codeos/"
install -m 644 "$RAIZ/iso/calamares/codeos-instalar.desktop" "$ROOTFS/usr/share/applications/codeos-instalar.desktop"
# na sessão live o instalador abre sozinho (o atalho sai depois de instalar: shellprocess_codeos_limpeza)
install -m 644 "$RAIZ/iso/calamares/codeos-instalar.desktop" "$ROOTFS/etc/xdg/autostart/codeos-instalar.desktop"
# na sessão live a tela não bloqueia nem apaga (o instalador pode levar vários minutos)
install -m 644 "$RAIZ/iso/calamares/codeos-live.desktop" "$ROOTFS/etc/xdg/autostart/codeos-live.desktop"
cat > "$ROOTFS/etc/casper.conf" <<EOF
# Sessão live do CodeOS (casper)
export USERNAME="codeos"
export USERFULLNAME="CodeOS"
export HOST="codeos"
export BUILD_SYSTEM="Ubuntu"
export FLAVOUR="CodeOS"
EOF

passo "Kernel e initrd da sessão live"
no_chroot update-initramfs -u -k all
KERNEL=$(ls "$ROOTFS"/boot/vmlinuz-* | sort -V | tail -1)
cp "$KERNEL" "$NOVOS/casper/vmlinuz"
cp "$ROOTFS/boot/initrd.img-${KERNEL##*/vmlinuz-}" "$NOVOS/casper/initrd"

passo "Limpando a imagem"
no_chroot apt-get -y autoremove --purge
no_chroot apt-get clean
rm -f "$ROOTFS/usr/sbin/policy-rc.d"
rm -f "$ROOTFS/etc/resolv.conf"
mv "$TRAB/resolv.conf.original" "$ROOTFS/etc/resolv.conf"
: > "$ROOTFS/etc/machine-id"
rm -f "$ROOTFS/var/lib/dbus/machine-id"
rm -rf "$ROOTFS"/tmp/* "$ROOTFS"/var/tmp/* "$ROOTFS"/root/.cache "$ROOTFS"/root/.ansible
find "$ROOTFS/var/log" -type f -exec truncate -s 0 {} +
no_chroot dpkg-query -W --showformat='${Package} ${Version}\n' > "$NOVOS/casper/filesystem.manifest"
desmontar
# tira a pasta vazia em que o projeto ficou montado (só o caminho criado aqui)
d="$RAIZ"; while [ "$d" != "/" ] && [ -d "$ROOTFS$d" ] && rmdir "$ROOTFS$d" 2>/dev/null; do d=$(dirname "$d"); done

passo "Fechando o sistema numa camada só (casper/filesystem.squashfs)"
du -sx --block-size=1 "$ROOTFS" | cut -f1 > "$NOVOS/casper/filesystem.size"
mksquashfs "$ROOTFS" "$NOVOS/casper/filesystem.squashfs" -comp xz -b 1M -noappend -quiet

# boot=casper: o initrd vem do próprio sistema (com os scripts do casper, mas sem a marca de "live" que o
# da ISO do Xubuntu tem embutida); é a linha de boot que diz para entrar como sessão live, como no Lubuntu
passo "Menu de boot e identificação do disco"
cat > "$NOVOS/boot/grub/grub.cfg" <<'EOF'
set timeout=10

loadfont unicode

set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

menuentry "Try or Install CodeOS" {
	set gfxpayload=keep
	linux	/casper/vmlinuz boot=casper --- quiet splash
	initrd	/casper/initrd
}
menuentry "CodeOS (safe graphics)" {
	set gfxpayload=keep
	linux	/casper/vmlinuz boot=casper nomodeset --- quiet splash
	initrd	/casper/initrd
}
grub_platform
if [ "$grub_platform" = "efi" ]; then
menuentry 'Boot from next volume' {
	exit 1
}
menuentry 'UEFI Firmware Settings' {
	fwsetup
}
else
menuentry 'Test memory' {
	linux16 /boot/memtest86+x64.bin
}
fi
EOF
printf 'CodeOS %s "Noble" - amd64 (%s)\n' "$VERSAO" "$(date +%Y%m%d)" > "$NOVOS/.disk/info"

passo "Gravando a ISO (boot da original: UEFI, Secure Boot e BIOS)"
rm -f "$SAIDA"
xorriso -indev "$BASE" -outdev "$SAIDA" \
    -rm /casper/minimal.squashfs /casper/minimal.live.squashfs /casper/minimal.manifest \
        /casper/minimal.live.manifest /casper/minimal.size /casper/minimal.live.size \
        /casper/install-sources.yaml /casper/SHA256SUMS /casper/SHA256SUMS.gpg /md5sum.txt -- \
    -rm_r /preseed -- \
    -map "$NOVOS/casper/filesystem.squashfs" /casper/filesystem.squashfs \
    -map "$NOVOS/casper/filesystem.manifest" /casper/filesystem.manifest \
    -map "$NOVOS/casper/filesystem.size" /casper/filesystem.size \
    -map "$NOVOS/casper/vmlinuz" /casper/vmlinuz \
    -map "$NOVOS/casper/initrd" /casper/initrd \
    -map "$NOVOS/boot/grub/grub.cfg" /boot/grub/grub.cfg \
    -map "$NOVOS/.disk/info" /.disk/info \
    -volid "CodeOS $VERSAO amd64" \
    -boot_image any replay
chown "$SUDO_USER:" "$SAIDA"
( cd "$(dirname "$SAIDA")" && sha256sum "$(basename "$SAIDA")" > "$(basename "$SAIDA").sha256" )
chown "$SUDO_USER:" "$SAIDA.sha256"

passo "Pronto: $SAIDA ($(du -h "$SAIDA" | cut -f1))"
