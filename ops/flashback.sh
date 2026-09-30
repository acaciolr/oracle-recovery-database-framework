#!/usr/bin/sh
###############################################################################
# ops/flashback.sh - Flashback Database / Table / Drop / Data Archive
###############################################################################

orb_op_flashback_menu()
{
    while :
    do
        orb_title "FLASHBACK"
        orb_field "flashback_on" "`orb_sql_value "(select flashback_on from v\\$database)"`"
        orb_log_raw ""
        orb_menu_begin
        orb_menu_group "SITUACAO (somente leitura)"
        orb_menu_add  1 "Status, janela e restore points"
        orb_menu_add  2 "Uso da FRA (quanto de flashback cabe)"
        orb_menu_add  3 "Flashback Data Archive"

        orb_menu_group "VOLTAR NO TEMPO"
        orb_menu_add  4 "Flashback DATABASE"                 danger
        orb_menu_add  5 "Flashback TABLE"                    danger
        orb_menu_add  6 "Flashback DROP (recyclebin)"        danger
        orb_menu_add  7 "Flashback QUERY / VERSIONS (leitura)"
        orb_menu_add  8 "Flashback TRANSACTION (roteiro)"

        orb_menu_group "RESTORE POINTS"
        orb_menu_add  9 "Criar restore point"                danger
        orb_menu_add 10 "Apagar restore point"               danger

        orb_menu_group "CONFIGURACAO"
        orb_menu_add 11 "Ligar / desligar FLASHBACK DATABASE" danger
        orb_menu_add 12 "Ajustar retention target"            danger
        orb_menu_add  0 "Voltar"
        orb_menu_render
        orb_log_raw ""

        orb_ask "Opcao" "1" || return 0
        case "$ORB_ANSWER" in
            1)  orb_fb_status ;;
            2)  orb_fb_fra ;;
            3)  orb_fb_fda ;;
            4)  orb_fb_database ;;
            5)  orb_fb_table ;;
            6)  orb_fb_drop ;;
            7)  orb_fb_query ;;
            8)  orb_fb_transaction ;;
            9)  orb_fb_create_rp ;;
            10) orb_fb_drop_rp ;;
            11) orb_fb_toggle ;;
            12) orb_fb_retention ;;
            0)  return 0 ;;
            "") ;;
            *)  orb_warn "Opcao invalida." ;;
        esac
        orb_pause
    done
}

orb_fb_status()
{
    orb_section "FLASHBACK DATABASE"
    orb_field "flashback_on"  "`orb_sql_value "(select flashback_on from v\\$database)"`"
    orb_field "Retention alvo" "`orb_sql_value "(select value from v\\$parameter where name='db_flashback_retention_target')"` min"
    orb_field "FRA"            "`_orb_or_na "$ORB_D_FRA"`"

    _oldest=`orb_sql_value "(select to_char(oldest_flashback_time,'YYYY-MM-DD HH24:MI:SS') from v\\$flashback_database_log)"`
    _oscn=`orb_sql_value   "(select to_char(oldest_flashback_scn) from v\\$flashback_database_log)"`
    orb_field "Flashback mais antigo" "`_orb_or_na "$_oldest"` (SCN `_orb_or_na "$_oscn"`)"
    orb_item "Nao e possivel voltar para antes desse ponto."

    orb_section "RESTORE POINTS"
    orb_sql_query "select 'ORBR|'||name||'|'||to_char(scn)||'|'||nvl(to_char(time,'YYYY-MM-DD HH24:MI:SS'),'-')||'|'||guarantee_flashback_database from v\$restore_point order by scn;" \
        | while IFS='|' read _n _s _t _g
        do
            orb_log_raw "  $_n  scn=$_s  time=$_t  guaranteed=$_g"
        done
    return 0
}

