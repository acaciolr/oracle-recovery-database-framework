#!/usr/bin/sh
###############################################################################
# ops/backup_health.sh - saude do backup
#
# Esta e a operacao mais importante do framework, e a mais barata.
#
# O incidente que originou o projeto: um banco de 7 TB passou 17 meses sem
# backup nivel 0. Os incrementais diarios continuaram rodando e "com sucesso"
# o tempo todo. So se descobriu no dia em que foi preciso restaurar - quando
# o nivel 0 pai ja tinha expirado da fita.
#
# Nenhum orquestrador de restore teria salvado aquele banco. Este relatorio,
# rodando semanalmente, teria.
#
# Somente leitura. Nao altera nada. Feito para rodar em cron.
###############################################################################

ORB_HEALTH_RC=0     # 0 ok, 1 warning, 2 critico

_orb_days_since()
{
    # <dias> a partir de um "days" ja calculado no SQL; util para formatar
    case "$1" in ''|*[!0-9.]*) echo "?" ; return 1 ;; esac
    echo "$1" | awk '{printf "%d", $1}'
}

orb_health_check()
{
    orb_title "SAUDE DO BACKUP"

    if ! orb_sql_alive; then
        orb_err "Instancia nao responde - nao ha como avaliar a saude do backup."
        ORB_HEALTH_RC=2
        return 2
    fi

    orb_field "Database"  "${ORB_D_DBNAME:-?} / ${ORB_D_DBUNIQUE:-?}"
    orb_field "DBID"      "${ORB_D_DBID:-?}"
    orb_field "Role"      "${ORB_D_ROLE:-?}"
    orb_field "Log mode"  "${ORB_D_LOGMODE:-?}"
    orb_field "Catalogo"  "`orb_rman_has_catalog && echo SIM || echo NAO`"
    orb_field "cf_keep"   "${ORB_D_CFKEEP:-?} dias"

    if [ "$ORB_D_LOGMODE" = "NOARCHIVELOG" ]; then
        orb_err "Banco em NOARCHIVELOG: nao ha recuperacao point-in-time possivel."
        ORB_HEALTH_RC=2
    fi

    # ---------------------------------------------------------------------
    # 1. Ultimo backup NIVEL 0 de datafile
    #
    # v$backup_datafile.incremental_level=0 cobre o nivel 0; backups FULL
    # aparecem com incremental_level nulo. Consideramos os dois.
    # ---------------------------------------------------------------------
    orb_section "ULTIMO BACKUP BASE (NIVEL 0 / FULL)"

    _l0=`orb_sql_value "(select to_char(max(bs.completion_time),'YYYY-MM-DD HH24:MI:SS')
                           from v\\$backup_set bs, v\\$backup_datafile bd
                          where bs.set_stamp = bd.set_stamp
                            and bs.set_count = bd.set_count
                            and bd.file# = 1
                            and (bd.incremental_level = 0 or bd.incremental_level is null))"`

    _l0d=`orb_sql_value "(select to_char(round(sysdate - max(bs.completion_time)))
                            from v\\$backup_set bs, v\\$backup_datafile bd
                           where bs.set_stamp = bd.set_stamp
                             and bs.set_count = bd.set_count
                             and bd.file# = 1
                             and (bd.incremental_level = 0 or bd.incremental_level is null))"`

    if [ -z "$_l0" ]; then
        orb_err "NENHUM backup nivel 0 encontrado no repositorio visivel."
        orb_item "Sem nivel 0, incrementais nao restauram nada."
        ORB_HEALTH_RC=2
    else
        orb_field "Ultimo nivel 0" "$_l0"
        orb_field "Idade"          "${_l0d:-?} dias"
        _d=`_orb_days_since "$_l0d"`
        if [ "$_d" != "?" ]; then
            if [ "$_d" -ge "${ORB_HEALTH_L0_CRIT_DAYS:-31}" ]; then
                orb_err "CRITICO: nivel 0 com $_d dias (limite ${ORB_HEALTH_L0_CRIT_DAYS:-31})."
                orb_item "A cadeia de restore depende de um backup que pode ja ter"
                orb_item "expirado na midia. Verifique retencao com o time de backup."
                ORB_HEALTH_RC=2
            elif [ "$_d" -ge "${ORB_HEALTH_L0_WARN_DAYS:-8}" ]; then
                orb_warn "Nivel 0 com $_d dias (limite ${ORB_HEALTH_L0_WARN_DAYS:-8})."
                [ "$ORB_HEALTH_RC" -lt 1 ] && ORB_HEALTH_RC=1
            else
                orb_ok "Nivel 0 recente ($_d dias)."
            fi
        fi
    fi

    # ---------------------------------------------------------------------
    # 2. Datafiles sem backup nenhum
    # ---------------------------------------------------------------------
    orb_section "DATAFILES SEM BACKUP"
    _semb=`orb_sql_value "(select to_char(count(*)) from v\\$datafile d
                            where not exists (select 1 from v\\$backup_datafile b
                                               where b.file# = d.file#))"`
    if [ -n "$_semb" ] && [ "$_semb" != "0" ]; then
        orb_err "$_semb datafiles SEM nenhum backup no repositorio visivel."
        orb_sql_query "select 'ORBR|'||d.file#||'|'||d.name from v\$datafile d
                        where not exists (select 1 from v\$backup_datafile b
                                           where b.file# = d.file#)
                        order by d.file#;" \
            | head -20 | while IFS='|' read _f _n
        do
            orb_log_raw "    file $_f : $_n"
        done
        ORB_HEALTH_RC=2
    else
        orb_ok "Todos os datafiles tem ao menos um backup."
    fi

    # ---------------------------------------------------------------------
    # 3. Backup de archivelog
    # ---------------------------------------------------------------------
    if [ "$ORB_D_LOGMODE" = "ARCHIVELOG" ]; then
        orb_section "BACKUP DE ARCHIVELOG"
        _ar=`orb_sql_value "(select to_char(max(completion_time),'YYYY-MM-DD HH24:MI:SS')
                               from v\\$backup_redolog)"`
        _arh=`orb_sql_value "(select to_char(round((sysdate - max(completion_time))*24))
                                from v\\$backup_redolog)"`
        if [ -z "$_ar" ]; then
            orb_err "Nenhum backup de archivelog encontrado."
            ORB_HEALTH_RC=2
        else
            orb_field "Ultimo backup de archive" "$_ar"
            orb_field "Idade"                    "${_arh:-?} horas"
            _h=`_orb_days_since "$_arh"`
            if [ "$_h" != "?" ]; then
                if [ "$_h" -ge "${ORB_HEALTH_ARCH_CRIT_HOURS:-72}" ]; then
                    orb_err "CRITICO: archivelog sem backup ha $_h horas."
                    ORB_HEALTH_RC=2
                elif [ "$_h" -ge "${ORB_HEALTH_ARCH_WARN_HOURS:-26}" ]; then
                    orb_warn "Archivelog sem backup ha $_h horas."
                    [ "$ORB_HEALTH_RC" -lt 1 ] && ORB_HEALTH_RC=1
                else
                    orb_ok "Backup de archivelog em dia ($_h horas)."
                fi
            fi
        fi

        # gap na sequencia de archive
        _gap=`orb_sql_value "(select to_char(count(*)) from v\\$archived_log
                               where deleted='NO' and status='A'
                                 and completion_time > sysdate-1)"`
        [ -n "$_gap" ] && orb_field "Archives ultimas 24h" "$_gap"
    fi

    # ---------------------------------------------------------------------
    # 4. Autobackup de controlfile
    # ---------------------------------------------------------------------
    orb_section "CONTROLFILE"
    _cfab=`orb_sql_value "(select to_char(max(completion_time),'YYYY-MM-DD HH24:MI:SS')
                             from v\\$backup_piece where controlfile_included='YES')"`
    if [ -z "$_cfab" ]; then
        orb_err "Nenhum backup de controlfile encontrado."
        orb_item "Sem autobackup de controlfile, um restore do zero fica muito mais dificil."
        ORB_HEALTH_RC=2
    else
        orb_field "Ultimo backup de controlfile" "$_cfab"
        orb_ok "Controlfile presente no repositorio."
    fi

    # ---------------------------------------------------------------------
    # 5. Corrupcao conhecida
    # ---------------------------------------------------------------------
    orb_section "CORRUPCAO"
    _corr=`orb_sql_value "(select to_char(count(*)) from v\\$database_block_corruption)"`
    if [ -n "$_corr" ] && [ "$_corr" != "0" ]; then
        orb_err "$_corr blocos corrompidos registrados em v\$database_block_corruption."
        ORB_HEALTH_RC=2
    else
        orb_ok "Nenhum bloco corrompido registrado."
    fi

    # ---------------------------------------------------------------------
    # 6. FRA
    # ---------------------------------------------------------------------
    if [ -n "$ORB_D_FRA" ]; then
        orb_section "FLASH RECOVERY AREA"
        _used=`orb_sql_value "(select to_char(round(sum(percent_space_used))) from v\\$recovery_area_usage)"`
        orb_field "FRA"       "$ORB_D_FRA"
        orb_field "Uso"       "${_used:-?} %"
        if [ -n "$_used" ] && [ "$_used" -ge 90 ] 2>/dev/null; then
            orb_warn "FRA acima de 90% de uso."
            [ "$ORB_HEALTH_RC" -lt 1 ] && ORB_HEALTH_RC=1
        fi
    fi

    # ---------------------------------------------------------------------
    # VEREDITO
    # ---------------------------------------------------------------------
    orb_title "VEREDITO"
    case "$ORB_HEALTH_RC" in
        0) orb_ok    "BACKUP SAUDAVEL." ;;
        1) orb_warn  "BACKUP COM AVISOS - revise os itens marcados." ;;
        2) orb_err   "BACKUP EM ESTADO CRITICO."
           orb_item  "Neste estado, uma perda do banco pode nao ser recuperavel."
           orb_item  "Trate isso como incidente, nao como tarefa de rotina." ;;
    esac

    if [ -n "$ORB_HEALTH_MAIL" ] && [ "$ORB_HEALTH_RC" -gt 0 ] && orb_have mailx; then
        _sub="[ORB] backup ${ORB_D_DBNAME:-?} estado="
        case "$ORB_HEALTH_RC" in 1) _sub="${_sub}AVISO" ;; 2) _sub="${_sub}CRITICO" ;; esac
        [ -n "$ORB_LOG" ] && mailx -s "$_sub" "$ORB_HEALTH_MAIL" < "$ORB_LOG" 2>/dev/null
        orb_log "Alerta enviado para $ORB_HEALTH_MAIL"
    fi

    return $ORB_HEALTH_RC
}

orb_op_backup_health() { orb_health_check ; }
