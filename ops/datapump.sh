#!/usr/bin/sh
###############################################################################
# ops/datapump.sh - RECUPERACAO LOGICA (Data Pump)
#
# Nem todo desastre pede restore fisico. Quando alguem apagou uma tabela, um
# schema inteiro, ou fez um UPDATE sem WHERE, restaurar o banco todo para um
# ponto no tempo costuma ser desproporcional: derruba producao inteira para
# consertar um objeto.
#
# Ordem de preferencia para "sumiu um objeto":
#
#   1. Flashback Query / Flashback Table   - segundos, sem parada  (menu FLASHBACK)
#   2. Flashback Drop (recyclebin)         - se foi DROP TABLE     (menu FLASHBACK)
#   3. Data Pump a partir de um export     - se existir dump recente (AQUI)
#   4. RMAN RECOVER TABLE                  - restaura em auxiliar   (menu RECOVERY)
#   5. TSPITR                              - tablespace inteiro     (menu RECOVERY)
#   6. Restore + PITR do banco             - ultimo recurso         (menu RESTORE)
#
# Este modulo cuida do item 3, e do export preventivo que torna o item 3
# possivel. Um dump logico noturno de metadados custa quase nada e resolve o
# caso mais comum de todos: "o desenvolvedor dropou a package".
###############################################################################

orb_op_datapump_menu()
{
    while :
    do
        orb_title "DATA PUMP - RECUPERACAO LOGICA"
        orb_field "Instancia" "${ORB_D_STATUS:-?}"
        orb_log_raw ""

        orb_menu_begin
        orb_menu_group "ANTES DO PROBLEMA"
        orb_menu_add  1 "Directories disponiveis"
        orb_menu_add  2 "Criar DIRECTORY"                        danger
        orb_menu_add  3 "Export de SCHEMA"                       danger
        orb_menu_add  4 "Export so de METADADOS (barato, diario)" danger
        orb_menu_add  5 "Export de TABELAS"                      danger
        orb_menu_add  6 "Export do banco inteiro (FULL)"         danger

        orb_menu_group "DEPOIS DO PROBLEMA"
        orb_menu_add  7 "Import de SCHEMA (com remap)"           danger
        orb_menu_add  8 "Import de TABELAS"                      danger
        orb_menu_add  9 "Import so do DDL (sqlfile - nao altera nada)"
        orb_menu_add 10 "Import pela REDE (network_link)"        danger

        orb_menu_group "NO TEMPO"
        orb_menu_add 11 "Export com FLASHBACK_SCN / FLASHBACK_TIME" danger
        orb_menu_add 12 "Descobrir o SCN de um instante"

        orb_menu_group "ACOMPANHAMENTO"
        orb_menu_add 13 "Jobs de Data Pump em andamento"
        orb_menu_add 14 "Conteudo de um dumpfile"
        orb_menu_add  0 "Voltar"
        orb_menu_render
        orb_log_raw ""

        orb_ask "Opcao" "1" || return 0
        case "$ORB_ANSWER" in
            1)  orb_dp_dirs ;;
            2)  orb_dp_mkdir ;;
            3)  orb_dp_export schema ;;
            4)  orb_dp_export meta ;;
            5)  orb_dp_export table ;;
            6)  orb_dp_export full ;;
            7)  orb_dp_import schema ;;
            8)  orb_dp_import table ;;
            9)  orb_dp_sqlfile ;;
            10) orb_dp_network ;;
            11) orb_dp_export flashback ;;
            12) orb_dp_scn_at ;;
            13) orb_dp_jobs ;;
            14) orb_dp_dumpinfo ;;
            0)  return 0 ;;
            "") ;;
            *)  orb_warn "Opcao invalida." ;;
        esac
        orb_pause
    done
}

