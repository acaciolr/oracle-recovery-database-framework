#!/usr/bin/sh
###############################################################################
# ops/dataguard.sh - Data Guard
###############################################################################

orb_op_dataguard_menu()
{
    while :
    do
        orb_title "DATA GUARD"
        orb_field "Role atual"   "${ORB_D_ROLE:-?}"
        orb_field "Open mode"    "${ORB_D_OPENMODE:-?}"
        orb_field "Controlfile"  "${ORB_D_CFTYPE:-?}"
        orb_log_raw ""

        orb_menu_begin
        orb_menu_group "DIAGNOSTICO (somente leitura)"
        orb_menu_add  1 "Status do Data Guard"
        orb_menu_add  2 "Conferir parametros de Data Guard"
        orb_menu_add  3 "Progresso do apply / atraso"
        orb_menu_add  4 "Status do broker (DGMGRL)"

        orb_menu_group "APPLY"
        orb_menu_add  5 "Iniciar managed recovery (MRP)"      danger
        orb_menu_add  6 "Parar managed recovery"              danger
        orb_menu_add  7 "Recuperar gap: RECOVER FROM SERVICE" danger
        orb_menu_add  8 "Criar standby redo logs"             danger
        orb_menu_add  9 "Reabastecer archives faltantes (catalog+recover)" danger

        orb_menu_group "SNAPSHOT STANDBY (teste sem perder o standby)"
        orb_menu_add 10 "Converter para SNAPSHOT STANDBY"     danger
        orb_menu_add 11 "Reverter para PHYSICAL STANDBY"      danger

        orb_menu_group "TROCA DE PAPEL"
        orb_menu_add 12 "SWITCHOVER (planejado, sem perda)"   danger
        orb_menu_add 13 "FAILOVER (desastre, com perda)"      danger
        orb_menu_add 14 "REINSTATE apos failover"             danger
        orb_menu_add 15 "Checklist pre-switchover"

        orb_menu_group "CONSTRUCAO"
        orb_menu_add 16 "Recriar standby controlfile a partir do primary" danger
        orb_menu_add 17 "Sincronizar datafiles novos (standby_file_management)" danger
        orb_menu_add  0 "Voltar"
        orb_menu_render
        orb_log_raw ""

        orb_ask "Opcao" "1" || return 0
        case "$ORB_ANSWER" in
            1)  orb_dg_status ;;
            2)  orb_dg_params ;;
            3)  orb_dg_progress ;;
            4)  orb_dg_broker_status ;;
            5)  orb_dg_mrp_start ;;
            6)  orb_dg_mrp_stop ;;
            7)  orb_dg_recover_from_service ;;
            8)  orb_dg_create_srl ;;
            9)  orb_dg_refill_archives ;;
            10) orb_dg_snapshot_convert ;;
            11) orb_dg_snapshot_revert ;;
            12) orb_dg_switchover ;;
            13) orb_dg_failover ;;
            14) orb_dg_reinstate ;;
            15) orb_dg_switchover_checklist ;;
            16) orb_dg_recreate_standby_cf ;;
            17) orb_dg_sync_newfiles ;;
            0)  return 0 ;;
            "") ;;
            *)  orb_warn "Opcao invalida." ;;
        esac
        orb_pause
    done
}

orb_dg_status()
{
    orb_section "STATUS DATA GUARD"
    orb_field "Role"        "`orb_sql_value "(select database_role from v\\$database)"`"
    orb_field "Protecao"    "`orb_sql_value "(select protection_mode from v\\$database)"`"
    orb_field "Switchover"  "`orb_sql_value "(select switchover_status from v\\$database)"`"

    orb_section "PROCESSOS DE APPLY"
    orb_sql_query "select 'ORBR|'||process||'|'||status||'|'||nvl(to_char(sequence#),'-')||'|'||nvl(to_char(thread#),'-') from v\$managed_standby order by process;" \
        | while IFS='|' read _p _s _q _t
        do
            orb_log_raw "  $_p  status=$_s  thread=$_t  seq=$_q"
        done

    orb_section "GAP DE ARCHIVE"
    _gap=`orb_sql_value "(select to_char(count(*)) from v\\$archive_gap)"`
    if [ -n "$_gap" ] && [ "$_gap" != "0" ]; then
        orb_err "$_gap gaps detectados."
        orb_sql_query "select 'ORBR|'||thread#||'|'||low_sequence#||'|'||high_sequence# from v\$archive_gap;" \
            | while IFS='|' read _t _l _h
            do
                orb_log_raw "  thread $_t : sequences $_l a $_h ausentes"
            done
        orb_item "Use a opcao 4 (RECOVER FROM SERVICE) para fechar o gap sem backup."
    else
        orb_ok "Nenhum gap detectado."
    fi

    orb_section "ATRASO DO APPLY"
    orb_sql_query "select 'ORBR|'||name||'|'||value from v\$dataguard_stats where name in ('transport lag','apply lag','apply finish time');" \
        | while IFS='|' read _n _v ; do orb_field "$_n" "$_v" ; done
    return 0
}

orb_dg_mrp_start()
{
    orb_require_mounted || orb_require_open || return 1

    orb_ask "Usar CURRENT LOGFILE (real-time apply)? [S/N]" "S"
    if [ "`orb_upper $ORB_ANSWER`" = "S" ]; then
        _sql="alter database recover managed standby database using current logfile disconnect from session;"
    else
        _sql="alter database recover managed standby database disconnect from session;"
    fi

    orb_plan_begin "INICIAR MANAGED RECOVERY"
    orb_plan_field "Database" "${ORB_D_DBNAME:-?} / ${ORB_D_DBUNIQUE:-?}"
    orb_plan_field "Role"     "${ORB_D_ROLE:-?}"
    orb_plan_cmd "Managed recovery" "$_sql"
    orb_plan_risk "O standby passa a aplicar redo continuamente."
    orb_plan_risk "Com real-time apply, e preciso ter standby redo logs criados."
    orb_plan_confirm "INICIAR-MRP" || return 1

    _s="$ORB_RUNDIR/dg_mrp_start.sql"
    printf "%s\nexit\n" "$_sql" > "$_s"
    orb_exec_sql "dg_mrp_start" "$_s"
    orb_dg_status
    return 0
}

