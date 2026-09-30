# Changelog

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/).
Este projeto usa versionamento `MAJOR.MINOR`.

---

## [1.3] - 2026-09-30

### Corrigido

- **Laço infinito do menu no fim de stdin (EOF).** `orb_ask` e `orb_pause`
  descartavam o status do `read`. Sem TTY — `cron` sem flag de ação, pipe,
  `ssh host './orb.sh'` sem `-t`, stdin em `/dev/null` — o `read` falhava, a
  resposta caía no default vazio, nenhuma opção do `case` casava e o menu se
  redesenhava indefinidamente, gravando log até encher o filesystem. Num
  servidor de banco isso derruba `/var` ou a FRA: a ferramenta de resolver
  incidente causando o incidente. Um log real do projeto chegou a **109 MB**
  com 13.890 redesenhos do menu principal.

  Correção em quatro camadas:

  1. `orb_ask` e `orb_pause` propagam o status do `read` e travam a flag
     `ORB_EOF`; depois do EOF todo prompt devolve 1 na hora, sem imprimir.
  2. `orb_confirm` trata EOF como **cancelamento** — EOF nunca vale como
     confirmação de operação destrutiva.
  3. Os 17 laços de menu (`orb.sh` e 12 módulos de `ops/`) encerram com
     `|| return 0` (`|| break` no laço principal).
  4. `orb_menu_begin` tem parada dura: menu montado depois do EOF sai com
     `rc=3`. É a última linha de defesa se algum laço futuro esquecer o guard.

### Adicionado

- **Guarda de terminal.** O menu interativo recusa abrir quando stdin não é um
  TTY, saindo com `rc=2` e listando as ações não interativas (`--health`,
  `--fleet`, `--drill`, `--discover`, `--selftest`) — que é o que quase sempre
  se queria no crontab. `ORB_ALLOW_NOTTY=Y` libera para quem realmente precisa
  alimentar o menu por pipe.
- `.gitignore`, `CHANGELOG.md` e `LICENSE`.

### Alterado

- Novos códigos de retorno: `2` uso incorreto (inclui menu sem TTY), `3` EOF
  durante o menu.
- `README.md`: seções "Menu exige terminal" e "O que entrou na v1.3"; nota
  sobre os placeholders obrigatórios do `conf/media.conf`.
- `CKSUM.txt` regenerado.

### Removido

- Diretório `templates/`, vazio e não referenciado por nenhum arquivo do
  projeto. Os scripts de `--generate` sempre foram para `scripts/`.

---

## [1.2] - 2026-08-26

### Adicionado

- Menu hierárquico com 14 destinos (era lista única de 28 itens).
- `ops/backup.sh` — nível 0/1, full, tablespace, datafile, archivelog,
  for duplicate, incremental merge, KEEP FOREVER.
- `ops/catalog.sh` — register/resync/upgrade, crosscheck, expired, obsolete,
  retenção, autobackup, BCT.
- `ops/postrestore.sh` — RESETLOGS, tempfiles, password file, wallet TDE, BCT.
- `ops/restore_advanced.sh` — outro host, TAG, SCN/TIME/SEQUENCE,
  `USING BACKUP CONTROLFILE`, NOARCHIVELOG, mover datafile entre diskgroups.
- `ops/tts.sh` — transportable tablespace, `RMAN CONVERT` cross-platform,
  XTTS, full transportable.
- `ops/datapump.sh` — recuperação lógica com árvore de decisão.
- `ops/gridasm.sh` — OCR, voting disk, spfile do ASM, `md_backup`/`md_restore`,
  diskgroups.
- Data Guard: snapshot standby, switchover, failover, reinstate, broker,
  checklist pré-switchover.
- PDB: unplug/plug, flashback, restore parcial, `CDB$ROOT`/`PDB$SEED`.
- Flashback: FRA, flashback query/versions/transaction, restore points.
- `scripts/orb_sqlcheck.sh` e check estático de escape no `--selftest`.
- Guarda de CR no boot: pacote vindo do Windows falha com mensagem clara.

### Corrigido

- **69 consultas com `v\$view` escapado errado dentro de crase.** O shell
  truncava o nome da view e todo campo voltava vazio — o framework ficava
  cego sem avisar que estava cego.

---

## [1.1] - 2026-08

### Adicionado

- Lista única de 28 operações, ciclo DISCOVER → VALIDATE → PLAN → CONFIRM →
  EXECUTE → POST-CHECK, modos `--dry-run` e `--generate`.