# ---------------------------------------------------------------------------
orb_dp_dirs()
{
    orb_section "DIRECTORIES"
    orb_sql_query "select 'ORBR|'||directory_name||'|'||directory_path from dba_directories order by directory_name;" \
        | while IFS='|' read _n _p
        do
            orb_log_raw "  `printf '%-24s %s' "$_n" "$_p"`"
        done

    orb_section "ATENCAO"
    orb_item "O caminho existe no SERVIDOR do banco, nao na sua estacao."
    orb_item "O usuario oracle precisa ter permissao de escrita nele."
    orb_item "Em RAC, se o caminho nao for compartilhado, o dump sai no node"
    orb_item "onde a sessao caiu - e voce vai procura-lo no node errado."
    return 0
}

orb_dp_mkdir()
{
    orb_title "CRIAR DIRECTORY"
    orb_ask "Nome (sera criado em maiusculas)" "ORB_DUMP"
    _n=`orb_upper "$ORB_ANSWER"`
    orb_ask "Caminho no servidor do banco" "/oracle/dpdump"
    _p="$ORB_ANSWER"

    _s="$ORB_RUNDIR/dp_mkdir.sql"
    {
        echo "create or replace directory $_n as '$_p';"
        echo "select directory_name, directory_path from dba_directories where directory_name='$_n';"
        echo "exit"
    } > "$_s"

    orb_plan_begin "CRIAR DIRECTORY $_n"
    orb_plan_field "Nome"    "$_n"
    orb_plan_field "Caminho" "$_p"
    orb_plan_cmd_file "DDL" "$_s"
    orb_plan_risk "O Oracle NAO cria o diretorio no sistema de arquivos - ele so"
    orb_plan_risk "registra o apontamento. Crie o caminho e de permissao antes."
    orb_plan_risk "CREATE OR REPLACE em um directory ja existente muda o destino"
    orb_plan_risk "de todo mundo que o usa. Confira quem usa antes."
    orb_plan_confirm "CRIAR-DIRECTORY" || return 1
    orb_exec_sql "dp_mkdir" "$_s"
    return $?
}

# ---------------------------------------------------------------------------
# helper de destino
# ---------------------------------------------------------------------------
orb_dp_target()
{
    orb_ask "DIRECTORY" "${ORB_DP_DIR:-DATA_PUMP_DIR}"
    ORB_DP_DIR="$ORB_ANSWER"
    _dp=`orb_sql_value "(select directory_path from dba_directories where directory_name=upper('$ORB_DP_DIR'))"`
    if [ -z "$_dp" ]; then
        orb_warn "DIRECTORY '$ORB_DP_DIR' nao existe no dicionario."
    else
        orb_field "Caminho real" "$_dp"
    fi
    orb_ask "Paralelismo" "${ORB_CHANNELS:-4}"
    ORB_DP_PAR="$ORB_ANSWER"
    return 0
}