orb_dg_mrp_stop()
{
    orb_plan_begin "PARAR MANAGED RECOVERY"
    orb_plan_cmd "Cancelar MRP" "alter database recover managed standby database cancel;"
    orb_plan_risk "O standby para de aplicar redo e comeca a acumular atraso."
    orb_plan_confirm "PARAR-MRP" || return 1
    _s="$ORB_RUNDIR/dg_mrp_stop.sql"
    printf "alter database recover managed standby database cancel;\nexit\n" > "$_s"
    orb_exec_sql "dg_mrp_stop" "$_s"
    return 0
}

# ---------------------------------------------------------------------------
# RECOVER STANDBY FROM SERVICE  -  fecha gap sem depender de backup
# ---------------------------------------------------------------------------
orb_dg_recover_from_service()
{
    orb_title "RECOVER STANDBY FROM SERVICE"
    orb_check_version 12 || return 1
    orb_require_mounted  || return 1

    orb_item "Traz o redo/incremental direto do primary pela rede."
    orb_item "Nao usa backup: util quando ha gap grande ou a midia expirou."
    orb_log_raw ""

    orb_ask "Alias TNS do primary" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _svc="$ORB_ANSWER"

    orb_ask "Usar COMPRESSED BACKUPSET? [S/N]" "S"
    _cmp=""
    [ "`orb_upper $ORB_ANSWER`" = "S" ] && _cmp=" USING COMPRESSED BACKUPSET"

    _f="$ORB_RUNDIR/cmd_dg_service.rman"
    {
        echo "RECOVER DATABASE FROM SERVICE $_svc$_cmp;"
        echo "EXIT;"
    } > "$_f"

    orb_plan_begin "RECOVER STANDBY FROM SERVICE $_svc"
    orb_plan_field "Primary"  "$_svc"
    orb_plan_field "Standby"  "${ORB_D_DBUNIQUE:-?}"
    orb_plan_cmd "Parar o MRP antes" "alter database recover managed standby database cancel;"
    orb_plan_cmd_file "Recover pela rede" "$_f"
    orb_plan_risk "Le do PRIMARY: gera carga de I/O e rede em producao."
    orb_plan_risk "O MRP precisa estar parado durante a operacao."
    orb_plan_risk "Apos concluir, reinicie o managed recovery."
    orb_plan_confirm "RECUPERAR-DA-REDE" || return 1

    _s="$ORB_RUNDIR/dg_cancel.sql"
    printf "alter database recover managed standby database cancel;\nexit\n" > "$_s"
    orb_exec_sql "dg_cancel" "$_s"

    orb_exec_rman "dg_recover_service" "$_f" || return 1
    orb_postcheck_database
    orb_item "Reinicie o managed recovery (opcao 2) para o standby voltar a acompanhar."
    return 0
}

orb_dg_create_srl()
{
    orb_section "STANDBY REDO LOGS"
    _n=`orb_sql_value "(select to_char(count(*)) from v\\$standby_log)"`
    _o=`orb_sql_value "(select to_char(count(*)) from v\\$log)"`
    _sz=`orb_sql_value "(select to_char(max(bytes)/1024/1024) from v\\$log)"`
    _th=`orb_sql_value "(select to_char(count(distinct thread#)) from v\\$log)"`
    orb_field "Standby redo logs existentes" "`_orb_or_na "$_n"`"
    orb_field "Online redo logs"             "`_orb_or_na "$_o"`"
    orb_field "Tamanho (MB)"                 "`_orb_or_na "$_sz"`"
    orb_field "Threads"                      "`_orb_or_na "$_th"`"

    case "$_o" in ''|*[!0-9]*) orb_err "Nao consegui ler v\$log." ; return 1 ;; esac
    case "$_th" in ''|*[!0-9]*) _th=1 ;; esac
    _need=`expr $_o + $_th`
    orb_field "Recomendado" "$_need (online + threads)"

    if [ -n "$_n" ] && [ "$_n" -ge "$_need" ] 2>/dev/null; then
        orb_ok "Quantidade de standby redo logs adequada."
        return 0
    fi

    orb_ask "Destino dos SRL (+DG ou caminho, vazio = OMF)" "${ORB_D_DBCREATE}"
    _dst="$ORB_ANSWER"

    _s="$ORB_RUNDIR/dg_create_srl.sql"
    : > "$_s"
    _i=0
    _grp=90
    while [ $_i -lt $_need ]
    do
        if [ -n "$_dst" ]; then
            echo "alter database add standby logfile thread 1 group $_grp ('$_dst') size ${_sz}M;" >> "$_s"
        else
            echo "alter database add standby logfile thread 1 group $_grp size ${_sz}M;" >> "$_s"
        fi
        _grp=`expr $_grp + 1`
        _i=`expr $_i + 1`
    done
    echo "exit" >> "$_s"

    orb_plan_begin "CRIAR STANDBY REDO LOGS"
    orb_plan_field "Quantidade" "$_need"
    orb_plan_field "Tamanho"    "${_sz} MB"
    orb_plan_field "Destino"    "${_dst:-OMF}"
    orb_plan_cmd_file "Criacao dos SRL" "$_s"
    orb_plan_risk "SRL devem ter o MESMO tamanho dos online redo logs."
    orb_plan_risk "Sem SRL nao ha real-time apply."
    orb_plan_confirm "CRIAR-SRL" || return 1
    orb_exec_sql "dg_create_srl" "$_s"
    return $?
}

