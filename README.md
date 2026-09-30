# ORACLE RECOVERY BRABO

Orquestrador de Backup, Restore e Recovery Oracle para Unix.

**Estado: v1.3** — 14 áreas, 226 opções de menu, 320 funções, ~11.400 linhas
de shell POSIX. Sintaxe validada em `ksh` e `sh`,
smoke test navegando todos os menus, e dois testes próprios que checam o SQL
gerado. Ainda **não** foi executado contra um banco Oracle real. Leia a seção
"Antes de usar em produção" antes de apontar isso para qualquer coisa que
importe.

---

## Princípio fundamental

```
DISCOVER → VALIDATE → PLAN → SHOW COMMANDS → SHOW RISKS
         → CONFIRM → EXECUTE → POST-CHECK → REPORT
```

Nunca `DISCOVER → EXECUTE`.

Nenhuma operação que altera estado roda sem que você tenha visto antes o
comando RMAN/SQL/SRVCTL exato e os riscos daquilo. Um módulo de operação não
chama `rman` diretamente para mudar estado — ele descreve o plano, e o engine
executa. É isso que faz o `--dry-run` funcionar de graça e o `--generate`
produzir script fiel ao que seria executado.

---

## Origem

Este framework nasceu de um incidente real de restore de standby. Vários
comportamentos aqui não são teoria — são cicatriz:

| O que aconteceu | O que o framework faz |
|---|---|
| Script avaliava estado do banco por `grep` na saída do `srvctl`. Com o CRS fora, o `srvctl` devolvia **erro**, o grep não casava, e o script concluía "banco parado" — e seguia para um `chown -R`. | `orb_instance_state` devolve `UNKNOWN` como estado distinto de `DOWN`. Indeterminado **aborta**. |
| `RESTORE`/`RECOVER` conectavam sem catálogo. O controlfile só guardava 7 dias, o RMAN via incrementais sem o nível 0 pai, e tentou **criar** o datafile 1 → `ORA-01180`. | Catálogo em todas as conexões; `orb_require_catalog` explica exatamente esse risco antes de deixar seguir sem ele. |
| `RESET DATABASE TO INCARNATION` recebeu o **Reset SCN** em vez do **Inc Key** → `RMAN-20010`. | Módulo de incarnation lista do catálogo, explica a diferença, e exige confirmação mostrando o que muda. |
| `RESTORE ... VALIDATE HEADER` passou listando tudo como `AVAILABLE`. Minutos depois o restore falhou: as fitas de 17 meses atrás tinham expirado. | O módulo de validação diz, em texto, que `PREVIEW` e `VALIDATE HEADER` consultam o **repositório** e não provam nada sobre a mídia. Só `RESTORE ... VALIDATE` lê a mídia. |
| Um banco de 7 TB passou **17 meses sem backup nível 0**. Os incrementais rodaram "com sucesso" o tempo todo. Só se descobriu no dia do restore. | `--health`. É a operação mais barata do framework e a única que teria evitado o incidente. |
| **Bug do próprio framework, achado na v1.3:** sem TTY (cron sem flag, pipe, `ssh` sem `-t`), o `read` do menu devolvia EOF, o código ignorava o status, nenhuma opção casava e o menu se redesenhava **para sempre** — um log cresceu até 109 MB. A ferramenta de resolver incidente virava o incidente: num servidor de banco isso enche `/var` ou a FRA. | `orb_ask`, `orb_pause` e `orb_confirm` propagam o EOF e travam `ORB_EOF`; todo laço de menu encerra com `\|\| return 0`; `orb_menu_begin` tem parada dura (`exit 3`); e o menu se recusa a abrir sem TTY. |
| **Bug do próprio framework, achado na v1.2:** 69 consultas escreviam `v\\$instance` fora de crase. O shell come o nome da view e o SQL vira `from v\`. Efeito: todo campo viraria `<não detectado>` — o framework ficaria **cego sem avisar que estava cego**. | `scripts/orb_sqlcheck.sh` (sqlplus falso que grava o SQL gerado) e o check de escape dentro do `--selftest`. Ver "O erro que não aparece". |

---

## O erro que não aparece

Em shell, dentro de aspas duplas:

```sh
"select status from v\$instance"      →  v$instance     CORRETO
"select status from v\\$instance"     →  v\             ERRADO
```

Mas **dentro de crase o número de barras inverte**:

```sh
X=`f "... from v\\$instance"`         →  v$instance     CORRETO
X=`f "... from v\$instance"`          →  v              ERRADO
```

Essa diferença não aparece em `sh -n`, não aparece em revisão visual, não
aparece em teste de menu. Aparece na primeira execução contra um banco de
verdade — e o sintoma é o pior possível: **tudo funciona, nada falha, e todo
campo volta vazio.** Um framework de recovery cego que não sabe que está cego
é pior que script nenhum.

A v1.2 tinha 69 dessas. Duas defesas foram escritas para que não volte:

```sh
sh scripts/orb_sqlcheck.sh    # sobe um sqlplus FALSO, grava o SQL realmente
                              # gerado, e procura view truncada
