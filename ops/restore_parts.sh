#!/usr/bin/sh
###############################################################################
# ops/restore_parts.sh - restore de partes do banco
#
# controlfile, spfile, datafile, tablespace, archivelog, block media recovery.
###############################################################################

# ---------------------------------------------------------------------------
# CONTROLFILE
# ---------------------------------------------------------------------------
orb_op_restore_controlfile()
{
    orb_title "RESTORE CONTROLFILE"
    orb_require_oracle_home || return 1

    _st=`orb_instance_state`
    orb_field "Estado da instancia" "$_st"
    if [ "$_st" = "UNKNOWN" ]; then
        orb_err "Estado indeterminado - nao prossigo."
        return 1
    fi
    if [ "$_st" = "OPEN" ] || [ "$_st" = "MOUNTED" ]; then
        orb_err "O banco precisa estar em NOMOUNT para restaurar controlfile."
        return 1
    fi

    orb_ask "Tipo [NORMAL|STANDBY]" "NORMAL"
    _tipo=`orb_upper "$ORB_ANSWER"`

    orb_ask "Origem [AUTOBACKUP|TAG|HANDLE]" "AUTOBACKUP"
    _src=`orb_upper "$ORB_ANSWER"`

    _dbid="${ORB_D_DBID}"
    if [ -z "$_dbid" ]; then
        orb_ask "DBID (obrigatorio com a instancia em nomount)" ""
        _dbid="$ORB_ANSWER"
    fi
    case "$_dbid" in ''|*[!0-9]*) orb_err "DBID invalido ou nao informado." ; return 1 ;; esac

    case "$_tipo" in
        STANDBY) _kw="RESTORE STANDBY CONTROLFILE" ;;
        *)       _kw="RESTORE CONTROLFILE" ;;
    esac

    case "$_src" in
        TAG)
            orb_ask "TAG" ""
            _from="FROM TAG '$ORB_ANSWER'"
            ;;
        HANDLE)
            orb_ask "Handle do backup piece" ""
            _from="FROM '$ORB_ANSWER'"
            ;;
        *)
            orb_ask "MAXDAYS para busca do autobackup" "5"
            _from="FROM AUTOBACKUP MAXDAYS $ORB_ANSWER"
            ;;
    esac

    case "$_tipo" in
        STANDBY) _mount="  SQL 'ALTER DATABASE MOUNT STANDBY DATABASE';" ;;
        *)       _mount="  SQL 'ALTER DATABASE MOUNT';" ;;
    esac

    _f="$ORB_RUNDIR/cmd_restore_cf.rman"
    orb_rman_build "$_f" \
        "  SET DBID=$_dbid;" \
        "  $_kw $_from;" \
        "$_mount"

    orb_plan_begin "$_kw"
    orb_plan_field "DBID"    "$_dbid"
    orb_plan_field "Tipo"    "$_tipo"
    orb_plan_field "Origem"  "$_from"
    orb_plan_field "Media"   "`orb_media_summary`"
    orb_plan_cmd_file "Restore do controlfile" "$_f"
    orb_plan_risk "Sobrescreve o controlfile atual em TODOS os destinos configurados."
    orb_plan_risk "O controlfile restaurado carrega os NOMES gravados no backup;"
    orb_plan_risk "em standby eles podem vir como MUST_RENAME_THIS_DATAFILE."
    orb_plan_risk "Registros de backup ficam limitados a control_file_record_keep_time."

    orb_plan_confirm "RESTAURAR-CONTROLFILE" || return 1
    orb_exec_rman "restore_controlfile" "$_f" || return 1

    orb_discover_instance
    orb_section "NOMES NO CONTROLFILE RESTAURADO"
    orb_sql_query "select 'ORBR|'||file#||'|'||name from v\$datafile where file# <= 5 order by file#;" \
        | while IFS='|' read _n _nm ; do orb_log_raw "  file $_n : $_nm" ; done
    orb_item "Se aparecer MUST_RENAME_THIS_DATAFILE, o restore precisa de SET NEWNAME."
    return 0
}