orb_dg_params()
{
    orb_section "PARAMETROS DE DATA GUARD"
    for _p in db_unique_name log_archive_config log_archive_dest_1 log_archive_dest_2 \
              log_archive_dest_state_2 fal_server fal_client standby_file_management \
              db_file_name_convert log_file_name_convert remote_login_passwordfile \
              dg_broker_start
    do
        _v=`orb_sql_value "(select value from v\\$parameter where name='$_p')"`
        orb_field "$_p" "`_orb_or_na "$_v"`"
    done

    orb_section "OBSERVACOES"
    _sfm=`orb_sql_value "(select value from v\\$parameter where name='standby_file_management')"`
    [ "$_sfm" != "AUTO" ] && orb_warn "standby_file_management nao esta AUTO: datafiles novos no primary nao serao criados aqui."
    _fal=`orb_sql_value "(select value from v\\$parameter where name='fal_server')"`
    [ -z "$_fal" ] && orb_warn "fal_server vazio: o standby nao consegue buscar logs faltantes sozinho."
    return 0
}

# ---------------------------------------------------------------------------
# PROGRESSO DO APPLY
# ---------------------------------------------------------------------------
orb_dg_progress()
{
    orb_section "SEQUENCIAS"
    orb_log_raw "  `printf '%-8s %-14s %12s %12s' THREAD ORIGEM ULT_RECEBIDA ULT_APLICADA`"
    orb_sql_query "select 'ORBR|'||thread#||'|'||to_char(max(case when applied='YES' then sequence# end))||'|'||to_char(max(sequence#))
                     from v\$archived_log where resetlogs_change# = (select resetlogs_change# from v\$database)
                    group by thread#;" \
        | while IFS='|' read _t _ap _rc
        do
            orb_log_raw "  `printf '%-8s %-14s %12s %12s' "$_t" "-" "$_rc" "$_ap"`"
        done

    orb_section "ATRASO"
    orb_sql_query "select 'ORBR|'||name||'|'||value||'|'||nvl(time_computed,'-') from v\$dataguard_stats;" \
        | while IFS='|' read _n _v _c ; do orb_field "$_n" "$_v  (em $_c)" ; done

    orb_section "ULTIMOS EVENTOS DO DATA GUARD"
    orb_sql_query "select 'ORBR|'||to_char(timestamp,'DD/MM HH24:MI')||'|'||message
                     from v\$dataguard_status
                    where rownum <= 20 order by timestamp desc;" \
        | while IFS='|' read _ts _m ; do orb_log_raw "  $_ts  $_m" ; done

    orb_section "ERROS RECENTES"
    _e=`orb_sql_value "(select to_char(count(*)) from v\\$dataguard_status where severity in ('Error','Fatal'))"`
    if [ -n "$_e" ] && [ "$_e" != "0" ]; then
        orb_err "$_e mensagens de erro em v\$dataguard_status."
        orb_sql_query "select 'ORBR|'||to_char(timestamp,'DD/MM HH24:MI')||'|'||message
                         from v\$dataguard_status where severity in ('Error','Fatal')
                          and rownum <= 10 order by timestamp desc;" \
            | while IFS='|' read _ts _m ; do orb_log_raw "  $_ts  $_m" ; done
    else
        orb_ok "Sem erros registrados."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# BROKER
# ---------------------------------------------------------------------------
orb_dg_broker_status()
{
    orb_section "BROKER"
    _b=`orb_sql_value "(select value from v\\$parameter where name='dg_broker_start')"`
    orb_field "dg_broker_start" "`_orb_or_na "$_b"`"
    if [ "$_b" != "TRUE" ]; then
        orb_warn "Broker desligado - a configuracao e gerida manualmente."
        orb_item "Neste modo, switchover e failover sao feitos por SQL (opcoes 12/13)."
        return 0
    fi

    for _p in dg_broker_config_file1 dg_broker_config_file2
    do
        _v=`orb_sql_value "(select value from v\\$parameter where name='$_p')"`
        orb_field "$_p" "`_orb_or_na "$_v"`"
    done

    if [ -x "$ORACLE_HOME/bin/dgmgrl" ]; then
        orb_section "SHOW CONFIGURATION"
        _o="$ORB_RUNDIR/dgmgrl.out"
        printf "show configuration;\nexit\n" | "$ORACLE_HOME/bin/dgmgrl" -silent / > "$_o" 2>&1
        orb_log_file "$_o"
        while IFS= read _l ; do orb_log_raw "  $_l" ; done < "$_o"
        orb_log_raw ""
        orb_item "Com broker ativo, PREFIRA dgmgrl para switchover/failover:"
        orb_item "  DGMGRL> switchover to '<db_unique_name>';"
        orb_item "  DGMGRL> failover to '<db_unique_name>';"
        orb_item "O broker cuida de MRP, redo transport e reinicio dos bancos."
    else
        orb_warn "dgmgrl nao encontrado em \$ORACLE_HOME/bin."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# REABASTECER ARCHIVES
# ---------------------------------------------------------------------------
orb_dg_refill_archives()
{
    orb_title "REABASTECER ARCHIVES FALTANTES"
    orb_item "Use quando os archives ja foram copiados do primary para um"
    orb_item "diretorio local, mas o standby nao os conhece."
    orb_log_raw ""
    orb_require_mounted || orb_require_open || return 1

    orb_ask "Diretorio com os archives copiados" "/tmp/arch_in"
    _d="$ORB_ANSWER"
    [ -d "$_d" ] || { orb_err "Diretorio nao encontrado: $_d" ; return 1 ; }

    _n=`ls "$_d" 2>/dev/null | wc -l | tr -d ' '`
    orb_field "Arquivos no diretorio" "$_n"
    [ "$_n" = "0" ] && { orb_err "Diretorio vazio." ; return 1 ; }

    _f="$ORB_RUNDIR/cmd_dg_refill.rman"
    {
        echo "CATALOG START WITH '$_d' NOPROMPT;"
        echo "EXIT;"
    } > "$_f"

    _s="$ORB_RUNDIR/dg_refill.sql"
    {
        echo "alter database recover managed standby database cancel;"
        echo "exit"
    } > "$_s"

    orb_plan_begin "CATALOGAR ARCHIVES E RETOMAR O APPLY"
    orb_plan_field "Diretorio" "$_d"
    orb_plan_field "Arquivos"  "$_n"
    orb_plan_cmd_file "Parar o MRP" "$_s"
    orb_plan_cmd_file "Catalogar"   "$_f"
    orb_plan_risk "CATALOG START WITH varre o diretorio inteiro - se houver lixo,"
    orb_plan_risk "ele tenta catalogar tudo."
    orb_plan_risk "Depois de catalogar, reinicie o MRP (opcao 5)."
    orb_plan_confirm "CATALOGAR-ARCHIVES" || return 1

    orb_exec_sql  "dg_cancel_refill" "$_s"
    orb_exec_rman "dg_refill" "$_f" || return 1
    orb_dg_status
    return 0
}

# ---------------------------------------------------------------------------
# SNAPSHOT STANDBY
#
# Abre o standby para escrita (teste, homologacao, validacao de patch) sem
# perder a protecao: o redo continua chegando e fica acumulado. Ao reverter,
# o Oracle faz flashback ate o ponto de garantia e aplica tudo que chegou.
#
# O que da errado na pratica: a FRA enche. Enquanto o standby esta snapshot,
# o flashback log cresce com TODA a alteracao feita nos testes, e o archive
# recebido do primary tambem fica retido. FRA pequena = standby quebrado.
# ---------------------------------------------------------------------------
orb_dg_snapshot_convert()
{
    orb_title "CONVERTER PARA SNAPSHOT STANDBY"
    orb_check_version 11 || return 1

    _role=`orb_sql_value "(select database_role from v\\$database)"`
    if [ "$_role" != "PHYSICAL STANDBY" ]; then
        orb_err "Role atual: ${_role:-?}. So converto a partir de PHYSICAL STANDBY."
        return 1
    fi

    orb_section "PRE-REQUISITOS"
    _lm=`orb_sql_value "(select log_mode from v\\$database)"`
    orb_field "Log mode" "`_orb_or_na "$_lm"`"
    [ "$_lm" != "ARCHIVELOG" ] && { orb_err "Standby precisa estar em ARCHIVELOG." ; return 1 ; }

    _fra=`orb_sql_value "(select value from v\\$parameter where name='db_recovery_file_dest')"`
    orb_field "FRA" "`_orb_or_na "$_fra"`"
    [ -z "$_fra" ] && { orb_err "Sem FRA configurada nao ha onde guardar o flashback log." ; return 1 ; }

    _used=`orb_sql_value "(select to_char(round(sum(percent_space_used))) from v\\$flash_recovery_area_usage)"`
    _sz=`orb_sql_value "(select to_char(round(space_limit/1024/1024)) from v\\$recovery_file_dest where rownum=1)"`
    orb_field "FRA tamanho (MB)" "`_orb_or_na "$_sz"`"
    orb_field "FRA em uso (%)"   "`_orb_or_na "$_used"`"
    if [ -n "$_used" ] && [ "$_used" -ge 70 ] 2>/dev/null; then
        orb_warn "FRA ja em ${_used}%. Snapshot standby VAI encher isso."
    fi

    orb_ask "Por quanto tempo o standby ficara em snapshot (horas, estimativa)" "4"
    _hrs="$ORB_ANSWER"

    _s="$ORB_RUNDIR/dg_snap_conv.sql"
    {
        echo "alter database recover managed standby database cancel;"
        echo "shutdown immediate"
        echo "startup mount"
        echo "alter database convert to snapshot standby;"
        echo "alter database open;"
        echo "select database_role, open_mode from v\$database;"
        echo "exit"
    } > "$_s"

    orb_plan_begin "CONVERTER PARA SNAPSHOT STANDBY"
    orb_plan_field "Database"      "${ORB_D_DBNAME:-?} / ${ORB_D_DBUNIQUE:-?}"
    orb_plan_field "Role atual"    "$_role"
    orb_plan_field "FRA"           "$_fra ($_sz MB, ${_used}% usado)"
    orb_plan_field "Janela prevista" "$_hrs horas"
    orb_plan_cmd_file "Conversao" "$_s"
    orb_plan_risk "O standby DEIXA de ser um destino de recovery valido enquanto"
    orb_plan_risk "estiver em snapshot. Se o primary cair agora, o failover exige"
    orb_plan_risk "reverter primeiro - o que leva tempo."
    orb_plan_risk "Todo redo recebido fica RETIDO na FRA ate a reversao."
    orb_plan_risk "O flashback log cresce com tudo que os testes escreverem."
    orb_plan_risk "FRA cheia = ORA-38760 e standby travado. Monitore durante a janela."
    orb_plan_risk "Se a protecao for MAXIMUM PROTECTION, converter derruba o primary."
    orb_plan_confirm "CONVERTER-SNAPSHOT" || return 1

    orb_exec_sql "dg_snap_conv" "$_s"
    _rc=$?
    orb_discover_instance 2>/dev/null

    orb_section "ENQUANTO ESTIVER EM SNAPSHOT"
    orb_item "Monitore: select * from v\$flash_recovery_area_usage;"
    orb_item "Reverta assim que o teste terminar - nao deixe para depois."
    return $_rc
}

orb_dg_snapshot_revert()
{
    orb_title "REVERTER PARA PHYSICAL STANDBY"

    _role=`orb_sql_value "(select database_role from v\\$database)"`
    if [ "$_role" != "SNAPSHOT STANDBY" ]; then
        orb_err "Role atual: ${_role:-?}. Nada a reverter."
        return 1
    fi

    orb_section "O QUE SERA DESCARTADO"
    _rp=`orb_sql_value "(select name from v\\$restore_point where guarantee_flashback_database='YES' and rownum=1)"`
    orb_field "Restore point de garantia" "`_orb_or_na "$_rp"`"
    orb_item "TUDO que foi escrito no standby desde a conversao sera PERDIDO."
    orb_item "Isso e o comportamento correto - o snapshot e descartavel."

    _s="$ORB_RUNDIR/dg_snap_rev.sql"
    {
        echo "shutdown immediate"
        echo "startup mount"
        echo "alter database convert to physical standby;"
        echo "shutdown immediate"
        echo "startup mount"
        echo "alter database recover managed standby database using current logfile disconnect from session;"
        echo "select database_role, open_mode from v\$database;"
        echo "exit"
    } > "$_s"

    orb_plan_begin "REVERTER SNAPSHOT PARA PHYSICAL STANDBY"
    orb_plan_field "Role atual" "$_role"
    orb_plan_cmd_file "Reversao e retomada do apply" "$_s"
    orb_plan_risk "Todos os dados gravados durante o snapshot serao descartados."
    orb_plan_risk "Depois da reversao o standby aplica TODO o redo acumulado - isso"
    orb_plan_risk "pode levar horas se a janela foi longa. Ele so volta a estar"
    orb_plan_risk "protegido de verdade quando o apply lag chegar a zero."
    orb_plan_confirm "REVERTER-PHYSICAL" || return 1

    orb_exec_sql "dg_snap_rev" "$_s"
    _rc=$?
    orb_discover_instance 2>/dev/null
    orb_dg_status
    orb_item "Acompanhe o apply lag ate zerar (opcao 3)."
    return $_rc
}

# ---------------------------------------------------------------------------
# CHECKLIST PRE-SWITCHOVER
# ---------------------------------------------------------------------------
orb_dg_switchover_checklist()
{
    orb_title "CHECKLIST PRE-SWITCHOVER"
    _fail=0

    _role=`orb_sql_value "(select database_role from v\\$database)"`
    _sw=`orb_sql_value   "(select switchover_status from v\\$database)"`
    orb_field "Role"              "`_orb_or_na "$_role"`"
    orb_field "switchover_status" "`_orb_or_na "$_sw"`"

    case "$_sw" in
        "TO STANDBY"|"TO PRIMARY"|"SESSIONS ACTIVE"|"TO LOGICAL STANDBY")
            orb_status_line ok "switchover_status permite a troca."
            [ "$_sw" = "SESSIONS ACTIVE" ] && orb_warn "Ha sessoes ativas - o comando exigira WITH SESSION SHUTDOWN."
            ;;
        "NOT ALLOWED")
            orb_status_line fail "switchover_status = NOT ALLOWED."
            orb_item "No standby isso costuma significar que o apply esta atrasado"
            orb_item "ou que o redo do primary nao esta chegando."
            _fail=1
            ;;
        *)
            orb_status_line warn "switchover_status = ${_sw:-<vazio>} - avalie antes de seguir."
            ;;
    esac

    _gap=`orb_sql_value "(select to_char(count(*)) from v\\$archive_gap)"`
    if [ "$_gap" = "0" ]; then
        orb_status_line ok "Sem gap de archive."
    else
        orb_status_line fail "$_gap gap(s) de archive - feche antes (opcao 7)."
        _fail=1
    fi

    _srl=`orb_sql_value "(select to_char(count(*)) from v\\$standby_log)"`
    if [ -n "$_srl" ] && [ "$_srl" != "0" ] 2>/dev/null; then
        orb_status_line ok "$_srl standby redo logs presentes."
    else
        orb_status_line fail "Sem standby redo logs - o novo standby nao tera real-time apply."
        _fail=1
    fi

    _sfm=`orb_sql_value "(select value from v\\$parameter where name='standby_file_management')"`
    if [ "$_sfm" = "AUTO" ]; then
        orb_status_line ok "standby_file_management = AUTO."
    else
        orb_status_line warn "standby_file_management = ${_sfm:-?} (recomendado AUTO)."
    fi

    _fal=`orb_sql_value "(select value from v\\$parameter where name='fal_server')"`
    if [ -n "$_fal" ]; then
        orb_status_line ok "fal_server = $_fal"
    else
        orb_status_line warn "fal_server vazio - o futuro standby nao busca logs sozinho."
    fi

    _lad=`orb_sql_value "(select to_char(count(*)) from v\\$archive_dest where status='VALID' and target='STANDBY')"`
    orb_field "Destinos STANDBY validos" "`_orb_or_na "$_lad"`"
    if [ "$_lad" = "0" ]; then
        orb_status_line warn "Nenhum destino STANDBY valido - apos a troca, o redo nao volta."
    fi

    _err=`orb_sql_value "(select to_char(count(*)) from v\\$archive_dest where status='ERROR')"`
    if [ -n "$_err" ] && [ "$_err" != "0" ]; then
        orb_status_line fail "$_err destino(s) de archive em ERROR."
        orb_sql_query "select 'ORBR|'||dest_id||'|'||error from v\$archive_dest where status='ERROR';" \
            | while IFS='|' read _i _e ; do orb_item "dest_$_i : $_e" ; done
        _fail=1
    fi

    _tmp=`orb_sql_value "(select to_char(count(*)) from v\\$tempfile)"`
    orb_field "Tempfiles" "`_orb_or_na "$_tmp"`"
    [ "$_tmp" = "0" ] && orb_status_line warn "Sem tempfile - depois do switchover, ORA-25153 na primeira query com sort."

    orb_section "VEREDITO"
    if [ $_fail -eq 0 ]; then
        orb_ok "Nada bloqueia o switchover pelo que da para checar daqui."
        orb_item "Confira TAMBEM no outro lado: role, apply lag e switchover_status."
    else
        orb_err "Ha bloqueios acima. Resolva antes de tentar o switchover."
    fi
    orb_log_raw ""
    orb_item "Lembre do que nao esta no banco: tnsnames, listener, password file,"
    orb_item "cron/jobs, DNS/VIP das aplicacoes e wallet TDE precisam existir do"
    orb_item "outro lado tambem."
    return $_fail
}