orb_fb_database()
{
    orb_title "FLASHBACK DATABASE"
    orb_require_mounted || return 1

    _on=`orb_sql_value "(select flashback_on from v\\$database)"`
    if [ "$_on" != "YES" ]; then
        orb_err "Flashback Database nao esta habilitado (flashback_on=$_on)."
        orb_item "Sem flashback logs nao ha como voltar. Considere PITR."
        return 1
    fi

    orb_fb_status

    orb_ask "Alvo [SCN|TIME|RESTORE POINT]" "RESTORE POINT"
    _t=`orb_upper "$ORB_ANSWER"`
    case "$_t" in
        SCN)
            orb_ask "SCN" ""
            _to="TO SCN $ORB_ANSWER" ; _desc="SCN $ORB_ANSWER" ;;
        TIME)
            orb_ask "Data/hora (DD-MM-YYYY HH24:MI:SS)" ""
            _to="TO TIMESTAMP TO_TIMESTAMP('$ORB_ANSWER','DD-MM-YYYY HH24:MI:SS')"
            _desc="TIME $ORB_ANSWER" ;;
        *)
            orb_ask "Nome do restore point" ""
            _to="TO RESTORE POINT $ORB_ANSWER" ; _desc="RESTORE POINT $ORB_ANSWER" ;;
    esac
    [ -z "$ORB_ANSWER" ] && return 1

    _f="$ORB_RUNDIR/cmd_flashback.rman"
    { echo "FLASHBACK DATABASE $_to;" ; echo "EXIT;" ; } > "$_f"

    orb_plan_begin "FLASHBACK DATABASE $_desc"
    orb_plan_field "Database" "${ORB_D_DBNAME:-?}"
    orb_plan_field "Alvo"     "$_desc"
    orb_plan_cmd_file "Flashback" "$_f"
    orb_plan_cmd "Abertura" \
        "sqlplus / as sysdba <<EOF
alter database open resetlogs;
EOF"
    orb_plan_risk "TODOS os dados posteriores ao ponto serao PERDIDOS."
    orb_plan_risk "OPEN RESETLOGS cria nova incarnation."
    orb_plan_risk "Antes de abrir, use OPEN READ ONLY para conferir se o ponto e o certo."
    orb_plan_confirm "FLASHBACK" || return 1

    orb_exec_rman "flashback" "$_f" || return 1

    orb_section "CONFERENCIA ANTES DE ABRIR"
    orb_item "Recomendado: abrir READ ONLY primeiro e validar os dados."
    orb_item "  alter database open read only;"
    orb_item "Se o ponto estiver errado, ainda da para refazer o flashback."
    orb_confirm "Abrir com RESETLOGS agora (irreversivel)?" "RESETLOGS" || {
        orb_log "Banco deixado montado."
        return 0
    }
    _s="$ORB_RUNDIR/fb_open.sql"
    printf "alter database open resetlogs;\nexit\n" > "$_s"
    orb_exec_sql "fb_open_resetlogs" "$_s"
    orb_warn "Nova incarnation criada. Faca backup NIVEL 0 antes de liberar o banco."
    return 0
}

orb_fb_table()
{
    orb_title "FLASHBACK TABLE"
    orb_require_open || return 1

    orb_ask "Schema.Tabela" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _tab="$ORB_ANSWER"

    orb_ask "Alvo [SCN|TIME|RESTORE POINT]" "TIME"
    _t=`orb_upper "$ORB_ANSWER"`
    case "$_t" in
        SCN)  orb_ask "SCN" "" ; _to="TO SCN $ORB_ANSWER" ;;
        TIME) orb_ask "Data/hora (DD-MM-YYYY HH24:MI:SS)" ""
              _to="TO TIMESTAMP TO_TIMESTAMP('$ORB_ANSWER','DD-MM-YYYY HH24:MI:SS')" ;;
        *)    orb_ask "Restore point" "" ; _to="TO RESTORE POINT $ORB_ANSWER" ;;
    esac
    [ -z "$ORB_ANSWER" ] && return 1

    _s="$ORB_RUNDIR/fb_table.sql"
    {
        echo "alter table $_tab enable row movement;"
        echo "flashback table $_tab $_to;"
        echo "exit"
    } > "$_s"

    orb_plan_begin "FLASHBACK TABLE $_tab"
    orb_plan_field "Tabela" "$_tab"
    orb_plan_field "Alvo"   "$_to"
    orb_plan_cmd_file "Flashback table" "$_s"
    orb_plan_risk "Alteracoes na tabela apos o ponto serao perdidas."
    orb_plan_risk "Exige ROW MOVEMENT habilitado e UNDO retido o suficiente."
    orb_plan_risk "Se o undo ja foi reciclado: ORA-01555 / ORA-08180."
    orb_plan_confirm "FLASHBACK-TABLE" || return 1
    orb_exec_sql "fb_table" "$_s"
    return $?
}