# ---------------------------------------------------------------------------
# EXPORT
# ---------------------------------------------------------------------------
orb_dp_export()
{
    _kind="$1"
    _ts=`orb_timestamp`

    case "$_kind" in
        schema)    orb_title "EXPORT DE SCHEMA" ;;
        meta)      orb_title "EXPORT DE METADADOS" ;;
        table)     orb_title "EXPORT DE TABELAS" ;;
        full)      orb_title "EXPORT FULL" ;;
        flashback) orb_title "EXPORT EM PONTO NO TEMPO" ;;
    esac
    orb_require_open || return 1
    orb_dp_target

    _sel=""
    _extra=""
    _base=""
    case "$_kind" in
        schema|meta|flashback)
            orb_section "SCHEMAS COM MAIS OBJETOS"
            orb_sql_query "select 'ORBR|'||owner||'|'||to_char(count(*))
                             from dba_objects
                            where owner not in ('SYS','SYSTEM','XDB','MDSYS','CTXSYS','ORDSYS','WMSYS','DBSNMP','OUTLN','APPQOSSYS','AUDSYS','GSMADMIN_INTERNAL','OJVMSYS','DVSYS','LBACSYS','OLAPSYS')
                            group by owner having count(*) > 10 order by count(*) desc;" \
                | head -20 \
                | while IFS='|' read _o _c ; do orb_log_raw "  `printf '%-30s %6s objetos' "$_o" "$_c"`" ; done
            orb_log_raw ""
            orb_ask "Schema(s), separados por virgula" ""
            [ -z "$ORB_ANSWER" ] && return 1
            _sel="schemas=$ORB_ANSWER"
            _base=`echo "$ORB_ANSWER" | tr ',' '_' | orb_lower`
            ;;
        table)
            orb_ask "Tabelas (owner.tabela, separadas por virgula)" ""
            [ -z "$ORB_ANSWER" ] && return 1
            _sel="tables=$ORB_ANSWER"
            _base=`echo "$ORB_ANSWER" | tr ',.' '__' | orb_lower`
            ;;
        full)
            _sel="full=y"
            _base=`echo "${ORB_D_DBNAME:-db}" | orb_lower`
            ;;
    esac

    case "$_kind" in
        meta) _extra="content=metadata_only" ;;
    esac

    if [ "$_kind" = "flashback" ]; then
        orb_ask "Ponto no tempo [SCN|TIME]" "TIME"
        if [ "`orb_upper $ORB_ANSWER`" = "SCN" ]; then
            orb_ask "SCN" ""
            [ -z "$ORB_ANSWER" ] && return 1
            _extra="flashback_scn=$ORB_ANSWER"
        else
            orb_ask "Data (DD-MM-YYYY HH24:MI:SS)" ""
            [ -z "$ORB_ANSWER" ] && return 1
            _extra="flashback_time=\"TO_TIMESTAMP('$ORB_ANSWER','DD-MM-YYYY HH24:MI:SS')\""
        fi
    fi

    orb_ask "Compactar? [S/N]" "S"
    _cmp=""
    [ "`orb_upper $ORB_ANSWER`" = "S" ] && _cmp="compression=all"

    _dmp="orb_${_kind}_${_base}_${_ts}"

    _f="$ORB_RUNDIR/dp_export.txt"
    {
        echo "expdp \\\"/ as sysdba\\\" \\"
        echo "  directory=$ORB_DP_DIR \\"
        if [ "${ORB_DP_PAR:-1}" -gt 1 ] 2>/dev/null; then
            echo "  dumpfile=${_dmp}_%U.dmp \\"
            echo "  parallel=$ORB_DP_PAR \\"
        else
            echo "  dumpfile=${_dmp}.dmp \\"
        fi
        echo "  logfile=${_dmp}.log \\"
        echo "  $_sel \\"
        [ -n "$_extra" ] && echo "  $_extra \\"
        [ -n "$_cmp" ]   && echo "  $_cmp \\"
        echo "  job_name=${_dmp}"
    } > "$_f"

    orb_plan_begin "EXPORT DATA PUMP ($_kind)"
    orb_plan_field "Directory"   "$ORB_DP_DIR"
    orb_plan_field "Dumpfile"    "$_dmp"
    orb_plan_field "Selecao"     "$_sel"
    orb_plan_field "Paralelismo" "$ORB_DP_PAR"
    orb_plan_cmd_file "Comando" "$_f"
    orb_plan_risk "O export LE o banco: gera I/O e pode competir com producao."
    if [ "$_kind" = "flashback" ]; then
        orb_plan_risk "FLASHBACK depende do UNDO: se undo_retention nao cobrir o"
        orb_plan_risk "ponto pedido, o job morre com ORA-01555 no meio."
    fi
    if [ "$_kind" = "meta" ]; then
        orb_plan_risk "content=metadata_only NAO leva dados - serve para recriar"
        orb_plan_risk "objetos, nao para recuperar linhas."
    fi
    orb_plan_risk "Com parallel > 1 o dumpfile PRECISA ter %U, senao o job falha."
    orb_plan_risk "Se houver colunas criptografadas, acrescente ENCRYPTION_PASSWORD."
    orb_plan_confirm "EXPORTAR" || return 1

    orb_dp_run expdp "$_f" "$_dmp"
    return $?
}

