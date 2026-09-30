#!/usr/bin/sh
###############################################################################
# ops/postrestore.sh - o que vem DEPOIS do restore
#
# Todo restore termina com uma lista de coisas que alguem tem que lembrar de
# fazer. Quando essa lista mora na cabeca do DBA, ela falha as 4 da manha.
#
# Aqui ela vira menu, com verificacao de estado em cada item.
###############################################################################

orb_op_postrestore_menu()
{
    while :
    do
        orb_title "POS-RESTORE"
        orb_postrestore_checklist
        orb_menu_begin
        orb_menu_group "ABERTURA"
        orb_menu_add  1 "OPEN RESETLOGS"                          danger
        orb_menu_add  2 "OPEN READ ONLY (conferir antes de decidir)"
        orb_menu_add  3 "Limpar online redo logs (CLEAR LOGFILE)" danger
        orb_menu_group "ARQUIVOS QUE NAO VOLTAM NO RESTORE"
        orb_menu_add  4 "Recriar TEMPFILES"
        orb_menu_add  5 "Password file (verificar / recriar)"
        orb_menu_add  6 "Wallet TDE (verificar)"
        orb_menu_add  7 "Block change tracking (recriar)"
        orb_menu_group "CONSISTENCIA"
        orb_menu_add  8 "Conferir datafiles fuzzy e recover pendente"
        orb_menu_add  9 "Conferir tablespaces e datafiles OFFLINE"
        orb_menu_add 10 "Colocar datafile/tablespace ONLINE"       danger
        orb_menu_add 11 "Registrar novo nivel 0 apos RESETLOGS"
        orb_menu_add  0 "Voltar"
        orb_menu_render
        orb_log_raw ""
        orb_ask "Opcao" "" || return 0
        case "$ORB_ANSWER" in
            1)  orb_pr_open_resetlogs ;;
            2)  orb_pr_open_readonly ;;
            3)  orb_pr_clear_logfile ;;
            4)  orb_pr_tempfiles ;;
            5)  orb_pr_pwfile ;;
            6)  orb_pr_wallet ;;
            7)  orb_cat_bct ;;
            8)  orb_pr_consistency ;;
            9)  orb_pr_offline_report ;;
            10) orb_pr_online ;;
            11) orb_pr_post_resetlogs_backup ;;
            0)  return 0 ;;
            "") continue ;;
            *)  orb_status_line warn "Opcao invalida." ;;
        esac
        orb_pause
    done
}

# ---------------------------------------------------------------------------
# checklist com estado real
# ---------------------------------------------------------------------------
orb_postrestore_checklist()
{
    orb_sql_alive || { orb_status_line warn "Instancia nao responde." ; return 1 ; }

    _fz=`orb_sql_value "(select to_char(count(*)) from v\\$datafile_header where fuzzy='YES')"`
    if [ "$_fz" = "0" ]; then
        orb_status_line ok   "datafiles fuzzy: 0"
    else
        orb_status_line warn "datafiles fuzzy: ${_fz:-?} - recovery ainda incompleto"
    fi

    _tmp=`orb_sql_value "(select to_char(count(*)) from v\\$tempfile)"`
    if [ -n "$_tmp" ] && [ "$_tmp" -gt 0 ] 2>/dev/null; then
        orb_status_line ok   "tempfiles: $_tmp"
    else
        orb_status_line warn "tempfiles: 0 - a TEMP nao volta no restore, precisa ser recriada"
    fi

    _off=`orb_sql_value "(select to_char(count(*)) from v\\$datafile where status='OFFLINE')"`
    [ "$_off" = "0" ] && orb_status_line ok "datafiles OFFLINE: 0" \
                      || orb_status_line warn "datafiles OFFLINE: ${_off:-?}"

    _tde=`orb_sql_value "(select status from v\\$encryption_wallet where rownum=1)"`
    case "$_tde" in
        ""|NOT_AVAILABLE) : ;;
        OPEN)   orb_status_line ok   "wallet TDE: OPEN" ;;
        *)      orb_status_line crit "wallet TDE: $_tde - dados criptografados ficam ilegiveis" ;;
    esac

    _om=`orb_sql_value "(select open_mode from v\\$database)"`
    orb_field "Open mode" "`_orb_or_na "$_om"`"
    return 0
}

