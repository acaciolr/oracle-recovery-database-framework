#!/usr/bin/sh
###############################################################################
#
#   ORACLE RECOVERY BRABO  1.3
#
#   Orquestrador de Backup, Restore e Recovery Oracle.
#
#   PRINCIPIO FUNDAMENTAL
#
#       DISCOVER -> VALIDATE -> PLAN -> SHOW COMMANDS -> SHOW RISKS
#                -> CONFIRM -> EXECUTE -> POST-CHECK -> REPORT
#
#       Nunca DISCOVER -> EXECUTE.
#
#   Uso:
#       ./orb.sh                    menu interativo
#       ./orb.sh --selftest         integridade do pacote e do ambiente
#       ./orb.sh --discover         inventario (so leitura)
#       ./orb.sh --health           saude do backup deste banco (cron)
#       ./orb.sh --fleet            saude de TODOS os bancos do catalogo (cron)
#       ./orb.sh --drill            simulado de restore lendo a midia
#
#   Opcoes:
#       --sid <SID>          --home <PATH>       --profile <NOME>
#       --channels <N>       --catalog <conn>
#       --dry-run            --generate          --yes
#       --color              --utf8 / --ascii    --no-lock
#       --version            --help
#
#   Codigos de retorno de --health e --fleet:
#       0 saudavel   1 avisos   2 critico
#
#   Ambiente:
#       ORB_ALLOW_NOTTY=Y    permite abrir o menu sem TTY (pipe)
#
#   Outros codigos de retorno:
#       2 uso incorreto (inclusive menu sem TTY)   3 EOF durante o menu
#
###############################################################################

ORB_VERSION="1.3"

