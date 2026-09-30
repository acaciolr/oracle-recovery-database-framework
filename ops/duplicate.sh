#!/usr/bin/sh
###############################################################################
# ops/duplicate.sh - RMAN DUPLICATE
#
# Gera DB_FILE_NAME_CONVERT / LOG_FILE_NAME_CONVERT a partir do que foi
# descoberto, em vez de pedir ao operador que decore a sintaxe.
###############################################################################

orb_op_duplicate_menu()
{
    while :
    do
        orb_title "RMAN DUPLICATE / CLONE"

        orb_menu_begin
        orb_menu_group "STANDBY"
        orb_menu_add  1 "FOR STANDBY FROM ACTIVE DATABASE"          danger
        orb_menu_add  2 "FOR STANDBY a partir do BACKUP (catalogo)"  danger
        orb_menu_add  3 "FOR STANDBY a partir de BACKUP LOCATION"    danger

        orb_menu_group "CLONE / COPIA"
        orb_menu_add  4 "TO <novo> FROM ACTIVE DATABASE"             danger
        orb_menu_add  5 "TO <novo> a partir do BACKUP (catalogo)"    danger
        orb_menu_add  6 "TO <novo> a partir de BACKUP LOCATION"      danger
        orb_menu_add  7 "TO <novo> em PONTO NO TEMPO (UNTIL)"        danger

        orb_menu_group "MULTITENANT"
        orb_menu_add  8 "DUPLICATE PLUGGABLE DATABASE"               danger
        orb_menu_add  9 "Clonar PDB dentro do mesmo CDB"             danger

        orb_menu_group "APOIO"
        orb_menu_add 10 "Checklist pre-duplicate"
        orb_menu_add  0 "Voltar"
        orb_menu_render
        orb_log_raw ""

        orb_ask "Opcao" "1" || return 0
        case "$ORB_ANSWER" in
            1)  orb_duplicate standby active ;;
            2)  orb_duplicate standby backup ;;
            3)  orb_duplicate standby location ;;
            4)  orb_duplicate clone   active ;;
            5)  orb_duplicate clone   backup ;;
            6)  orb_duplicate clone   location ;;
            7)  orb_duplicate clone   backup UNTIL ;;
            8)  orb_duplicate_pdb ;;
            9)  orb_clone_pdb_local ;;
            10) orb_duplicate_checklist ;;
            0)  return 0 ;;
            "") ;;
            *)  orb_warn "Opcao invalida." ;;
        esac
        orb_pause
    done
}

# ---------------------------------------------------------------------------
# CHECKLIST PRE-DUPLICATE
#
# Quase toda falha de DUPLICATE e uma destas cinco. Conferir antes custa dois
# minutos; descobrir no meio custa a janela inteira.
# ---------------------------------------------------------------------------
orb_duplicate_checklist()
{
    orb_title "CHECKLIST PRE-DUPLICATE"

    orb_section "NO SERVIDOR AUXILIARY (destino)"
    orb_item "1. Entrada no /etc/oratab e ORACLE_SID exportado."
    orb_item "2. initSID.ora minimo com pelo menos db_name, e a instancia em NOMOUNT:"
    orb_item "     sqlplus / as sysdba"
    orb_item "     startup nomount pfile=?/dbs/initSID.ora"
    orb_item "3. Password file COPIADO do target (nao recriado):"
    orb_item "     scp target:\$ORACLE_HOME/dbs/orapwSID \$ORACLE_HOME/dbs/orapwSID"
    orb_item "   Senha diferente = ORA-01017 no meio do duplicate."
    orb_item "4. Listener no ar com SID_LIST estatico (a instancia em NOMOUNT nao"
    orb_item "   se registra sozinha):"
    orb_item "     lsnrctl status  ->  precisa listar o SID auxiliar"
    orb_item "5. Diretorios de destino existentes e com permissao, ou diskgroup"
    orb_item "   ASM montado e com espaco."

    orb_section "NOS DOIS LADOS"
    orb_item "6. tnsping funcionando NOS DOIS SENTIDOS."
    orb_item "7. Mesma versao de binario Oracle (patch level incluso)."
    orb_item "8. Se houver TDE: wallet copiada e aberta no auxiliary."

    orb_section "ESPACO"
    _sz=`orb_sql_value "(select to_char(round(sum(bytes)/1024/1024)) from v\\$datafile)"`
    orb_field "Tamanho dos datafiles deste banco" "`_orb_or_na "$_sz"` MB"
    orb_item "O auxiliary precisa disso, mais redo, mais margem."

    orb_section "TESTE RAPIDO DE CONEXAO"
    orb_item "  rman target sys@<target> auxiliary sys@<aux>"
    orb_item "  RMAN> exit"
    orb_item "Se essa linha nao conectar, o duplicate tambem nao vai."
    return 0
}