# ---------------------------------------------------------------------------
orb_pr_open_resetlogs()
{
    orb_title "OPEN RESETLOGS"
    orb_require_mounted || return 1

    _fz=`orb_sql_value "(select to_char(count(*)) from v\\$datafile_header where fuzzy='YES')"`
    if [ -n "$_fz" ] && [ "$_fz" != "0" ]; then
        orb_status_line fail "$_fz datafiles ainda com fuzziness."
        orb_item "Abrir agora resultara em ORA-01195 / ORA-01110."
        orb_item "Termine o recovery antes."
        orb_confirm "Tentar mesmo assim (nao recomendado)?" "FORCAR" || return 1
    fi

    _s="$ORB_RUNDIR/open_resetlogs.sql"
    printf "alter database open resetlogs;\nexit\n" > "$_s"

    orb_plan_begin "ALTER DATABASE OPEN RESETLOGS"
    orb_plan_field "Database"  "${ORB_D_DBNAME:-?}"
    orb_plan_field "Fuzzy"     "${_fz:-?}"
    orb_plan_cmd_file "Abertura" "$_s"
    orb_plan_risk "Cria uma NOVA INCARNATION. Backups anteriores viram incarnation orfa."
    orb_plan_risk "Operacao IRREVERSIVEL: nao da para voltar ao ponto anterior sem novo restore."
    orb_plan_risk "Os online redo logs sao zerados."
    orb_plan_risk "Faca um nivel 0 IMEDIATAMENTE apos abrir - ate la o banco esta sem backup valido."
    orb_plan_confirm "RESETLOGS" || return 1

    orb_exec_sql "open_resetlogs" "$_s" || return 1
    orb_discover_instance
    orb_postcheck_database

    orb_status_line crit "Nova incarnation criada."
    orb_item "O banco esta SEM BACKUP VALIDO neste momento."
    orb_item "Use a opcao 11 deste menu para fazer o nivel 0 agora."
    return 0
}

orb_pr_open_readonly()
{
    orb_title "OPEN READ ONLY"
    orb_item "Abre para conferencia sem consumir o RESETLOGS. Se o ponto de"
    orb_item "recuperacao estiver errado, ainda da para refazer o recovery."
    orb_require_mounted || return 1
    _s="$ORB_RUNDIR/open_ro.sql"
    printf "alter database open read only;\nexit\n" > "$_s"
    orb_plan_begin "ALTER DATABASE OPEN READ ONLY"
    orb_plan_cmd_file "Abertura somente leitura" "$_s"
    orb_plan_risk "Para voltar a MOUNT depois: shutdown immediate + startup mount."
    orb_plan_risk "Nao funciona se o recovery estiver incompleto (fuzzy > 0)."
    orb_plan_confirm "ABRIR-READ-ONLY" || return 1
    orb_exec_sql "open_read_only" "$_s"
    _rc=$?
    orb_discover_instance
    [ $_rc -eq 0 ] && orb_item "Confira os dados. Para seguir: shutdown immediate; startup mount; OPEN RESETLOGS."
    return $_rc
}

orb_pr_clear_logfile()
{
    orb_title "CLEAR LOGFILE"
    orb_item "Usado quando o online redo log referenciado pelo controlfile nao"
    orb_item "existe ou esta corrompido - tipico apos restore de controlfile."
    orb_section "GRUPOS DE REDO"
    orb_sql_query "select 'ORBR|'||group#||'|'||thread#||'|'||status||'|'||to_char(bytes/1024/1024) from v\$log order by group#;" \
        | while IFS='|' read _g _t _s _m ; do orb_item "grupo $_g thread $_t $_s ${_m}MB" ; done
    orb_ask "Grupo a limpar (vazio = cancelar)" ""
    [ -z "$ORB_ANSWER" ] && return 0
    _g="$ORB_ANSWER"
    orb_ask "Usar UNARCHIVED? (S se o log nao pode ser arquivado) [S/N]" "N"
    if [ "`orb_upper $ORB_ANSWER`" = "S" ]; then
        _sql="alter database clear unarchived logfile group $_g;"
        _un="Y"
    else
        _sql="alter database clear logfile group $_g;"
        _un="N"
    fi
    _s="$ORB_RUNDIR/clear_log.sql"
    printf "%s\nexit\n" "$_sql" > "$_s"
    orb_plan_begin "CLEAR LOGFILE GROUP $_g"
    orb_plan_cmd_file "Clear logfile" "$_s"
    orb_plan_risk "O conteudo do grupo e DESCARTADO."
    [ "$_un" = "Y" ] && orb_plan_risk "UNARCHIVED descarta redo que nunca foi arquivado - possivel PERDA DE DADOS."
    [ "$_un" = "Y" ] && orb_plan_risk "Apos isso, backup anterior pode nao ser mais suficiente para recovery completo. Faca nivel 0."
    orb_plan_confirm "LIMPAR-LOGFILE" || return 1
    orb_exec_sql "clear_logfile" "$_s"
    return $?
}

