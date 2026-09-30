#!/usr/bin/sh
###############################################################################
# ops/tts.sh - TRANSPORTABLE TABLESPACE e CROSS-PLATFORM
#
# Movimentacao de dados que NAO passa por restore convencional:
#
#   - Transportable Tablespace (TTS) classico
#   - RMAN CONVERT (mesma endianness = so cabecalho; diferente = conversao)
#   - RMAN TRANSPORT TABLESPACE (extrai o tablespace de um BACKUP, sem tocar
#     no banco de origem - o RMAN sobe uma instancia auxiliar sozinho)
#   - XTTS (cross-platform incremental backup) - roteiro
#   - Full Transportable Export/Import (12c+)
#
# A armadilha classica de TTS:
#
#   o tablespace precisa estar READ ONLY no momento do export dos metadados,
#   e o conjunto precisa ser AUTO-CONTIDO. Se houver um indice em outro
#   tablespace apontando para uma tabela do conjunto, o import falha depois
#   de voce ja ter copiado terabytes.
#
#   Por isso TRANSPORT_SET_CHECK vem ANTES de qualquer copia, sempre.
###############################################################################

orb_op_tts_menu()
{
    while :
    do
        orb_title "TRANSPORTABLE TABLESPACE / CROSS-PLATFORM"
        orb_field "Plataforma deste banco" "${ORB_D_PLATFORM:-?}"
        orb_field "Endianness"             "${ORB_D_ENDIAN:-?}"
        orb_log_raw ""

        orb_menu_begin
        orb_menu_group "PREPARACAO (somente leitura)"
        orb_menu_add  1 "Plataformas e endianness suportadas"
        orb_menu_add  2 "Listar tablespaces (status, tamanho, self-contained)"
        orb_menu_add  3 "TRANSPORT_SET_CHECK (auto-contencao)"
        orb_menu_add  4 "Objetos que impedem o transporte"

        orb_menu_group "ORIGEM"
        orb_menu_add  5 "Colocar tablespaces em READ ONLY"          danger
        orb_menu_add  6 "Exportar metadados (expdp transportable)"  danger
        orb_menu_add  7 "RMAN CONVERT TABLESPACE (converter na origem)" danger
        orb_menu_add  8 "Devolver tablespaces para READ WRITE"      danger

        orb_menu_group "DESTINO"
        orb_menu_add  9 "RMAN CONVERT DATAFILE (converter no destino)" danger
        orb_menu_add 10 "Importar metadados (impdp transport_datafiles)" danger

        orb_menu_group "A PARTIR DE BACKUP / GRANDES VOLUMES"
        orb_menu_add 11 "RMAN TRANSPORT TABLESPACE (do backup, sem tocar na origem)" danger
        orb_menu_add 12 "XTTS - roteiro de incremental cross-platform"
        orb_menu_add 13 "Full Transportable Export/Import (12c+) - roteiro"
        orb_menu_add  0 "Voltar"
        orb_menu_render
        orb_log_raw ""

        orb_ask "Opcao" "1" || return 0
        case "$ORB_ANSWER" in
            1)  orb_tts_platforms ;;
            2)  orb_tts_list ;;
            3)  orb_tts_set_check ;;
            4)  orb_tts_blockers ;;
            5)  orb_tts_readonly "READ ONLY" ;;
            6)  orb_tts_expdp ;;
            7)  orb_tts_convert_source ;;
            8)  orb_tts_readonly "READ WRITE" ;;
            9)  orb_tts_convert_target ;;
            10) orb_tts_impdp ;;
            11) orb_tts_from_backup ;;
            12) orb_tts_xtts_guide ;;
            13) orb_tts_full_transportable ;;
            0)  return 0 ;;
            "") ;;
            *)  orb_warn "Opcao invalida." ;;
        esac
        orb_pause
    done
}

