#!/usr/bin/sh
###############################################################################
# ops/drill.sh - simulado de restore (restore drill)
#
# A licao mais cara do incidente que originou este framework:
#
#   RESTORE ... PREVIEW  e  RESTORE ... VALIDATE HEADER  consultam o
#   REPOSITORIO. Eles listaram 90 backupsets como AVAILABLE. Minutos depois o
#   restore real falhou em todos, com "not found in NetBackup catalog" - as
#   imagens tinham expirado da fita 17 meses antes.
#
#   Backup que nunca foi restaurado nao e backup. E intencao de backup.
#
# Este modulo executa RESTORE DATABASE VALIDATE - o unico comando que LE os
# backupsets da midia de ponta a ponta. E lento e consome drives. E o unico
# que responde "sim, da para restaurar" com alguma honestidade.
#
# Nao altera o banco. Nao escreve datafile nenhum.
###############################################################################

orb_drill_estimate()
{
    # Volume que sera lido, a partir do repositorio.
    orb_sql_value "(select to_char(round(sum(bytes)/1024/1024))
                      from v\$backup_piece
                     where status='A'
                       and completion_time > sysdate - 400)"
}

# ---------------------------------------------------------------------------
orb_op_drill()
{
    orb_title "SIMULADO DE RESTORE (le a midia de verdade)"

    orb_require_oracle_home || return 1

    orb_status_line info "PREVIEW e VALIDATE HEADER consultam o repositorio."
    orb_item "Eles dizem o que o RMAN ACHA que existe."
    orb_status_line info "Este simulado le os backupsets da MIDIA."
    orb_item "E o unico teste que prova que a fita responde."
    orb_log_raw ""

    if ! orb_rman_has_catalog; then
        orb_status_line warn "Sem catalogo: o simulado cobre so a janela do controlfile."
        orb_item "Um simulado que nao enxerga o nivel 0 nao prova nada."
        orb_confirm "Prosseguir mesmo assim?" "SEM-CATALOGO" || return 1
    fi

    orb_ask "Escopo [DATABASE|DATAFILE|ARCHIVELOG]" "DATABASE"
    _esc=`orb_upper "$ORB_ANSWER"`

    case "$_esc" in
        DATABASE)
            _cmd="  RESTORE DATABASE VALIDATE;"
            _desc="RESTORE DATABASE VALIDATE"
            ;;
        DATAFILE)
            orb_ask "Datafiles (ex: 1 ou 1,2,3)" "1"
            _cmd="  RESTORE DATAFILE $ORB_ANSWER VALIDATE;"
            _desc="RESTORE DATAFILE $ORB_ANSWER VALIDATE"
            ;;
        ARCHIVELOG)
            orb_ask "Dias de archive a validar" "7"
            _cmd="  RESTORE ARCHIVELOG FROM TIME 'SYSDATE-$ORB_ANSWER' VALIDATE;"
            _desc="RESTORE ARCHIVELOG ultimos $ORB_ANSWER dias VALIDATE"
            ;;
        *)
            orb_err "Escopo invalido." ; return 1 ;;
    esac

    orb_ask "Verificar corrupcao logica tambem? (mais lento) [S/N]" "N"
    [ "`orb_upper $ORB_ANSWER`" = "S" ] && _cmd=`echo "$_cmd" | sed 's/;$/ CHECK LOGICAL;/'`

    _vol=`orb_drill_estimate`

    _f="$ORB_RUNDIR/cmd_drill.rman"
    orb_rman_build "$_f" "$_cmd"

    orb_plan_begin "SIMULADO DE RESTORE: $_desc"
    orb_plan_field "Database"      "${ORB_D_DBNAME:-?} / ${ORB_D_DBUNIQUE:-?}"
    orb_plan_field "Media"         "`orb_media_summary`"
    orb_plan_field "Catalogo"      "`orb_rman_has_catalog && echo SIM || echo NAO`"
    orb_plan_field "Volume a ler"  "`orb_human_mb ${_vol:-0}` (estimativa)"
    orb_plan_cmd_file "Validacao lendo a midia" "$_f"
    orb_plan_risk "NAO altera o banco - so le. Nenhum datafile e escrito."
    orb_plan_risk "Le os backupsets inteiros: em fita, leva horas."
    orb_plan_risk "Consome drives/streams do media manager durante a execucao."
    orb_plan_risk "Combine a janela com o time de backup se houver backup em curso."

    orb_plan_confirm "SIMULAR" || return 1

    _t0=`orb_epoch`
    orb_exec_rman "drill" "$_f"
    _rc=$?
    _t1=`orb_epoch`

    orb_title "RESULTADO DO SIMULADO"
    orb_field "Escopo"   "$_desc"
    orb_field "Duracao"  "`orb_elapsed $_t0 $_t1`"
    orb_field "Volume"   "`orb_human_mb ${_vol:-0}`"

    # Estimativa de RTO a partir da taxa observada
    _dur=`expr $_t1 - $_t0`
    if [ "$_dur" -gt 30 ] && [ -n "$_vol" ] && [ "$_vol" -gt 0 ] 2>/dev/null; then
        _mbs=`echo "$_vol $_dur" | awk '{printf "%.1f", $1/$2}'`
        orb_field "Taxa observada" "${_mbs} MB/s"
        _dbmb=`orb_sql_value "(select to_char(round(sum(bytes)/1024/1024)) from v\\$datafile)"`
        if [ -n "$_dbmb" ] && [ "$_dbmb" -gt 0 ] 2>/dev/null; then
            _eta=`echo "$_dbmb $_mbs" | awk '{printf "%d", $1/$2}'`
            orb_field "Tamanho do banco" "`orb_human_mb $_dbmb`"
            orb_status_line info "RTO estimado do restore: `orb_elapsed 0 $_eta`"
            orb_item "Baseado na taxa medida agora. Restore real inclui ainda o"
            orb_item "recover dos archives, que nao entra nessa conta."
        fi
    fi

    if [ $_rc -ne 0 ]; then
        orb_log_raw ""
        orb_status_line crit "O SIMULADO FALHOU."
        orb_item "Isto significa que um restore real falharia agora."
        orb_item "Trate como incidente: o banco esta sem backup utilizavel."
        return 2
    fi

    orb_log_raw ""
    orb_status_line ok "Todos os backupsets foram lidos da midia com sucesso."
    orb_item "Este e o unico resultado que autoriza dizer 'o backup restaura'."
    orb_item "Repita periodicamente: retencao de midia muda sem avisar."
    return 0
}