# ---------------------------------------------------------------------------
# orb_duplicate <standby|clone> <active|backup|location>
# ---------------------------------------------------------------------------
orb_duplicate()
{
    _kind="$1" ; _src="$2" ; _wantuntil="$3"

    orb_title "DUPLICATE ($_kind / $_src)"
    orb_require_oracle_home || return 1

    orb_item "A instancia auxiliar precisa estar em NOMOUNT, com password file"
    orb_item "compativel com o target e entrada TNS resolvendo dos dois lados."
    orb_log_raw ""

    orb_ask "TNS do TARGET (origem)" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _tgt="$ORB_ANSWER"

    orb_ask "TNS do AUXILIARY (destino)" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _aux="$ORB_ANSWER"

    _newname=""
    if [ "$_kind" = "clone" ]; then
        orb_ask "DB_NAME do novo banco" ""
        [ -z "$ORB_ANSWER" ] && return 1
        _newname="$ORB_ANSWER"
    else
        orb_ask "DB_UNIQUE_NAME do standby" ""
        [ -z "$ORB_ANSWER" ] && return 1
        _newname="$ORB_ANSWER"
    fi

    # ---- conversao de nomes ------------------------------------------------
    orb_section "CONVERSAO DE NOMES DE ARQUIVO"
    orb_ask "Destino dos datafiles no auxiliary (+DG ou caminho)" "${ORB_D_DBCREATE:-+DATA}"
    _ddest="$ORB_ANSWER"
    orb_ask "Destino dos redologs (vazio = mesmo dos datafiles)" ""
    _ldest="${ORB_ANSWER:-$_ddest}"

    case "$_ddest" in
        +*)
            # Em ASM com OMF, db_create_file_dest resolve; convert vira opcional.
            _conv="  SET DB_CREATE_FILE_DEST '$_ddest'"
            _lconv="  SET DB_CREATE_ONLINE_LOG_DEST_1 '$_ldest'"
            orb_item "Destino ASM: usando DB_CREATE_FILE_DEST (OMF) em vez de convert."
            ;;
        *)
            orb_ask "Caminho de origem a substituir (para o CONVERT)" ""
            _sorig="$ORB_ANSWER"
            _conv="  SET DB_FILE_NAME_CONVERT '$_sorig','$_ddest'"
            _lconv="  SET LOG_FILE_NAME_CONVERT '$_sorig','$_ldest'"
            orb_item "Destino filesystem: usando DB_FILE_NAME_CONVERT."
            ;;
    esac

    # ---- corpo do duplicate ------------------------------------------------
    case "$_kind" in
        standby) _head="DUPLICATE TARGET DATABASE FOR STANDBY" ;;
        clone)   _head="DUPLICATE TARGET DATABASE TO $_newname" ;;
    esac

    case "$_src" in
        active)
            _from="FROM ACTIVE DATABASE"
            orb_ask "Usar COMPRESSED BACKUPSET na transferencia? [S/N]" "S"
            [ "`orb_upper $ORB_ANSWER`" = "S" ] && _from="$_from USING COMPRESSED BACKUPSET"
            _loc=""
            ;;
        backup)
            _from=""
            _loc=""
            ;;
        location)
            orb_ask "BACKUP LOCATION (diretorio com os backupsets)" ""
            [ -z "$ORB_ANSWER" ] && return 1
            _from="BACKUP LOCATION '$ORB_ANSWER'"
            _loc="$ORB_ANSWER"
            ;;
    esac

    # ---- ponto no tempo ----------------------------------------------------
    _until=""
    if [ "$_wantuntil" = "UNTIL" ]; then
        orb_section "PONTO NO TEMPO"
        orb_item "O clone sera criado como o banco estava naquele instante."
        orb_ask "Tipo [SCN|TIME|SEQUENCE]" "TIME"
        case "`orb_upper $ORB_ANSWER`" in
            SCN)
                orb_ask "SCN" ""
                [ -n "$ORB_ANSWER" ] && _until="    UNTIL SCN $ORB_ANSWER"
                ;;
            SEQUENCE)
                orb_ask "SEQUENCE" ""
                _sq="$ORB_ANSWER"
                orb_ask "THREAD" "1"
                [ -n "$_sq" ] && _until="    UNTIL SEQUENCE $_sq THREAD $ORB_ANSWER"
                ;;
            *)
                orb_ask "Data (DD-MM-YYYY HH24:MI:SS)" ""
                [ -n "$ORB_ANSWER" ] && _until="    UNTIL TIME \"TO_DATE('$ORB_ANSWER','DD-MM-YYYY HH24:MI:SS')\""
                ;;
        esac
        [ -z "$_until" ] && { orb_err "Sem ponto no tempo definido." ; return 1 ; }
    fi

    # ---- reducao de escopo -------------------------------------------------
    orb_ask "Pular tablespaces? (lista separada por virgula, vazio = nenhum)" ""
    _skip=""
    if [ -n "$ORB_ANSWER" ]; then
        _skip="    SKIP TABLESPACE $ORB_ANSWER"
        orb_warn "Tablespaces pulados ficam OFFLINE no clone - nao use para standby."
    fi

    orb_ask "SECTION SIZE para datafiles grandes (ex: 32G, vazio = nao usar)" ""
    _sect=""
    [ -n "$ORB_ANSWER" ] && _sect="    SECTION SIZE $ORB_ANSWER"

    orb_ask "NOFILENAMECHECK? (S se os caminhos forem iguais aos do target)" "N"
    _nfc=""
    [ "`orb_upper $ORB_ANSWER`" = "S" ] && _nfc="  NOFILENAMECHECK"

    _dopen=""
    if [ "$_kind" = "clone" ]; then
        orb_ask "Abrir o clone ao final? [S/N] (N = NOOPEN)" "S"
        [ "`orb_upper $ORB_ANSWER`" = "N" ] && _dopen="  NOOPEN"
    fi

    _f="$ORB_RUNDIR/cmd_duplicate.rman"
    {
        echo "RUN {"
        if [ "$_src" != "active" ]; then
            orb_channels_block
        fi
        echo "$_conv"
        echo "$_lconv"
        [ "$_kind" = "standby" ] && echo "  SET DB_UNIQUE_NAME '$_newname'"
        echo "  ;"
        echo "  $_head"
        [ -n "$_from" ]  && echo "    $_from"
        [ -n "$_until" ] && echo "$_until"
        [ -n "$_skip" ]  && echo "$_skip"
        [ -n "$_sect" ]  && echo "$_sect"
        [ -n "$_nfc" ]   && echo "  $_nfc"
        [ -n "$_dopen" ] && echo "  $_dopen"
        echo "  ;"
        echo "}"
        echo "EXIT;"
    } > "$_f"

    orb_plan_begin "$_head ($_src)"
    orb_plan_field "Target"      "$_tgt"
    orb_plan_field "Auxiliary"   "$_aux"
    orb_plan_field "Novo nome"   "$_newname"
    orb_plan_field "Origem"      "$_src"
    orb_plan_field "Datafiles"   "$_ddest"
    orb_plan_field "Redologs"    "$_ldest"
    orb_plan_cmd "Conexao" "rman target sys@$_tgt auxiliary sys@$_aux"
    orb_plan_cmd_file "Duplicate" "$_f"
    orb_plan_risk "O banco AUXILIARY sera SOBRESCRITO por completo."
    [ "$_src" = "active" ] && \
        orb_plan_risk "FROM ACTIVE le o target ao vivo: gera I/O e rede em producao."
    orb_plan_risk "Password file precisa ser identico entre target e auxiliary."
    orb_plan_risk "Operacao longa, proporcional ao tamanho do banco."
    [ "$_kind" = "clone" ] && \
        orb_plan_risk "O clone recebe novo DBID - nao serve como standby."
    [ -n "$_until" ] && \
        orb_plan_risk "UNTIL exige que o backup E os archives cubram o ponto pedido."
    [ -n "$_skip" ] && \
        orb_plan_risk "SKIP TABLESPACE deixa dados de fora - o clone fica incompleto."
    [ "$_src" = "backup" ] && \
        orb_plan_risk "FROM BACKUP: o auxiliary precisa ENXERGAR a midia (mesmo"
    [ "$_src" = "backup" ] && \
        orb_plan_risk "media manager, mesmo client name) ou nada sera restaurado."

    orb_plan_confirm "DUPLICAR" || return 1

    orb_warn "O DUPLICATE exige senha de SYS para target e auxiliary."
    orb_warn "Execute o comando abaixo manualmente para nao gravar senha em log:"
    orb_log_raw ""
    orb_log_raw "  rman target sys@$_tgt auxiliary sys@$_aux cmdfile=$_f log=$ORB_RUNDIR/rman_duplicate.log"
    orb_log_raw ""
    orb_item "O cmdfile ja esta pronto em: $_f"
    return 0
}