# ---------------------------------------------------------------------------
# IMPORT
# ---------------------------------------------------------------------------
orb_dp_import()
{
    _kind="$1"
    orb_title "IMPORT DATA PUMP ($_kind)"
    orb_require_open || return 1
    orb_dp_target

    orb_ask "Dumpfile (use %U se o export foi paralelo)" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _dmp="$ORB_ANSWER"

    _sel=""
    if [ "$_kind" = "schema" ]; then
        orb_ask "Schema(s) a importar (vazio = todos do dump)" ""
        [ -n "$ORB_ANSWER" ] && _sel="schemas=$ORB_ANSWER"
        orb_ask "Remapear schema? (origem:destino, vazio = nao)" ""
        _rm=""
        [ -n "$ORB_ANSWER" ] && _rm="remap_schema=$ORB_ANSWER"
    else
        orb_ask "Tabelas (owner.tabela, separadas por virgula)" ""
        [ -z "$ORB_ANSWER" ] && return 1
        _sel="tables=$ORB_ANSWER"
        _rm=""
    fi

    orb_ask "Remapear tablespace? (origem:destino, vazio = nao)" ""
    _rt=""
    [ -n "$ORB_ANSWER" ] && _rt="remap_tablespace=$ORB_ANSWER"

    orb_section "SE A TABELA JA EXISTIR"
    orb_item "SKIP    - ignora e nao importa (padrao)"
    orb_item "APPEND  - acrescenta linhas, mantem as atuais"
    orb_item "TRUNCATE- apaga as linhas atuais e carrega o dump"
    orb_item "REPLACE - DROPA a tabela e recria a partir do dump"
    orb_log_raw ""
    orb_ask "table_exists_action [SKIP|APPEND|TRUNCATE|REPLACE]" "SKIP"
    _tea=`orb_upper "$ORB_ANSWER"`
    case "$_tea" in
        SKIP|APPEND|TRUNCATE|REPLACE) : ;;
        *) orb_err "Valor invalido." ; return 1 ;;
    esac

    _ts=`orb_timestamp`
    _f="$ORB_RUNDIR/dp_import.txt"
    {
        echo "impdp \\\"/ as sysdba\\\" \\"
        echo "  directory=$ORB_DP_DIR \\"
        echo "  dumpfile=$_dmp \\"
        echo "  logfile=orb_imp_${_ts}.log \\"
        [ -n "$_sel" ] && echo "  $_sel \\"
        [ -n "$_rm" ]  && echo "  $_rm \\"
        [ -n "$_rt" ]  && echo "  $_rt \\"
        echo "  table_exists_action=$_tea \\"
        echo "  parallel=$ORB_DP_PAR \\"
        echo "  job_name=orb_imp_${_ts}"
    } > "$_f"

    orb_plan_begin "IMPORT DATA PUMP ($_kind)"
    orb_plan_field "Directory"  "$ORB_DP_DIR"
    orb_plan_field "Dumpfile"   "$_dmp"
    orb_plan_field "Selecao"    "${_sel:-todo o dump}"
    orb_plan_field "Se existir" "$_tea"
    orb_plan_cmd_file "Comando" "$_f"
    case "$_tea" in
        REPLACE)
            orb_plan_risk "REPLACE DROPA A TABELA ATUAL antes de recriar. Tudo que"
            orb_plan_risk "esta nela agora - inclusive o que voce quer preservar -"
            orb_plan_risk "sera perdido, junto com indices, grants e triggers que"
            orb_plan_risk "nao estejam no dump."
            ;;
        TRUNCATE)
            orb_plan_risk "TRUNCATE apaga TODAS as linhas atuais. Nao ha rollback."
            ;;
        APPEND)
            orb_plan_risk "APPEND pode duplicar linhas se as PKs nao barrarem."
            ;;
    esac
    orb_plan_risk "O import roda como uma carga: gera redo e undo em volume."
    orb_plan_risk "Se houver constraints entre schemas, importe na ordem certa"
    orb_plan_risk "ou desabilite/reabilite depois."
    orb_plan_risk "Antes de tocar em producao, considere importar em um schema"
    orb_plan_risk "temporario (remap_schema) e comparar."
    orb_plan_confirm "IMPORTAR" || return 1

    orb_dp_run impdp "$_f" "orb_imp_${_ts}"
    return $?
}

