#!/usr/bin/sh
###############################################################################
# ops/pdb.sh - CDB / PDB
###############################################################################

orb_op_pdb_menu()
{
    if [ "$ORB_D_CDB" != "Y" ]; then
        orb_warn "Este banco nao e CDB (v\$database.cdb != YES)."
        return 1
    fi

    while :
    do
        orb_title "PDB / CDB"
        orb_pdb_list
        orb_log_raw ""
        orb_menu_begin
        orb_menu_group "INFORMACAO"
        orb_menu_add  1 "Listar PDBs (estado, restricted, violacoes)"
        orb_menu_add  2 "Datafiles e tamanho por PDB"

        orb_menu_group "RESTORE E RECOVERY"
        orb_menu_add  3 "RESTORE PLUGGABLE DATABASE"          danger
        orb_menu_add  4 "RECOVER PLUGGABLE DATABASE"          danger
        orb_menu_add  5 "PDB POINT-IN-TIME RECOVERY"          danger
        orb_menu_add  6 "RESTORE de datafile/tablespace DENTRO de um PDB" danger
        orb_menu_add  7 "RESTORE do CDB$ROOT / PDB$SEED"      danger

        orb_menu_group "CICLO DE VIDA"
        orb_menu_add  8 "Abrir / fechar PDB"                  danger
        orb_menu_add  9 "UNPLUG de PDB (gera o XML)"          danger
        orb_menu_add 10 "PLUG de PDB (a partir do XML)"       danger
        orb_menu_add 11 "Flashback de PDB"                    danger
        orb_menu_add  0 "Voltar"
        orb_menu_render
        orb_log_raw ""

        orb_ask "Opcao" "1" || return 0
        case "$ORB_ANSWER" in
            1)  orb_pdb_list ;;
            2)  orb_pdb_files ;;
            3)  orb_pdb_restore ;;
            4)  orb_pdb_recover ;;
            5)  orb_pdb_pitr ;;
            6)  orb_pdb_restore_part ;;
            7)  orb_pdb_root_seed ;;
            8)  orb_pdb_openclose ;;
            9)  orb_pdb_unplug ;;
            10) orb_pdb_plug ;;
            11) orb_pdb_flashback ;;
            0)  return 0 ;;
            "") ;;
            *)  orb_warn "Opcao invalida." ;;
        esac
        orb_pause
    done
}

orb_pdb_list()
{
    orb_section "PLUGGABLE DATABASES"
    orb_sql_query "select 'ORBR|'||con_id||'|'||name||'|'||open_mode||'|'||restricted from v\$pdbs order by con_id;" \
        | while IFS='|' read _id _n _om _rs
        do
            orb_log_raw "  con_id=$_id  $_n  $_om  restricted=$_rs"
        done
    return 0
}

orb_pdb_pick()
{
    orb_ask "Nome do PDB" ""
    [ -z "$ORB_ANSWER" ] && return 1
    ORB_PDB="$ORB_ANSWER"
    _ck=`orb_sql_value "(select name from v\\$pdbs where upper(name)=upper('$ORB_PDB'))"`
    if [ -z "$_ck" ]; then
        orb_err "PDB nao encontrado: $ORB_PDB"
        return 1
    fi
    ORB_PDB="$_ck"
    return 0
}

orb_pdb_restore()
{
    orb_title "RESTORE PLUGGABLE DATABASE"
    orb_pdb_pick || return 1
    orb_require_mounted || orb_require_open || return 1

    _f="$ORB_RUNDIR/cmd_pdb_restore.rman"
    orb_rman_build "$_f" \
        "  ALTER PLUGGABLE DATABASE $ORB_PDB CLOSE;" \
        "  RESTORE PLUGGABLE DATABASE $ORB_PDB;" \
        "  RECOVER PLUGGABLE DATABASE $ORB_PDB;" \
        "  ALTER PLUGGABLE DATABASE $ORB_PDB OPEN;"

    orb_plan_begin "RESTORE + RECOVER PDB $ORB_PDB"
    orb_plan_field "CDB"   "${ORB_D_DBNAME:-?}"
    orb_plan_field "PDB"   "$ORB_PDB"
    orb_plan_field "Media" "`orb_media_summary`"
    orb_plan_cmd_file "Restore do PDB" "$_f"
    orb_plan_risk "O PDB sera fechado durante a operacao - indisponivel para os usuarios."
    orb_plan_risk "Os datafiles do PDB serao sobrescritos."
    orb_plan_risk "Os demais PDBs e o CDB\$ROOT continuam no ar."
    orb_plan_confirm "RESTAURAR-PDB" || return 1
    orb_exec_rman "pdb_restore" "$_f"
    _rc=$?
    orb_pdb_list
    return $_rc
}