# ---------------------------------------------------------------------------
# SWITCHOVER
# ---------------------------------------------------------------------------
orb_dg_switchover()
{
    orb_title "SWITCHOVER"
    orb_item "Troca planejada de papeis, sem perda de dados. Os dois bancos"
    orb_item "precisam estar saudaveis e o redo em dia."
    orb_log_raw ""

    orb_dg_switchover_checklist
    _ck=$?
    if [ $_ck -ne 0 ]; then
        orb_ask "O checklist apontou bloqueios. Continuar mesmo assim? [S/N]" "N"
        [ "`orb_upper $ORB_ANSWER`" = "S" ] || return 1
    fi

    _role=`orb_sql_value "(select database_role from v\\$database)"`
    _sw=`orb_sql_value   "(select switchover_status from v\\$database)"`

    _b=`orb_sql_value "(select value from v\\$parameter where name='dg_broker_start')"`
    if [ "$_b" = "TRUE" ]; then
        orb_section "BROKER ATIVO"
        orb_err "dg_broker_start=TRUE."
        orb_item "Com broker ligado, switchover por SQL deixa a configuracao"
        orb_item "inconsistente. Use o dgmgrl:"
        orb_item ""
        orb_item "  dgmgrl sys@<primary>"
        orb_item "  DGMGRL> show configuration;"
        orb_item "  DGMGRL> validate database '<standby_unique_name>';"
        orb_item "  DGMGRL> switchover to '<standby_unique_name>';"
        orb_item ""
        orb_item "Nao executo switchover por SQL com broker ligado."
        return 1
    fi

    _shut=""
    [ "$_sw" = "SESSIONS ACTIVE" ] && _shut=" with session shutdown"

    _s="$ORB_RUNDIR/dg_switchover.sql"
    if [ "$_role" = "PRIMARY" ]; then
        _dir="PRIMARY -> PHYSICAL STANDBY"
        {
            echo "alter database commit to switchover to physical standby${_shut};"
            echo "shutdown immediate"
            echo "startup mount"
            echo "alter database recover managed standby database using current logfile disconnect from session;"
            echo "select database_role, open_mode from v\$database;"
            echo "exit"
        } > "$_s"
    else
        _dir="PHYSICAL STANDBY -> PRIMARY"
        {
            echo "alter database recover managed standby database cancel;"
            echo "alter database commit to switchover to primary${_shut};"
            echo "shutdown immediate"
            echo "startup"
            echo "select database_role, open_mode from v\$database;"
            echo "exit"
        } > "$_s"
    fi

    orb_plan_begin "SWITCHOVER  ($_dir)"
    orb_plan_field "Database"          "${ORB_D_DBNAME:-?} / ${ORB_D_DBUNIQUE:-?}"
    orb_plan_field "Role atual"        "$_role"
    orb_plan_field "switchover_status" "$_sw"
    orb_plan_field "Direcao"           "$_dir"
    orb_plan_cmd_file "Comandos deste lado" "$_s"
    orb_plan_risk "SWITCHOVER E UMA OPERACAO DE DOIS LADOS. Este script cuida"
    orb_plan_risk "APENAS deste banco. O outro lado precisa do comando complementar,"
    orb_plan_risk "na ordem certa, ou a configuracao fica com dois standbys."
    orb_plan_risk "Ordem correta: primeiro o PRIMARY vira standby; so depois o"
    orb_plan_risk "STANDBY vira primary."
    orb_plan_risk "As aplicacoes precisam ser redirecionadas - o switchover nao"
    orb_plan_risk "move VIP, DNS nem connect string."
    orb_plan_risk "Se algo falhar no meio, voce pode ficar sem primary. Tenha o"
    orb_plan_risk "telefone do outro lado aberto antes de confirmar."
    orb_plan_confirm "SWITCHOVER-AGORA" || return 1

    orb_exec_sql "dg_switchover" "$_s"
    _rc=$?
    orb_discover_instance 2>/dev/null

    orb_section "AGORA, DO OUTRO LADO"
    if [ "$_role" = "PRIMARY" ]; then
        orb_item "No STANDBY, execute:"
        orb_item "  alter database recover managed standby database cancel;"
        orb_item "  alter database commit to switchover to primary;"
        orb_item "  shutdown immediate"
        orb_item "  startup"
    else
        orb_item "Este banco agora e o PRIMARY. Confirme no outro lado que ele"
        orb_item "esta em PHYSICAL STANDBY com MRP rodando."
    fi
    orb_log_raw ""
    orb_item "Depois: conferir tempfiles, servicos (srvctl), jobs e conexoes."
    return $_rc
}