# ---------------------------------------------------------------------------
# SQLFILE  -  extrai o DDL sem alterar nada
# ---------------------------------------------------------------------------
orb_dp_sqlfile()
{
    orb_title "EXTRAIR O DDL DO DUMP (sqlfile)"
    orb_item "Nao altera nada no banco. Gera um .sql com tudo que o import FARIA."
    orb_item "E o jeito certo de conferir um import antes de executa-lo, e"
    orb_item "tambem de recuperar so a definicao de um objeto perdido."
    orb_log_raw ""
    orb_dp_target

    orb_ask "Dumpfile" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _dmp="$ORB_ANSWER"
    orb_ask "Filtrar (ex: schemas=APP  ou  tables=APP.PEDIDOS ; vazio = tudo)" ""
    _sel="$ORB_ANSWER"
    _ts=`orb_timestamp`

    _f="$ORB_RUNDIR/dp_sqlfile.txt"
    {
        echo "impdp \\\"/ as sysdba\\\" \\"
        echo "  directory=$ORB_DP_DIR \\"
        echo "  dumpfile=$_dmp \\"
        echo "  sqlfile=orb_ddl_${_ts}.sql \\"
        echo "  logfile=orb_ddl_${_ts}.log \\"
        [ -n "$_sel" ] && echo "  $_sel"
    } > "$_f"

    orb_plan_begin "SQLFILE A PARTIR DO DUMP"
    orb_plan_field "Dumpfile" "$_dmp"
    orb_plan_field "Saida"    "orb_ddl_${_ts}.sql (no DIRECTORY $ORB_DP_DIR)"
    orb_plan_cmd_file "Comando" "$_f"
    orb_plan_risk "Nenhum: sqlfile e leitura. O arquivo sai no servidor, dentro"
    orb_plan_risk "do caminho do DIRECTORY."
    orb_plan_confirm "GERAR-DDL" || return 1

    orb_dp_run impdp "$_f" "orb_ddl_${_ts}"
    return $?
}

# ---------------------------------------------------------------------------
# NETWORK LINK
# ---------------------------------------------------------------------------
orb_dp_network()
{
    orb_title "IMPORT PELA REDE (network_link)"
    orb_item "Copia direto de outro banco, sem dumpfile e sem espaco em disco"
    orb_item "para arquivo intermediario. Precisa de um DATABASE LINK."
    orb_log_raw ""

    orb_section "DATABASE LINKS EXISTENTES"
    orb_sql_query "select 'ORBR|'||owner||'.'||db_link||'|'||host from dba_db_links order by 1;" \
        | while IFS='|' read _l _h ; do orb_log_raw "  $_l  ->  $_h" ; done
    orb_log_raw ""

    orb_ask "Nome do database link (origem)" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _lnk="$ORB_ANSWER"
    orb_ask "Schema(s) a trazer" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _sc="$ORB_ANSWER"
    orb_ask "Remapear schema? (origem:destino, vazio = nao)" ""
    _rm=""
    [ -n "$ORB_ANSWER" ] && _rm="remap_schema=$ORB_ANSWER"
    orb_ask "Paralelismo" "${ORB_CHANNELS:-4}"
    _par="$ORB_ANSWER"
    _ts=`orb_timestamp`

    _f="$ORB_RUNDIR/dp_network.txt"
    {
        echo "impdp \\\"/ as sysdba\\\" \\"
        echo "  network_link=$_lnk \\"
        echo "  schemas=$_sc \\"
        [ -n "$_rm" ] && echo "  $_rm \\"
        echo "  parallel=$_par \\"
        echo "  logfile=orb_net_${_ts}.log \\"
        echo "  directory=${ORB_DP_DIR:-DATA_PUMP_DIR} \\"
        echo "  job_name=orb_net_${_ts}"
    } > "$_f"

    orb_plan_begin "IMPORT PELA REDE VIA $_lnk"
    orb_plan_field "Link"    "$_lnk"
    orb_plan_field "Schemas" "$_sc"
    orb_plan_cmd_file "Comando" "$_f"
    orb_plan_risk "Le do banco REMOTO ao vivo: gera carga la, nao aqui."
    orb_plan_risk "O DIRECTORY ainda e necessario - so para o logfile."
    orb_plan_risk "Tipos LONG e alguns objetos nao viajam por network_link."
    orb_plan_risk "Sem dumpfile nao ha 'segunda tentativa barata': se falhar no"
    orb_plan_risk "meio, tudo e lido de novo."
    orb_plan_confirm "IMPORTAR-DA-REDE" || return 1

    orb_dp_run impdp "$_f" "orb_net_${_ts}"
    return $?
}