_self="$0"
case "$_self" in
    /*) ORB_HOME=`dirname "$_self"` ;;
    *)  _cwd=`pwd` ; ORB_HOME=`dirname "$_cwd/$_self"` ;;
esac
ORB_HOME=`cd "$ORB_HOME" 2>/dev/null && pwd`
[ -n "$ORB_HOME" ] || { echo "FATAL: nao consegui determinar a raiz do projeto." ; exit 1 ; }

ORB_LIB="$ORB_HOME/lib"
ORB_OPS="$ORB_HOME/ops"
ORB_CONF="$ORB_HOME/conf"

# ---------------------------------------------------------------------------
# Guarda de transferencia.
#
# Este pacote costuma viajar de Windows para AIX. Um unico CR sobrando faz o
# shell morrer com "not found" numa linha que esta visivelmente correta, e o
# DBA perde meia hora procurando erro de sintaxe onde nao ha.
# Detectar isso ANTES de carregar custa uma comparacao por arquivo.
# ---------------------------------------------------------------------------
_orb_boot_cr()
{
    tr -d '\015' < "$1" | cmp -s - "$1" && return 1
    return 0
}

for _m in compat logging ui sqlplus rman channels discover validate engine diag lock
do
    if [ ! -f "$ORB_LIB/$_m.sh" ]; then
        echo "FATAL: modulo ausente: $ORB_LIB/$_m.sh"
        echo "O pacote esta incompleto - verifique a transferencia (cksum)."
        exit 1
    fi
    if _orb_boot_cr "$ORB_LIB/$_m.sh"; then
        echo "FATAL: $ORB_LIB/$_m.sh tem CR (fim de linha do Windows)."
        echo "Corrija todos os arquivos de uma vez:"
        echo "    cd $ORB_HOME"
        echo "    for f in orb.sh lib/*.sh ops/*.sh scripts/*.sh"
        echo "    do"
        printf '%s\n' '        tr -d "\015" < "$f" > "$f.tmp" && mv "$f.tmp" "$f"' 
        echo "    done"
        exit 1
    fi
    . "$ORB_LIB/$_m.sh"
done

for _m in selftest fleet drill backup_health backup_info validate_backup \
          restore_database restore_parts restore_advanced pitr postrestore \
          duplicate dataguard flashback pdb backup catalog tts datapump gridasm
do
    [ -f "$ORB_OPS/$_m.sh" ] || continue
    if _orb_boot_cr "$ORB_OPS/$_m.sh"; then
        echo "AVISO: ops/$_m.sh tem CR (Windows) - modulo NAO carregado."
        continue
    fi
    . "$ORB_OPS/$_m.sh"
done

[ -f "$ORB_CONF/orb.conf" ] && . "$ORB_CONF/orb.conf"

# ---------------------------------------------------------------------------
ORB_ACTION=""
ORB_ASSUME_YES="${ORB_ASSUME_YES:-N}"
ORB_USE_LOCK="Y"

while [ $# -gt 0 ]
do
    case "$1" in
        --sid)      shift ; ORACLE_SID="$1"  ; export ORACLE_SID ;;
        --home)     shift ; ORACLE_HOME="$1" ; export ORACLE_HOME ;;
        --profile)  shift ; ORB_MEDIA_PROFILE="$1" ;;
        --channels) shift ; ORB_CHANNELS="$1" ;;
        --catalog)  shift ; ORB_CATALOG_CONNECT="$1" ;;
        --dry-run)  ORB_MODE="DRYRUN" ;;
        --generate) ORB_MODE="GENERATE" ;;
        --yes)      ORB_ASSUME_YES="Y" ;;
        --color)    ORB_COLOR="Y" ;;
        --utf8)     ORB_UI_UTF8="Y" ;;
        --ascii)    ORB_UI_UTF8="N" ;;
        --no-lock)  ORB_USE_LOCK="N" ;;
        --selftest) ORB_ACTION="selftest" ;;
        --health)   ORB_ACTION="health" ;;
        --fleet)    ORB_ACTION="fleet" ;;
        --drill)    ORB_ACTION="drill" ;;
        --discover) ORB_ACTION="discover" ;;
        --version)  echo "ORACLE RECOVERY BRABO $ORB_VERSION" ; exit 0 ;;
        --help|-h)  sed -n '2,32p' "$0" | sed 's/^#//' ; exit 0 ;;
        *)          echo "Opcao desconhecida: $1" ; echo "Use --help." ; exit 2 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Guarda de terminal.
#
# O menu interativo so faz sentido com um TTY. Sem ele (cron sem flag, pipe,
# ssh sem -t, stdin vindo de /dev/null) todo prompt le EOF na hora. A partir
# da v1.3 isso e tratado e o programa sai, mas sair ANTES de abrir log, criar
# rundir e rodar discovery e mais barato e a mensagem e mais util: quase
# sempre quem cai aqui queria --health, --fleet ou --drill no crontab.
#
# ORB_ALLOW_NOTTY=Y libera, para quem realmente quer alimentar o menu por
# pipe. O EOF continua encerrando com elegancia.
# ---------------------------------------------------------------------------
if [ -z "$ORB_ACTION" ] && [ ! -t 0 ] && [ "${ORB_ALLOW_NOTTY:-N}" != "Y" ]; then
    echo "FATAL: o menu interativo exige um terminal, e stdin nao e um TTY." >&2
    echo "" >&2
    echo "Para uso nao interativo (cron, script, ssh sem -t) use uma acao:" >&2
    echo "    $0 --health      saude do backup deste banco" >&2
    echo "    $0 --fleet       saude de todos os bancos do catalogo" >&2
    echo "    $0 --drill       simulado de restore" >&2
    echo "    $0 --discover    inventario, so leitura" >&2
    echo "    $0 --selftest    integridade do pacote" >&2
    echo "" >&2
    echo "Se voce realmente quer alimentar o menu por pipe:" >&2
    echo "    ORB_ALLOW_NOTTY=Y $0" >&2
    exit 2
fi

case "$ORB_LOGDIR" in    /*) : ;; *) ORB_LOGDIR="$ORB_HOME/$ORB_LOGDIR" ;; esac
case "$ORB_SCRIPTDIR" in /*) : ;; *) ORB_SCRIPTDIR="$ORB_HOME/$ORB_SCRIPTDIR" ;; esac

orb_log_init "$ORB_LOGDIR" "orb" || exit 1
ORB_RUNDIR="$ORB_LOGDIR/run_`orb_timestamp`_$$"
mkdir -p "$ORB_RUNDIR" 2>/dev/null || { echo "FATAL: nao criei $ORB_RUNDIR" ; exit 1 ; }
mkdir -p "$ORB_SCRIPTDIR" 2>/dev/null

orb_ui_init
orb_media_load "$ORB_CONF/media.conf" "$ORB_MEDIA_PROFILE"

# ---------------------------------------------------------------------------
orb_splash()
{
    orb_log_raw ""
    orb_box_top
    _s1=`printf '%s%s%s   %s' "$C_BOLD$C_CYA" 'ORACLE RECOVERY BRABO' "$C_OFF" "$ORB_VERSION"`
    orb_box_row "$_s1"
    orb_box_row "Backup - Restore - Recovery - Data Guard - Flashback - Transporte"
    orb_box_bot
}

orb_splash
orb_log "modo=$ORB_MODE  raiz=$ORB_HOME"
orb_log "log=$ORB_LOG"

orb_discover_all

# ---------------------------------------------------------------------------
# resumo de saude para o cabecalho (uma consulta, cacheada)
# ---------------------------------------------------------------------------
ORB_HDR_STATE="info"
ORB_HDR_MSG="saude do backup nao avaliada"
orb_header_health()
{
    orb_sql_alive || { ORB_HDR_STATE="warn" ; ORB_HDR_MSG="instancia nao responde" ; return ; }
    _d=`orb_sql_value "(select to_char(round(sysdate - max(bs.completion_time)))
                          from v\\$backup_set bs, v\\$backup_datafile bd
                         where bs.set_stamp=bd.set_stamp and bs.set_count=bd.set_count
                           and bd.file#=1
                           and (bd.incremental_level=0 or bd.incremental_level is null))"`
    if [ -z "$_d" ]; then
        ORB_HDR_STATE="crit" ; ORB_HDR_MSG="NENHUM backup nivel 0 visivel"
    elif [ "$_d" -ge "${ORB_HEALTH_L0_CRIT_DAYS:-31}" ] 2>/dev/null; then
        ORB_HDR_STATE="crit" ; ORB_HDR_MSG="ultimo nivel 0 ha $_d dias"
    elif [ "$_d" -ge "${ORB_HEALTH_L0_WARN_DAYS:-8}" ] 2>/dev/null; then
        ORB_HDR_STATE="warn" ; ORB_HDR_MSG="ultimo nivel 0 ha $_d dias"
    else
        ORB_HDR_STATE="ok"   ; ORB_HDR_MSG="ultimo nivel 0 ha $_d dias"
    fi
}

# =============================================================================
# ACOES NAO INTERATIVAS
# =============================================================================
case "$ORB_ACTION" in
    selftest) orb_op_selftest ; exit $? ;;
    discover) orb_discover_show ; orb_precheck_summary ; exit 0 ;;
    health)   orb_op_backup_health ; exit $? ;;
    fleet)    orb_op_fleet ; exit $? ;;
    drill)
        if [ "$ORB_USE_LOCK" = "Y" ]; then
            orb_lock_acquire "${ORACLE_SID:-orb}" || exit 1
            orb_lock_trap
        fi
        orb_op_drill ; exit $?
        ;;
esac

# =============================================================================
# INTERATIVO
# =============================================================================
if [ "$ORB_USE_LOCK" = "Y" ]; then
    orb_lock_acquire "${ORACLE_SID:-orb}" || exit 1
    orb_lock_trap
fi

orb_header_health

orb_header()
{
    # Valores calculados ANTES da composicao. Aninhar crase dentro de crase
    # dentro de aspas passa no ksh e quebra no sh - nao vale o risco.
    case "$ORB_MODE" in
        EXECUTE)  _mcol="$C_GRN" ;;
        DRYRUN)   _mcol="$C_YEL" ;;
        GENERATE) _mcol="$C_CYA" ;;
        *)        _mcol="" ;;
    esac

    if [ "$ORB_D_RAC" = "Y" ]; then
        _nn=`echo $ORB_D_NODES | wc -w | tr -d ' '`
        [ "$_nn" = "0" ] && _arch="RAC" || _arch="RAC ($_nn nodes)"
    else
        _arch="SingleInstance"
    fi
    [ "$ORB_D_ASM" = "Y" ] && _stor="ASM" || _stor="Filesystem"
    orb_rman_has_catalog && _cat="SIM" || _cat="NAO"
    _med=`orb_media_summary`

    # Larguras derivadas da largura real do terminal. Fixar 48+34 estourava a
    # borda direita em qualquer console de 80 colunas - que e a maioria dos
    # consoles de HMC e sessao serial onde este script vai rodar.
    _tw=`expr $ORB_W - 4`
    if [ "$_tw" -ge 84 ]; then
        _w2=34
    else
        _w2=26
    fi
    _w1=`expr $_tw - $_w2`
    [ "$_w1" -lt 24 ] && _w1=24

    _c1_1=`orb_pad_cell "DATABASE  ${ORB_D_DBNAME:-?} / ${ORB_D_DBUNIQUE:-?}" $_w1`
    _c1_2=`orb_pad_cell "SID       ${ORACLE_SID:-?}"                          $_w1`
    _c1_3=`orb_pad_cell "VERSION   ${ORB_D_VERSION:-?}"                       $_w1`
    _c1_4=`orb_pad_cell "STORAGE   $_stor"                                    $_w1`
    _c1_5=`orb_pad_cell "MEDIA     $_med"                                     $_w1`

    _c2_1=`orb_pad_cell "STATUS   ${ORB_D_STATUS:-?}"  $_w2`
    _c2_2=`orb_pad_cell "ROLE     ${ORB_D_ROLE:-?}"    $_w2`
    _c2_3=`orb_pad_cell "MODO     $_arch"              $_w2`
    _c2_4=`orb_pad_cell "CDB      $ORB_D_CDB"          $_w2`
    _c2_5=`orb_pad_cell "CATALOG  $_cat"               $_w2`

    _tit=`printf '%s%s%s %s%s%s' "$C_BOLD$C_CYA" 'ORACLE RECOVERY BRABO' "$C_OFF" "$_mcol" "modo $ORB_MODE" "$C_OFF"`
    _bdg=`orb_badge $ORB_HDR_STATE`

    orb_log_raw ""
    orb_box_top
    orb_box_row "$_tit"
    orb_box_mid
    orb_box_row "${_c1_1}${_c2_1}"
    orb_box_row "${_c1_2}${_c2_2}"
    orb_box_row "${_c1_3}${_c2_3}"
    orb_box_row "${_c1_4}${_c2_4}"
    orb_box_row "${_c1_5}${_c2_5}"
    orb_box_mid
    orb_box_row "${_bdg}  BACKUP  $ORB_HDR_MSG"
    orb_box_bot
}

# ---------------------------------------------------------------------------
# MENU
#
# Hierarquico de proposito. A versao anterior era uma lista unica de 28 itens
# e ja estava mentindo sobre onde as coisas ficavam: RESTORE PLUGGABLE
# DATABASE morava dentro do submenu PDB, que por sua vez morava no grupo
# RECOVERY. Para restaurar um PDB era preciso entrar em "recovery".
#
# Aqui cada categoria e um destino, e a mesma operacao aparece em mais de um
# lugar quando isso ajuda. O menu serve ao DBA as tres da manha, nao a
# elegancia da arvore.
# ---------------------------------------------------------------------------
orb_home_item()
{
    # orb_home_item <n> <titulo> <descricao>
    _hn=`printf '%3s' "$1"`
    _ht=`orb_pad_cell "$2" 26`
    orb_log_raw "  ${C_BOLD}${C_CYA}${_hn}${C_OFF}  ${C_BOLD}${_ht}${C_OFF}${C_DIM}$3${C_OFF}"
}

orb_menu_home()
{
    orb_header
    orb_log_raw ""
    orb_log_raw "  ${C_BOLD}${C_BLU}O QUE VOCE PRECISA FAZER?${C_OFF}"
    orb_log_raw ""
    orb_home_item  1 "RESTORE"      "trazer arquivos de volta do backup"
    orb_home_item  2 "RECOVERY"     "aplicar redo, PITR, tabela, bloco"
    orb_home_item  3 "POS-RESTORE"  "o que falta depois que o restore termina"
    orb_log_raw ""
    orb_home_item  4 "PDB / CDB"    "multitenant: restore, plug, clone"
    orb_home_item  5 "DATA GUARD"   "standby, switchover, failover"
    orb_home_item  6 "FLASHBACK"    "voltar no tempo sem restore"
    orb_home_item  7 "DUPLICATE"    "clonar banco ou criar standby"
    orb_home_item  8 "TRANSPORTE"   "TTS, cross-platform, migracao"
    orb_home_item  9 "DATA PUMP"    "recuperacao logica: schema, tabela, DDL"
    orb_log_raw ""
    orb_home_item 10 "BACKUP"       "gerar backup"
    orb_home_item 11 "CATALOGO"     "catalogo, crosscheck, retencao"
    orb_home_item 12 "GRID / ASM"   "clusterware, OCR, voting, diskgroup"
    orb_log_raw ""
    orb_home_item 13 "DIAGNOSTICO"  "saude, frota, simulado, validacao"
    orb_home_item 14 "AMBIENTE"     "inventario, canais, modo, autoteste"
    orb_log_raw ""
    orb_home_item  0 "SAIR"         ""
    orb_log_raw ""
    orb_rule
}

orb_menu_hint()
{
    orb_log_raw ""
    orb_log_raw "  ${C_DIM}itens em vermelho alteram o estado do banco${C_OFF}"
}

# ---------------------------------------------------------------------------
# 1 - RESTORE
# ---------------------------------------------------------------------------
orb_menu_restore()
{
    while :
    do
        orb_title "RESTORE"
        orb_field "Instancia" "${ORB_D_STATUS:-?}"
        orb_field "Media"     "`orb_media_summary`"
        orb_log_raw ""

        orb_menu_begin
        orb_menu_group "O BANCO INTEIRO"
        orb_menu_add  1 "Database (restore + recover)"           danger
        orb_menu_add  2 "Cold restore - fluxo completo guiado"   danger
        orb_menu_add  3 "FROM SERVICE (direto do primary)"       danger
        orb_menu_add  4 "Restore para OUTRO HOST"                danger
        orb_menu_add  5 "Restore em NOARCHIVELOG"                danger

        orb_menu_group "PARTES DO BANCO"
        orb_menu_add  6 "Datafile"                               danger
        orb_menu_add  7 "Tablespace"                             danger
        orb_menu_add  8 "SYSTEM / UNDO"                          danger
        orb_menu_add  9 "Controlfile"                            danger
        orb_menu_add 10 "SPFILE"                                 danger
        orb_menu_add 11 "Archivelog"                             danger

        orb_menu_group "MULTITENANT"
        orb_menu_add 12 "PLUGGABLE DATABASE"                     danger
        orb_menu_add 13 "Datafile/tablespace dentro de um PDB"   danger
        orb_menu_add 14 "CDB ROOT / PDB SEED"                    danger

        orb_menu_group "ESCOLHENDO A ORIGEM E O PONTO"
        orb_menu_add 15 "Listar TAGs disponiveis"
        orb_menu_add 16 "Restore por TAG"                        danger
        orb_menu_add 17 "Restore ate SCN / TIME / SEQUENCE"      danger
        orb_menu_add 18 "Mover datafile entre diskgroups"        danger
        orb_menu_add  0 "Voltar"
        orb_menu_render
        orb_menu_hint

        orb_ask "Opcao" "" || return 0
        case "$ORB_ANSWER" in
            1)  orb_op_restore_database ;;
            2)  orb_op_cold_restore ;;
            3)  orb_op_restore_from_service ;;
            4)  orb_call_op orb_ra_other_host ;;
            5)  orb_call_op orb_ra_noarchivelog ;;
            6)  orb_op_restore_datafile ;;
            7)  orb_op_restore_tablespace ;;
            8)  orb_call_op orb_ra_system_undo ;;
            9)  orb_op_restore_controlfile ;;
            10) orb_op_restore_spfile ;;
            11) orb_op_restore_archivelog ;;
            12) orb_call_op orb_op_pdb_restore ;;
            13) orb_call_op orb_pdb_restore_part ;;
            14) orb_call_op orb_pdb_root_seed ;;
            15) orb_call_op orb_ra_list_tags ;;
            16) orb_call_op orb_ra_by_tag ;;
            17) orb_call_op orb_ra_until_point ;;
            18) orb_call_op orb_ra_move_datafile ;;
            0)  return 0 ;;
            "") continue ;;
            *)  orb_status_line warn "Opcao invalida." ;;
        esac
        orb_discover_instance 2>/dev/null
        orb_pause
    done
}

# ---------------------------------------------------------------------------
# 2 - RECOVERY
# ---------------------------------------------------------------------------
orb_menu_recovery()
{
    while :
    do
        orb_title "RECOVERY"
        orb_field "Instancia"   "${ORB_D_STATUS:-?}"
        orb_field "Log mode"    "${ORB_D_LOGMODE:-?}"
        orb_field "Controlfile" "${ORB_D_CFTYPE:-?}"
        orb_log_raw ""

        orb_menu_begin
        orb_menu_group "APLICAR REDO"
        orb_menu_add  1 "RECOVER DATABASE"                       danger
        orb_menu_add  2 "RECOVER USING BACKUP CONTROLFILE"       danger
        orb_menu_add  3 "RECOVER UNTIL CANCEL (manual)"          danger

        orb_menu_group "PONTO NO TEMPO"
        orb_menu_add  4 "PITR do banco inteiro"                  danger
        orb_menu_add  5 "PITR de tablespace (TSPITR)"            danger
        orb_menu_add  6 "PITR de PDB"                            danger

        orb_menu_group "GRANULAR"
        orb_menu_add  7 "RECOVER TABLE (tabela unica)"           danger
        orb_menu_add  8 "Block media recovery"                   danger
        orb_menu_add  9 "RECOVER PLUGGABLE DATABASE"             danger
        orb_menu_add 12 "Sumiu um objeto? escolha o caminho certo"

        orb_menu_group "DEPOIS DO RECOVERY"
        orb_menu_add 10 "Abrir o banco (RESETLOGS e afins)"      danger
        orb_menu_add 11 "Checklist de pos-restore"
        orb_menu_add  0 "Voltar"
        orb_menu_render
        orb_menu_hint

        orb_ask "Opcao" "" || return 0
        case "$ORB_ANSWER" in
            1)  orb_op_recover_database ;;
            2)  orb_call_op orb_ra_using_backup_cf ;;
            3)  orb_call_op orb_ra_until_cancel ;;
            4)  orb_op_pitr_database ;;
            5)  orb_op_pitr_tablespace ;;
            6)  orb_call_op orb_op_pdb_pitr ;;
            7)  orb_op_recover_table ;;
            8)  orb_op_blockrecover ;;
            9)  orb_call_op orb_op_pdb_recover ;;
            10) orb_call_op orb_pr_open_resetlogs ;;
            11) orb_call_op orb_postrestore_checklist ;;
            12) orb_recovery_decision ;;
            0)  return 0 ;;
            "") continue ;;
            *)  orb_status_line warn "Opcao invalida." ;;
        esac
        orb_discover_instance 2>/dev/null
        orb_pause
    done
}

# ---------------------------------------------------------------------------
# ARVORE DE DECISAO
#
# A pergunta que o DBA faz as tres da manha nao e "qual comando RMAN". E
# "qual e o menor estrago que resolve isso". Esta tela responde essa, e so
# depois manda para o comando.
# ---------------------------------------------------------------------------
orb_recovery_decision()
{
    orb_title "SUMIU UM OBJETO - QUAL CAMINHO?"

    orb_section "DO MENOS INVASIVO PARA O MAIS INVASIVO"
    orb_log_raw ""
    orb_log_raw "  1. DELETE / UPDATE errado, ainda dentro do undo_retention"
    orb_item "     -> FLASHBACK QUERY  (menu 6, opcao 7)"
    orb_item "        Segundos. Nao para nada. Nao altera nada ate voce mandar."
    orb_log_raw ""
    orb_log_raw "  2. DROP TABLE, recyclebin ligado"
    orb_item "     -> FLASHBACK DROP  (menu 6, opcao 6)"
    orb_item "        Segundos. So a tabela volta."
    orb_log_raw ""
    orb_log_raw "  3. Objeto de codigo perdido (package, view, trigger)"
    orb_item "     -> DATA PUMP sqlfile  (menu 9, opcao 9)"
    orb_item "        Extrai o DDL do dump sem tocar no banco."
    orb_log_raw ""
    orb_log_raw "  4. Tabela perdida, undo ja reciclado, existe backup"
    orb_item "     -> RMAN RECOVER TABLE  (menu 2, opcao 7)"
    orb_item "        O RMAN sobe instancia auxiliar sozinho. So a tabela volta."
    orb_log_raw ""
    orb_log_raw "  5. Tablespace inteiro corrompido ou truncado"
    orb_item "     -> TSPITR  (menu 2, opcao 5)"
    orb_item "        O resto do banco continua no ar."
    orb_log_raw ""
    orb_log_raw "  6. Banco inteiro comprometido"
    orb_item "     -> PITR do banco  (menu 2, opcao 4)"
    orb_item "        PARADA TOTAL e perda de tudo apos o ponto escolhido."
    orb_log_raw ""

    orb_section "O QUE CONFERIR ANTES DE ESCOLHER"
    _fb=`orb_sql_value "(select flashback_on from v\\$database)"`
    _ur=`orb_sql_value "(select value from v\\$parameter where name='undo_retention')"`
    _rb=`orb_sql_value "(select value from v\\$parameter where name='recyclebin')"`
    orb_field "flashback_on"   "`_orb_or_na "$_fb"`"
    orb_field "undo_retention" "`_orb_or_na "$_ur"` s"
    orb_field "recyclebin"     "`_orb_or_na "$_rb"`"
    orb_log_raw ""
    orb_item "Se o undo_retention nao cobre o horario do estrago, os caminhos 1"
    orb_item "e 3 ja estao fora - nao perca tempo tentando."
    orb_item "Cada minuto de producao rodando reduz a janela do undo. Se voce"
    orb_item "suspeita de flashback query, considere criar um restore point"
    orb_item "GARANTIDO agora, antes de investigar (menu 6, opcao 9)."
    return 0
}

# ---------------------------------------------------------------------------
# 13 - DIAGNOSTICO
# ---------------------------------------------------------------------------
orb_menu_diag()
{
    while :
    do
        orb_title "DIAGNOSTICO E PROVA"
        orb_log_raw "  `orb_badge $ORB_HDR_STATE`  $ORB_HDR_MSG"
        orb_log_raw ""

        orb_menu_begin
        orb_menu_group "SAUDE"
        orb_menu_add 1 "Saude do backup (este banco)"
        orb_menu_add 2 "Saude da frota (todo o catalogo)"
        orb_menu_add 3 "Informacoes de backup"
        orb_menu_add 4 "Incarnation"

        orb_menu_group "PROVA"
        orb_menu_add 5 "Simulado de restore (le a midia)"
        orb_menu_add 6 "Validacao de backup"

        orb_menu_group "QUANDO DEU ERRADO"
        orb_menu_add 7 "Dicionario de erros (ORA- / RMAN- / CRS-)"
        orb_menu_add 0 "Voltar"
        orb_menu_render
        orb_log_raw ""

        orb_ask "Opcao" "" || return 0
        case "$ORB_ANSWER" in
            1) orb_op_backup_health ; orb_header_health ;;
            2) orb_op_fleet ;;
            3) orb_op_backup_info ;;
            4) orb_op_incarnation ;;
            5) orb_op_drill ;;
            6) orb_op_validate_menu ;;
            7) orb_diag_lookup ;;
            0) return 0 ;;
            "") continue ;;
            *) orb_status_line warn "Opcao invalida." ;;
        esac
        orb_pause
    done
}

# ---------------------------------------------------------------------------
# 14 - AMBIENTE
# ---------------------------------------------------------------------------
orb_menu_env()
{
    while :
    do
        orb_title "AMBIENTE"
        orb_field "Modo"   "$ORB_MODE"
        orb_field "Perfil" "${ORB_MEDIA_PROFILE:-<nenhum>}"
        orb_field "Log"    "$ORB_LOG"
        orb_log_raw ""

        orb_menu_begin
        orb_menu_group "INSPECAO"
        orb_menu_add 1 "Inventario do ambiente"
        orb_menu_add 2 "Canais / media manager"
        orb_menu_add 3 "Autoteste do framework"

        orb_menu_group "ESTA SESSAO"
        orb_menu_add 4 "Alternar modo (EXECUTE/DRYRUN/GENERATE)"
        orb_menu_add 5 "Recarregar discovery"
        orb_menu_add 6 "Onde estao os arquivos desta execucao"
        orb_menu_add 0 "Voltar"
        orb_menu_render
        orb_log_raw ""

        orb_ask "Opcao" "" || return 0
        case "$ORB_ANSWER" in
            1) orb_discover_show ; orb_precheck_summary ;;
            2) orb_channels_interactive ;;
            3) orb_op_selftest ;;
            4) orb_switch_mode ;;
            5) orb_discover_all ; orb_header_health ; orb_status_line ok "Discovery recarregado." ;;
            6) orb_show_paths ;;
            0) return 0 ;;
            "") continue ;;
            *) orb_status_line warn "Opcao invalida." ;;
        esac
        orb_pause
    done
}

orb_show_paths()
{
    orb_section "ARQUIVOS DESTA EXECUCAO"
    orb_field "Raiz do projeto"  "$ORB_HOME"
    orb_field "Log principal"    "$ORB_LOG"
    orb_field "Diretorio da run" "$ORB_RUNDIR"
    orb_field "Scripts gerados"  "$ORB_SCRIPTDIR"
    orb_log_raw ""
    orb_item "Os cmdfiles RMAN e os .sql montados ficam no diretorio da run."
    orb_item "Voce pode reexecuta-los a mao se preferir nao passar pelo menu."
    return 0
}

orb_switch_mode()
{
    orb_section "MODO DE EXECUCAO"
    orb_item "EXECUTE  - executa de verdade, apos confirmacao"
    orb_item "DRYRUN   - mostra o plano e NAO executa nada"
    orb_item "GENERATE - grava o plano como script e nao executa"
    orb_log_raw ""
    orb_ask "Modo [EXECUTE|DRYRUN|GENERATE]" "$ORB_MODE"
    _m=`orb_upper "$ORB_ANSWER"`
    case "$_m" in
        EXECUTE|DRYRUN|GENERATE) ORB_MODE="$_m" ; orb_status_line ok "Modo: $ORB_MODE" ;;
        *) orb_status_line warn "Modo invalido - mantido $ORB_MODE." ;;
    esac
}

# ---------------------------------------------------------------------------
# orb_call_op  -  chama a operacao so se ela existir neste pacote.
#
# Um pacote transferido pela metade nao pode virar "command not found" no meio
# de uma janela de recovery. Se faltar modulo, o menu diz o que faltou.
# ---------------------------------------------------------------------------
orb_call_op()
{
    _fn="$1" ; shift
    if type "$_fn" >/dev/null 2>&1; then
        "$_fn" "$@"
        return $?
    fi
    orb_status_line fail "Operacao indisponivel: $_fn"
    orb_item "O modulo que a implementa nao foi carregado."
    orb_item "Rode ./orb.sh --selftest para conferir a integridade do pacote."
    return 1
}

# =============================================================================
# LOOP PRINCIPAL
# =============================================================================
while :
do
    orb_menu_home
    orb_ask "Opcao" "" || break
    case "$ORB_ANSWER" in
        1)  orb_menu_restore ;;
        2)  orb_menu_recovery ;;
        3)  orb_call_op orb_op_postrestore_menu ;;
        4)  orb_call_op orb_op_pdb_menu ;;
        5)  orb_call_op orb_op_dataguard_menu ;;
        6)  orb_call_op orb_op_flashback_menu ;;
        7)  orb_call_op orb_op_duplicate_menu ;;
        8)  orb_call_op orb_op_tts_menu ;;
        9)  orb_call_op orb_op_datapump_menu ;;
        10) orb_call_op orb_op_backup_menu ;;
        11) orb_call_op orb_op_catalog_menu ;;
        12) orb_call_op orb_op_gridasm_menu ;;
        13) orb_menu_diag ;;
        14) orb_menu_env ;;
        0)  break ;;
        "") continue ;;
        *)  orb_status_line warn "Opcao invalida." ; orb_pause ;;
    esac
    orb_discover_instance 2>/dev/null
done

orb_report
_rc=$?
orb_lock_release
exit $_rc