# ---------------------------------------------------------------------------
# TEMPFILES - a lacuna classica
# ---------------------------------------------------------------------------
orb_pr_tempfiles()
{
    orb_title "TEMPFILES"
    orb_item "Tempfiles nao entram no backup e nao voltam no restore. Depois de"
    orb_item "abrir o banco, a TEMP costuma estar vazia - e ninguem percebe ate"
    orb_item "a primeira query com ORDER BY grande estourar ORA-25153."
    orb_require_open || { orb_item "Abra o banco antes de recriar tempfiles." ; return 1 ; }

    orb_section "SITUACAO ATUAL"
    _n=`orb_sql_value "(select to_char(count(*)) from v\\$tempfile)"`
    orb_field "Tempfiles existentes" "`_orb_or_na "$_n"`"
    orb_sql_query "select 'ORBR|'||ts.tablespace_name||'|'||nvl(to_char(count(tf.file#)),'0')||'|'||nvl(to_char(round(sum(tf.bytes)/1024/1024)),'0')
                     from dba_tablespaces ts, v\$tempfile tf, dba_temp_files dtf
                    where ts.contents='TEMPORARY'
                      and dtf.tablespace_name(+)=ts.tablespace_name
                      and tf.file#(+)=dtf.file_id
                    group by ts.tablespace_name;" 2>/dev/null \
        | while IFS='|' read _t _c _m ; do orb_item "$_t : $_c arquivo(s), ${_m}MB" ; done

    orb_section "TABLESPACES TEMPORARIAS SEM ARQUIVO"
    _falta=`orb_sql_query "select 'ORBR|'||tablespace_name from dba_tablespaces
                            where contents='TEMPORARY'
                              and tablespace_name not in
                                  (select nvl(tablespace_name,'x') from dba_temp_files);" 2>/dev/null`
    if [ -z "$_falta" ]; then
        orb_status_line ok "Todas as tablespaces temporarias tem arquivo."
        orb_ask "Adicionar tempfile mesmo assim? [S/N]" "N"
        [ "`orb_upper $ORB_ANSWER`" = "S" ] || return 0
        orb_ask "Tablespace" "TEMP"
        _falta="$ORB_ANSWER"
    else
        echo "$_falta" | while IFS= read _t ; do orb_status_line warn "$_t sem tempfile" ; done
    fi

    orb_ask "Destino (+DG ou caminho; vazio = OMF via db_create_file_dest)" "${ORB_D_DBCREATE}"
    _dst="$ORB_ANSWER"
    orb_ask "Tamanho inicial" "1G"
    _sz="$ORB_ANSWER"
    orb_ask "AUTOEXTEND? [S/N]" "S"
    _ae=""
    if [ "`orb_upper $ORB_ANSWER`" = "S" ]; then
        orb_ask "MAXSIZE" "32G"
        _ae=" autoextend on next 128M maxsize $ORB_ANSWER"
    fi

    _s="$ORB_RUNDIR/tempfiles.sql"
    : > "$_s"
    echo "$_falta" | while IFS= read _t
    do
        [ -n "$_t" ] || continue
        if [ -n "$_dst" ]; then
            echo "alter tablespace $_t add tempfile '$_dst' size $_sz$_ae;" >> "$_s"
        else
            echo "alter tablespace $_t add tempfile size $_sz$_ae;" >> "$_s"
        fi
    done
    echo "select tablespace_name, file_name, bytes/1024/1024 mb from dba_temp_files;" >> "$_s"
    echo "exit" >> "$_s"

    orb_plan_begin "RECRIAR TEMPFILES"
    orb_plan_field "Destino"  "${_dst:-OMF}"
    orb_plan_field "Tamanho"  "$_sz"
    orb_plan_cmd_file "Tempfiles" "$_s"
    orb_plan_risk "Consome espaco no destino imediatamente."
    orb_plan_risk "Sem tempfile, qualquer sort grande falha com ORA-25153."
    orb_plan_confirm "CRIAR-TEMPFILES" || return 1
    orb_exec_sql "tempfiles" "$_s"
    return $?
}

