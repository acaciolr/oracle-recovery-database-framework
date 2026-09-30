#!/usr/bin/sh
###############################################################################
# ops/backup_info.sh - descoberta de backups e incarnation
#
# Somente leitura. Nada aqui altera estado.
###############################################################################

orb_op_backup_info()
{
    orb_title "INFORMACOES DE BACKUP"
    orb_field "Catalogo" "`orb_rman_has_catalog && echo SIM || echo NAO`"
    if ! orb_rman_has_catalog; then
        orb_warn "Sem catalogo: a listagem cobre so a janela do controlfile"
        orb_warn "(control_file_record_keep_time = ${ORB_D_CFKEEP:-?} dias)."
    fi

    _l=`orb_rman_capture "backupinfo" \
        "LIST BACKUP SUMMARY;" \
        "LIST BACKUP OF DATABASE SUMMARY;" \
        "LIST BACKUP OF CONTROLFILE SUMMARY;" \
        "LIST BACKUP OF SPFILE SUMMARY;" \
        "LIST BACKUP OF ARCHIVELOG ALL SUMMARY;" \
        "LIST COPY SUMMARY;" \
        "REPORT SCHEMA;" \
        "REPORT NEED BACKUP;" \
        "REPORT OBSOLETE;" \
        "EXIT;"`
    orb_log_file "$_l"
    cat "$_l"
    orb_ok "Saida completa em $_l"
    return 0
}

# ---------------------------------------------------------------------------
# INCARNATION
#
# Modulo obrigatorio. O erro classico e passar o Reset SCN ou o Inc Key que
# aparece quando se lista pelo controlfile - os dois produzem RMAN-20010.
# Aqui a listagem sai do CATALOGO quando existe, e o reset exige confirmacao
# explicita mostrando antes o que muda.
# ---------------------------------------------------------------------------
orb_op_incarnation()
{
    orb_title "INCARNATION"

    _l=`orb_rman_capture "incarnation" \
        "LIST INCARNATION OF DATABASE '${ORB_D_DBNAME}';" \
        "EXIT;"`
    orb_log_file "$_l"
    cat "$_l"

    orb_section "COMO LER"
    orb_item "A coluna 'Inc Key' e o unico valor aceito por RESET DATABASE."
    orb_item "'Reset SCN' NAO serve - usar ele devolve RMAN-20010."
    orb_item "Se a linha CURRENT ja e a incarnation desejada, NAO faca reset."
    orb_item "A listagem acima veio `orb_rman_has_catalog && echo 'do CATALOGO' || echo 'do CONTROLFILE'`;"
    orb_item "os Inc Key das duas origens sao numeros diferentes."

    if [ "${ORB_MODE}" != "EXECUTE" ]; then
        return 0
    fi

    orb_ask "Deseja resetar a incarnation? (Inc Key, ou vazio para nao)" ""
    [ -z "$ORB_ANSWER" ] && { orb_log "Nenhum reset solicitado." ; return 0 ; }
    _key="$ORB_ANSWER"
    case "$_key" in ''|*[!0-9]*) orb_err "Inc Key invalido: $_key" ; return 1 ;; esac

    _f="$ORB_RUNDIR/cmd_incarnation.rman"
    {
        echo "RESET DATABASE TO INCARNATION $_key;"
        echo "EXIT;"
    } > "$_f"

    orb_plan_begin "RESET DATABASE TO INCARNATION $_key"
    orb_plan_field "Database"            "${ORB_D_DBNAME:-?}"
    orb_plan_field "DBID"                "${ORB_D_DBID:-?}"
    orb_plan_field "Inc Key escolhido"   "$_key"
    orb_plan_field "Origem da listagem"  "`orb_rman_has_catalog && echo CATALOGO || echo CONTROLFILE`"
    orb_plan_cmd_file "Reset de incarnation" "$_f"
    orb_plan_risk "Muda qual conjunto de backups o RMAN considera valido."
    orb_plan_risk "Backups da incarnation atual passam a ser tratados como orfaos."
    orb_plan_risk "Se o Inc Key vier do controlfile e nao do catalogo, resulta em RMAN-20010."

    orb_plan_confirm "RESETAR" || return 1
    orb_exec_rman "incarnation" "$_f"
    return $?
}