# ---------------------------------------------------------------------------
# 1 - plataformas
# ---------------------------------------------------------------------------
orb_tts_platforms()
{
    orb_section "PLATAFORMA DESTE BANCO"
    _p=`orb_sql_value "(select platform_name from v\\$database)"`
    _e=`orb_sql_value "(select endian_format from v\\$transportable_platform tp, v\\$database d where tp.platform_name=d.platform_name)"`
    orb_field "platform_name" "`_orb_or_na "$_p"`"
    orb_field "endian_format" "`_orb_or_na "$_e"`"

    orb_section "PLATAFORMAS SUPORTADAS"
    orb_log_raw "  ID   ENDIAN         PLATAFORMA"
    orb_sql_query "select 'ORBR|'||platform_id||'|'||endian_format||'|'||platform_name from v\$transportable_platform order by endian_format, platform_name;" \
        | while IFS='|' read _id _en _nm
        do
            orb_log_raw "  `printf '%-4s %-14s %s' "$_id" "$_en" "$_nm"`"
        done

    orb_section "O QUE ISSO DECIDE"
    orb_item "Endianness IGUAL  : RMAN CONVERT so reescreve o cabecalho - rapido."
    orb_item "Endianness DIFERENTE: cada bloco e reescrito - lento, e precisa de"
    orb_item "                     espaco para a copia convertida."
    orb_item "AIX e Solaris SPARC sao BIG endian. Linux x86, Windows sao LITTLE."
    orb_item "AIX -> Linux e, portanto, conversao real de bloco."
    return 0
}

# ---------------------------------------------------------------------------
# 2 - listar tablespaces
# ---------------------------------------------------------------------------
orb_tts_list()
{
    orb_section "TABLESPACES"
    orb_log_raw "  `printf '%-24s %-12s %-10s %10s %6s' TABLESPACE STATUS CONTENTS MB FILES`"
    orb_sql_query "select 'ORBR|'||t.tablespace_name||'|'||t.status||'|'||t.contents||'|'||
                          to_char(round(nvl(f.mb,0)))||'|'||to_char(nvl(f.n,0))
                     from dba_tablespaces t,
                          (select tablespace_name, sum(bytes)/1024/1024 mb, count(*) n
                             from dba_data_files group by tablespace_name) f
                    where t.tablespace_name = f.tablespace_name(+)
                    order by t.tablespace_name;" \
        | while IFS='|' read _t _s _c _m _n
        do
            orb_log_raw "  `printf '%-24s %-12s %-10s %10s %6s' "$_t" "$_s" "$_c" "$_m" "$_n"`"
        done

    orb_section "NAO SAO TRANSPORTAVEIS"
    orb_item "SYSTEM, SYSAUX, UNDO e TEMP nunca entram num conjunto TTS."
    orb_item "Para levar o banco inteiro use Full Transportable (opcao 13)."
    return 0
}

# ---------------------------------------------------------------------------
# helper - pede a lista de tablespaces
# ---------------------------------------------------------------------------
orb_tts_ask_set()
{
    orb_ask "Tablespaces (separados por virgula, sem espaco)" "${ORB_TTS_SET:-}"
    [ -z "$ORB_ANSWER" ] && return 1
    ORB_TTS_SET=`orb_upper "$ORB_ANSWER"`
    # lista com aspas, para o TRANSPORT_SET_CHECK
    ORB_TTS_SET_Q=`echo "$ORB_TTS_SET" | sed "s/,/','/g"`
    ORB_TTS_SET_Q="'$ORB_TTS_SET_Q'"
    return 0
}

# ---------------------------------------------------------------------------
# 3 - TRANSPORT_SET_CHECK
# ---------------------------------------------------------------------------
orb_tts_set_check()
{
    orb_title "TRANSPORT_SET_CHECK"
    orb_require_open || return 1
    orb_tts_ask_set  || return 1

    orb_ask "Incluir constraints (referencial completo)? [S/N]" "S"
    if [ "`orb_upper $ORB_ANSWER`" = "S" ]; then
        _incl="TRUE"
    else
        _incl="FALSE"
    fi

    _s="$ORB_RUNDIR/tts_check.sql"
    {
        echo "set serveroutput on size unlimited"
        echo "set heading off feedback off pagesize 0 linesize 400"
        echo "exec dbms_tts.transport_set_check('$ORB_TTS_SET', $_incl, TRUE);"
        echo "prompt"
        echo "prompt === VIOLACOES ==="
        echo "select 'ORBR|'||violations from transport_set_violations;"
        echo "exit"
    } > "$_s"

    orb_section "EXECUTANDO A VERIFICACAO"
    orb_item "Conjunto : $ORB_TTS_SET"
    orb_item "Constraints incluidas: $_incl"
    orb_log_raw ""

    # leitura pura: roda direto, nao passa pelo engine
    _out="$ORB_RUNDIR/tts_check.out"
    "$ORACLE_HOME/bin/sqlplus" -s -L "/ as sysdba" @"$_s" > "$_out" 2>&1
    orb_log_file "$_out"

    if grep '^ORBR|' "$_out" >/dev/null 2>&1; then
        orb_err "O conjunto NAO e auto-contido. Violacoes:"
        sed -n 's/^ORBR|//p' "$_out" | while IFS= read _v ; do orb_item "$_v" ; done
        orb_log_raw ""
        orb_item "Resolva ANTES de copiar datafile algum. Caminhos usuais:"
        orb_item "  - incluir no conjunto o tablespace que falta"
        orb_item "  - mover o indice orfao para dentro do conjunto"
        orb_item "  - rodar de novo com constraints=FALSE se a FK for aceitavel perder"
        return 1
    fi
    orb_ok "Conjunto auto-contido - pode transportar."
    return 0
}