orb_pdb_recover()
{
    orb_title "RECOVER PLUGGABLE DATABASE"
    orb_pdb_pick || return 1

    _f="$ORB_RUNDIR/cmd_pdb_recover.rman"
    orb_rman_build "$_f" "  RECOVER PLUGGABLE DATABASE $ORB_PDB;"

    orb_plan_begin "RECOVER PDB $ORB_PDB"
    orb_plan_field "PDB" "$ORB_PDB"
    orb_plan_cmd_file "Recover do PDB" "$_f"
    orb_plan_risk "Aplica redo nos datafiles do PDB."
    orb_plan_confirm "RECUPERAR-PDB" || return 1
    orb_exec_rman "pdb_recover" "$_f"
    return $?
}

orb_pdb_pitr()
{
    orb_title "PDB POINT-IN-TIME RECOVERY"
    orb_check_version 12 || return 1
    orb_pdb_pick || return 1

    orb_pitr_target || return 1

    orb_ask "Auxiliary destination (necessario em algumas versoes)" "/tmp/pdbpitr"
    _aux="$ORB_ANSWER"

    _f="$ORB_RUNDIR/cmd_pdb_pitr.rman"
    {
        echo "RUN {"
        orb_channels_block
        echo "  $ORB_PITR_UNTIL"
        echo "  ALTER PLUGGABLE DATABASE $ORB_PDB CLOSE;"
        echo "  RESTORE PLUGGABLE DATABASE $ORB_PDB;"
        echo "  RECOVER PLUGGABLE DATABASE $ORB_PDB AUXILIARY DESTINATION '$_aux';"
        echo "  ALTER PLUGGABLE DATABASE $ORB_PDB OPEN RESETLOGS;"
        echo "}"
        echo "EXIT;"
    } > "$_f"

    orb_plan_begin "PDB PITR: $ORB_PDB ate $ORB_PITR_DESC"
    orb_plan_field "PDB"       "$ORB_PDB"
    orb_plan_field "Alvo"      "$ORB_PITR_DESC"
    orb_plan_field "Auxiliary" "$_aux"
    orb_plan_cmd_file "PDB PITR" "$_f"
    orb_plan_risk "Dados do PDB posteriores ao ponto serao PERDIDOS."
    orb_plan_risk "O PDB abre com RESETLOGS - os demais PDBs nao sao afetados."
    orb_plan_risk "Pode exigir instancia auxiliar com espaco em $_aux."
    orb_plan_confirm "PDB-PITR" || return 1
    orb_exec_rman "pdb_pitr" "$_f"
    _rc=$?
    orb_pdb_list
    return $_rc
}

# ---------------------------------------------------------------------------
# Wrappers de nivel superior.
#
# RESTORE PLUGGABLE DATABASE estava so dentro do submenu PDB, que por sua vez
# estava no grupo RECOVERY. Para restaurar um PDB era preciso passar por
# "recovery" - organizacao errada. Agora aparece no grupo RESTORE tambem.
# ---------------------------------------------------------------------------
orb_op_pdb_restore()
{
    [ "$ORB_D_CDB" = "Y" ] || { orb_status_line warn "Este banco nao e CDB." ; return 1 ; }
    orb_pdb_list
    orb_pdb_restore
}

orb_op_pdb_recover()
{
    [ "$ORB_D_CDB" = "Y" ] || { orb_status_line warn "Este banco nao e CDB." ; return 1 ; }
    orb_pdb_list
    orb_pdb_recover
}

orb_op_pdb_pitr()
{
    [ "$ORB_D_CDB" = "Y" ] || { orb_status_line warn "Este banco nao e CDB." ; return 1 ; }
    orb_pdb_list
    orb_pdb_pitr
}