orb_fb_drop()
{
    orb_title "FLASHBACK DROP"
    orb_require_open || return 1

    orb_section "RECYCLEBIN"
    orb_sql_query "select 'ORBR|'||object_name||'|'||original_name||'|'||type||'|'||droptime from recyclebin order by droptime desc;" \
        | head -30 | while IFS='|' read _o _n _t _d
        do
            orb_log_raw "  $_n  ($_t)  dropado em $_d   [$_o]"
        done

    orb_ask "Nome ORIGINAL da tabela a restaurar" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _tab="$ORB_ANSWER"

    orb_ask "Renomear para (vazio = nome original)" ""
    _rn=""
    [ -n "$ORB_ANSWER" ] && _rn=" rename to $ORB_ANSWER"

    _s="$ORB_RUNDIR/fb_drop.sql"
    { echo "flashback table $_tab to before drop$_rn;" ; echo "exit" ; } > "$_s"

    orb_plan_begin "FLASHBACK TABLE $_tab TO BEFORE DROP"
    orb_plan_cmd_file "Flashback drop" "$_s"
    orb_plan_risk "Se houver mais de uma versao no recyclebin, a mais recente e usada."
    orb_plan_risk "Indices e constraints voltam com nomes gerados pelo sistema."
    orb_plan_confirm "RESTAURAR-TABELA" || return 1
    orb_exec_sql "fb_drop" "$_s"
    return $?
}

orb_fb_fda()
{
    orb_section "FLASHBACK DATA ARCHIVE"
    orb_sql_query "select 'ORBR|'||flashback_archive_name||'|'||retention_in_days||'|'||status from dba_flashback_archive;" \
        | while IFS='|' read _n _r _s
        do
            orb_log_raw "  $_n  retencao=${_r}d  status=$_s"
        done
    orb_section "TABELAS COM FDA"
    orb_sql_query "select 'ORBR|'||owner_name||'.'||table_name||'|'||flashback_archive_name from dba_flashback_archive_tables;" \
        | while IFS='|' read _t _a ; do orb_log_raw "  $_t -> $_a" ; done
    return 0
}

orb_fb_create_rp()
{
    orb_ask "Nome do restore point" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _n="$ORB_ANSWER"
    orb_ask "GUARANTEED? [S/N]" "N"
    _g=""
    [ "`orb_upper $ORB_ANSWER`" = "S" ] && _g=" guarantee flashback database"

    _s="$ORB_RUNDIR/fb_create_rp.sql"
    { echo "create restore point $_n$_g;" ; echo "exit" ; } > "$_s"

    orb_plan_begin "CRIAR RESTORE POINT $_n"
    orb_plan_cmd_file "Restore point" "$_s"
    [ -n "$_g" ] && orb_plan_risk "GUARANTEED impede a reciclagem dos flashback logs - a FRA pode encher e travar o banco."
    orb_plan_confirm "CRIAR" || return 1
    orb_exec_sql "fb_create_rp" "$_s"
    return $?
}