# ---------------------------------------------------------------------------
# 4 - bloqueadores
# ---------------------------------------------------------------------------
orb_tts_blockers()
{
    orb_title "OBJETOS QUE IMPEDEM OU COMPLICAM O TRANSPORTE"
    orb_require_open || return 1
    orb_tts_ask_set  || return 1

    _in=`echo "$ORB_TTS_SET" | sed "s/,/','/g"`
    _in="'$_in'"

    orb_section "OBJETOS SYS/SYSTEM DENTRO DO CONJUNTO"
    orb_sql_query "select 'ORBR|'||owner||'.'||segment_name||'|'||segment_type
                     from dba_segments
                    where tablespace_name in ($_in)
                      and owner in ('SYS','SYSTEM')
                    order by 1;" \
        | while IFS='|' read _o _t ; do orb_log_raw "  $_o  ($_t)" ; done

    orb_section "TIPOS QUE EXIGEM ATENCAO"
    orb_sql_query "select 'ORBR|'||segment_type||'|'||to_char(count(*))
                     from dba_segments
                    where tablespace_name in ($_in)
                      and segment_type in ('LOBSEGMENT','LOBINDEX','NESTED TABLE','TABLE PARTITION','INDEX PARTITION')
                    group by segment_type order by 1;" \
        | while IFS='|' read _t _n ; do orb_field "$_t" "$_n" ; done

    orb_section "OPAQUE / EXTERNAL / TIPOS NAO TRANSPORTAVEIS"
    orb_sql_query "select 'ORBR|'||owner||'.'||table_name||'|EXTERNAL'
                     from dba_external_tables
                    where owner not in ('SYS','SYSTEM') and rownum <= 30;" \
        | while IFS='|' read _o _t ; do orb_log_raw "  $_o  ($_t)" ; done

    orb_section "PONTOS QUE NAO VIAJAM COM O TABLESPACE"
    orb_item "Usuarios/roles/grants - crie no destino ANTES do impdp."
    orb_item "Sequences, PL/SQL, views, jobs - ficam no banco de origem."
    orb_item "Objetos com TDE - a wallet precisa acompanhar (ver PÓS-RESTORE)."
    orb_item "Se houver colunas criptografadas, o export exige ENCRYPTION_PASSWORD."
    return 0
}

# ---------------------------------------------------------------------------
# 5 / 8 - READ ONLY / READ WRITE
# ---------------------------------------------------------------------------
orb_tts_readonly()
{
    _mode="$1"
    orb_title "COLOCAR TABLESPACES EM $_mode"
    orb_require_open || return 1
    orb_tts_ask_set  || return 1

    _s="$ORB_RUNDIR/tts_mode.sql"
    : > "$_s"
    echo "$ORB_TTS_SET" | tr ',' '\n' | while IFS= read _t
    do
        [ -n "$_t" ] && echo "alter tablespace $_t $_mode;" >> "$_s"
    done
    echo "exit" >> "$_s"

    orb_plan_begin "TABLESPACES EM $_mode"
    orb_plan_field "Conjunto" "$ORB_TTS_SET"
    orb_plan_cmd_file "Alteracao de modo" "$_s"
    if [ "$_mode" = "READ ONLY" ]; then
        orb_plan_risk "As aplicacoes que gravam nesses tablespaces vao receber ORA-00372."
        orb_plan_risk "O tablespace precisa permanecer READ ONLY ate o fim do expdp"
        orb_plan_risk "E ate a copia dos datafiles terminar - se voltar antes, o SCN"
        orb_plan_risk "do cabecalho muda e o import rejeita o arquivo."
        orb_plan_risk "Transacoes ativas impedem a mudanca (ORA-01546)."
    else
        orb_plan_risk "So devolva para READ WRITE depois que a copia dos datafiles"
        orb_plan_risk "estiver CONCLUIDA e conferida no destino."
    fi
    orb_plan_confirm "ALTERAR-MODO" || return 1
    orb_exec_sql "tts_mode" "$_s"

    orb_section "CONFERENCIA"
    _in=`echo "$ORB_TTS_SET" | sed "s/,/','/g"`
    orb_sql_query "select 'ORBR|'||tablespace_name||'|'||status from dba_tablespaces where tablespace_name in ('$_in');" \
        | while IFS='|' read _t _st ; do orb_field "$_t" "$_st" ; done
    return 0
}