# ---------------------------------------------------------------------------
# FAILOVER
# ---------------------------------------------------------------------------
orb_dg_failover()
{
    orb_title "FAILOVER"
    orb_log_raw ""
    orb_status_line crit "FAILOVER assume que o PRIMARY ESTA PERDIDO."
    orb_item "Se o primary ainda responde, o comando certo e SWITCHOVER (opcao 12)."
    orb_item "Failover com o primary vivo produz duas cabecas e perda de dados."
    orb_log_raw ""

    _role=`orb_sql_value "(select database_role from v\\$database)"`
    if [ "$_role" != "PHYSICAL STANDBY" ]; then
        orb_err "Este banco esta como '${_role:-?}'. Failover se faz NO STANDBY."
        return 1
    fi

    orb_section "QUANTO SE PERDE"
    _lag=`orb_sql_value "(select value from v\\$dataguard_stats where name='apply lag')"`
    _tl=`orb_sql_value  "(select value from v\\$dataguard_stats where name='transport lag')"`
    orb_field "apply lag"     "`_orb_or_na "$_lag"`"
    orb_field "transport lag" "`_orb_or_na "$_tl"`"
    _gap=`orb_sql_value "(select to_char(count(*)) from v\\$archive_gap)"`
    orb_field "Gaps"          "`_orb_or_na "$_gap"`"
    if [ -n "$_gap" ] && [ "$_gap" != "0" ]; then
        orb_err "Ha gap. O que estiver no gap sera PERDIDO no failover."
        orb_item "Se o storage do primary ainda estiver acessivel, tente copiar os"
        orb_item "archives faltantes e usar a opcao 9 ANTES de falhar sobre."
    fi

    orb_ask "Tentar aplicar todo o redo disponivel antes (recomendado)? [S/N]" "S"
    _flush="N"
    [ "`orb_upper $ORB_ANSWER`" = "S" ] && _flush="S"

    _s="$ORB_RUNDIR/dg_failover.sql"
    : > "$_s"
    echo "alter database recover managed standby database cancel;" >> "$_s"
    if [ "$_flush" = "S" ]; then
        echo "alter database recover managed standby database finish force;" >> "$_s"
    fi
    {
        echo "alter database activate physical standby database;"
        echo "shutdown immediate"
        echo "startup"
        echo "select database_role, open_mode from v\$database;"
        echo "exit"
    } >> "$_s"

    orb_plan_begin "FAILOVER PARA ${ORB_D_DBUNIQUE:-ESTE STANDBY}"
    orb_plan_field "Database"      "${ORB_D_DBNAME:-?} / ${ORB_D_DBUNIQUE:-?}"
    orb_plan_field "Role atual"    "$_role"
    orb_plan_field "apply lag"     "${_lag:-?}"
    orb_plan_field "Gaps"          "${_gap:-?}"
    orb_plan_cmd_file "Failover" "$_s"
    orb_plan_risk "ISTO E IRREVERSIVEL sem flashback: o standby vira primary com"
    orb_plan_risk "uma nova incarnation (RESETLOGS)."
    orb_plan_risk "O primary antigo NAO volta sozinho para a configuracao - ele"
    orb_plan_risk "precisa de REINSTATE (opcao 14) ou de ser reconstruido."
    orb_plan_risk "Tudo que estava em transito e nao chegou aqui esta PERDIDO."
    orb_plan_risk "CONFIRME que o primary esta realmente fora antes de seguir."
    orb_plan_risk "Faca um backup completo do novo primary logo apos o failover:"
    orb_plan_risk "a incarnation antiga deixa de servir para restore direto."
    orb_plan_confirm "FAILOVER-PRIMARY-PERDIDO" || return 1

    orb_exec_sql "dg_failover" "$_s"
    _rc=$?
    orb_discover_instance 2>/dev/null
    orb_postcheck_database

    orb_section "IMEDIATAMENTE APOS O FAILOVER"
    orb_item "1. Conferir tempfiles (PÓS-RESTORE)."
    orb_item "2. Redirecionar as aplicacoes."
    orb_item "3. BACKUP NIVEL 0 do novo primary - prioridade alta."
    orb_item "4. Decidir sobre o primary antigo: reinstate ou rebuild."
    return $_rc
}

