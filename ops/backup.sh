#!/usr/bin/sh
###############################################################################
# ops/backup.sh - BACKUP
#
# O framework nasceu de restore, mas deixar backup de fora era incoerente: o
# modulo de saude detecta "sem nivel 0 ha 17 meses" e nao tinha como resolver.
# Aqui fecha o ciclo.
#
# Todo backup passa pelo engine igual a um restore - o comando aparece antes.
###############################################################################

orb_op_backup_menu()
{
    while :
    do
        orb_title "BACKUP"
        orb_field "Media"    "`orb_media_summary`"
        orb_field "Catalogo" "`orb_rman_has_catalog && echo SIM || echo NAO`"
        orb_menu_begin
        orb_menu_group "BASE"
        orb_menu_add  1 "Nivel 0 (full incremental) do database"
        orb_menu_add  2 "Backup FULL (nao incremental)"
        orb_menu_add  3 "Nivel 1 diferencial"
        orb_menu_add  4 "Nivel 1 cumulativo"
        orb_menu_group "PARCIAL"
        orb_menu_add  5 "Tablespace"
        orb_menu_add  6 "Datafile"
        orb_menu_add  7 "Archivelog"
        orb_menu_add  8 "Controlfile e SPFILE"
        orb_menu_group "ESPECIAL"
        orb_menu_add  9 "Backup para DUPLICATE (com archivelog, tag propria)"
        orb_menu_add 10 "Backup de recuperacao rapida (incremental merge)"
        orb_menu_add 11 "Backup keep forever (fora da politica de retencao)"
        orb_menu_add  0 "Voltar"
        orb_menu_render
        orb_log_raw ""
        orb_ask "Opcao" "" || return 0
        case "$ORB_ANSWER" in
            1)  orb_backup_db "INCREMENTAL LEVEL 0" "nivel 0" ;;
            2)  orb_backup_db "" "full" ;;
            3)  orb_backup_db "INCREMENTAL LEVEL 1" "nivel 1 diferencial" ;;
            4)  orb_backup_db "INCREMENTAL LEVEL 1 CUMULATIVE" "nivel 1 cumulativo" ;;
            5)  orb_backup_tablespace ;;
            6)  orb_backup_datafile ;;
            7)  orb_backup_archivelog ;;
            8)  orb_backup_cfspfile ;;
            9)  orb_backup_for_duplicate ;;
            10) orb_backup_merge ;;
            11) orb_backup_keep ;;
            0)  return 0 ;;
            "") continue ;;
            *)  orb_status_line warn "Opcao invalida." ;;
        esac
        orb_pause
    done
}