# ---------------------------------------------------------------------------
# DATAFILES POR PDB
# ---------------------------------------------------------------------------
orb_pdb_files()
{
    orb_section "DATAFILES POR PDB"
    orb_sql_query "select 'ORBR|'||p.name||'|'||to_char(count(*))||'|'||to_char(round(sum(d.bytes)/1024/1024))
                     from v\$pdbs p, cdb_data_files d
                    where p.con_id = d.con_id
                    group by p.name order by p.name;" \
        | while IFS='|' read _n _c _m
        do
            orb_log_raw "  `printf '%-24s %4s arquivos  %10s MB' "$_n" "$_c" "$_m"`"
        done

    orb_section "VIOLACOES DE PLUG"
    _v=`orb_sql_value "(select to_char(count(*)) from pdb_plug_in_violations where status<>'RESOLVED')"`
    orb_field "Violacoes pendentes" "`_orb_or_na "$_v"`"
    if [ -n "$_v" ] && [ "$_v" != "0" ]; then
        orb_sql_query "select 'ORBR|'||name||'|'||type||'|'||substr(message,1,90)
                         from pdb_plug_in_violations where status<>'RESOLVED' and rownum<=15;" \
            | while IFS='|' read _n _t _m ; do orb_log_raw "  [$_t] $_n : $_m" ; done
        orb_item "Violacoes ERROR impedem o PDB de abrir em modo normal."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# RESTORE PARCIAL DENTRO DE UM PDB
# ---------------------------------------------------------------------------
orb_pdb_restore_part()
{
    orb_title "RESTORE PARCIAL DENTRO DE UM PDB"
    orb_pdb_pick || return 1

    orb_ask "Restaurar [TABLESPACE|DATAFILE]" "TABLESPACE"
    _kind=`orb_upper "$ORB_ANSWER"`

    if [ "$_kind" = "DATAFILE" ]; then
        orb_section "DATAFILES DO PDB $ORB_PDB"
        orb_sql_query "select 'ORBR|'||d.file_id||'|'||d.tablespace_name||'|'||d.file_name
                         from cdb_data_files d, v\$pdbs p
                        where d.con_id=p.con_id and p.name=upper('$ORB_PDB')
                        order by d.file_id;" \
            | while IFS='|' read _i _t _f ; do orb_log_raw "  $_i  $_t  $_f" ; done
        orb_log_raw ""
        orb_ask "file_id (separados por virgula)" ""
        [ -z "$ORB_ANSWER" ] && return 1
        _obj="DATAFILE $ORB_ANSWER"
    else
        orb_section "TABLESPACES DO PDB $ORB_PDB"
        orb_sql_query "select 'ORBR|'||t.tablespace_name||'|'||t.status
                         from cdb_tablespaces t, v\$pdbs p
                        where t.con_id=p.con_id and p.name=upper('$ORB_PDB')
                        order by t.tablespace_name;" \
            | while IFS='|' read _t _st ; do orb_log_raw "  $_t  ($_st)" ; done
        orb_log_raw ""
        orb_ask "Tablespace(s), separados por virgula" ""
        [ -z "$ORB_ANSWER" ] && return 1
        _obj="TABLESPACE \"$ORB_PDB\":$ORB_ANSWER"
    fi

    _f="$ORB_RUNDIR/cmd_pdb_part.rman"
    orb_rman_build "$_f" \
        "  SQL 'ALTER PLUGGABLE DATABASE $ORB_PDB CLOSE';" \
        "  RESTORE $_obj;" \
        "  RECOVER $_obj;" \
        "  SQL 'ALTER PLUGGABLE DATABASE $ORB_PDB OPEN';"

    orb_plan_begin "RESTORE PARCIAL EM $ORB_PDB"
    orb_plan_field "PDB"    "$ORB_PDB"
    orb_plan_field "Objeto" "$_obj"
    orb_plan_cmd_file "Restore parcial" "$_f"
    orb_plan_risk "O PDB inteiro sera fechado - nao so o tablespace."
    orb_plan_risk "Para restaurar sem fechar o PDB, coloque apenas o TABLESPACE"
    orb_plan_risk "offline e restaure com o PDB aberto (menos disruptivo)."
    orb_plan_risk "Note a sintaxe \"PDB\":TABLESPACE - sem ela o RMAN procura o"
    orb_plan_risk "tablespace no CDB\$ROOT e nao encontra."
    orb_plan_confirm "RESTAURAR-PARTE-PDB" || return 1
    orb_exec_rman "pdb_part" "$_f"
    return $?
}

# ---------------------------------------------------------------------------
# CDB$ROOT / PDB$SEED
# ---------------------------------------------------------------------------
orb_pdb_root_seed()
{
    orb_title "RESTORE DO CDB\$ROOT / PDB\$SEED"
    orb_check_version 12 || return 1

    orb_item "CDB\$ROOT e o container. Restaurar o root significa parada TOTAL:"
    orb_item "todos os PDBs ficam indisponiveis."
    orb_item "PDB\$SEED e o molde de novos PDBs - perde-lo nao derruba producao,"
    orb_item "mas impede criar PDB novo."
    orb_log_raw ""

    orb_ask "Restaurar [ROOT|SEED]" "SEED"
    case "`orb_upper $ORB_ANSWER`" in
        ROOT)
            _obj="DATABASE ROOT"
            _lbl="CDB\$ROOT"
            _pre="  STARTUP FORCE MOUNT;"
            ;;
        *)
            _obj="PLUGGABLE DATABASE \"PDB\$SEED\""
            _lbl="PDB\$SEED"
            _pre=""
            ;;
    esac

    _f="$ORB_RUNDIR/cmd_pdb_rootseed.rman"
    if [ -n "$_pre" ]; then
        orb_rman_build "$_f" "$_pre" "  RESTORE $_obj;" "  RECOVER $_obj;"
    else
        orb_rman_build "$_f" "  RESTORE $_obj;" "  RECOVER $_obj;"
    fi

    orb_plan_begin "RESTORE $_lbl"
    orb_plan_field "Alvo" "$_lbl"
    orb_plan_cmd_file "Restore" "$_f"
    if [ "$_lbl" = "CDB\$ROOT" ]; then
        orb_plan_risk "PARADA TOTAL: o CDB precisa ir para MOUNT e TODOS os PDBs caem."
        orb_plan_risk "Depois do recover, abra o CDB e os PDBs um a um, conferindo"
        orb_plan_risk "pdb_plug_in_violations antes de liberar os usuarios."
    else
        orb_plan_risk "PDB\$SEED precisa estar READ ONLY - o restore o fecha antes."
    fi
    orb_plan_confirm "RESTAURAR-CONTAINER" || return 1
    orb_exec_rman "pdb_rootseed" "$_f"
    _rc=$?
    orb_pdb_list
    return $_rc
}

