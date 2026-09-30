#!/usr/bin/sh
###############################################################################
# ops/pitr.sh - Point-In-Time Recovery
#
# Antes de executar, o modulo monta um RECOVERY PLAN: traduz o alvo em SCN,
# identifica qual backup base sera usado e quais archives serao necessarios,
# e so entao mostra os comandos.
###############################################################################

ORB_PITR_UNTIL=""
ORB_PITR_DESC=""

# ---------------------------------------------------------------------------
# orb_pitr_target  -  captura o alvo e resolve para SCN quando possivel
# ---------------------------------------------------------------------------
orb_pitr_target()
{
    orb_ask "Tipo de alvo [TIME|SCN|SEQUENCE|RESTORE POINT]" "TIME"
    _t=`orb_upper "$ORB_ANSWER"`

    case "$_t" in
        TIME)
            orb_ask "Data/hora (DD-MM-YYYY HH24:MI:SS)" ""
            [ -z "$ORB_ANSWER" ] && return 1
            _v="$ORB_ANSWER"
            ORB_PITR_UNTIL="SET UNTIL TIME \"TO_DATE('$_v','DD-MM-YYYY HH24:MI:SS')\";"
            ORB_PITR_DESC="TIME $_v"
            _scn=`orb_sql_value "(select to_char(timestamp_to_scn(to_date('$_v','DD-MM-YYYY HH24:MI:SS'))) from dual)" 2>/dev/null`
            [ -n "$_scn" ] && orb_field "SCN correspondente" "$_scn"
            ;;
        SCN)
            orb_ask "SCN" ""
            [ -z "$ORB_ANSWER" ] && return 1
            ORB_PITR_UNTIL="SET UNTIL SCN $ORB_ANSWER;"
            ORB_PITR_DESC="SCN $ORB_ANSWER"
            _tm=`orb_sql_value "(select to_char(scn_to_timestamp($ORB_ANSWER),'YYYY-MM-DD HH24:MI:SS') from dual)" 2>/dev/null`
            [ -n "$_tm" ] && orb_field "Timestamp correspondente" "$_tm"
            ;;
        SEQUENCE)
            orb_ask "Sequence" ""
            [ -z "$ORB_ANSWER" ] && return 1
            _s="$ORB_ANSWER"
            orb_ask "Thread" "1"
            ORB_PITR_UNTIL="SET UNTIL SEQUENCE $_s THREAD $ORB_ANSWER;"
            ORB_PITR_DESC="SEQUENCE $_s THREAD $ORB_ANSWER"
            ;;
        "RESTORE POINT")
            orb_section "RESTORE POINTS"
            orb_sql_query "select 'ORBR|'||name||'|'||to_char(scn)||'|'||guarantee_flashback_database from v\$restore_point order by scn;" \
                | while IFS='|' read _n _sc _g
                do
                    orb_log_raw "  $_n  scn=$_sc  guaranteed=$_g"
                done
            orb_ask "Nome do restore point" ""
            [ -z "$ORB_ANSWER" ] && return 1
            ORB_PITR_UNTIL="SET UNTIL RESTORE POINT $ORB_ANSWER;"
            ORB_PITR_DESC="RESTORE POINT $ORB_ANSWER"
            ;;
        *)
            orb_err "Tipo invalido."
            return 1
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# orb_pitr_plan_report  -  o que o RMAN usaria para chegar naquele ponto
# ---------------------------------------------------------------------------
orb_pitr_plan_report()
{
    orb_section "RECOVERY PLAN (consulta ao repositorio)"
    _f="$ORB_RUNDIR/cmd_pitr_preview.rman"
    {
        echo "RUN {"
        orb_channels_block
        echo "  $ORB_PITR_UNTIL"
        echo "  RESTORE DATABASE PREVIEW SUMMARY;"
        echo "}"
        echo "EXIT;"
    } > "$_f"
    orb_rman_run "pitr_preview" "$_f"
    orb_item "Confirme acima que existe um NIVEL 0 anterior ao alvo,"
    orb_item "e que os archives entre o backup e o alvo aparecem na lista."
    return 0
}

# ---------------------------------------------------------------------------
# DATABASE PITR
# ---------------------------------------------------------------------------
orb_op_pitr_database()
{
    orb_title "DATABASE POINT-IN-TIME RECOVERY"

    orb_require_oracle_home || return 1
    orb_require_mounted     || return 1

    orb_pitr_target || return 1
    orb_pitr_plan_report

    _f="$ORB_RUNDIR/cmd_pitr.rman"
    {
        echo "RUN {"
        orb_channels_block
        echo "  $ORB_PITR_UNTIL"
        echo "  RESTORE DATABASE;"
        echo "  RECOVER DATABASE;"
        echo "}"
        echo "EXIT;"
    } > "$_f"

    orb_plan_begin "DATABASE PITR ate $ORB_PITR_DESC"
    orb_plan_field "Database" "${ORB_D_DBNAME:-?}"
    orb_plan_field "Alvo"     "$ORB_PITR_DESC"
    orb_plan_field "Media"    "`orb_media_summary`"
    orb_plan_cmd_file "Restore e recover ate o ponto" "$_f"
    orb_plan_cmd "Abertura apos recovery incompleto" \
        "sqlplus / as sysdba <<EOF
alter database open resetlogs;
EOF"
    orb_plan_risk "TODOS os dados posteriores ao ponto escolhido serao PERDIDOS."
    orb_plan_risk "OPEN RESETLOGS cria uma NOVA incarnation."
    orb_plan_risk "Backups anteriores viram incarnation orfa - faca nivel 0 logo apos."
    orb_plan_risk "Em RAC, apenas uma instancia pode estar montada durante o PITR."

    orb_plan_confirm "PITR" || return 1

    orb_exec_rman "pitr" "$_f" || return 1

    orb_section "ABERTURA"
    orb_confirm "Abrir o banco com RESETLOGS agora?" "RESETLOGS" || {
        orb_log "Banco deixado montado. Abra manualmente quando decidir."
        return 0
    }
    _s="$ORB_RUNDIR/open_resetlogs.sql"
    printf "alter database open resetlogs;\nexit\n" > "$_s"
    orb_exec_sql "open_resetlogs" "$_s"
    orb_discover_instance
    orb_postcheck_database
    orb_warn "Nova incarnation criada. Faca um backup NIVEL 0 antes de liberar o banco."
    return 0
}