# ---------------------------------------------------------------------------
# opcoes comuns de backup
# ---------------------------------------------------------------------------
orb_backup_opts()
{
    ORB_BK_OPT=""
    orb_ask "Comprimir o backupset? [S/N]" "N"
    [ "`orb_upper $ORB_ANSWER`" = "S" ] && ORB_BK_OPT="$ORB_BK_OPT AS COMPRESSED BACKUPSET"

    orb_ask "Incluir archivelogs no mesmo comando? [S/N]" "S"
    ORB_BK_ARCH="N"
    [ "`orb_upper $ORB_ANSWER`" = "S" ] && ORB_BK_ARCH="S"

    orb_ask "TAG (vazio = o RMAN gera)" ""
    ORB_BK_TAG=""
    [ -n "$ORB_ANSWER" ] && ORB_BK_TAG=" TAG '$ORB_ANSWER'"

    ORB_BK_SEC=""
    if [ -n "$ORB_D_DATAFILES" ] && [ "$ORB_D_DATAFILES" -gt 0 ] 2>/dev/null; then
        orb_ask "SECTION SIZE (paraleliza datafile grande; vazio = nao usar)" ""
        [ -n "$ORB_ANSWER" ] && ORB_BK_SEC=" SECTION SIZE $ORB_ANSWER"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# orb_backup_db <clausula incremental> <descricao>
# ---------------------------------------------------------------------------
orb_backup_db()
{
    _inc="$1" ; _desc="$2"
    orb_title "BACKUP `orb_upper "$_desc"`"
    orb_require_oracle_home || return 1

    _st=`orb_instance_state`
    if [ "$_st" = "UNKNOWN" ] || [ "$_st" = "DOWN" ]; then
        orb_status_line fail "Instancia em '$_st' - backup exige o banco montado ou aberto."
        return 1
    fi
    if [ "$ORB_D_LOGMODE" = "NOARCHIVELOG" ] && [ "$_st" = "OPEN" ]; then
        orb_status_line fail "Banco em NOARCHIVELOG e ABERTO."
        orb_item "Backup online exige ARCHIVELOG. Feche e monte para backup consistente."
        return 1
    fi

    orb_backup_opts

    _cmd="  BACKUP${ORB_BK_OPT} ${_inc} DATABASE${ORB_BK_TAG}${ORB_BK_SEC};"
    _f="$ORB_RUNDIR/cmd_backup_db.rman"
    if [ "$ORB_BK_ARCH" = "S" ]; then
        orb_rman_build "$_f" \
            "  SQL 'ALTER SYSTEM ARCHIVE LOG CURRENT';" \
            "$_cmd" \
            "  BACKUP${ORB_BK_OPT} ARCHIVELOG ALL NOT BACKED UP 1 TIMES;" \
            "  BACKUP CURRENT CONTROLFILE;" \
            "  BACKUP SPFILE;"
    else
        orb_rman_build "$_f" "$_cmd" "  BACKUP CURRENT CONTROLFILE;" "  BACKUP SPFILE;"
    fi

    orb_plan_begin "BACKUP $_desc"
    orb_plan_field "Database"  "${ORB_D_DBNAME:-?} / ${ORB_D_DBUNIQUE:-?}"
    orb_plan_field "Estado"    "$_st"
    orb_plan_field "Log mode"  "${ORB_D_LOGMODE:-?}"
    orb_plan_field "Media"     "`orb_media_summary`"
    _mb=`orb_sql_value "(select to_char(round(sum(bytes)/1024/1024)) from v\\$datafile)"`
    orb_plan_field "Tamanho"   "`orb_human_mb $_mb`"
    orb_plan_cmd_file "Backup" "$_f"
    orb_plan_risk "Consome drives/streams do media manager e I/O do banco."
    orb_plan_risk "Backup online exige ARCHIVELOG - sem ele o backup nao e recuperavel."
    case "$_inc" in
        *"LEVEL 1"*) orb_plan_risk "Incremental SEM nivel 0 valido nao restaura nada. Confirme com a saude do backup." ;;
    esac
    orb_plan_confirm "FAZER-BACKUP" || return 1
    orb_exec_rman "backup_${_desc}" "$_f"
    _rc=$?
    [ $_rc -eq 0 ] && orb_status_line ok "Backup concluido. Rode a saude do backup para confirmar a cadeia."
    return $_rc
}

# ---------------------------------------------------------------------------
orb_backup_tablespace()
{
    orb_title "BACKUP TABLESPACE"
    orb_sql_query "select 'ORBR|'||tablespace_name||'|'||status from dba_tablespaces order by 1;" \
        | while IFS='|' read _t _s ; do orb_item "$_t ($_s)" ; done
    orb_ask "Tablespace(s), separadas por virgula" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _ts="$ORB_ANSWER"
    orb_backup_opts
    _f="$ORB_RUNDIR/cmd_backup_ts.rman"
    orb_rman_build "$_f" "  BACKUP${ORB_BK_OPT} TABLESPACE $_ts${ORB_BK_TAG};"
    orb_plan_begin "BACKUP TABLESPACE $_ts"
    orb_plan_cmd_file "Backup" "$_f"
    orb_plan_risk "Backup parcial: sozinho nao permite restaurar o banco inteiro."
    orb_plan_confirm "FAZER-BACKUP" || return 1
    orb_exec_rman "backup_tablespace" "$_f"
    return $?
}