# ---------------------------------------------------------------------------
# USO DA FRA
#
# A pergunta pratica nao e "flashback esta ligado", e "ate onde eu consigo
# voltar antes de o log ser reciclado". Isso e espaco, nao configuracao.
# ---------------------------------------------------------------------------
orb_fb_fra()
{
    orb_section "FLASH RECOVERY AREA"
    _lim=`orb_sql_value "(select to_char(round(space_limit/1024/1024)) from v\\$recovery_file_dest where rownum=1)"`
    _use=`orb_sql_value "(select to_char(round(space_used/1024/1024)) from v\\$recovery_file_dest where rownum=1)"`
    _rec=`orb_sql_value "(select to_char(round(space_reclaimable/1024/1024)) from v\\$recovery_file_dest where rownum=1)"`
    orb_field "Destino"       "`_orb_or_na "$ORB_D_FRA"`"
    orb_field "Limite"        "`_orb_or_na "$_lim"` MB"
    orb_field "Usado"         "`_orb_or_na "$_use"` MB"
    orb_field "Recuperavel"   "`_orb_or_na "$_rec"` MB"

    if [ -n "$_lim" ] && [ -n "$_use" ] && [ "$_lim" -gt 0 ] 2>/dev/null; then
        _pct=`expr $_use \* 100 / $_lim`
        orb_progress_bar "$_use" "$_lim" 40
        if [ "$_pct" -ge 90 ]; then
            orb_err "FRA em ${_pct}% - risco de ORA-19809 e banco travado."
        elif [ "$_pct" -ge 75 ]; then
            orb_warn "FRA em ${_pct}%."
        fi
    fi

    orb_section "COMPOSICAO"
    orb_sql_query "select 'ORBR|'||file_type||'|'||to_char(percent_space_used)||'|'||to_char(percent_space_reclaimable)||'|'||to_char(number_of_files)
                     from v\$flash_recovery_area_usage order by file_type;" \
        | while IFS='|' read _t _u _r _n
        do
            orb_log_raw "  `printf '%-24s usado=%5s%%  recuperavel=%5s%%  arquivos=%s' "$_t" "$_u" "$_r" "$_n"`"
        done

    orb_section "JANELA REAL DE FLASHBACK"
    _o=`orb_sql_value "(select to_char(oldest_flashback_time,'DD/MM/YYYY HH24:MI:SS') from v\\$flashback_database_log)"`
    _rt=`orb_sql_value "(select value from v\\$parameter where name='db_flashback_retention_target')"`
    _est=`orb_sql_value "(select to_char(round(estimated_flashback_size/1024/1024)) from v\\$flashback_database_log)"`
    orb_field "Ponto mais antigo alcancavel" "`_orb_or_na "$_o"`"
    orb_field "Retention target"             "`_orb_or_na "$_rt"` min"
    orb_field "Tamanho estimado necessario"  "`_orb_or_na "$_est"` MB"
    orb_item "Se o estimado for maior que o espaco livre da FRA, a janela real"
    orb_item "sera MENOR que o retention target - o log e reciclado antes."
    return 0
}

# ---------------------------------------------------------------------------
# FLASHBACK QUERY / VERSIONS  -  leitura, nao altera nada
# ---------------------------------------------------------------------------
orb_fb_query()
{
    orb_title "FLASHBACK QUERY / VERSIONS"
    orb_item "Le o passado sem alterar nada. Depende do UNDO, nao do flashback"
    orb_item "database - a janela e undo_retention, tipicamente bem menor."
    orb_log_raw ""

    _ur=`orb_sql_value "(select value from v\\$parameter where name='undo_retention')"`
    _rt=`orb_sql_value "(select to_char(round(max(maxquerylen))) from v\\$undostat)"`
    orb_field "undo_retention"        "`_orb_or_na "$_ur"` s"
    orb_field "Maior query observada" "`_orb_or_na "$_rt"` s"

    orb_ask "Tabela (owner.tabela)" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _t="$ORB_ANSWER"
    orb_ask "Quantos minutos atras" "60"
    _m="$ORB_ANSWER"

    orb_section "CONSULTAS PRONTAS"
    orb_log_raw "  -- como estava ha $_m minutos"
    orb_log_raw "  select * from $_t as of timestamp systimestamp - interval '$_m' minute;"
    orb_log_raw ""
    orb_log_raw "  -- o que mudou na janela (precisa de ROW MOVEMENT / supplemental)"
    orb_log_raw "  select versions_startscn, versions_endscn, versions_operation, t.*"
    orb_log_raw "    from $_t versions between timestamp"
    orb_log_raw "         systimestamp - interval '$_m' minute and systimestamp t;"
    orb_log_raw ""
    orb_log_raw "  -- reinserir o que sumiu, sem tocar no resto"
    orb_log_raw "  insert into $_t"
    orb_log_raw "  select * from $_t as of timestamp systimestamp - interval '$_m' minute"
    orb_log_raw "   minus select * from $_t;"

    orb_section "LIMITE"
    orb_item "ORA-01555 = o undo daquele periodo ja foi sobrescrito. Nesse caso"
    orb_item "o caminho e TSPITR, RECOVER TABLE ou restore em banco auxiliar."
    return 0
}