# ---------------------------------------------------------------------------
# TABLESPACE PITR (TSPITR)
# ---------------------------------------------------------------------------
orb_op_pitr_tablespace()
{
    orb_title "TABLESPACE POINT-IN-TIME RECOVERY"
    orb_require_oracle_home || return 1
    orb_require_open        || return 1

    orb_ask "Tablespace(s)" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _ts="$ORB_ANSWER"

    orb_pitr_target || return 1

    orb_ask "Auxiliary destination (diretorio com espaco livre)" "/tmp/tspitr"
    _aux="$ORB_ANSWER"

    _f="$ORB_RUNDIR/cmd_tspitr.rman"
    {
        echo "RUN {"
        orb_channels_block
        echo "  $ORB_PITR_UNTIL"
        echo "  RECOVER TABLESPACE $_ts AUXILIARY DESTINATION '$_aux';"
        echo "}"
        echo "EXIT;"
    } > "$_f"

    orb_plan_begin "TSPITR de $_ts ate $ORB_PITR_DESC"
    orb_plan_field "Tablespaces" "$_ts"
    orb_plan_field "Alvo"        "$ORB_PITR_DESC"
    orb_plan_field "Auxiliary"   "$_aux"
    orb_plan_cmd_file "TSPITR" "$_f"
    orb_plan_risk "A tablespace volta ao ponto escolhido; alteracoes posteriores nela sao perdidas."
    orb_plan_risk "O RMAN cria uma instancia auxiliar - precisa de espaco em $_aux."
    orb_plan_risk "A tablespace fica OFFLINE durante a operacao."
    orb_plan_risk "Objetos com dependencia fora da tablespace podem impedir o TSPITR."
    orb_plan_confirm "TSPITR" || return 1
    orb_exec_rman "tspitr" "$_f"
    return $?
}

# ---------------------------------------------------------------------------
# TABLE RECOVERY  (12c+)
# ---------------------------------------------------------------------------
orb_op_recover_table()
{
    orb_title "TABLE RECOVERY"
    orb_check_version 12 || return 1
    orb_require_open     || return 1

    orb_ask "Schema.Tabela (ex: HR.EMPLOYEES)" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _tab="$ORB_ANSWER"

    orb_pitr_target || return 1

    orb_ask "Auxiliary destination" "/tmp/tabrec"
    _aux="$ORB_ANSWER"

    orb_ask "REMAP TABLE destino (vazio = mesmo nome)" ""
    _remap=""
    [ -n "$ORB_ANSWER" ] && _remap="  REMAP TABLE $_tab:$ORB_ANSWER"

    orb_ask "REMAP TABLESPACE (origem:destino, vazio = nenhum)" ""
    _remapts=""
    [ -n "$ORB_ANSWER" ] && _remapts="  REMAP TABLESPACE $ORB_ANSWER"

    _f="$ORB_RUNDIR/cmd_recover_table.rman"
    {
        echo "RUN {"
        orb_channels_block
        echo "  RECOVER TABLE $_tab"
        echo "    UNTIL `echo "$ORB_PITR_UNTIL" | sed 's/^SET UNTIL //; s/;$//'`"
        echo "    AUXILIARY DESTINATION '$_aux'"
        [ -n "$_remap" ]   && echo "  $_remap"
        [ -n "$_remapts" ] && echo "  $_remapts"
        echo "  ;"
        echo "}"
        echo "EXIT;"
    } > "$_f"

    orb_plan_begin "RECOVER TABLE $_tab"
    orb_plan_field "Tabela"    "$_tab"
    orb_plan_field "Alvo"      "$ORB_PITR_DESC"
    orb_plan_field "Auxiliary" "$_aux"
    orb_plan_cmd_file "Table recovery" "$_f"
    orb_plan_risk "O RMAN cria instancia auxiliar completa - exige espaco significativo em $_aux."
    orb_plan_risk "Sem REMAP, a tabela atual sera SOBRESCRITA."
    orb_plan_risk "Operacao longa: restaura SYSTEM, SYSAUX, UNDO e a tablespace da tabela."
    orb_plan_confirm "RECUPERAR-TABELA" || return 1
    orb_exec_rman "recover_table" "$_f"
    return $?
}