orb_backup_datafile()
{
    orb_title "BACKUP DATAFILE"
    orb_ask "Datafile(s) (ex: 1 ou 4,7)" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _df="$ORB_ANSWER"
    orb_backup_opts
    _f="$ORB_RUNDIR/cmd_backup_df.rman"
    orb_rman_build "$_f" "  BACKUP${ORB_BK_OPT} DATAFILE $_df${ORB_BK_TAG};"
    orb_plan_begin "BACKUP DATAFILE $_df"
    orb_plan_cmd_file "Backup" "$_f"
    orb_plan_confirm "FAZER-BACKUP" || return 1
    orb_exec_rman "backup_datafile" "$_f"
    return $?
}

orb_backup_archivelog()
{
    orb_title "BACKUP ARCHIVELOG"
    orb_ask "Escopo [ALL|NOT BACKED UP|FROM TIME]" "NOT BACKED UP"
    _e=`orb_upper "$ORB_ANSWER"`
    case "$_e" in
        ALL)              _sel="ALL" ;;
        "NOT BACKED UP")  orb_ask "Quantas copias ja feitas para pular" "1"
                          _sel="ALL NOT BACKED UP $ORB_ANSWER TIMES" ;;
        "FROM TIME")      orb_ask "Dias atras" "1"
                          _sel="FROM TIME 'SYSDATE-$ORB_ANSWER'" ;;
        *)                _sel="ALL NOT BACKED UP 1 TIMES" ;;
    esac

    orb_ask "Apagar os archives depois de backupear? [S/N]" "N"
    _del=""
    if [ "`orb_upper $ORB_ANSWER`" = "S" ]; then
        _del=" DELETE INPUT"
    fi

    orb_ask "Forcar switch de redo antes? [S/N]" "S"
    _sw=""
    [ "`orb_upper $ORB_ANSWER`" = "S" ] && _sw="  SQL 'ALTER SYSTEM ARCHIVE LOG CURRENT';"

    _f="$ORB_RUNDIR/cmd_backup_arch.rman"
    if [ -n "$_sw" ]; then
        orb_rman_build "$_f" "$_sw" "  BACKUP ARCHIVELOG $_sel$_del;"
    else
        orb_rman_build "$_f" "  BACKUP ARCHIVELOG $_sel$_del;"
    fi

    orb_plan_begin "BACKUP ARCHIVELOG $_sel"
    orb_plan_cmd_file "Backup de archivelog" "$_f"
    [ -n "$_del" ] && orb_plan_risk "DELETE INPUT apaga os archives do disco apos o backup. Se o backup falhar depois, eles ja se foram."
    [ -n "$_del" ] && orb_plan_risk "Em Data Guard, apagar archive que o standby ainda nao aplicou cria gap."
    orb_plan_confirm "FAZER-BACKUP" || return 1
    orb_exec_rman "backup_archivelog" "$_f"
    return $?
}

orb_backup_cfspfile()
{
    _f="$ORB_RUNDIR/cmd_backup_cf.rman"
    orb_rman_build "$_f" "  BACKUP CURRENT CONTROLFILE;" "  BACKUP SPFILE;"
    orb_plan_begin "BACKUP CONTROLFILE E SPFILE"
    orb_plan_cmd_file "Backup" "$_f"
    orb_plan_risk "Rapido e barato. Faca sempre depois de mudanca estrutural."
    orb_plan_confirm "FAZER-BACKUP" || return 1
    orb_exec_rman "backup_cfspfile" "$_f"
    return $?
}

orb_backup_for_duplicate()
{
    orb_title "BACKUP PARA DUPLICATE"
    orb_item "Gera um conjunto completo e autocontido: nivel 0 + archivelogs +"
    orb_item "controlfile, com tag propria, para alimentar um DUPLICATE."
    orb_ask "TAG" "PARA_DUPLICATE"
    _tag="$ORB_ANSWER"
    _f="$ORB_RUNDIR/cmd_backup_dup.rman"
    orb_rman_build "$_f" \
        "  SQL 'ALTER SYSTEM ARCHIVE LOG CURRENT';" \
        "  BACKUP INCREMENTAL LEVEL 0 DATABASE TAG '$_tag'" \
        "    PLUS ARCHIVELOG TAG '$_tag';" \
        "  BACKUP CURRENT CONTROLFILE TAG '$_tag';" \
        "  BACKUP SPFILE TAG '$_tag';"
    orb_plan_begin "BACKUP PARA DUPLICATE (tag $_tag)"
    orb_plan_cmd_file "Backup autocontido" "$_f"
    orb_plan_risk "Conjunto completo: volume equivalente ao banco inteiro."
    orb_plan_confirm "FAZER-BACKUP" || return 1
    orb_exec_rman "backup_para_duplicate" "$_f"
    return $?
}