# ---------------------------------------------------------------------------
orb_fb_transaction()
{
    orb_title "FLASHBACK TRANSACTION"
    orb_section "PRE-REQUISITOS"
    _s1=`orb_sql_value "(select supplemental_log_data_min from v\\$database)"`
    _s2=`orb_sql_value "(select supplemental_log_data_pk from v\\$database)"`
    orb_field "Supplemental log (min)" "`_orb_or_na "$_s1"`"
    orb_field "Supplemental log (PK)"  "`_orb_or_na "$_s2"`"
    if [ "$_s1" != "YES" ]; then
        orb_warn "Sem supplemental logging minimo, flashback transaction nao funciona."
        orb_item "  alter database add supplemental log data;"
        orb_item "  alter database add supplemental log data (primary key) columns;"
        orb_item "Isso vale a partir de AGORA - nao recupera o passado."
    fi

    orb_section "COMO ACHAR A TRANSACAO"
    orb_log_raw "  select xid, operation, table_name, undo_sql"
    orb_log_raw "    from flashback_transaction_query"
    orb_log_raw "   where table_owner = 'DONO' and table_name = 'TABELA'"
    orb_log_raw "     and start_timestamp > systimestamp - interval '2' hour;"

    orb_section "COMO DESFAZER"
    orb_log_raw "  begin"
    orb_log_raw "    dbms_flashback.transaction_backout("
    orb_log_raw "      numtxns  => 1,"
    orb_log_raw "      xids     => sys.xid_array('<XID>'),"
    orb_log_raw "      options  => dbms_flashback.cascade);"
    orb_log_raw "  end;"
    orb_log_raw "  /"
    orb_item "options: nocascade | cascade | nocascade_force | nonconflict_only"
    orb_item "Confira dba_flashback_txn_report ANTES do commit."

    orb_section "ATENCAO"
    orb_item "transaction_backout NAO commita sozinho - revise e so entao commit."
    orb_item "cascade desfaz transacoes dependentes: pode ser bem mais amplo do"
    orb_item "que voce imagina. Leia o relatorio."
    return 0
}

# ---------------------------------------------------------------------------
orb_fb_drop_rp()
{
    orb_title "APAGAR RESTORE POINT"
    orb_section "RESTORE POINTS EXISTENTES"
    orb_sql_query "select 'ORBR|'||name||'|'||to_char(scn)||'|'||guarantee_flashback_database||'|'||to_char(round(storage_size/1024/1024))
                     from v\$restore_point order by scn;" \
        | while IFS='|' read _n _s _g _m
        do
            orb_log_raw "  `printf '%-28s scn=%-16s garantido=%-4s %8s MB' "$_n" "$_s" "$_g" "$_m"`"
        done
    orb_log_raw ""

    orb_ask "Nome do restore point a apagar" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _n="$ORB_ANSWER"

    _g=`orb_sql_value "(select guarantee_flashback_database from v\\$restore_point where name=upper('$_n'))"`
    if [ -z "$_g" ]; then
        orb_err "Restore point '$_n' nao existe."
        return 1
    fi

    _s="$ORB_RUNDIR/fb_drop_rp.sql"
    { echo "drop restore point $_n;" ; echo "exit" ; } > "$_s"

    orb_plan_begin "APAGAR RESTORE POINT $_n"
    orb_plan_field "Nome"      "$_n"
    orb_plan_field "Garantido" "$_g"
    orb_plan_cmd_file "Drop" "$_s"
    orb_plan_risk "Depois disso nao ha mais como voltar aquele ponto."
    if [ "$_g" = "YES" ]; then
        orb_plan_risk "Este e GARANTIDO: apaga-lo libera espaco na FRA, mas remove"
        orb_plan_risk "a unica garantia de que a janela alcanca aquele instante."
        orb_plan_risk "So apague depois de confirmar que a mudanca que ele protegia"
        orb_plan_risk "foi validada e aceita."
    fi
    orb_plan_confirm "APAGAR-RP" || return 1
    orb_exec_sql "fb_drop_rp" "$_s"
    return $?
}