# ---------------------------------------------------------------------------
# ABRIR / FECHAR
# ---------------------------------------------------------------------------
orb_pdb_openclose()
{
    orb_title "ABRIR / FECHAR PDB"
    orb_pdb_pick || return 1

    orb_ask "Acao [OPEN|OPEN READ ONLY|OPEN RESTRICTED|CLOSE|CLOSE IMMEDIATE]" "OPEN"
    _act=`orb_upper "$ORB_ANSWER"`
    case "$_act" in
        OPEN|"OPEN READ ONLY"|"OPEN RESTRICTED"|CLOSE|"CLOSE IMMEDIATE") : ;;
        *) orb_err "Acao invalida." ; return 1 ;;
    esac

    orb_ask "Salvar o state (o PDB sobe sozinho no proximo startup)? [S/N]" "N"
    _save=""
    [ "`orb_upper $ORB_ANSWER`" = "S" ] && _save="alter pluggable database $ORB_PDB save state;"

    _s="$ORB_RUNDIR/pdb_openclose.sql"
    {
        echo "alter pluggable database $ORB_PDB $_act;"
        [ -n "$_save" ] && echo "$_save"
        echo "select name, open_mode, restricted from v\$pdbs where name=upper('$ORB_PDB');"
        echo "exit"
    } > "$_s"

    orb_plan_begin "$_act NO PDB $ORB_PDB"
    orb_plan_field "PDB"   "$ORB_PDB"
    orb_plan_field "Acao"  "$_act"
    orb_plan_cmd_file "Comando" "$_s"
    case "$_act" in
        CLOSE*) orb_plan_risk "Os usuarios conectados neste PDB perdem a sessao." ;;
    esac
    orb_plan_confirm "ALTERAR-PDB" || return 1
    orb_exec_sql "pdb_openclose" "$_s"
    _rc=$?
    orb_pdb_list
    return $_rc
}