# ---------------------------------------------------------------------------
# DUPLICATE PLUGGABLE DATABASE  -  leva um ou mais PDBs para outro CDB
# ---------------------------------------------------------------------------
orb_duplicate_pdb()
{
    orb_title "DUPLICATE PLUGGABLE DATABASE"
    orb_check_version 12 || return 1

    orb_item "Copia um ou mais PDBs de um CDB para OUTRO CDB, sem levar o"
    orb_item "container inteiro. O auxiliary aqui e um CDB ja existente."
    orb_log_raw ""

    if [ "$ORB_D_CDB" = "Y" ]; then
        orb_section "PDBS DESTE CDB"
        orb_sql_query "select 'ORBR|'||con_id||'|'||name||'|'||open_mode from v\$pdbs order by con_id;" \
            | while IFS='|' read _i _n _o ; do orb_log_raw "  con_id=$_i  $_n  $_o" ; done
    else
        orb_warn "Este banco nao e CDB - os dados abaixo virao do target remoto."
    fi
    orb_log_raw ""

    orb_ask "TNS do TARGET (CDB de origem)" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _tgt="$ORB_ANSWER"
    orb_ask "TNS do AUXILIARY (CDB de destino, ja existente)" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _aux="$ORB_ANSWER"
    orb_ask "PDBs a duplicar (separados por virgula)" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _pdbs="$ORB_ANSWER"
    orb_ask "Destino dos datafiles no auxiliary (+DG ou caminho)" "${ORB_D_DBCREATE:-+DATA}"
    _ddest="$ORB_ANSWER"

    case "$_ddest" in
        +*) _conv="  SET DB_CREATE_FILE_DEST '$_ddest'" ;;
        *)  orb_ask "Caminho de origem a substituir" ""
            _conv="  SET DB_FILE_NAME_CONVERT '$ORB_ANSWER','$_ddest'" ;;
    esac

    _f="$ORB_RUNDIR/cmd_duplicate_pdb.rman"
    {
        echo "RUN {"
        echo "$_conv"
        echo "  ;"
        echo "  DUPLICATE PLUGGABLE DATABASE $_pdbs"
        echo "    TO CDB_DESTINO"
        echo "    FROM ACTIVE DATABASE"
        echo "  ;"
        echo "}"
        echo "EXIT;"
    } > "$_f"

    orb_plan_begin "DUPLICATE PLUGGABLE DATABASE"
    orb_plan_field "Target"    "$_tgt"
    orb_plan_field "Auxiliary" "$_aux"
    orb_plan_field "PDBs"      "$_pdbs"
    orb_plan_field "Destino"   "$_ddest"
    orb_plan_cmd "Conexao" "rman target sys@$_tgt auxiliary sys@$_aux"
    orb_plan_cmd_file "Duplicate PDB" "$_f"
    orb_plan_risk "Se ja existir PDB com o mesmo nome no destino, o comando falha."
    orb_plan_risk "Objetos comuns (common users, roles) precisam existir no CDB destino."
    orb_plan_risk "Tablespaces do CDB\$ROOT nao viajam - so os do PDB."
    orb_plan_risk "Ajuste o nome do CDB destino no cmdfile antes de executar."
    orb_plan_confirm "DUPLICAR-PDB" || return 1

    orb_warn "Execute manualmente para nao gravar senha em log:"
    orb_log_raw ""
    orb_log_raw "  rman target sys@$_tgt auxiliary sys@$_aux cmdfile=$_f log=$ORB_RUNDIR/rman_dup_pdb.log"
    orb_log_raw ""
    orb_item "cmdfile pronto em: $_f"
    return 0
}

