# Pacote `codeos` e repositório APT

Como a configuração do CodeOS chega a quem já instalou o sistema.

## Como funciona

O Ansible continua sendo a fonte de tudo. O pacote `codeos` leva os papéis `desktop`, `system` e `dev`
mais os assets já gerados (ícones, tema de boot, papéis de parede):

| Onde | O quê |
|---|---|
| `/usr/share/codeos/ansible` | os papéis e a coleção `community.general` (só o `ansible-core` é dependência) |
| `/usr/share/codeos/assets` | ícones e tema de boot gerados, logo e papéis de parede |
| `/usr/lib/codeos/aplicar` + `codeos-aplicar.service` | reaplica a parte do sistema, como root |
| `/usr/lib/codeos/sessao` + autostart da sessão CodeOS | leva os padrões novos do Xfce para cada conta |
| `/etc/apt/sources.list.d/codeos.sources` + chave | o repositório de onde vêm as próximas versões |

Numa atualização:

1. O apt instala a versão nova. O `postinst` marca `/var/lib/codeos/pendente` e liga o
   `codeos-aplicar.service`.
2. O serviço espera o apt soltar o dpkg e roda os papéis no mesmo modo da montagem da ISO
   (`codeos_imagem=true`): só o sistema, nenhuma conta. Registro em `/var/log/codeos/aplicar.log`.
   Se falhar (sem rede, por exemplo), a marca fica e ele tenta de novo no próximo boot.
3. No próximo login, `sessao` passa os padrões novos da barra, das janelas e dos atalhos para a conta
   com o `codeos-xfconf-merge`. O que a pessoa mudou fica como está.

A versão é `<codeos_version>.<número de commits>`, então cada commit no `main` gera uma versão maior.

## Uma vez só: a chave do repositório

```bash
./packages/gerar-chave.sh
```

Cria a chave que assina o repositório (fora do git, em `~/.local/share/codeos/chave-apt`), grava a parte
pública em `packages/codeos-archive-keyring.asc` e envia a secreta para o segredo
`CODEOS_GPG_PRIVATE_KEY` do GitHub. Faça commit do `.asc`. Guarde uma cópia offline da chave secreta:
sem ela, quem já instalou não aceita versões assinadas por uma chave nova.

Depois, no GitHub: Settings → Pages → Source: **GitHub Actions**.

## Publicar

Push no `main` que mexa em `ansible/`, `assets/` ou `packages/`: o workflow
`.github/workflows/pacotes.yml` monta o pacote, assina o repositório e publica em
<https://matheusantunes-dev.github.io/codeos-linux>.

À mão (para testar):

```bash
./packages/construir.sh
```

```bash
CODEOS_GPG_KEY="CodeOS Archive Signing Key" GNUPGHOME=~/.local/share/codeos/chave-apt ./packages/repo.sh
```

## Num CodeOS instalado antes do repositório existir

```bash
wget https://matheusantunes-dev.github.io/codeos-linux/codeos_latest_all.deb
```

```bash
sudo apt install ./codeos_latest_all.deb
```

A ISO montada por `iso/construir.sh` já vem com o pacote instalado.