# ---------------------------------------------------------------------------
# SPFILE
# ---------------------------------------------------------------------------
orb_op_restore_spfile()
{
    orb_title "RESTORE SPFILE"
    orb_require_oracle_home || return 1

    _dbid="${ORB_D_DBID}"
    if [ -z "$_dbid" ]; then
        orb_ask "DBID" ""
        _dbid="$ORB_ANSWER"
    fi
    case "$_dbid" in ''|*[!0-9]*) orb_err "DBID invalido." ; return 1 ;; esac

    orb_ask "Destino do spfile (vazio = destino padrao)" ""
    if [ -n "$ORB_ANSWER" ]; then
        _to=" TO '$ORB_ANSWER'"
    else
        _to=""
    fi

    _f="$ORB_RUNDIR/cmd_restore_spfile.rman"
    orb_rman_build "$_f" \
        "  SET DBID=$_dbid;" \
        "  RESTORE SPFILE${_to} FROM AUTOBACKUP;"

    orb_plan_begin "RESTORE SPFILE"
    orb_plan_field "DBID"    "$_dbid"
    orb_plan_field "Destino" "${_to:-padrao}"
    orb_plan_cmd_file "Restore do spfile" "$_f"
    orb_plan_risk "Sobrescreve o spfile atual - parametros customizados serao perdidos."
    orb_plan_risk "A instancia precisa ser reiniciada para ler o novo spfile."
    orb_plan_confirm "RESTAURAR-SPFILE" || return 1
    orb_exec_rman "restore_spfile" "$_f"
    return $?
}

# ---------------------------------------------------------------------------
# DATAFILE
# ---------------------------------------------------------------------------
orb_op_restore_datafile()
{
    orb_title "RESTORE DATAFILE"
    orb_require_oracle_home || return 1
    orb_require_mounted     || orb_require_open || return 1

    orb_ask "Numeros dos datafiles (ex: 1 ou 4,7,9)" ""
    [ -z "$ORB_ANSWER" ] && { orb_err "Nenhum datafile informado." ; return 1 ; }
    _dfs="$ORB_ANSWER"

    orb_section "ARQUIVOS ALVO"
    for _d in `echo "$_dfs" | tr ',' ' '`
    do
        _nm=`orb_sql_value "(select name from v\\$datafile where file#=$_d)"`
        _sz=`orb_sql_value "(select to_char(round(bytes/1024/1024)) from v\\$datafile where file#=$_d)"`
        orb_field "file $_d" "`_orb_or_na "$_nm"` (`orb_human_mb ${_sz:-0}`)"
    done

    orb_ask "Renomear no restore? (destino, vazio = manter nomes)" ""
    _newname=""
    if [ -n "$ORB_ANSWER" ]; then
        _dest="$ORB_ANSWER"
        for _d in `echo "$_dfs" | tr ',' ' '`
        do
            _newname="$_newname
  SET NEWNAME FOR DATAFILE $_d TO '$_dest';"
        done
    fi

    _f="$ORB_RUNDIR/cmd_restore_df.rman"
    if [ -n "$_newname" ]; then
        orb_rman_build "$_f" "$_newname" \
            "  RESTORE DATAFILE $_dfs;" \
            "  SWITCH DATAFILE ALL;" \
            "  RECOVER DATAFILE $_dfs;"
    else
        orb_rman_build "$_f" \
            "  RESTORE DATAFILE $_dfs;" \
            "  RECOVER DATAFILE $_dfs;"
    fi

    orb_plan_begin "RESTORE + RECOVER DATAFILE $_dfs"
    orb_plan_field "Datafiles" "$_dfs"
    orb_plan_field "Media"     "`orb_media_summary`"
    orb_plan_cmd_file "Restore e recover dos datafiles" "$_f"
    orb_plan_risk "Os arquivos listados serao sobrescritos."
    orb_plan_risk "Com o banco OPEN, coloque os datafiles OFFLINE antes."
    orb_plan_confirm "RESTAURAR-DATAFILE" || return 1
    orb_exec_rman "restore_datafile" "$_f"
    _rc=$?
    orb_postcheck_database
    return $_rc
}