# ---------------------------------------------------------------------------
# 6 - expdp
# ---------------------------------------------------------------------------
orb_tts_expdp()
{
    orb_title "EXPORT DOS METADADOS (TRANSPORTABLE)"
    orb_require_open || return 1
    orb_tts_ask_set  || return 1

    _st=`orb_sql_value "(select count(*) from dba_tablespaces where status<>'READ ONLY' and tablespace_name in (select trim(regexp_substr('$ORB_TTS_SET','[^,]+',1,level)) from dual connect by level<=100))"`
    if [ -n "$_st" ] && [ "$_st" != "0" ] 2>/dev/null; then
        orb_err "$_st tablespace(s) do conjunto NAO estao READ ONLY."
        orb_item "O expdp transportable exige READ ONLY. Use a opcao 5 primeiro."
        return 1
    fi

    orb_ask "Diretorio Oracle (DIRECTORY) para o dumpfile" "DATA_PUMP_DIR"
    _dir="$ORB_ANSWER"
    orb_ask "Nome do dumpfile" "tts_${ORB_D_DBNAME:-db}.dmp"
    _dmp="$ORB_ANSWER"

    _f="$ORB_RUNDIR/tts_expdp.txt"
    {
        echo "expdp \\\"/ as sysdba\\\" \\"
        echo "  directory=$_dir \\"
        echo "  dumpfile=$_dmp \\"
        echo "  logfile=${_dmp}.log \\"
        echo "  transport_tablespaces=$ORB_TTS_SET \\"
        echo "  transport_full_check=y"
    } > "$_f"

    orb_section "CAMINHO FISICO DO DIRECTORY"
    _dp=`orb_sql_value "(select directory_path from dba_directories where directory_name=upper('$_dir'))"`
    orb_field "$_dir" "`_orb_or_na "$_dp"`"
    [ -z "$_dp" ] && orb_warn "DIRECTORY '$_dir' nao existe no dicionario."

    orb_section "DATAFILES QUE PRECISAM SER COPIADOS"
    _in=`echo "$ORB_TTS_SET" | sed "s/,/','/g"`
    orb_sql_query "select 'ORBR|'||file_name||'|'||to_char(round(bytes/1024/1024))
                     from dba_data_files where tablespace_name in ('$_in') order by file_id;" \
        | while IFS='|' read _fn _mb ; do orb_log_raw "  `printf '%10s MB  %s' "$_mb" "$_fn"`" ; done

    orb_plan_begin "EXPDP TRANSPORTABLE TABLESPACES"
    orb_plan_field "Conjunto"  "$ORB_TTS_SET"
    orb_plan_field "Directory" "$_dir ($_dp)"
    orb_plan_field "Dumpfile"  "$_dmp"
    orb_plan_cmd_file "Comando expdp" "$_f"
    orb_plan_risk "O dump contem SO metadados - os datafiles viajam separados."
    orb_plan_risk "Copie os datafiles apos o expdp, com o tablespace ainda READ ONLY."
    orb_plan_risk "Se houver TDE, acrescente ENCRYPTION_PASSWORD ao comando."
    orb_plan_confirm "EXPORTAR-METADADOS" || return 1

    orb_exec_os "expdp_tts" "$ORACLE_HOME/bin/expdp" "/ as sysdba" \
        "directory=$_dir" "dumpfile=$_dmp" "logfile=${_dmp}.log" \
        "transport_tablespaces=$ORB_TTS_SET" "transport_full_check=y"
    return $?
}