# ---------------------------------------------------------------------------
# REINSTATE
# ---------------------------------------------------------------------------
orb_dg_reinstate()
{
    orb_title "REINSTATE APOS FAILOVER"
    orb_item "Traz o primary ANTIGO de volta como standby do novo primary,"
    orb_item "usando flashback ate o SCN do failover - sem restore completo."
    orb_log_raw ""

    _fb=`orb_sql_value "(select flashback_on from v\\$database)"`
    orb_field "Flashback database" "`_orb_or_na "$_fb"`"
    if [ "$_fb" != "YES" ]; then
        orb_err "Flashback desligado neste banco."
        orb_item "Sem flashback, o primary antigo NAO pode ser reinstalado por aqui."
        orb_item "Caminho alternativo: recriar o standby (DUPLICATE FROM ACTIVE"
        orb_item "DATABASE FOR STANDBY, no menu DUPLICATE)."
        return 1
    fi

    orb_ask "Alias TNS do NOVO primary" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _svc="$ORB_ANSWER"

    orb_section "SCN DO FAILOVER"
    orb_item "Execute no NOVO primary e anote o valor:"
    orb_item "  select to_char(standby_became_primary_scn) from v\$database;"
    orb_log_raw ""
    orb_ask "standby_became_primary_scn do novo primary" ""
    [ -z "$ORB_ANSWER" ] && { orb_err "Sem o SCN nao da para reinstalar." ; return 1 ; }
    _scn="$ORB_ANSWER"

    _s="$ORB_RUNDIR/dg_reinstate.sql"
    {
        echo "shutdown immediate"
        echo "startup mount"
        echo "flashback database to scn $_scn;"
        echo "alter database convert to physical standby;"
        echo "shutdown immediate"
        echo "startup mount"
        echo "alter database recover managed standby database using current logfile disconnect from session;"
        echo "select database_role, open_mode from v\$database;"
        echo "exit"
    } > "$_s"

    orb_plan_begin "REINSTATE DO PRIMARY ANTIGO"
    orb_plan_field "Este banco"   "${ORB_D_DBNAME:-?} / ${ORB_D_DBUNIQUE:-?}"
    orb_plan_field "Novo primary" "$_svc"
    orb_plan_field "SCN alvo"     "$_scn"
    orb_plan_cmd_file "Reinstate" "$_s"
    orb_plan_risk "Todas as transacoes feitas NESTE banco depois do SCN $_scn serao"
    orb_plan_risk "DESCARTADAS. Se alguem gravou aqui achando que era o primary,"
    orb_plan_risk "esses dados somem. Confira antes."
    orb_plan_risk "O flashback precisa alcancar o SCN - se os flashback logs ja"
    orb_plan_risk "foram reciclados, o comando falha (ORA-38729/38754)."
    orb_plan_risk "fal_server e log_archive_dest deste banco devem apontar para o"
    orb_plan_risk "NOVO primary antes de retomar o apply."
    orb_plan_confirm "REINSTATE-COMO-STANDBY" || return 1

    orb_exec_sql "dg_reinstate" "$_s"
    _rc=$?
    orb_discover_instance 2>/dev/null
    orb_dg_status
    return $_rc
}