./orb.sh --selftest           # inclui o check estático de escape em todos
                              # os módulos (conta crases, cobra as barras)
```

O check estático pegou 4 erros novos poucos minutos depois de ter sido
escrito — introduzidos por mim, no mesmo dia. Vale a pena rodar os dois
sempre que mexer em qualquer consulta.

**Regra para quem for mexer:**

| Contexto | Escrever |
|---|---|
| Fora de crase — `orb_sql_query "..."` seguido de pipe | `v\$view` (uma barra) |
| Dentro de crase — ``_x=`orb_sql_value "..."` `` | `v\\$view` (duas barras) |

Crase dentro de crase é proibida no projeto: passa no `ksh`, quebra no `sh`.
Calcule em variável antes de compor.

---

## Instalação

Do repositório:

```sh
git clone https://github.com/acaciolr/oracle-recovery-database-framework.git
cd oracle-recovery-database-framework
```

Do tarball, que é como ele costuma chegar no servidor de banco:

```sh
tar xzf oracle-recovery-brabo-<versao>.tar.gz
cd oracle-recovery-brabo
chmod 755 orb.sh
```

Transferência: use **SFTP/scp**, não copy-paste de terminal. Confira o
`cksum` contra o `CKSUM.txt` antes de usar — servidor Unix raramente tem o
`git` do lado de dentro, e o caminho real até lá é quase sempre um arquivo
copiado à mão.

Edite `conf/orb.conf` (catálogo, perfil de mídia, limites do health) e
`conf/media.conf` (parâmetros do seu media manager).

`conf/media.conf` vem com os perfis de exemplo usando placeholders
(`<client>`, `<master>`, `<host>`). **Instalação nova reprova no `--selftest`
até você preenchê-los** — é de propósito: um `SEND` com `<master>` literal só
falharia no dia do restore. Preencha o perfil que você usa ou apague os que
não usa.

```sh
chmod 600 conf/orb.conf     # se houver senha de catálogo
```

---

## Uso

```sh
./orb.sh                      # menu interativo
./orb.sh --selftest           # integridade do pacote e do ambiente
./orb.sh --discover           # inventário do ambiente (só leitura)
./orb.sh --health             # saúde do backup deste banco (cron)
./orb.sh --fleet              # saúde de TODOS os bancos do catálogo (cron)
./orb.sh --drill              # simulado de restore lendo a mídia
./orb.sh --dry-run            # menu, mas sem executar nada
./orb.sh --generate           # grava os scripts em scripts/, não executa

./orb.sh --sid ECP001 --profile NETBACKUP --health
./orb.sh --color --utf8       # bordas e cores em terminal moderno
./orb.sh --ascii              # força ASCII (console HMC/ILO/serial)
```

### Menu exige terminal

O menu interativo só abre com um TTY. Sem ele — `cron` sem flag de ação, pipe,
`ssh host './orb.sh'` sem `-t`, stdin em `/dev/null` — o programa sai na hora
com `rc=2` e diz qual ação não interativa você provavelmente queria. Quem
realmente precisa alimentar o menu por pipe usa `ORB_ALLOW_NOTTY=Y`; o EOF
continua encerrando com elegância, agora com `rc=3`.

Isso não é preciosismo: até a v1.2 esse cenário era um laço infinito gravando
log até encher o filesystem. Ver "Origem".

### Interface

Três capacidades são detectadas em runtime, nunca assumidas: largura
(`tput cols` → `stty` → `COLUMNS` → 80), cor (probe real de `tput setaf`) e
charset (UTF-8 só com locale compatível **e** opt-in). Sem cor e sem UTF-8 o
layout continua alinhado — bordas viram `+ - |`. O cálculo de padding ignora
sequências ANSI, então linha colorida não desalinha a moldura.

Itens de menu que alteram o estado do banco saem em vermelho; leitura sai em
ciano. Numa madrugada de incidente, essa é a diferença entre apertar 20 e
apertar 2.

### O menu

A v1.1 era uma lista única de 28 itens, e já estava mentindo sobre onde as
coisas ficavam: `RESTORE PLUGGABLE DATABASE` morava dentro do submenu PDB, que
por sua vez morava no grupo RECOVERY. Para **restaurar** um PDB era preciso
entrar em "recovery". Isso é falha de organização, não de funcionalidade — e
organização errada, às três da manhã, custa tempo.

A v1.2 é hierárquica, com 14 destinos:

```
 1 RESTORE       trazer arquivos de volta do backup
 2 RECOVERY      aplicar redo, PITR, tabela, bloco
 3 POS-RESTORE   o que falta depois que o restore termina
 4 PDB / CDB     multitenant: restore, plug, clone
 5 DATA GUARD    standby, switchover, failover
 6 FLASHBACK     voltar no tempo sem restore
 7 DUPLICATE     clonar banco ou criar standby
 8 TRANSPORTE    TTS, cross-platform, migração
 9 DATA PUMP     recuperação lógica: schema, tabela, DDL