# ---------------------------------------------------------------------------
# SCN de um instante
# ---------------------------------------------------------------------------
orb_dp_scn_at()
{
    orb_section "SCN DE UM INSTANTE"
    _now=`orb_sql_value "(select to_char(current_scn) from v\\$database)"`
    orb_field "SCN atual" "`_orb_or_na "$_now"`"

    orb_ask "Quantos minutos atras" "60"
    _m="$ORB_ANSWER"
    case "$_m" in ''|*[!0-9]*) orb_err "Valor invalido." ; return 1 ;; esac

    _scn=`orb_sql_value "(select to_char(timestamp_to_scn(systimestamp - interval '$_m' minute)) from dual)"`
    if [ -z "$_scn" ]; then
        orb_err "Nao consegui converter - o instante pode estar fora da janela."
        orb_item "timestamp_to_scn so enxerga cerca de 5 dias (smon_scn_time)."
        orb_item "Para pontos mais antigos, use v\$log_history ou o catalogo RMAN."
        return 1
    fi
    orb_field "SCN de ${_m} min atras" "$_scn"

    orb_section "ONDE USAR"
    orb_item "expdp ... flashback_scn=$_scn"
    orb_item "RMAN> SET UNTIL SCN $_scn;"
    orb_item "select * from <tabela> as of scn $_scn;"

    orb_section "HISTORICO DE REDO (para pontos mais antigos)"
    orb_sql_query "select 'ORBR|'||to_char(first_time,'DD/MM/YYYY HH24:MI:SS')||'|'||to_char(first_change#)||'|'||to_char(sequence#)
                     from v\$log_history where first_time > sysdate - 7
                    order by first_time desc;" \
        | head -15 \
        | while IFS='|' read _t _c _s
        do
            orb_log_raw "  `printf '%-20s scn=%-16s seq=%s' "$_t" "$_c" "$_s"`"
        done
    return 0
}

# ---------------------------------------------------------------------------
# JOBS
# ---------------------------------------------------------------------------
orb_dp_jobs()
{
    orb_section "JOBS DE DATA PUMP"
    _n=`orb_sql_value "(select to_char(count(*)) from dba_datapump_jobs)"`
    orb_field "Jobs registrados" "`_orb_or_na "$_n"`"

    if [ -z "$_n" ] || [ "$_n" = "0" ]; then
        orb_ok "Nenhum job de Data Pump registrado."
        return 0
    fi

    orb_sql_query "select 'ORBR|'||owner_name||'|'||job_name||'|'||operation||'|'||job_mode||'|'||state||'|'||to_char(degree)
                     from dba_datapump_jobs order by owner_name, job_name;" \
        | while IFS='|' read _o _j _op _md _st _dg
        do
            orb_log_raw "  $_o.$_j  $_op/$_md  state=$_st  degree=$_dg"
        done

    orb_section "JOBS ORFAOS"
    orb_item "State NOT RUNNING com a sessao ja morta = job orfao. Ele segura a"
    orb_item "master table e o nome do job. Limpar:"
    orb_item "  drop table <owner>.<job_name> purge;"
    orb_item "Confirme que o job realmente morreu antes de dropar a master table."

    orb_section "ANEXAR A UM JOB EM ANDAMENTO"
    orb_item "  expdp \\\"/ as sysdba\\\" attach=<job_name>"
    orb_item "  Export> status"
    orb_item "  Export> parallel=8"
    orb_item "  Export> stop_job=immediate     (pausa, permite retomar)"
    orb_item "  Export> kill_job               (mata e apaga o dump)"
    return 0
}