orb_backup_merge()
{
    orb_title "INCREMENTAL MERGE (recuperacao rapida)"
    orb_item "Mantem uma copia-imagem atualizada por incremental. O restore vira"
    orb_item "um SWITCH, quase instantaneo - troca tempo de restore por espaco."
    orb_item "So faz sentido em DISK."
    if [ "$ORB_MEDIA_TYPE" != "DISK" ]; then
        orb_status_line warn "Perfil de media atual e $ORB_MEDIA_TYPE, nao DISK."
        orb_item "Troque para um perfil DISK antes (menu de canais)."
        return 1
    fi
    orb_ask "Destino das copias-imagem (+DG ou caminho)" "${ORB_D_DBCREATE:-+DATA}"
    _d="$ORB_ANSWER"
    orb_ask "TAG da estrategia" "MERGE"
    _tag="$ORB_ANSWER"
    _f="$ORB_RUNDIR/cmd_backup_merge.rman"
    orb_rman_build "$_f" \
        "  RECOVER COPY OF DATABASE WITH TAG '$_tag';" \
        "  BACKUP INCREMENTAL LEVEL 1 FOR RECOVER OF COPY WITH TAG '$_tag' DATABASE FORMAT '$_d';"
    orb_plan_begin "INCREMENTAL MERGE (tag $_tag)"
    orb_plan_field "Destino" "$_d"
    orb_plan_cmd_file "Merge" "$_f"
    orb_plan_risk "Exige espaco equivalente ao banco inteiro no destino."
    orb_plan_risk "A primeira execucao cria a copia-imagem completa - demorada."
    orb_plan_risk "Rode diariamente: a copia so fica util se estiver atualizada."
    orb_plan_confirm "FAZER-BACKUP" || return 1
    orb_exec_rman "backup_merge" "$_f"
    return $?
}

orb_backup_keep()
{
    orb_title "BACKUP KEEP (fora da retencao)"
    orb_item "Para marco legal, fim de exercicio, pre-upgrade. Este backup NAO"
    orb_item "e apagado pela politica de retencao."
    orb_ask "Reter ate [FOREVER|UNTIL TIME]" "FOREVER"
    _k=`orb_upper "$ORB_ANSWER"`
    if [ "$_k" = "FOREVER" ]; then
        _keep="KEEP FOREVER"
        _needcat="Y"
    else
        orb_ask "Data limite (DD-MM-YYYY)" ""
        _keep="KEEP UNTIL TIME \"TO_DATE('$ORB_ANSWER','DD-MM-YYYY')\""
        _needcat="N"
    fi
    orb_ask "TAG" "KEEP_`orb_timestamp`"
    _tag="$ORB_ANSWER"

    if [ "$_needcat" = "Y" ] && ! orb_rman_has_catalog; then
        orb_status_line fail "KEEP FOREVER exige recovery catalog."
        orb_item "Sem catalogo, o registro do backup expira do controlfile."
        return 1
    fi

    _f="$ORB_RUNDIR/cmd_backup_keep.rman"
    orb_rman_build "$_f" \
        "  BACKUP DATABASE $_keep TAG '$_tag'" \
        "    PLUS ARCHIVELOG $_keep TAG '$_tag';"
    orb_plan_begin "BACKUP $_keep"
    orb_plan_field "TAG" "$_tag"
    orb_plan_cmd_file "Backup KEEP" "$_f"
    orb_plan_risk "Ocupa midia indefinidamente - nao entra na rotacao."
    orb_plan_risk "Anote o TAG: e por ele que voce vai achar esse backup daqui a anos."
    orb_plan_confirm "FAZER-BACKUP" || return 1
    orb_exec_rman "backup_keep" "$_f"
    _rc=$?
    [ $_rc -eq 0 ] && orb_status_line info "Registre o TAG '$_tag' na documentacao do change."
    return $_rc
}