# ---------------------------------------------------------------------------
# TABLESPACE
# ---------------------------------------------------------------------------
orb_op_restore_tablespace()
{
    orb_title "RESTORE TABLESPACE"
    orb_require_oracle_home || return 1

    orb_section "TABLESPACES"
    orb_sql_query "select 'ORBR|'||tablespace_name||'|'||status from dba_tablespaces order by tablespace_name;" \
        | while IFS='|' read _t _s ; do orb_log_raw "  $_t  ($_s)" ; done

    orb_ask "Tablespace(s), separadas por virgula" ""
    [ -z "$ORB_ANSWER" ] && { orb_err "Nenhuma tablespace informada." ; return 1 ; }
    _ts="$ORB_ANSWER"

    _f="$ORB_RUNDIR/cmd_restore_ts.rman"
    orb_rman_build "$_f" \
        "  RESTORE TABLESPACE $_ts;" \
        "  RECOVER TABLESPACE $_ts;"

    orb_plan_begin "RESTORE + RECOVER TABLESPACE $_ts"
    orb_plan_field "Tablespaces" "$_ts"
    orb_plan_field "Media"       "`orb_media_summary`"
    orb_plan_cmd_file "Restore e recover" "$_f"
    orb_plan_risk "Os datafiles da tablespace serao sobrescritos."
    orb_plan_risk "Com o banco OPEN, a tablespace precisa estar OFFLINE."
    orb_plan_risk "SYSTEM e UNDO nao podem ficar offline com o banco aberto."
    orb_plan_confirm "RESTAURAR-TABLESPACE" || return 1
    orb_exec_rman "restore_tablespace" "$_f"
    _rc=$?
    orb_postcheck_database
    return $_rc
}

# ---------------------------------------------------------------------------
# ARCHIVELOG
# ---------------------------------------------------------------------------
orb_op_restore_archivelog()
{
    orb_title "RESTORE ARCHIVELOG"
    orb_require_oracle_home || return 1

    orb_ask "Criterio [ALL|SEQUENCE|TIME|SCN]" "SEQUENCE"
    _crit=`orb_upper "$ORB_ANSWER"`

    case "$_crit" in
        ALL)
            _sel="ALL"
            ;;
        SEQUENCE)
            orb_ask "Sequence inicial" ""
            _from="$ORB_ANSWER"
            orb_ask "Sequence final (vazio = ate a ultima)" ""
            _to="$ORB_ANSWER"
            orb_ask "Thread" "1"
            _thr="$ORB_ANSWER"
            if [ -n "$_to" ]; then
                _sel="FROM SEQUENCE $_from UNTIL SEQUENCE $_to THREAD $_thr"
            else
                _sel="FROM SEQUENCE $_from THREAD $_thr"
            fi
            ;;
        TIME)
            orb_ask "De (DD-MM-YYYY HH24:MI:SS)" ""
            _from="$ORB_ANSWER"
            orb_ask "Ate (DD-MM-YYYY HH24:MI:SS)" ""
            _to="$ORB_ANSWER"
            _sel="FROM TIME \"TO_DATE('$_from','DD-MM-YYYY HH24:MI:SS')\" UNTIL TIME \"TO_DATE('$_to','DD-MM-YYYY HH24:MI:SS')\""
            ;;
        SCN)
            orb_ask "SCN inicial" ""
            _from="$ORB_ANSWER"
            orb_ask "SCN final" ""
            _to="$ORB_ANSWER"
            _sel="FROM SCN $_from UNTIL SCN $_to"
            ;;
        *)
            orb_err "Criterio invalido." ; return 1 ;;
    esac

    orb_ask "Destino dos archives (vazio = destino padrao)" ""
    _dst=""
    [ -n "$ORB_ANSWER" ] && _dst="  SET ARCHIVELOG DESTINATION TO '$ORB_ANSWER';"

    _f="$ORB_RUNDIR/cmd_restore_arch.rman"
    if [ -n "$_dst" ]; then
        orb_rman_build "$_f" "$_dst" "  RESTORE ARCHIVELOG $_sel;"
    else
        orb_rman_build "$_f" "  RESTORE ARCHIVELOG $_sel;"
    fi

    orb_plan_begin "RESTORE ARCHIVELOG"
    orb_plan_field "Criterio" "$_sel"
    orb_plan_field "Destino"  "${ORB_ANSWER:-padrao}"
    orb_plan_cmd_file "Restore de archivelog" "$_f"
    orb_plan_risk "Archives restaurados consomem espaco no destino."
    orb_plan_risk "Confira o espaco livre antes - restore grande enche FRA."
    orb_plan_confirm "RESTAURAR-ARCHIVELOG" || return 1
    orb_exec_rman "restore_archivelog" "$_f"
    return $?
}