# ---------------------------------------------------------------------------
# UNPLUG
# ---------------------------------------------------------------------------
orb_pdb_unplug()
{
    orb_title "UNPLUG DE PDB"
    orb_pdb_pick || return 1

    orb_ask "Caminho do XML de descricao" "/tmp/${ORB_PDB}.xml"
    _xml="$ORB_ANSWER"

    _s="$ORB_RUNDIR/pdb_unplug.sql"
    {
        echo "alter pluggable database $ORB_PDB close immediate;"
        echo "alter pluggable database $ORB_PDB unplug into '$_xml';"
        echo "select name, open_mode from v\$pdbs where name=upper('$ORB_PDB');"
        echo "exit"
    } > "$_s"

    orb_plan_begin "UNPLUG DO PDB $ORB_PDB"
    orb_plan_field "PDB" "$ORB_PDB"
    orb_plan_field "XML" "$_xml"
    orb_plan_cmd_file "Unplug" "$_s"
    orb_plan_risk "O PDB fica indisponivel a partir do close."
    orb_plan_risk "O XML descreve os datafiles mas NAO os contem - os arquivos"
    orb_plan_risk "precisam ser copiados junto para o destino."
    orb_plan_risk "Depois do unplug o PDB fica em estado UNPLUGGED aqui; para"
    orb_plan_risk "remove-lo:  drop pluggable database $ORB_PDB keep datafiles;"
    orb_plan_risk "NAO faca drop antes de confirmar o plug no destino."
    orb_plan_confirm "DESPLUGAR-PDB" || return 1
    orb_exec_sql "pdb_unplug" "$_s"
    _rc=$?

    orb_section "PROXIMO PASSO"
    orb_item "1. Copiar $_xml e TODOS os datafiles do PDB para o CDB destino."
    orb_item "2. No destino, usar a opcao PLUG."
    return $_rc
}

# ---------------------------------------------------------------------------
# PLUG
# ---------------------------------------------------------------------------
orb_pdb_plug()
{
    orb_title "PLUG DE PDB"
    if [ "$ORB_D_CDB" != "Y" ]; then
        orb_err "Este banco nao e CDB."
        return 1
    fi

    orb_ask "Caminho do XML de descricao" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _xml="$ORB_ANSWER"
    [ -f "$_xml" ] || orb_warn "Nao encontrei $_xml neste host - confirme o caminho."

    orb_ask "Nome do PDB no destino" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _new="$ORB_ANSWER"

    orb_ask "Os datafiles ja estao no lugar final? [S/N] (N = COPY)" "N"
    if [ "`orb_upper $ORB_ANSWER`" = "S" ]; then
        _mode="NOCOPY"
    else
        _mode="COPY"
    fi

    orb_ask "Destino dos datafiles (+DG ou caminho, vazio = OMF)" "${ORB_D_DBCREATE:-}"
    _dst="$ORB_ANSWER"

    _s="$ORB_RUNDIR/pdb_plug.sql"
    {
        echo "set serveroutput on"
        echo "declare"
        echo "  ok boolean;"
        echo "begin"
        echo "  ok := dbms_pdb.check_plug_compatibility('$_xml');"
        echo "  if ok then dbms_output.put_line('COMPATIVEL');"
        echo "  else dbms_output.put_line('INCOMPATIVEL - veja pdb_plug_in_violations');"
        echo "  end if;"
        echo "end;"
        echo "/"
        if [ -n "$_dst" ]; then
            echo "create pluggable database $_new using '$_xml' $_mode file_name_convert=none create_file_dest='$_dst';"
        else
            echo "create pluggable database $_new using '$_xml' $_mode;"
        fi
        echo "alter pluggable database $_new open;"
        echo "select name, open_mode from v\$pdbs where name=upper('$_new');"
        echo "select type, message from pdb_plug_in_violations where name=upper('$_new') and status<>'RESOLVED';"
        echo "exit"
    } > "$_s"

    orb_plan_begin "PLUG DO PDB $_new"
    orb_plan_field "XML"       "$_xml"
    orb_plan_field "Novo nome" "$_new"
    orb_plan_field "Modo"      "$_mode"
    orb_plan_field "Destino"   "${_dst:-OMF}"
    orb_plan_cmd_file "Plug" "$_s"
    orb_plan_risk "check_plug_compatibility roda ANTES - se der INCOMPATIVEL, pare"
    orb_plan_risk "e leia pdb_plug_in_violations em vez de forcar."
    orb_plan_risk "NOCOPY usa os datafiles ONDE ESTAO - se voce apagar aquela copia,"
    orb_plan_risk "o PDB morre. Em duvida, use COPY."
    orb_plan_risk "Versao e patch level do destino precisam ser >= os da origem."
    orb_plan_risk "Se houver TDE na origem, importe a chave antes de abrir o PDB."
    orb_plan_confirm "PLUGAR-PDB" || return 1
    orb_exec_sql "pdb_plug" "$_s"
    _rc=$?
    orb_pdb_list
    orb_item "Se houver violacoes, rode noncdb_to_pdb.sql / utlrp.sql conforme o caso."
    return $_rc
}