# ---------------------------------------------------------------------------
# 7 - CONVERT na origem
# ---------------------------------------------------------------------------
orb_tts_convert_source()
{
    orb_title "RMAN CONVERT TABLESPACE (na origem)"
    orb_require_open || return 1
    orb_tts_ask_set  || return 1

    orb_tts_platforms > /dev/null 2>&1
    orb_ask "Plataforma de DESTINO (platform_name exato)" "Linux x86 64-bit"
    _plat="$ORB_ANSWER"
    orb_ask "Diretorio de saida dos arquivos convertidos" "/tmp/tts_out"
    _out="$ORB_ANSWER"
    orb_ask "Paralelismo" "${ORB_CHANNELS:-4}"
    _par="$ORB_ANSWER"

    _f="$ORB_RUNDIR/cmd_tts_convert_src.rman"
    {
        echo "CONVERT TABLESPACE $ORB_TTS_SET"
        echo "  TO PLATFORM '$_plat'"
        echo "  FORMAT '$_out/%U'"
        echo "  PARALLELISM $_par;"
        echo "EXIT;"
    } > "$_f"

    orb_plan_begin "CONVERT TABLESPACE PARA $_plat"
    orb_plan_field "Conjunto"  "$ORB_TTS_SET"
    orb_plan_field "Destino"   "$_out"
    orb_plan_field "Plataforma" "$_plat"
    orb_plan_cmd_file "RMAN CONVERT" "$_f"
    orb_plan_risk "Precisa de espaco livre igual ao tamanho dos tablespaces em $_out."
    orb_plan_risk "Os tablespaces precisam estar READ ONLY."
    orb_plan_risk "Converter na ORIGEM consome CPU do servidor de producao."
    orb_plan_risk "Alternativa: copiar cru e converter no destino (opcao 9)."
    orb_plan_confirm "CONVERTER-ORIGEM" || return 1

    orb_check_space "$_out" "" >/dev/null 2>&1
    orb_exec_rman "tts_convert_src" "$_f"
    return $?
}

# ---------------------------------------------------------------------------
# 9 - CONVERT no destino
# ---------------------------------------------------------------------------
orb_tts_convert_target()
{
    orb_title "RMAN CONVERT DATAFILE (no destino)"
    orb_item "Rode ESTE passo no servidor de DESTINO, com os datafiles crus"
    orb_item "ja copiados da origem."
    orb_log_raw ""

    orb_ask "Diretorio com os datafiles vindos da origem" "/tmp/tts_in"
    _src="$ORB_ANSWER"
    orb_ask "Plataforma de ORIGEM (platform_name exato)" "AIX-Based Systems (64-bit)"
    _plat="$ORB_ANSWER"
    orb_ask "Destino final (+DG ou caminho)" "${ORB_D_DBCREATE:-+DATA}"
    _dst="$ORB_ANSWER"
    orb_ask "Paralelismo" "${ORB_CHANNELS:-4}"
    _par="$ORB_ANSWER"

    if [ ! -d "$_src" ]; then
        orb_err "Diretorio nao encontrado: $_src"
        return 1
    fi

    _lst="$ORB_RUNDIR/tts_files.lst"
    ls "$_src" 2>/dev/null | while IFS= read _n
    do
        [ -f "$_src/$_n" ] && echo "$_src/$_n"
    done > "$_lst"

    if [ ! -s "$_lst" ]; then
        orb_err "Nenhum arquivo em $_src."
        return 1
    fi

    orb_section "ARQUIVOS ENCONTRADOS"
    _n=0
    while IFS= read _fn
    do
        orb_item "$_fn"
        _n=`expr $_n + 1`
    done < "$_lst"
    orb_field "Total" "$_n arquivos"

    _f="$ORB_RUNDIR/cmd_tts_convert_tgt.rman"
    {
        echo "CONVERT DATAFILE"
        _first=1
        while IFS= read _fn
        do
            if [ $_first -eq 1 ]; then
                echo "  '$_fn'"
                _first=0
            else
                echo " ,'$_fn'"
            fi
        done < "$_lst"
        echo "  FROM PLATFORM '$_plat'"
        echo "  DB_FILE_NAME_CONVERT '$_src', '$_dst'"
        echo "  PARALLELISM $_par;"
        echo "EXIT;"
    } > "$_f"

    orb_plan_begin "CONVERT DATAFILE DE $_plat"
    orb_plan_field "Origem dos arquivos" "$_src"
    orb_plan_field "Destino"             "$_dst"
    orb_plan_field "Arquivos"            "$_n"
    orb_plan_cmd_file "RMAN CONVERT" "$_f"
    orb_plan_risk "Este RMAN conecta em um banco DESTINO ja existente e aberto."
    orb_plan_risk "A conversao reescreve cada bloco: reserve tempo e espaco."
    orb_plan_risk "Depois da conversao, rode o impdp (opcao 10) apontando para"
    orb_plan_risk "os arquivos JA CONVERTIDOS, nao para os crus."
    orb_plan_confirm "CONVERTER-DESTINO" || return 1

    orb_exec_rman "tts_convert_tgt" "$_f"
    return $?
}

