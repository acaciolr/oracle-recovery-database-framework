#!/usr/bin/sh
###############################################################################
# ops/restore_database.sh - restore e recover de database
#
# Cobre database completo, cold restore, standby e restore FROM SERVICE.
# Toda alteracao de estado passa pelo engine: plano -> comandos -> riscos ->
# confirmacao -> execucao -> post-check.
###############################################################################

# ---------------------------------------------------------------------------
# Decide o bloco de destino. Nao transforma tudo em '+DG' cegamente:
#
#   SET NEWNAME       quando o controlfile aponta para nomes que nao existem
#                     aqui (tipico de standby restaurado do autobackup do
#                     primary - os nomes aparecem como MUST_RENAME_THIS_DATAFILE)
#   in-place          quando db_file_name_convert ja converteu os nomes
#   db_create_file_dest  quando o destino e OMF e o parametro ja aponta certo
# ---------------------------------------------------------------------------
orb_restore_destination_probe()
{
    orb_section "DESTINO DOS DATAFILES"
    _n1=`orb_sql_value "(select name from v\\$datafile where file#=1)"`
    orb_field "datafile 1 no controlfile" "`_orb_or_na "$_n1"`"
    orb_field "db_create_file_dest"       "`_orb_or_na "$ORB_D_DBCREATE"`"

    case "$_n1" in
        *MUST_RENAME_THIS_DATAFILE*)
            orb_warn "O controlfile nao conseguiu mapear os nomes do primary."
            orb_item "SET NEWNAME e necessario. Os arquivos serao criados novos."
            ORB_RESTORE_MODE="NEWNAME"
            ;;
        +*|/*)
            orb_ok "O controlfile ja conhece nomes utilizaveis."
            orb_item "Restore in-place e possivel (nao precisa apagar nada antes)."
            ORB_RESTORE_MODE="INPLACE"
            ;;
        *)
            orb_warn "Nao consegui determinar o modo pelo nome do datafile 1."
            ORB_RESTORE_MODE="NEWNAME"
            ;;
    esac

    orb_ask "Modo de destino [NEWNAME|INPLACE]" "$ORB_RESTORE_MODE"
    ORB_RESTORE_MODE=`orb_upper "$ORB_ANSWER"`

    if [ "$ORB_RESTORE_MODE" = "NEWNAME" ]; then
        orb_ask "Destino (diskgroup +DG ou caminho)" "${ORB_D_DBCREATE:-+DATA}"
        ORB_RESTORE_DEST="$ORB_ANSWER"
    else
        ORB_RESTORE_DEST=""
    fi
    return 0
}

# ---------------------------------------------------------------------------
# orb_restore_estimate  -  MB necessarios, a partir do tamanho dos datafiles
# ---------------------------------------------------------------------------
orb_restore_estimate()
{
    orb_sql_value "(select to_char(round(sum(bytes)/1024/1024)) from v\$datafile)"
}

# ---------------------------------------------------------------------------
# RESTORE DATABASE
# ---------------------------------------------------------------------------
orb_op_restore_database()
{
    orb_title "RESTORE DATABASE"

    orb_require_oracle_home || return 1
    orb_require_mounted     || return 1
    [ "$ORB_D_RAC" = "Y" ] && { orb_require_crs || return 1 ; }

    if ! orb_rman_has_catalog; then
        orb_warn "Operacao sem recovery catalog."
        orb_item "Backups fora da janela de ${ORB_D_CFKEEP:-?} dias ficam invisiveis."
        orb_item "Este e o cenario que produz ORA-01180 (RMAN tenta CRIAR o datafile)."
        orb_confirm "Prosseguir mesmo assim sem catalogo?" "SEM-CATALOGO" || return 1
    fi

    orb_restore_destination_probe

    _need=`orb_restore_estimate`
    if [ "$ORB_RESTORE_MODE" = "NEWNAME" ] && [ -n "$ORB_RESTORE_DEST" ]; then
        orb_check_space "$ORB_RESTORE_DEST" "$_need"
        _sp=$?
        if [ $_sp -eq 1 ]; then
            orb_err "Espaco insuficiente. Corrija antes de continuar."
            return 1
        fi
    fi

    _f="$ORB_RUNDIR/cmd_restore_db.rman"
    if [ "$ORB_RESTORE_MODE" = "NEWNAME" ]; then
        orb_rman_build "$_f" \
            "  SET NEWNAME FOR DATABASE TO '$ORB_RESTORE_DEST';" \
            "  RESTORE DATABASE;" \
            "  SWITCH DATAFILE ALL;"
    else
        orb_rman_build "$_f" "  RESTORE DATABASE;"
    fi

    orb_plan_begin "RESTORE DATABASE"
    orb_plan_field "Database"   "${ORB_D_DBNAME:-?} / ${ORB_D_DBUNIQUE:-?}"
    orb_plan_field "DBID"       "${ORB_D_DBID:-?}"
    orb_plan_field "Versao"     "${ORB_D_VERSION:-?}"
    orb_plan_field "Modo"       "`[ "$ORB_D_RAC" = Y ] && echo RAC || echo Single`"
    orb_plan_field "Storage"    "`[ "$ORB_D_ASM" = Y ] && echo ASM || echo Filesystem`"
    orb_plan_field "Destino"    "${ORB_RESTORE_DEST:-in-place}"
    orb_plan_field "Media"      "`orb_media_summary`"
    orb_plan_field "Catalogo"   "`orb_rman_has_catalog && echo SIM || echo NAO`"
    orb_plan_field "Volume est." "`orb_human_mb ${_need:-0}`"
    orb_plan_cmd_file "Restore do database" "$_f"
    orb_plan_risk "Os datafiles serao sobrescritos ou recriados no destino."
    orb_plan_risk "Operacao longa: proporcional ao volume lido da midia."
    [ "$ORB_RESTORE_MODE" = "NEWNAME" ] && \
        orb_plan_risk "SET NEWNAME cria arquivos NOVOS - os antigos continuam ocupando espaco."
    orb_plan_risk "Um RECOVER sera necessario depois; o banco nao abre so com restore."

    orb_plan_confirm "RESTAURAR" || return 1

    orb_exec_rman "restore_database" "$_f" || return 1
    orb_ok "Restore concluido. Execute o RECOVER antes de abrir."
    return 0
}

# ---------------------------------------------------------------------------
# RECOVER DATABASE
#
# RMAN-06054 e tolerado APENAS quando o alvo e standby. Em primary o mesmo
# codigo significa archivelog faltando de verdade.
# ---------------------------------------------------------------------------
orb_op_recover_database()
{
    orb_title "RECOVER DATABASE"

    orb_require_oracle_home || return 1
    orb_require_mounted     || return 1

    _isstby="N"
    case "$ORB_D_ROLE" in
        *STANDBY*) _isstby="Y" ;;
    esac

    orb_field "Role detectado" "${ORB_D_ROLE:-?}"

    orb_ask "Ponto de recuperacao [CURRENT|SCN|TIME|SEQUENCE]" "CURRENT"
    _mode=`orb_upper "$ORB_ANSWER"`
    _until=""
    case "$_mode" in
        SCN)
            orb_ask "SCN" ""
            [ -z "$ORB_ANSWER" ] && { orb_err "SCN nao informado." ; return 1 ; }
            _until="  SET UNTIL SCN $ORB_ANSWER;"
            ;;
        TIME)
            orb_ask "Data/hora (DD-MM-YYYY HH24:MI:SS)" ""
            [ -z "$ORB_ANSWER" ] && { orb_err "Tempo nao informado." ; return 1 ; }
            _until="  SET UNTIL TIME \"TO_DATE('$ORB_ANSWER','DD-MM-YYYY HH24:MI:SS')\";"
            ;;
        SEQUENCE)
            orb_ask "Sequence" ""
            orb_ask "Thread" "1"
            _thr="$ORB_ANSWER"
            _until="  SET UNTIL SEQUENCE $ORB_ANSWER THREAD $_thr;"
            ;;
    esac

    orb_ask "Apagar archivelogs restaurados apos aplicar? [S/N]" "S"
    if [ "`orb_upper $ORB_ANSWER`" = "S" ]; then
        orb_ask "Limite de disco para archives restaurados" "200 G"
        _rec="  RECOVER DATABASE DELETE ARCHIVELOG MAXSIZE $ORB_ANSWER;"
    else
        _rec="  RECOVER DATABASE;"
    fi

    _f="$ORB_RUNDIR/cmd_recover_db.rman"
    if [ -n "$_until" ]; then
        orb_rman_build "$_f" "$_until" "$_rec"
    else
        orb_rman_build "$_f" "$_rec"
    fi

    orb_plan_begin "RECOVER DATABASE"
    orb_plan_field "Database"  "${ORB_D_DBNAME:-?}"
    orb_plan_field "Role"      "${ORB_D_ROLE:-?}"
    orb_plan_field "Ponto"     "$_mode"
    orb_plan_field "Media"     "`orb_media_summary`"
    orb_plan_cmd_file "Recover" "$_f"
    orb_plan_risk "Aplica redo nos datafiles - operacao nao reversivel."
    if [ "$_isstby" = "Y" ]; then
        orb_plan_risk "Standby: o recover TERMINA com RMAN-06054 e isso e o fim normal."
    else
        orb_plan_risk "Primary: RMAN-06054 aqui significa archivelog faltando de verdade."
    fi
    [ -n "$_until" ] && orb_plan_risk "Recovery incompleto: OPEN RESETLOGS sera necessario e cria nova incarnation."

    orb_plan_confirm "RECUPERAR" || return 1

    if [ "$_isstby" = "Y" ]; then
        orb_exec_rman "recover_database" "$_f" "RMAN-06054"
    else
        orb_exec_rman "recover_database" "$_f"
    fi
    _rc=$?

    orb_postcheck_database

    if [ "$_isstby" = "Y" ]; then
        orb_section "PROXIMO PASSO"
        orb_item "Para alcancar o primary, inicie o managed recovery:"
        orb_item "  ALTER DATABASE RECOVER MANAGED STANDBY DATABASE"
        orb_item "    USING CURRENT LOGFILE DISCONNECT FROM SESSION;"
        orb_item "Confira antes: standby redo logs, log_archive_dest do primary, broker."
    elif [ -n "$_until" ]; then
        orb_section "PROXIMO PASSO"
        orb_item "Recovery incompleto: abra com ALTER DATABASE OPEN RESETLOGS;"
        orb_item "Isso cria nova incarnation - faca backup nivel 0 logo apos."
    fi
    return $_rc
}

# ---------------------------------------------------------------------------
# COLD RESTORE  -  fluxo completo do zero
# ---------------------------------------------------------------------------
orb_op_cold_restore()
{
    orb_title "COLD RESTORE (fluxo completo)"

    orb_require_oracle_home || return 1
    [ "$ORB_D_RAC" = "Y" ] && { orb_require_crs || return 1 ; }

    orb_plan_begin "COLD RESTORE COMPLETO"
    orb_plan_field "Database" "${ORB_D_DBNAME:-?} / ${ORB_D_DBUNIQUE:-?}"
    orb_plan_field "DBID"     "${ORB_D_DBID:-?}"
    orb_plan_field "Modo"     "`[ "$ORB_D_RAC" = Y ] && echo RAC || echo Single`"
    orb_plan_field "Media"    "`orb_media_summary`"

    if [ "$ORB_D_RAC" = "Y" ]; then
        orb_plan_cmd "Parar o database" \
            "srvctl stop database -d ${ORB_D_DBUNIQUE} -o abort"
        orb_plan_cmd "Subir SOMENTE a instancia local em nomount" \
            "srvctl start instance -d ${ORB_D_DBUNIQUE} -i ${ORACLE_SID} -o nomount"
        orb_plan_risk "start database subiria TODAS as instancias; restore precisa de uma."
    else
        orb_plan_cmd "Parar e subir em nomount" \
            "sqlplus / as sysdba <<EOF
shutdown abort
startup nomount
EOF"
    fi

    _cf="$ORB_RUNDIR/cmd_cold_ctlfile.rman"
    orb_rman_build "$_cf" \
        "  SET DBID=${ORB_D_DBID};" \
        "  RESTORE CONTROLFILE FROM AUTOBACKUP;" \
        "  SQL 'ALTER DATABASE MOUNT';"
    orb_plan_cmd_file "Restaurar controlfile e montar" "$_cf"

    orb_plan_risk "TODOS os datafiles serao sobrescritos."
    orb_plan_risk "O banco fica indisponivel durante toda a operacao."
    orb_plan_risk "OPEN RESETLOGS podera ser necessario ao final."

    orb_plan_confirm "COLD-RESTORE" || return 1

    if [ "$ORB_D_RAC" = "Y" ]; then
        orb_exec_os "stop database" \
            "${ORB_D_GRIDHOME}/bin/srvctl" stop database -d "${ORB_D_DBUNIQUE}" -o abort
        orb_exec_os "start instance nomount" \
            "${ORB_D_GRIDHOME}/bin/srvctl" start instance -d "${ORB_D_DBUNIQUE}" -i "${ORACLE_SID}" -o nomount
    else
        _s="$ORB_RUNDIR/cold_nomount.sql"
        printf "shutdown abort\nstartup nomount\nexit\n" > "$_s"
        orb_exec_sql "cold_nomount" "$_s"
    fi

    orb_exec_rman "cold_controlfile" "$_cf" || return 1
    orb_discover_instance
    orb_op_restore_database || return 1
    orb_op_recover_database
    return $?
}

# ---------------------------------------------------------------------------
# RESTORE FROM SERVICE  -  copia direto do primary pela rede
#
# Nao depende de backup nenhum. E a saida quando a midia expirou.
# Exige 12c+ , TNS para o primary e password file compativel.
# ---------------------------------------------------------------------------
orb_op_restore_from_service()
{
    orb_title "RESTORE FROM SERVICE (copia do primary pela rede)"

    orb_check_version 12 || return 1
    orb_require_mounted  || return 1

    orb_item "Este caminho nao usa backup: le os datafiles direto do primary."
    orb_item "Requisitos: TNS alcancavel e password file compativel entre os dois."
    orb_log_raw ""

    orb_ask "Alias TNS do primary" ""
    [ -z "$ORB_ANSWER" ] && { orb_err "Alias nao informado." ; return 1 ; }
    _svc="$ORB_ANSWER"

    orb_log "Testando alcance de $_svc ..."
    if orb_have tnsping; then
        tnsping "$_svc" 2>&1 | tail -3 | while IFS= read _l ; do orb_item "$_l" ; done
    else
        orb_warn "tnsping nao encontrado - nao consegui testar o alias."
    fi

    orb_ask "Usar compressao na transferencia? [S/N]" "S"
    if [ "`orb_upper $ORB_ANSWER`" = "S" ]; then
        _cmp=" USING COMPRESSED BACKUPSET"
    else
        _cmp=""
    fi

    orb_restore_destination_probe

    _f="$ORB_RUNDIR/cmd_from_service.rman"
    if [ "$ORB_RESTORE_MODE" = "NEWNAME" ]; then
        orb_rman_build "$_f" \
            "  SET NEWNAME FOR DATABASE TO '$ORB_RESTORE_DEST';" \
            "  RESTORE DATABASE FROM SERVICE $_svc$_cmp;" \
            "  SWITCH DATAFILE ALL;"
    else
        orb_rman_build "$_f" "  RESTORE DATABASE FROM SERVICE $_svc$_cmp;"
    fi

    orb_plan_begin "RESTORE DATABASE FROM SERVICE $_svc"
    orb_plan_field "Database"  "${ORB_D_DBNAME:-?} / ${ORB_D_DBUNIQUE:-?}"
    orb_plan_field "Origem"    "servico $_svc (primary ao vivo)"
    orb_plan_field "Destino"   "${ORB_RESTORE_DEST:-in-place}"
    orb_plan_field "Compressao" "`[ -n "$_cmp" ] && echo SIM || echo NAO`"
    orb_plan_cmd_file "Restore pela rede" "$_f"
    orb_plan_risk "Le os datafiles do PRIMARY: gera carga de I/O e rede em producao."
    orb_plan_risk "Volume igual ao tamanho do banco - operacao longa."
    orb_plan_risk "Combine a janela com quem cuida do primary."

    orb_plan_confirm "RESTAURAR-DA-REDE" || return 1

    orb_exec_rman "restore_from_service" "$_f" || return 1

    orb_section "RECOVER"
    _r="$ORB_RUNDIR/cmd_recover_service.rman"
    orb_rman_build "$_r" "  RECOVER DATABASE FROM SERVICE $_svc$_cmp;"
    orb_plan_begin "RECOVER DATABASE FROM SERVICE $_svc"
    orb_plan_cmd_file "Recover pela rede" "$_r"
    orb_plan_risk "Aplica incremental a partir do primary."
    orb_plan_confirm "RECUPERAR" || return 0
    orb_exec_rman "recover_from_service" "$_r" "RMAN-06054"
    orb_postcheck_database
    return $?
}