# ---------------------------------------------------------------------------
# CLONE LOCAL DE PDB  -  sem RMAN, so SQL. E o caminho mais rapido para
# criar ambiente de teste a partir de um PDB de producao no mesmo CDB.
# ---------------------------------------------------------------------------
orb_clone_pdb_local()
{
    orb_title "CLONAR PDB DENTRO DO MESMO CDB"
    orb_check_version 12 || return 1
    if [ "$ORB_D_CDB" != "Y" ]; then
        orb_err "Este banco nao e CDB."
        return 1
    fi

    orb_section "PDBS DISPONIVEIS"
    orb_sql_query "select 'ORBR|'||con_id||'|'||name||'|'||open_mode from v\$pdbs order by con_id;" \
        | while IFS='|' read _i _n _o ; do orb_log_raw "  con_id=$_i  $_n  $_o" ; done
    orb_log_raw ""

    orb_ask "PDB de ORIGEM" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _src="$ORB_ANSWER"
    orb_ask "Nome do NOVO PDB" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _new="$ORB_ANSWER"
    orb_ask "Destino dos datafiles (+DG ou caminho, vazio = OMF)" "${ORB_D_DBCREATE:-}"
    _dst="$ORB_ANSWER"

    _om=`orb_sql_value "(select open_mode from v\\$pdbs where name=upper('$_src'))"`
    orb_field "Open mode da origem" "`_orb_or_na "$_om"`"

    _hot="N"
    _v=`orb_sql_value "(select to_char(count(*)) from v\\$parameter where name='local_undo_enabled' and value='TRUE')"`
    [ "$_v" = "1" ] && _hot="Y"
    orb_field "Local undo (permite hot clone)" "$_hot"

    _s="$ORB_RUNDIR/pdb_clone.sql"
    : > "$_s"
    if [ "$_hot" != "Y" ]; then
        orb_warn "Sem local undo: a origem precisa ficar READ ONLY durante o clone."
        {
            echo "alter pluggable database $_src close immediate;"
            echo "alter pluggable database $_src open read only;"
        } >> "$_s"
    fi
    if [ -n "$_dst" ]; then
        echo "create pluggable database $_new from $_src create_file_dest='$_dst';" >> "$_s"
    else
        echo "create pluggable database $_new from $_src;" >> "$_s"
    fi
    echo "alter pluggable database $_new open;" >> "$_s"
    if [ "$_hot" != "Y" ]; then
        {
            echo "alter pluggable database $_src close immediate;"
            echo "alter pluggable database $_src open;"
        } >> "$_s"
    fi
    echo "select name, open_mode from v\$pdbs;" >> "$_s"
    echo "exit" >> "$_s"

    orb_plan_begin "CLONE LOCAL DE PDB $_src -> $_new"
    orb_plan_field "Origem"    "$_src"
    orb_plan_field "Novo PDB"  "$_new"
    orb_plan_field "Destino"   "${_dst:-OMF}"
    orb_plan_field "Hot clone" "$_hot"
    orb_plan_cmd_file "Clone" "$_s"
    if [ "$_hot" != "Y" ]; then
        orb_plan_risk "A origem FICA INDISPONIVEL PARA ESCRITA durante todo o clone."
        orb_plan_risk "Em producao isso e uma parada - avalie o horario."
    fi
    orb_plan_risk "O clone ocupa o mesmo espaco do PDB de origem."
    orb_plan_risk "Dados sensiveis viajam junto - considere mascaramento depois."
    orb_plan_risk "O novo PDB comeca em MOUNTED ate o open; salve o state se quiser"
    orb_plan_risk "que ele suba sozinho:  alter pluggable database $_new save state;"
    orb_plan_confirm "CLONAR-PDB" || return 1

    orb_exec_sql "pdb_clone" "$_s"
    return $?
}