# ---------------------------------------------------------------------------
orb_pr_pwfile()
{
    orb_title "PASSWORD FILE"
    _rl=`orb_sql_value "(select value from v\\$parameter where name='remote_login_passwordfile')"`
    orb_field "remote_login_passwordfile" "`_orb_or_na "$_rl"`"
    _pw=`orb_sql_value "(select to_char(count(*)) from v\\$pwfile_users)" 2>/dev/null`
    orb_field "Usuarios no pwfile"        "`_orb_or_na "$_pw"`"

    orb_item "O password file NAO volta no restore de datafile. Sem ele:"
    orb_item "  - conexao 'sys@tns as sysdba' falha (ORA-01017)"
    orb_item "  - DUPLICATE falha"
    orb_item "  - Data Guard nao autentica o redo transport"
    orb_log_raw ""

    if [ "$ORB_D_RAC" = "Y" ] || [ "$ORB_D_ASM" = "Y" ]; then
        orb_status_line info "Em RAC/ASM o pwfile deve ficar no diskgroup e ser registrado no CRS:"
        orb_item "  srvctl modify database -db ${ORB_D_DBUNIQUE:-<db>} -pwfile +DATA/${ORB_D_DBUNIQUE:-<db>}/orapw${ORB_D_DBNAME:-<db>}"
        orb_item "  srvctl config database -d ${ORB_D_DBUNIQUE:-<db>} | grep -i password"
    fi

    orb_ask "Acao [VERIFICAR|RECRIAR|RESTAURAR]" "VERIFICAR"
    case "`orb_upper $ORB_ANSWER`" in
        RECRIAR)
            orb_item "orapwd nao aceita senha em linha de comando sem expor no ps."
            orb_item "Comando para rodar A MAO, como owner do Oracle:"
            orb_log_raw ""
            if [ "$ORB_D_ASM" = "Y" ]; then
                orb_item "  orapwd file='+DATA/${ORB_D_DBUNIQUE}/orapw${ORB_D_DBNAME}' dbuniquename=${ORB_D_DBUNIQUE} format=12 force=y"
            else
                orb_item "  orapwd file=\$ORACLE_HOME/dbs/orapw\$ORACLE_SID format=12 force=y"
            fi
            orb_log_raw ""
            orb_item "Ele vai pedir a senha interativamente - e assim que deve ser."
            ;;
        RESTAURAR)
            orb_check_version 12 || return 1
            _f="$ORB_RUNDIR/cmd_restore_pw.rman"
            orb_rman_build "$_f" "  RESTORE PASSWORDFILE TO '${ORACLE_HOME}/dbs/orapw${ORACLE_SID}';"
            orb_plan_begin "RESTORE PASSWORDFILE"
            orb_plan_cmd_file "Restore do password file" "$_f"
            orb_plan_risk "Sobrescreve o password file atual."
            orb_plan_risk "So funciona se o pwfile estiver no backup (12.2+ com pwfile em ASM)."
            orb_plan_confirm "RESTAURAR-PWFILE" || return 1
            orb_exec_rman "restore_passwordfile" "$_f"
            ;;
        *)
            [ -n "$_pw" ] && [ "$_pw" != "0" ] && orb_status_line ok "Password file presente com $_pw usuario(s)." \
                                               || orb_status_line warn "Password file ausente ou vazio."
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
orb_pr_wallet()
{
    orb_title "WALLET TDE"
    _st=`orb_sql_value "(select status from v\\$encryption_wallet where rownum=1)"`
    _lo=`orb_sql_value "(select wrl_parameter from v\\$encryption_wallet where rownum=1)"`
    _ty=`orb_sql_value "(select wallet_type from v\\$encryption_wallet where rownum=1)" 2>/dev/null`

    if [ -z "$_st" ] || [ "$_st" = "NOT_AVAILABLE" ]; then
        orb_status_line info "Nenhum wallet TDE configurado neste banco."
        orb_item "Se o banco NAO usa criptografia, isto esta correto."
        return 0
    fi

    orb_field "Status"    "$_st"
    orb_field "Tipo"      "`_orb_or_na "$_ty"`"
    orb_field "Local"     "`_orb_or_na "$_lo"`"

    orb_section "TABLESPACES CRIPTOGRAFADAS"
    orb_sql_query "select 'ORBR|'||tablespace_name||'|'||encrypted from dba_tablespaces where encrypted='YES';" 2>/dev/null \
        | while IFS='|' read _t _e ; do orb_item "$_t" ; done

    if [ "$_st" = "OPEN" ]; then
        orb_status_line ok "Wallet aberto - dados criptografados legiveis."
    else
        orb_status_line crit "Wallet em '$_st'."
        orb_item "Com o wallet fechado, os datafiles criptografados restaurados"
        orb_item "sao BYTES INUTEIS. O restore 'funciona' e os dados nao abrem."
        orb_log_raw ""
        orb_item "ESTE E O PONTO MAIS ESQUECIDO EM RESTORE PARA OUTRO HOST:"
        orb_item "o wallet precisa ser copiado junto, e ele nao esta no backup RMAN."
        orb_log_raw ""
        orb_item "Para abrir:"
        orb_item "  ADMINISTER KEY MANAGEMENT SET KEYSTORE OPEN IDENTIFIED BY \"<senha>\";"
        orb_item "Com auto-login, basta o arquivo cwallet.sso estar no lugar certo."
    fi
    return 0
}