# ---------------------------------------------------------------------------
orb_dp_dumpinfo()
{
    orb_title "CONTEUDO DE UM DUMPFILE"
    orb_dp_target
    orb_ask "Dumpfile" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _dmp="$ORB_ANSWER"
    _ts=`orb_timestamp`

    orb_section "COMO INSPECIONAR SEM IMPORTAR"
    orb_log_raw "  # 1. lista de objetos e schemas que o dump contem"
    orb_log_raw "  impdp \\\"/ as sysdba\\\" directory=$ORB_DP_DIR dumpfile=$_dmp \\"
    orb_log_raw "        sqlfile=orb_peek_${_ts}.sql logfile=orb_peek_${_ts}.log"
    orb_log_raw ""
    orb_log_raw "  # 2. cabecalho do dump (versao, data, modo)"
    orb_log_raw "  strings $_dmp | head -40"
    orb_log_raw ""
    orb_log_raw "  # 3. pelo dicionario, apos um attach:"
    orb_log_raw "  select * from <owner>.<master_table> where process_order < 0;"

    orb_section "COMPATIBILIDADE"
    orb_item "Um dump so importa em versao IGUAL ou SUPERIOR a que o gerou,"
    orb_item "a menos que o export tenha usado version=<destino>."
    orb_item "Exportar de 19c para 12c sem version=12 gera um dump inutil la."
    return 0
}

# ---------------------------------------------------------------------------
# orb_dp_run  -  executa o comando montado, sem senha em linha de comando
# ---------------------------------------------------------------------------
orb_dp_run()
{
    _tool="$1" ; _file="$2" ; _job="$3"

    if [ "$ORB_MODE" != "EXECUTE" ]; then
        orb_log "[$ORB_MODE] $_tool nao executado."
        orb_section "COMANDO"
        while IFS= read _l ; do orb_log_raw "  $_l" ; done < "$_file"
        return 0
    fi

    if [ ! -x "$ORACLE_HOME/bin/$_tool" ]; then
        orb_err "$_tool nao encontrado em \$ORACLE_HOME/bin"
        return 1
    fi

    orb_section "EXECUTANDO $_tool"
    orb_item "Job: $_job"
    orb_item "Para acompanhar de outra sessao:  $_tool \\\"/ as sysdba\\\" attach=$_job"
    orb_log_raw ""

    # parfile evita expor parametros na linha de comando e sobrevive a espacos
    _par="$ORB_RUNDIR/${_job}.par"
    sed -e '1d' -e 's/[ ]*\\$//' -e 's/^  //' "$_file" > "$_par"

    _t0=`orb_epoch`
    "$ORACLE_HOME/bin/$_tool" "/ as sysdba" parfile="$_par" 2>&1 \
        | while IFS= read _l ; do orb_log_raw "  $_l" ; done
    _rc=$?
    _t1=`orb_epoch`
    orb_audit "DP:$_tool" "parfile=$_par" "$_rc" "`expr $_t1 - $_t0`"

    if [ $_rc -ne 0 ]; then
        orb_err "$_tool retornou $_rc."
        ORB_STEP_FAIL=`expr $ORB_STEP_FAIL + 1`
        return 1
    fi
    ORB_STEP_OK=`expr $ORB_STEP_OK + 1`
    orb_ok "$_tool concluido. Parfile guardado em $_par"
    return 0
}