10 BACKUP        gerar backup
11 CATALOGO      catálogo, crosscheck, retenção
12 GRID / ASM    clusterware, OCR, voting, diskgroup
13 DIAGNOSTICO   saúde, frota, simulado, validação
14 AMBIENTE      inventário, canais, modo, autoteste
```

A mesma operação aparece em mais de um lugar quando isso ajuda. RESTORE traz
PDB, `CDB$ROOT`/`PDB$SEED`, restore por TAG, até SCN/TIME/SEQUENCE e para outro
host — tudo na primeira tela, sem submenu escondido.

RECOVERY tem uma opção que não executa nada: **"Sumiu um objeto? escolha o
caminho certo"**. Ela lista os seis caminhos do menos para o mais invasivo
(flashback query → flashback drop → sqlfile do Data Pump → `RECOVER TABLE` →
TSPITR → PITR do banco) e mostra `flashback_on`, `undo_retention` e
`recyclebin` do banco atual — porque se o undo não cobre o horário do estrago,
os dois primeiros caminhos já estão fora e não adianta tentar.

### No cron

```
# saúde deste banco, toda segunda
0 6 * * 1  /opt/orb/orb.sh --sid ECP001 --health >> /var/log/orb_health.log 2>&1

# saúde da FROTA inteira pelo catálogo, todo dia
0 7 * * *  /opt/orb/orb.sh --fleet >> /var/log/orb_fleet.log 2>&1