# ---------------------------------------------------------------------------
# 10 - impdp
# ---------------------------------------------------------------------------
orb_tts_impdp()
{
    orb_title "IMPORT DOS METADADOS (TRANSPORT_DATAFILES)"
    orb_item "Rode no banco de DESTINO, com ele ABERTO."
    orb_log_raw ""

    orb_ask "Directory do dumpfile" "DATA_PUMP_DIR"
    _dir="$ORB_ANSWER"
    orb_ask "Nome do dumpfile" "tts_db.dmp"
    _dmp="$ORB_ANSWER"
    orb_ask "Datafiles convertidos (separados por virgula, caminho completo)" ""
    [ -z "$ORB_ANSWER" ] && { orb_err "Sem datafiles nao ha o que importar." ; return 1 ; }
    _dfs="$ORB_ANSWER"
    orb_ask "Remapear schema? (origem:destino, vazio = nao)" ""
    _rmp="$ORB_ANSWER"

    _f="$ORB_RUNDIR/tts_impdp.txt"
    {
        echo "impdp \\\"/ as sysdba\\\" \\"
        echo "  directory=$_dir \\"
        echo "  dumpfile=$_dmp \\"
        echo "  logfile=imp_${_dmp}.log \\"
        echo "  transport_datafiles='$_dfs'"
        [ -n "$_rmp" ] && echo "  remap_schema=$_rmp"
    } > "$_f"

    orb_plan_begin "IMPDP TRANSPORT_DATAFILES"
    orb_plan_field "Directory" "$_dir"
    orb_plan_field "Dumpfile"  "$_dmp"
    orb_plan_field "Datafiles" "$_dfs"
    orb_plan_cmd_file "Comando impdp" "$_f"
    orb_plan_risk "Os owners dos objetos precisam JA EXISTIR no destino (ou remap_schema)."
    orb_plan_risk "Os datafiles passam a pertencer ao banco destino - nao os apague."
    orb_plan_risk "Apos o import, coloque os tablespaces em READ WRITE no destino."
    orb_plan_risk "Se o export usou ENCRYPTION_PASSWORD, o import exige a mesma senha."
    orb_plan_confirm "IMPORTAR-METADADOS" || return 1

    if [ -n "$_rmp" ]; then
        orb_exec_os "impdp_tts" "$ORACLE_HOME/bin/impdp" "/ as sysdba" \
            "directory=$_dir" "dumpfile=$_dmp" "logfile=imp_${_dmp}.log" \
            "transport_datafiles=$_dfs" "remap_schema=$_rmp"
    else
        orb_exec_os "impdp_tts" "$ORACLE_HOME/bin/impdp" "/ as sysdba" \
            "directory=$_dir" "dumpfile=$_dmp" "logfile=imp_${_dmp}.log" \
            "transport_datafiles=$_dfs"
    fi
    _rc=$?

    orb_section "DEPOIS DO IMPORT"
    orb_item "alter tablespace <nome> read write;   -- em cada tablespace importado"
    orb_item "Recolete estatisticas: dbms_stats.gather_schema_stats"
    orb_item "Confira dba_tablespaces e dba_data_files no destino."
    return $_rc
}