# ---------------------------------------------------------------------------
# FLASHBACK DE PDB
# ---------------------------------------------------------------------------
orb_pdb_flashback()
{
    orb_title "FLASHBACK DE PDB"
    orb_check_version 12 || return 1
    orb_pdb_pick || return 1

    _fb=`orb_sql_value "(select flashback_on from v\\$database)"`
    orb_field "Flashback do CDB" "`_orb_or_na "$_fb"`"
    if [ "$_fb" != "YES" ]; then
        orb_err "Flashback desligado no CDB - flashback de PDB depende dele."
        return 1
    fi

    orb_section "RESTORE POINTS DESTE PDB"
    orb_sql_query "select 'ORBR|'||name||'|'||to_char(scn)||'|'||nvl(to_char(time,'DD/MM/YYYY HH24:MI:SS'),'-')||'|'||guarantee_flashback_database
                     from v\$restore_point order by scn;" \
        | while IFS='|' read _n _s _t _g
        do
            orb_log_raw "  `printf '%-24s scn=%-16s %s  garantido=%s' "$_n" "$_s" "$_t" "$_g"`"
        done
    orb_log_raw ""

    orb_ask "Alvo [RESTORE POINT|SCN|TIME]" "RESTORE POINT"
    case "`orb_upper $ORB_ANSWER`" in
        SCN)
            orb_ask "SCN" ""
            [ -z "$ORB_ANSWER" ] && return 1
            _to="to scn $ORB_ANSWER" ; _desc="SCN $ORB_ANSWER" ;;
        TIME)
            orb_ask "Data (DD-MM-YYYY HH24:MI:SS)" ""
            [ -z "$ORB_ANSWER" ] && return 1
            _to="to timestamp to_timestamp('$ORB_ANSWER','DD-MM-YYYY HH24:MI:SS')" ; _desc="$ORB_ANSWER" ;;
        *)
            orb_ask "Nome do restore point" ""
            [ -z "$ORB_ANSWER" ] && return 1
            _to="to restore point $ORB_ANSWER" ; _desc="restore point $ORB_ANSWER" ;;
    esac

    _s="$ORB_RUNDIR/pdb_flashback.sql"
    {
        echo "alter pluggable database $ORB_PDB close immediate;"
        echo "flashback pluggable database $ORB_PDB $_to;"
        echo "alter pluggable database $ORB_PDB open resetlogs;"
        echo "select name, open_mode from v\$pdbs where name=upper('$ORB_PDB');"
        echo "exit"
    } > "$_s"

    orb_plan_begin "FLASHBACK DO PDB $ORB_PDB PARA $_desc"
    orb_plan_field "PDB"  "$ORB_PDB"
    orb_plan_field "Alvo" "$_desc"
    orb_plan_cmd_file "Flashback do PDB" "$_s"
    orb_plan_risk "Tudo que o PDB gravou depois do ponto sera PERDIDO."
    orb_plan_risk "O PDB abre com RESETLOGS - os demais PDBs nao sao afetados."
    orb_plan_risk "Se os flashback logs nao alcancarem o ponto, o comando falha"
    orb_plan_risk "(ORA-38729). Restore point GARANTIDO evita isso."
    orb_plan_risk "Faca backup do PDB depois - a incarnation dele mudou."
    orb_plan_confirm "FLASHBACK-PDB" || return 1
    orb_exec_sql "pdb_flashback" "$_s"
    _rc=$?
    orb_pdb_list
    return $_rc
}