# simulado mensal - o único teste que prova que a mídia responde
0 2 1 * *  /opt/orb/orb.sh --sid ECP001 --drill --yes >> /var/log/orb_drill.log 2>&1
```

`--fleet` é o que encontra o problema antes do dia do restore: pergunta ao
catálogo, de uma vez, quando foi o último nível 0 de **cada** database
registrado, e ordena do mais antigo para o mais novo. O banco esquecido
aparece na primeira linha.

Retorno: `0` saudável, `1` avisos, `2` crítico. Configure `ORB_HEALTH_MAIL`
em `conf/orb.conf` para receber alerta quando não for 0.

---

## Estrutura

```
oracle-recovery-brabo/
├── orb.sh                  programa principal e menu
├── conf/
│   ├── orb.conf            configuração global
│   └── media.conf          perfis de media manager
├── lib/
│   ├── compat.sh           portabilidade Unix (sem GNU coreutils)
│   ├── lock.sh             exclusão mútua por database (mkdir atômico)
│   ├── logging.sh          log operacional + trilha de auditoria + redact
│   ├── ui.sh               caixas, menus, confirmação forte
│   ├── sqlplus.sh          wrapper SQL*Plus
│   ├── rman.sh             wrapper RMAN
│   ├── channels.sh         canais e media manager
│   ├── discover.sh         descoberta do ambiente
│   ├── validate.sh         precheck
│   ├── engine.sh           EXECUTION ENGINE
│   └── diag.sh             dicionário de erros ORA/RMAN
├── ops/
│   ├── selftest.sh         integridade do pacote e do ambiente
│   ├── fleet.sh            saúde de todos os bancos do catálogo
│   ├── drill.sh            simulado de restore (lê a mídia)
│   ├── backup_health.sh    saúde do backup
│   ├── backup_info.sh      descoberta de backups + incarnation
│   ├── validate_backup.sh  preview / validate header / validate mídia
│   ├── restore_database.sh restore, recover, cold restore, FROM SERVICE
│   ├── restore_parts.sh    controlfile, spfile, datafile, tablespace,
│   │                       archivelog, block media recovery
│   ├── restore_advanced.sh USING BACKUP CONTROLFILE, UNTIL CANCEL, outro host,
│   │                       por TAG, até SCN/TIME/SEQUENCE, NOARCHIVELOG,
│   │                       mover datafile entre diskgroups, SYSTEM/UNDO
│   ├── pitr.sh             DBPITR, TSPITR, table recovery
│   ├── postrestore.sh      RESETLOGS, tempfiles, password file, wallet TDE,
│   │                       BCT, consistência, voltar datafiles online
│   ├── backup.sh           nível 0/1, full, tablespace, datafile, archivelog,
│   │                       for duplicate, incremental merge, KEEP FOREVER
│   ├── catalog.sh          register/resync/upgrade, crosscheck, expired,
│   │                       obsolete, retenção, autobackup, BCT
│   ├── duplicate.sh        standby / clone × active / backup / location,
│   │                       UNTIL, duplicate de PDB, clone local de PDB
│   ├── dataguard.sh        status, MRP, gap, SRL, broker, snapshot standby,
│   │                       switchover, failover, reinstate, checklist
│   ├── flashback.sh        database, table, drop, query, transaction, FDA,
│   │                       restore points, FRA, retention
│   ├── pdb.sh              restore, recover, PITR, restore parcial, unplug,
│   │                       plug, flashback de PDB, CDB$ROOT / PDB$SEED
│   ├── tts.sh              transportable tablespace, RMAN CONVERT,
│   │                       TRANSPORT TABLESPACE do backup, XTTS,
│   │                       full transportable
│   ├── datapump.sh         export/import de schema e tabela, sqlfile,
│   │                       network_link, flashback_scn, jobs
│   └── gridasm.sh          clusterware, OCR, voting disk, spfile do ASM,
│                           md_backup/md_restore, diskgroups, rebalance
├── scripts/
│   └── orb_sqlcheck.sh     sqlplus falso: confere o SQL realmente gerado
└── logs/                   logs e diretórios de execução
```

---

## Compatibilidade

POSIX shell. Roda em `sh`, `ksh` e `bash`. Sem `[[ ]]`, sem `local`, sem
arrays, sem `$(())` obrigatório.

`lib/compat.sh` cobre as diferenças que mordem em Unix não-Linux:

- `date +%s` com fallback para `perl` (AIX antigo)
- `readlink -f` inexistente → `orb_realpath`
- `sed -i` inexistente em AIX/Solaris → `orb_sed_replace`
- `grep '\|'` não funciona como alternação no AIX → `orb_grep_any`
- saída de `df` diferente por plataforma → `orb_free_mb`

Testado quanto a sintaxe em Linux com `ksh` e `sh`. **Não testado em execução
em AIX/Solaris/HP-UX.**

---

## Segurança

- Senhas nunca vão para log: `orb_log_redact` filtra `user/senha@tns`,
  `catalog user/senha` e `sys/senha as sysdba` em toda saída.
- `DUPLICATE` **não** executa com senha na linha de comando. O framework monta
  o cmdfile e mostra o comando para você rodar à mão.
- Trilha de auditoria em `logs/*.audit`, pipe-delimited:
  `timestamp|usuário|host|sid|ação|comando|rc|duração`.
- Prefira wallet ou autenticação de SO para o catálogo.

---

## Antes de usar em produção

Isto é v1.2 de um framework que ainda não tocou um banco real. Sequência
sugerida:

0. **`sh scripts/orb_sqlcheck.sh`** e **`./orb.sh --selftest`**. Levam
   segundos e provam que o pacote chegou inteiro e que o SQL gerado está
   íntegro.
1. **`--discover`** em um ambiente de teste. Confira campo a campo se o que
   ele detectou bate com a realidade. Qualquer `<não detectado>` é um ponto a
   investigar antes de confiar no resto.
2. **`--health`** no mesmo ambiente. Compare com o que você sabe do backup de
   lá.
3. **`--dry-run`** em cada operação que você pretende usar. Leia os comandos
   gerados como se fosse revisar o script de outra pessoa. É exatamente isso.
4. **`--generate`** e execute o script à mão, uma vez, acompanhando.
5. Só então `EXECUTE`, e ainda assim primeiro em não-produção.

Um framework de recovery que nunca foi exercitado é mais perigoso que script
nenhum, porque dá confiança falsa. Foi assim que o `VALIDATE HEADER` enganou a
gente.

---

## O que entrou na v1.3

- **Correção do laço infinito no EOF** — a única mudança de comportamento, e a
  mais importante até aqui. Ver "Origem" e "Menu exige terminal".
  `orb_ask` e `orb_pause` agora propagam o status do `read`; `orb_confirm`
  trata EOF como **cancelamento** (EOF nunca vale como confirmação); os 17
  laços de menu encerram com `|| return 0`; `orb_menu_begin` sai com `rc=3` se
  algum laço escapar; e o menu recusa abrir sem TTY (`rc=2`).
- **`templates/` removida** — diretório vazio que nenhum arquivo do projeto
  referenciava. Os scripts de `--generate` sempre foram para `scripts/`.
- **Repositório** — `.gitignore`, `CHANGELOG.md` e `LICENSE`. `logs/`,
  `scripts/*.sh` gerados e tarballs ficam fora do versionamento.

## O que entrou na v1.2

- **Menu hierárquico** com 14 destinos (era lista única de 28 itens)
- **`ops/backup.sh`** — fecha o ciclo: o health detectava "sem nível 0 há 17
  meses" mas não sabia rodar um
- **`ops/catalog.sh`** — catálogo, crosscheck, expired/obsolete, retenção
- **`ops/postrestore.sh`** — inclusive **tempfiles**, o buraco clássico que
  gera `ORA-25153` na primeira query com sort depois de um restore
- **`ops/restore_advanced.sh`** — outro host, TAG, SCN/TIME/SEQUENCE,
  `USING BACKUP CONTROLFILE`, NOARCHIVELOG, mover datafile entre diskgroups
- **`ops/tts.sh`** — transportable tablespace, `RMAN CONVERT` cross-platform
  (AIX big endian → Linux little endian é conversão real de bloco), XTTS,
  full transportable
- **`ops/datapump.sh`** — recuperação lógica, com a árvore de decisão de qual
  caminho é o menor estrago
- **`ops/gridasm.sh`** — a camada que nenhum backup RMAN cobre: OCR, voting
  disk, spfile do ASM, `md_backup`/`md_restore`, diskgroups
- **Data Guard** ganhou snapshot standby, switchover, failover, reinstate,
  broker e checklist pré-switchover
- **PDB** ganhou unplug/plug, flashback, restore parcial e `CDB$ROOT`/`PDB$SEED`
- **Flashback** ganhou FRA, flashback query/versions/transaction e gestão de
  restore points
- **Testes de escape de SQL** (ver "O erro que não aparece") e **guarda de CR**
  no boot: um pacote que veio do Windows agora falha com mensagem clara e o
  comando de correção, em vez de `not found` numa linha visivelmente correta

## O que ainda não existe (roadmap, em ordem de valor)

1. **Execução contra um banco real.** Nada abaixo importa antes disso.
2. **Notificação estruturada** — saída `--json`/key=value para Zabbix, Nagios
   ou Grafana. Hoje é exit code + mailx.
3. **Checkpoint e resume** — restore de 8 h que morre na hora 6 recomeça do
   zero. O RMAN é retomável; o framework ainda não sabe disso.
4. **Evidence pack** — bundle único (plano + comandos + log + auditoria) para
   change management depois de cada operação.
5. **Orquestração multi-node** — hoje cada node roda o seu.

## O que não está no escopo

- Execução remota multi-node — cada node roda o seu
- Operações de Grid que exigem root: o framework **mostra** o roteiro e o
  comando completo, mas não escala privilégio sozinho
- `dgmgrl` como executor: com broker ligado, o módulo de Data Guard **recusa**
  fazer switchover por SQL e manda você para o `dgmgrl` — fazer por SQL com
  broker ativo deixa a configuração inconsistente

---

## Convenções para quem for mexer

- Toda função pública tem prefixo `orb_`; variáveis internas começam com `_`.
- Nada inventa valor. Se não deu para descobrir, a variável fica vazia e o
  campo aparece como `<não detectado>`.
- Código tolerado no RMAN é declarado **por passo**, nunca global.
  `RMAN-06054` é fim normal de recover de standby e é falha em qualquer outro
  lugar.
- Operação nova = arquivo em `ops/`, função `orb_op_<nome>`, e o ciclo
  `orb_plan_begin` → `orb_plan_field`/`orb_plan_cmd`/`orb_plan_risk` →
  `orb_plan_confirm` → `orb_exec_*` → `orb_postcheck_*`.
- Nenhum módulo de operação conhece media manager. Ele pede o bloco de canais
  ao `channels.sh`.