# ---------------------------------------------------------------------------
orb_pr_consistency()
{
    orb_title "CONSISTENCIA APOS RESTORE"
    _s="$ORB_RUNDIR/pr_consist.sql"
    cat > "$_s" <<'EOSQL'
set lines 200 pages 200
col name format a58
prompt === headers por status ===
select status, count(*) from v$datafile_header group by status;
prompt === fuzzy pendente ===
select count(*) "FUZZY" from v$datafile_header where fuzzy='YES';
prompt === datafiles precisando de recover ===
select file#, error, change# from v$recover_file where error is not null;
prompt === checkpoint mais antigo e mais novo ===
select min(checkpoint_change#) menor, max(checkpoint_change#) maior from v$datafile_header;
prompt === arquivos com checkpoint divergente ===
select file#, name, checkpoint_change# from v$datafile_header
 where checkpoint_change# <> (select max(checkpoint_change#) from v$datafile_header)
 order by file#;
prompt === database ===
select name, dbid, database_role, open_mode, controlfile_type, log_mode from v$database;
exit
EOSQL
    orb_sql_run "consistencia" "$_s"
    orb_item "Todos os checkpoint_change# devem ser iguais antes do OPEN RESETLOGS."
    orb_item "Divergencia = falta recover em algum arquivo."
    return 0
}

orb_pr_offline_report()
{
    orb_title "DATAFILES E TABLESPACES OFFLINE"
    orb_sql_query "select 'ORBR|'||file#||'|'||status||'|'||name from v\$datafile where status not in ('ONLINE','SYSTEM') order by file#;" \
        | while IFS='|' read _f _s _n ; do orb_item "file $_f  $_s  $_n" ; done
    orb_sql_query "select 'ORBR|'||tablespace_name||'|'||status from dba_tablespaces where status<>'ONLINE';" \
        | while IFS='|' read _t _s ; do orb_item "tablespace $_t  $_s" ; done
    return 0
}

orb_pr_online()
{
    orb_title "COLOCAR ONLINE"
    orb_pr_offline_report
    orb_ask "Alvo [DATAFILE|TABLESPACE]" "DATAFILE"
    _t=`orb_upper "$ORB_ANSWER"`
    orb_ask "Numero(s) ou nome(s)" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _v="$ORB_ANSWER"
    _s="$ORB_RUNDIR/pr_online.sql"
    : > "$_s"
    if [ "$_t" = "DATAFILE" ]; then
        for _d in `echo "$_v" | tr ',' ' '`
        do
            echo "alter database datafile $_d online;" >> "$_s"
        done
    else
        for _d in `echo "$_v" | tr ',' ' '`
        do
            echo "alter tablespace $_d online;" >> "$_s"
        done
    fi
    echo "exit" >> "$_s"
    orb_plan_begin "COLOCAR $_t ONLINE: $_v"
    orb_plan_cmd_file "Online" "$_s"
    orb_plan_risk "Falha se o arquivo precisar de recover - faca o recover antes."
    orb_plan_confirm "ONLINE" || return 1
    orb_exec_sql "pr_online" "$_s"
    return $?
}

orb_pr_post_resetlogs_backup()
{
    orb_title "NIVEL 0 APOS RESETLOGS"
    orb_status_line crit "Depois de um RESETLOGS o banco esta SEM BACKUP VALIDO."
    orb_item "A incarnation e nova; os backups anteriores pertencem a incarnation"
    orb_item "antiga e nao servem para um restore direto."
    orb_item "Este e o passo que fecha a janela de exposicao."
    orb_log_raw ""
    orb_backup_db "INCREMENTAL LEVEL 0" "nivel 0 pos-resetlogs"
    return $?
}