# ---------------------------------------------------------------------------
orb_fb_toggle()
{
    orb_title "LIGAR / DESLIGAR FLASHBACK DATABASE"
    _on=`orb_sql_value "(select flashback_on from v\\$database)"`
    orb_field "Estado atual" "`_orb_or_na "$_on"`"

    if [ "$_on" = "YES" ]; then
        _act="off" ; _sql="alter database flashback off;"
    else
        _act="on"  ; _sql="alter database flashback on;"
    fi
    orb_ask "Confirma alternar para ${_act}? [S/N]" "N"
    [ "`orb_upper $ORB_ANSWER`" = "S" ] || return 1

    if [ "$_act" = "on" ]; then
        [ -n "$ORB_D_FRA" ] || { orb_err "Sem db_recovery_file_dest nao da para ligar flashback." ; return 1 ; }
    fi

    _s="$ORB_RUNDIR/fb_toggle.sql"
    { echo "$_sql" ; echo "select flashback_on from v\$database;" ; echo "exit" ; } > "$_s"

    orb_plan_begin "FLASHBACK DATABASE $_act"
    orb_plan_field "Estado atual" "$_on"
    orb_plan_field "Novo estado"  "$_act"
    orb_plan_cmd_file "Comando" "$_s"
    if [ "$_act" = "on" ]; then
        orb_plan_risk "A partir de agora todo bloco alterado gera flashback log na FRA."
        orb_plan_risk "Ha custo de I/O e de espaco. Dimensione a FRA antes."
        orb_plan_risk "Em versoes anteriores a 12.2 o banco precisa estar em MOUNT."
    else
        orb_plan_risk "TODOS os flashback logs sao descartados e os restore points"
        orb_plan_risk "garantidos deixam de valer. Nao ha volta sem restore."
    fi
    orb_plan_confirm "ALTERAR-FLASHBACK" || return 1
    orb_exec_sql "fb_toggle" "$_s"
    return $?
}

# ---------------------------------------------------------------------------
orb_fb_retention()
{
    orb_title "RETENTION TARGET DO FLASHBACK"
    _rt=`orb_sql_value "(select value from v\\$parameter where name='db_flashback_retention_target')"`
    _est=`orb_sql_value "(select to_char(round(estimated_flashback_size/1024/1024)) from v\\$flashback_database_log)"`
    orb_field "Atual (min)"          "`_orb_or_na "$_rt"`"
    orb_field "Estimado necessario"  "`_orb_or_na "$_est"` MB"

    orb_ask "Novo retention target (minutos)" "$_rt"
    [ -z "$ORB_ANSWER" ] && return 1
    case "$ORB_ANSWER" in ''|*[!0-9]*) orb_err "Valor invalido." ; return 1 ;; esac
    _new="$ORB_ANSWER"

    _s="$ORB_RUNDIR/fb_retention.sql"
    {
        echo "alter system set db_flashback_retention_target=$_new scope=both;"
        echo "select value from v\$parameter where name='db_flashback_retention_target';"
        echo "exit"
    } > "$_s"

    orb_plan_begin "RETENTION TARGET = $_new min"
    orb_plan_field "De"   "$_rt min"
    orb_plan_field "Para" "$_new min"
    orb_plan_cmd_file "Comando" "$_s"
    orb_plan_risk "Isto e um ALVO, nao uma garantia: se a FRA encher, o log e"
    orb_plan_risk "reciclado mesmo assim. Garantia so com restore point GARANTIDO."
    orb_plan_risk "Aumentar o alvo sem aumentar a FRA nao aumenta a janela real."
    orb_plan_confirm "ALTERAR-RETENTION" || return 1
    orb_exec_sql "fb_retention" "$_s"
    return $?
}
