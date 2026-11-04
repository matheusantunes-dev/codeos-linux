# Restauração

Dois backups com papéis diferentes, ambos no HDD externo (WD 320 GB, partição `sdc2`):

| O quê | Ferramenta | Onde no HDD | Volta o quê |
|---|---|---|---|
| Sistema (`/`, sem o `/home`) | Timeshift (rsync) | `timeshift/snapshots/` | pacotes, `/etc`, boot |
| `/home` | restic (cifrado) | `nexodev-backup/restic-home/` | seus arquivos e configurações |

A senha do restic está no seu gerenciador de senhas (e em `~/.config/nexodev/restic-password` enquanto o SSD estiver vivo).

## Um módulo deu errado, o sistema ainda inicia

```bash
sudo timeshift --restore
```

Escolha o snapshot "NexoDev M0" (ou o automático tirado antes do módulo). O `/home` não é tocado.

## Recuperar arquivos do /home

```bash
./backup/backup.sh status
```

Depois, com as variáveis do repositório:

```bash
export RESTIC_REPOSITORY=/media/$USER/sec/nexodev-backup/restic-home RESTIC_PASSWORD_FILE=~/.config/nexodev/restic-password
```

```bash
restic restore latest --target /tmp/restaurado --include "$HOME/Documents"
```

Para navegar no backup como uma pasta: `restic mount ~/backup-montado`.

## O sistema não inicia ou o SSD morreu

1. Inicie pelo pendrive live do Mint e conecte o HDD.
2. Sistema: o Timeshift do live (`sudo timeshift --restore`) restaura o snapshot no SSD (novo ou formatado) e reinstala o GRUB.
3. `/home`: no live, `sudo apt install restic`. Com o HDD montado:

```bash
restic -r /media/mint/sec/nexodev-backup/restic-home restore latest --target /
```

   (a senha é pedida; use a do gerenciador de senhas). Depois: `sudo chown -R 1000:1000 /home/matheusdev`.
4. Pacotes de uma instalação limpa: `~/.local/state/nexodev/system-state/` tem `dpkg-selections.txt`, `apt-manual.txt`, repositórios, Flatpaks e serviços ativos.