# ---------------------------------------------------------------------------
# BLOCK MEDIA RECOVERY
# ---------------------------------------------------------------------------
orb_op_blockrecover()
{
    orb_title "BLOCK MEDIA RECOVERY"
    orb_require_oracle_home || return 1

    orb_section "CORRUPCAO CONHECIDA"
    _n=`orb_sql_value "(select to_char(count(*)) from v\\$database_block_corruption)"`
    orb_field "Blocos em v\$database_block_corruption" "`_orb_or_na "$_n"`"
    if [ -n "$_n" ] && [ "$_n" != "0" ]; then
        orb_sql_query "select 'ORBR|'||file#||'|'||block#||'|'||blocks||'|'||corruption_type from v\$database_block_corruption order by file#, block#;" \
            | while IFS='|' read _f _b _c _t
            do
                orb_log_raw "  file $_f  bloco $_b  qtd $_c  tipo $_t"
            done
    fi

    orb_ask "Estrategia [CORRUPTION LIST|DATAFILE BLOCK]" "CORRUPTION LIST"
    _est=`orb_upper "$ORB_ANSWER"`

    if [ "$_est" = "CORRUPTION LIST" ]; then
        if [ "$_n" = "0" ] || [ -z "$_n" ]; then
            orb_warn "Lista de corrupcao vazia. Rode VALIDATE DATABASE antes para popular."
            return 1
        fi
        _cmd="  RECOVER CORRUPTION LIST;"
        _desc="RECOVER CORRUPTION LIST"
    else
        orb_ask "Datafile" ""
        _df="$ORB_ANSWER"
        orb_ask "Bloco(s) (ex: 1234 ou 1234,1235)" ""
        _bl="$ORB_ANSWER"
        _cmd="  RECOVER DATAFILE $_df BLOCK $_bl;"
        _desc="RECOVER DATAFILE $_df BLOCK $_bl"
    fi

    _f="$ORB_RUNDIR/cmd_blockrecover.rman"
    orb_rman_build "$_f" "$_cmd"

    orb_plan_begin "$_desc"
    orb_plan_field "Media" "`orb_media_summary`"
    orb_plan_cmd_file "Block media recovery" "$_f"
    orb_plan_risk "Recupera apenas os blocos indicados; o banco pode ficar aberto."
    orb_plan_risk "Exige backup que contenha versao integra dos blocos."
    orb_plan_confirm "RECUPERAR-BLOCOS" || return 1
    orb_exec_rman "blockrecover" "$_f"
    _rc=$?
    _n2=`orb_sql_value "(select to_char(count(*)) from v\\$database_block_corruption)"`
    orb_field "Blocos corrompidos apos" "`_orb_or_na "$_n2"`"
    return $_rc
}