# ---------------------------------------------------------------------------
# RECRIAR STANDBY CONTROLFILE
# ---------------------------------------------------------------------------
orb_dg_recreate_standby_cf()
{
    orb_title "RECRIAR STANDBY CONTROLFILE A PARTIR DO PRIMARY"
    orb_item "Use quando o controlfile do standby esta fora de sincronia com a"
    orb_item "estrutura do primary (datafile novo, rename, resize que nao passou)."
    orb_log_raw ""
    orb_check_version 12 || return 1

    orb_ask "Alias TNS do primary" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _svc="$ORB_ANSWER"

    _f="$ORB_RUNDIR/cmd_dg_stbycf.rman"
    {
        echo "RESTORE STANDBY CONTROLFILE FROM SERVICE $_svc;"
        echo "EXIT;"
    } > "$_f"

    _s1="$ORB_RUNDIR/dg_cf_pre.sql"
    {
        echo "alter database recover managed standby database cancel;"
        echo "shutdown immediate"
        echo "startup nomount"
        echo "exit"
    } > "$_s1"

    _s2="$ORB_RUNDIR/dg_cf_pos.sql"
    {
        echo "alter database mount standby database;"
        echo "exit"
    } > "$_s2"

    _f2="$ORB_RUNDIR/cmd_dg_stbycf2.rman"
    {
        echo "SWITCH DATABASE TO COPY;"
        echo "EXIT;"
    } > "$_f2"

    orb_plan_begin "RESTORE STANDBY CONTROLFILE FROM SERVICE"
    orb_plan_field "Primary" "$_svc"
    orb_plan_field "Standby" "${ORB_D_DBUNIQUE:-?}"
    orb_plan_cmd_file "Parar apply e ir para NOMOUNT" "$_s1"
    orb_plan_cmd_file "Restaurar o controlfile"       "$_f"
    orb_plan_cmd_file "Montar como standby"           "$_s2"
    orb_plan_cmd_file "Reapontar os datafiles"        "$_f2"
    orb_plan_risk "O controlfile novo vem com os CAMINHOS DO PRIMARY. Em ASM com"
    orb_plan_risk "diskgroup de nome diferente, ou em filesystem com layout distinto,"
    orb_plan_risk "e obrigatorio db_file_name_convert / CATALOG + SWITCH."
    orb_plan_risk "Todo o historico de backup registrado no controlfile do standby"
    orb_plan_risk "e substituido pelo do primary."
    orb_plan_risk "SWITCH DATABASE TO COPY so resolve se os datafiles do standby"
    orb_plan_risk "estiverem catalogados. Confira o resultado antes de subir o MRP."
    orb_plan_confirm "RECRIAR-STANDBY-CF" || return 1

    orb_exec_sql  "dg_cf_pre"  "$_s1"
    orb_exec_rman "dg_stbycf"  "$_f"  || return 1
    orb_exec_sql  "dg_cf_pos"  "$_s2"
    orb_exec_rman "dg_stbycf2" "$_f2"
    orb_postcheck_database
    orb_item "Confira v\$datafile antes de reiniciar o managed recovery."
    return 0
}