# ---------------------------------------------------------------------------
# 11 - TRANSPORT TABLESPACE a partir de backup
# ---------------------------------------------------------------------------
orb_tts_from_backup()
{
    orb_title "RMAN TRANSPORT TABLESPACE (a partir de BACKUP)"
    orb_item "Extrai o tablespace de um backup, num ponto no tempo, sem colocar"
    orb_item "nada em READ ONLY e sem tocar no banco de origem. O RMAN sobe uma"
    orb_item "instancia auxiliar por conta propria e a derruba no fim."
    orb_log_raw ""
    orb_check_version 11 || return 1
    orb_tts_ask_set  || return 1

    orb_ask "Diretorio auxiliar (destino dos datafiles)" "/tmp/tts_aux/datafile"
    _dfd="$ORB_ANSWER"
    orb_ask "Diretorio do dump de metadados" "/tmp/tts_aux/dump"
    _dpd="$ORB_ANSWER"
    orb_ask "Area de trabalho da instancia auxiliar" "/tmp/tts_aux/work"
    _aux="$ORB_ANSWER"
    orb_ask "Ponto no tempo [SCN|TIME|NONE]" "NONE"
    _pk=`orb_upper "$ORB_ANSWER"`
    _until=""
    case "$_pk" in
        SCN)  orb_ask "SCN" "" ; [ -n "$ORB_ANSWER" ] && _until="  UNTIL SCN $ORB_ANSWER" ;;
        TIME) orb_ask "Data (DD-MON-YYYY HH24:MI:SS)" ""
              [ -n "$ORB_ANSWER" ] && _until="  UNTIL TIME \"TO_DATE('$ORB_ANSWER','DD-MON-YYYY HH24:MI:SS')\"" ;;
    esac

    for _d in "$_dfd" "$_dpd" "$_aux"
    do
        mkdir -p "$_d" 2>/dev/null
        [ -d "$_d" ] || { orb_err "Nao consegui criar $_d" ; return 1 ; }
    done

    _f="$ORB_RUNDIR/cmd_tts_backup.rman"
    {
        echo "TRANSPORT TABLESPACE $ORB_TTS_SET"
        echo "  TABLESPACE DESTINATION '$_dfd'"
        echo "  AUXILIARY DESTINATION '$_aux'"
        echo "  DATAPUMP DIRECTORY tts_dump_dir"
        echo "  DUMP FILE 'tts_dump.dmp'"
        echo "  IMPORT SCRIPT 'tts_import.sql'"
        echo "  EXPORT LOG 'tts_export.log'$_until;"
        echo "EXIT;"
    } > "$_f"

    _s="$ORB_RUNDIR/tts_dir.sql"
    printf "create or replace directory tts_dump_dir as '%s';\nexit\n" "$_dpd" > "$_s"

    orb_plan_begin "TRANSPORT TABLESPACE A PARTIR DE BACKUP"
    orb_plan_field "Conjunto"   "$ORB_TTS_SET"
    orb_plan_field "Datafiles"  "$_dfd"
    orb_plan_field "Dump"       "$_dpd"
    orb_plan_field "Auxiliar"   "$_aux"
    orb_plan_field "Ponto"      "${_until:-ultimo backup disponivel}"
    orb_plan_cmd "Criar directory do dump" "create or replace directory tts_dump_dir as '$_dpd';"
    orb_plan_cmd_file "RMAN TRANSPORT TABLESPACE" "$_f"
    orb_plan_risk "O RMAN sobe uma instancia auxiliar: precisa de memoria livre no host."
    orb_plan_risk "A area auxiliar guarda SYSTEM, SYSAUX, UNDO e os tablespaces do"
    orb_plan_risk "conjunto - dimensione o espaco pensando nisso, nao so no conjunto."
    orb_plan_risk "O conjunto tambem precisa ser auto-contido AQUI (rode a opcao 3)."
    orb_plan_risk "Sem backup que cubra o ponto pedido, o comando falha no meio."
    orb_plan_confirm "TRANSPORTAR-DO-BACKUP" || return 1

    orb_exec_sql  "tts_dir"        "$_s"
    orb_exec_rman "tts_from_backup" "$_f" || return 1

    orb_section "PROXIMO PASSO"
    orb_item "O RMAN gerou $_dpd/tts_import.sql - rode-o no banco DESTINO,"
    orb_item "ou use impdp com transport_datafiles apontando para $_dfd."
    return 0
}

# ---------------------------------------------------------------------------
# 12 - XTTS
# ---------------------------------------------------------------------------
orb_tts_xtts_guide()
{
    orb_title "XTTS - CROSS-PLATFORM INCREMENTAL BACKUP"

    orb_section "QUANDO USAR"
    orb_item "Migracao entre plataformas de endianness diferente (ex.: AIX -> Linux)"
    orb_item "com volume grande demais para uma janela de READ ONLY convencional."
    orb_item "A ideia: copiar quente, aplicar incrementais ate a diferenca ficar"
    orb_item "pequena, e so entao parar a aplicacao para o passo final."

    orb_section "ROTEIRO"
    orb_item " 1. Nota MOS 2005729.1 - baixar o kit rman_xttconvert."
    orb_item " 2. Preparar xtt.properties (tablespaces, plataformas, diretorios)."
    orb_item " 3. FASE PREPARE  : xttdriver.pl -p   (backup nivel 0 dos datafiles)"
    orb_item " 4. Copiar para o destino e converter  : xttdriver.pl -c"
    orb_item " 5. FASE ROLL FWD : xttdriver.pl -i    (incremental)  - repetir N vezes"
    orb_item "    Cada rodada diminui o delta. Repita ate o incremental ficar curto."
    orb_item " 6. JANELA FINAL  : tablespaces em READ ONLY"
    orb_item " 7. Ultimo incremental + xttdriver.pl -e (gera o expdp transportable)"
    orb_item " 8. impdp no destino com transport_datafiles"
    orb_item " 9. Tablespaces em READ WRITE no destino, estatisticas, validacao"

    orb_section "O QUE MAIS DA ERRADO"
    orb_item "Datafile adicionado na origem no meio do processo: o XTTS nao o pega"
    orb_item "sozinho. Congele DDL de tablespace durante a migracao."
    orb_item "Relogio dessincronizado entre origem e destino confunde o driver."
    orb_item "Perl e a versao do kit precisam bater com a versao do banco."
    orb_item "Nao esqueca dos objetos que NAO viajam: usuarios, PL/SQL, sequences,"
    orb_item "views, jobs, dblinks, sinonimos publicos, perfis e grants."

    orb_section "ALTERNATIVA MODERNA"
    orb_item "19c: Full Transportable + Data Pump over network_link resolve boa"
    orb_item "parte dos casos com muito menos peca movel. Veja a opcao 13."
    return 0
}

# ---------------------------------------------------------------------------
# 13 - Full transportable
# ---------------------------------------------------------------------------
orb_tts_full_transportable()
{
    orb_title "FULL TRANSPORTABLE EXPORT/IMPORT (12c+)"
    orb_check_version 12 >/dev/null 2>&1

    orb_section "O QUE E"
    orb_item "Move o banco INTEIRO (dados nos datafiles + tudo que e metadado)"
    orb_item "em uma operacao. Diferente do TTS classico, leva usuarios, PL/SQL,"
    orb_item "views, sequences e grants junto."
    orb_item "E o caminho mais direto de non-CDB para PDB."

    orb_section "PRE-REQUISITOS"
    orb_item "Origem 11.2.0.3 ou superior; destino 12.1 ou superior."
    orb_item "COMPATIBLE >= 12.0.0 no destino."
    orb_item "Todos os tablespaces de usuario em READ ONLY durante o export."
    orb_item "SYSTEM/SYSAUX/UNDO/TEMP nao sao transportados - o destino usa os seus."

    orb_section "MODO 1 - COM DUMPFILE"
    orb_log_raw "  expdp \\\"/ as sysdba\\\" full=y transportable=always \\"
    orb_log_raw "        version=12 directory=DP_DIR dumpfile=full_tts.dmp \\"
    orb_log_raw "        logfile=full_tts.log"
    orb_log_raw ""
    orb_log_raw "  (copiar os datafiles + converter se a endianness for diferente)"
    orb_log_raw ""
    orb_log_raw "  impdp \\\"/ as sysdba\\\" full=y directory=DP_DIR \\"
    orb_log_raw "        dumpfile=full_tts.dmp \\"
    orb_log_raw "        transport_datafiles='/u01/oradata/PDB1/users01.dbf' \\"
    orb_log_raw "        logfile=imp_full_tts.log"

    orb_section "MODO 2 - PELA REDE (sem dumpfile)"
    orb_log_raw "  impdp \\\"/ as sysdba\\\" network_link=ORIGEM_DB \\"
    orb_log_raw "        full=y transportable=always version=12 \\"
    orb_log_raw "        transport_datafiles='...' \\"
    orb_log_raw "        logfile=imp_net.log"
    orb_item "Exige dblink para a origem e os datafiles ja visiveis no destino."

    orb_section "PARA PDB"
    orb_item "Acrescente no impdp:  transport_datafiles=... e conecte no PDB alvo"
    orb_item "  impdp usuario@destino:1521/PDB1 ..."
    orb_item "Assim o non-CDB inteiro vira um PDB do container destino."

    orb_section "DEPOIS"
    orb_item "Tablespaces em READ WRITE, estatisticas, recompilacao (utlrp.sql),"
    orb_item "conferencia de invalid objects e de dba_tablespaces no destino."
    return 0
}