# ---------------------------------------------------------------------------
# SINCRONIZAR DATAFILES NOVOS
# ---------------------------------------------------------------------------
orb_dg_sync_newfiles()
{
    orb_title "DATAFILES NOVOS NO PRIMARY QUE NAO CHEGARAM AQUI"
    orb_item "Sintoma classico: MRP para com ORA-01111/ORA-01110 apontando para"
    orb_item "'UNNAMED0000NN' em \$ORACLE_HOME/dbs."
    orb_log_raw ""

    orb_section "ARQUIVOS SEM NOME"
    _n=`orb_sql_value "(select to_char(count(*)) from v\\$datafile where name like '%UNNAMED%')"`
    orb_field "Datafiles UNNAMED" "`_orb_or_na "$_n"`"
    if [ -z "$_n" ] || [ "$_n" = "0" ]; then
        orb_ok "Nenhum datafile UNNAMED."
        _sfm=`orb_sql_value "(select value from v\\$parameter where name='standby_file_management')"`
        [ "$_sfm" != "AUTO" ] && orb_warn "standby_file_management=${_sfm:-?} - o proximo datafile novo vai dar problema."
        return 0
    fi

    orb_sql_query "select 'ORBR|'||file#||'|'||name from v\$datafile where name like '%UNNAMED%';" \
        | while IFS='|' read _fn _nm ; do orb_log_raw "  file $_fn : $_nm" ; done

    orb_ask "Destino dos datafiles (+DG ou caminho)" "${ORB_D_DBCREATE:-+DATA}"
    _dst="$ORB_ANSWER"

    _s="$ORB_RUNDIR/dg_newfiles.sql"
    {
        echo "alter database recover managed standby database cancel;"
        echo "alter system set standby_file_management=manual scope=memory;"
    } > "$_s"
    orb_sql_query "select 'ORBR|'||file#||'|'||name from v\$datafile where name like '%UNNAMED%';" \
        | while IFS='|' read _fn _nm
        do
            [ -n "$_fn" ] || continue
            echo "alter database create datafile $_fn as '$_dst';" >> "$_s"
        done
    {
        echo "alter system set standby_file_management=auto scope=memory;"
        echo "alter database recover managed standby database using current logfile disconnect from session;"
        echo "exit"
    } >> "$_s"

    orb_plan_begin "CRIAR DATAFILES AUSENTES NO STANDBY"
    orb_plan_field "Quantidade" "$_n"
    orb_plan_field "Destino"    "$_dst"
    orb_plan_cmd_file "Criacao e retomada do apply" "$_s"
    orb_plan_risk "O datafile e criado vazio e reconstruido pelo redo - reserve"
    orb_plan_risk "tempo e espaco proporcionais ao tamanho no primary."
    orb_plan_risk "standby_file_management volta para AUTO no fim; confirme depois,"
    orb_plan_risk "porque em MANUAL o proximo datafile novo repete o problema."
    orb_plan_risk "Se o parametro estiver no spfile como MANUAL, ajuste tambem la."
    orb_plan_confirm "CRIAR-DATAFILES" || return 1

    orb_exec_sql "dg_newfiles" "$_s"
    _rc=$?
    orb_dg_status
    return $_rc
}
