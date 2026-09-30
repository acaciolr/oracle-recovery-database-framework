#!/usr/bin/sh
###############################################################################
# ops/restore_advanced.sh - cenarios de restore que faltavam
#
#  - RECOVER DATABASE USING BACKUP CONTROLFILE   (o classico do controlfile antigo)
#  - restore para OUTRO HOST / outro caminho     (clone de teste, DR)
#  - restore por TAG / por handle especifico
#  - restore de banco NOARCHIVELOG               (consistente, sem recover)
#  - mover datafile entre diskgroups sem restore
#  - restore de CDB$ROOT e PDB$SEED
###############################################################################

orb_op_restore_adv_menu()
{
    while :
    do
        orb_title "RESTORE - CENARIOS AVANCADOS"
        orb_menu_begin
        orb_menu_group "CONTROLFILE ANTIGO"
        orb_menu_add  1 "RECOVER USING BACKUP CONTROLFILE"        danger
        orb_menu_add  2 "RECOVER UNTIL CANCEL (manual, sqlplus)"  danger
        orb_menu_group "OUTRO DESTINO"
        orb_menu_add  3 "Restore para OUTRO HOST / outro caminho" danger
        orb_menu_add  4 "Mover datafile entre diskgroups (sem restore)" danger
        orb_menu_group "SELECAO DE BACKUP"
        orb_menu_add  5 "Restore por TAG"                         danger
        orb_menu_add  6 "Restore ate SCN / TIME / SEQUENCE"        danger
        orb_menu_add  7 "Listar backups por TAG (leitura)"
        orb_menu_group "CASOS ESPECIAIS"
        orb_menu_add  8 "Restore de banco NOARCHIVELOG"           danger
        orb_menu_add  9 "Restore de CDB\$ROOT / PDB\$SEED"          danger
        orb_menu_add 10 "Restore de tablespace SYSTEM / UNDO"     danger
        orb_menu_add  0 "Voltar"
        orb_menu_render
        orb_log_raw ""
        orb_ask "Opcao" "" || return 0
        case "$ORB_ANSWER" in
            1)  orb_ra_using_backup_cf ;;
            2)  orb_ra_until_cancel ;;
            3)  orb_ra_other_host ;;
            4)  orb_ra_move_datafile ;;
            5)  orb_ra_by_tag ;;
            6)  orb_ra_until_point ;;
            7)  orb_ra_list_tags ;;
            8)  orb_ra_noarchivelog ;;
            9)  orb_ra_cdb_root ;;
            10) orb_ra_system_undo ;;
            0)  return 0 ;;
            "") continue ;;
            *)  orb_status_line warn "Opcao invalida." ;;
        esac
        orb_pause
    done
}

# ---------------------------------------------------------------------------
# RECOVER ... USING BACKUP CONTROLFILE
#
# Necessario sempre que o controlfile em uso for restaurado de backup, e nao
# o controlfile corrente. Sem essa clausula o Oracle recusa aplicar redo alem
# do que o controlfile antigo conhece.
# ---------------------------------------------------------------------------
orb_ra_using_backup_cf()
{
    orb_title "RECOVER DATABASE USING BACKUP CONTROLFILE"
    orb_require_mounted || return 1

    _ct=`orb_sql_value "(select controlfile_type from v\\$database)"`
    orb_field "controlfile_type" "`_orb_or_na "$_ct"`"
    orb_item "BACKUP = controlfile veio de backup; CURRENT = e o corrente."
    orb_item "Com BACKUP, o recover EXIGE a clausula USING BACKUP CONTROLFILE"
    orb_item "e termina obrigatoriamente em OPEN RESETLOGS."
    orb_log_raw ""

    orb_ask "Ate onde recuperar [CANCEL|SCN|TIME|SEQUENCE]" "CANCEL"
    _m=`orb_upper "$ORB_ANSWER"`
    case "$_m" in
        SCN)      orb_ask "SCN" "" ; _u="  SET UNTIL SCN $ORB_ANSWER;" ; _d="SCN $ORB_ANSWER" ;;
        TIME)     orb_ask "Data/hora (DD-MM-YYYY HH24:MI:SS)" ""
                  _u="  SET UNTIL TIME \"TO_DATE('$ORB_ANSWER','DD-MM-YYYY HH24:MI:SS')\";"
                  _d="TIME $ORB_ANSWER" ;;
        SEQUENCE) orb_ask "Sequence" "" ; _sq="$ORB_ANSWER"
                  orb_ask "Thread" "1"
                  _u="  SET UNTIL SEQUENCE $_sq THREAD $ORB_ANSWER;" ; _d="SEQUENCE $_sq" ;;
        *)        _u="" ; _d="ate onde houver redo" ;;
    esac

    _f="$ORB_RUNDIR/cmd_ra_ubcf.rman"
    if [ -n "$_u" ]; then
        orb_rman_build "$_f" "$_u" "  RECOVER DATABASE USING BACKUP CONTROLFILE;"
    else
        orb_rman_build "$_f" "  RECOVER DATABASE USING BACKUP CONTROLFILE;"
    fi

    orb_plan_begin "RECOVER USING BACKUP CONTROLFILE ($_d)"
    orb_plan_field "controlfile_type" "${_ct:-?}"
    orb_plan_field "Alvo"             "$_d"
    orb_plan_cmd_file "Recover" "$_f"
    orb_plan_risk "Recovery INCOMPLETO por definicao: exige OPEN RESETLOGS depois."
    orb_plan_risk "OPEN RESETLOGS cria nova incarnation - faca nivel 0 em seguida."
    orb_plan_risk "Se o controlfile nao conhecer datafiles criados depois dele, eles precisam ser adicionados a mao."
    orb_plan_risk "RMAN-06054 ao final e esperado quando o redo acaba."
    orb_plan_confirm "RECUPERAR" || return 1
    orb_exec_rman "recover_using_backup_cf" "$_f" "RMAN-06054"
    orb_postcheck_database
    orb_item "Proximo passo: menu POS-RESTORE -> OPEN RESETLOGS."
    return 0
}

# ---------------------------------------------------------------------------
orb_ra_until_cancel()
{
    orb_title "RECOVER UNTIL CANCEL (manual)"
    orb_item "Modo manual pelo SQL*Plus: o Oracle pede log a log e voce decide"
    orb_item "quando parar digitando CANCEL. Util quando falta um archive no meio"
    orb_item "e voce quer ir ate o ultimo aplicavel."
    orb_log_raw ""
    orb_status_line warn "Este comando e INTERATIVO - o framework nao consegue"
    orb_status_line warn "responder aos prompts por voce. Ele prepara e voce executa."
    orb_log_raw ""
    _s="$ORB_RUNDIR/until_cancel.sql"
    cat > "$_s" <<'EOSQL'
-- Execute a mao. A cada prompt:
--   ENTER  aceita o log sugerido
--   AUTO   aplica tudo que encontrar sem perguntar
--   CANCEL encerra o recovery aqui
recover database until cancel using backup controlfile;
EOSQL
    orb_item "Arquivo preparado: $_s"
    orb_log_raw ""
    orb_item "Rode assim:"
    orb_item "  sqlplus / as sysdba"
    orb_item "  SQL> recover database until cancel using backup controlfile;"
    orb_log_raw ""
    orb_item "Depois: alter database open resetlogs;"
    return 0
}

# ---------------------------------------------------------------------------
# RESTORE PARA OUTRO HOST
# ---------------------------------------------------------------------------
orb_ra_other_host()
{
    orb_title "RESTORE PARA OUTRO HOST / OUTRO CAMINHO"
    orb_item "Cenario: subir uma copia do banco em outro servidor a partir do"
    orb_item "backup, sem tocar no original. Clone de teste, DR, investigacao."
    orb_log_raw ""

    orb_section "CHECKLIST DO QUE PRECISA IR JUNTO"
    orb_status_line info "Estes itens NAO estao no backup RMAN de datafile:"
    orb_item "1. password file        - sem ele nao ha conexao sysdba remota"
    orb_item "2. wallet TDE           - sem ele os datafiles criptografados nao abrem"
    orb_item "3. oratab / ambiente    - ORACLE_HOME, SID, permissoes"
    orb_item "4. tnsnames / listener  - para o media manager e para o catalogo"
    orb_item "5. cliente do media manager - o NB_ORA_CLIENT tem que apontar para o"
    orb_item "   nome sob o qual o backup foi CATALOGADO, nao para o host novo"
    orb_log_raw ""
    orb_status_line warn "O item 5 e a causa mais comum de 'not found in catalog'"
    orb_status_line warn "num restore cruzado. Nao e expiracao - e client name errado."
    orb_log_raw ""

    _dbid="${ORB_D_DBID}"
    if [ -z "$_dbid" ]; then
        orb_ask "DBID do banco de ORIGEM" ""
        _dbid="$ORB_ANSWER"
    fi
    case "$_dbid" in ''|*[!0-9]*) orb_status_line fail "DBID obrigatorio." ; return 1 ;; esac

    orb_ask "Destino dos datafiles (+DG ou caminho)" "${ORB_D_DBCREATE:-+DATA}"
    _dst="$ORB_ANSWER"

    _f="$ORB_RUNDIR/cmd_ra_otherhost.rman"
    orb_rman_build "$_f" \
        "  SET DBID=$_dbid;" \
        "  RESTORE CONTROLFILE FROM AUTOBACKUP;" \
        "  SQL 'ALTER DATABASE MOUNT';" \
        "  SET NEWNAME FOR DATABASE TO '$_dst';" \
        "  RESTORE DATABASE;" \
        "  SWITCH DATAFILE ALL;" \
        "  RECOVER DATABASE;"

    orb_plan_begin "RESTORE PARA OUTRO HOST (DBID $_dbid)"
    orb_plan_field "DBID origem"  "$_dbid"
    orb_plan_field "Destino"      "$_dst"
    orb_plan_field "Media"        "`orb_media_summary`"
    orb_plan_field "SEND"         "${ORB_MEDIA_SEND:-<nenhum>}"
    orb_plan_cmd_file "Restore completo" "$_f"
    orb_plan_risk "A instancia local precisa estar em NOMOUNT com o mesmo DB_NAME."
    orb_plan_risk "Se o SEND apontar para o client errado, os pieces nao serao encontrados."
    orb_plan_risk "O banco resultante tem o MESMO DBID do original - nao registre os dois no mesmo catalogo sem DUPLICATE."
    orb_plan_risk "Termina em OPEN RESETLOGS - o clone vira nova incarnation."
    orb_plan_confirm "RESTAURAR-OUTRO-HOST" || return 1
    orb_exec_rman "restore_other_host" "$_f" "RMAN-06054"
    orb_postcheck_database
    orb_item "Depois: POS-RESTORE -> OPEN RESETLOGS, tempfiles, pwfile, wallet."
    return 0
}

# ---------------------------------------------------------------------------
orb_ra_move_datafile()
{
    orb_title "MOVER DATAFILE ENTRE DISKGROUPS"
    orb_check_version 12 || {
        orb_item "Antes do 12c: RMAN BACKUP AS COPY + SWITCH, com o arquivo offline."
        return 1
    }
    orb_item "A partir do 12c, ALTER DATABASE MOVE DATAFILE move online, sem"
    orb_item "restore e sem downtime do arquivo."
    orb_require_open || return 1

    orb_sql_query "select 'ORBR|'||file#||'|'||name||'|'||to_char(round(bytes/1024/1024)) from v\$datafile order by file#;" \
        | head -30 | while IFS='|' read _f _n _m ; do orb_item "file $_f  ${_m}MB  $_n" ; done

    orb_ask "Numero do datafile" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _df="$ORB_ANSWER"
    orb_ask "Destino (+DG ou caminho completo)" "${ORB_D_DBCREATE:-+DATA}"
    _to="$ORB_ANSWER"
    orb_ask "Manter o arquivo antigo? [S/N]" "N"
    _keep=""
    [ "`orb_upper $ORB_ANSWER`" = "S" ] && _keep=" KEEP"

    _s="$ORB_RUNDIR/move_datafile.sql"
    printf "alter database move datafile %s to '%s'%s;\nexit\n" "$_df" "$_to" "$_keep" > "$_s"

    orb_plan_begin "MOVE DATAFILE $_df -> $_to"
    orb_plan_cmd_file "Move online" "$_s"
    orb_plan_risk "Copia o arquivo inteiro - gera I/O proporcional ao tamanho."
    [ -z "$_keep" ] && orb_plan_risk "Sem KEEP, o arquivo de origem e APAGADO ao final."
    orb_plan_risk "Confira espaco no destino antes."
    orb_plan_confirm "MOVER" || return 1
    orb_exec_sql "move_datafile" "$_s"
    return $?
}

# ---------------------------------------------------------------------------
orb_ra_list_tags()
{
    orb_title "BACKUPS POR TAG"
    _f="$ORB_RUNDIR/cmd_listtag.rman"
    { echo "LIST BACKUP SUMMARY;" ; echo "EXIT;" ; } > "$_f"
    orb_rman_run "list_tags" "$_f"
    orb_item "A coluna TAG identifica o conjunto. Use-a para restaurar um"
    orb_item "backup especifico em vez de deixar o RMAN escolher."
    return 0
}

orb_ra_by_tag()
{
    orb_title "RESTORE POR TAG"
    orb_require_mounted || return 1
    orb_ask "TAG do backup" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _tag="$ORB_ANSWER"

    orb_ask "Escopo [DATABASE|TABLESPACE|DATAFILE]" "DATABASE"
    _e=`orb_upper "$ORB_ANSWER"`
    case "$_e" in
        TABLESPACE) orb_ask "Tablespace(s)" "" ; _obj="TABLESPACE $ORB_ANSWER" ;;
        DATAFILE)   orb_ask "Datafile(s)"   "" ; _obj="DATAFILE $ORB_ANSWER" ;;
        *)          _obj="DATABASE" ;;
    esac

    _f="$ORB_RUNDIR/cmd_ra_tag.rman"
    orb_rman_build "$_f" \
        "  RESTORE $_obj FROM TAG '$_tag' PREVIEW SUMMARY;" \
        "  RESTORE $_obj FROM TAG '$_tag';"

    orb_plan_begin "RESTORE $_obj FROM TAG '$_tag'"
    orb_plan_cmd_file "Restore por tag" "$_f"
    orb_plan_risk "Forca um backup especifico - o RMAN nao escolhe o melhor caminho."
    orb_plan_risk "Se aquele TAG for de um nivel 1, o restore precisa do nivel 0 pai."
    orb_plan_confirm "RESTAURAR" || return 1
    orb_exec_rman "restore_by_tag" "$_f"
    return $?
}

orb_ra_until_point()
{
    orb_title "RESTORE ATE UM PONTO"
    orb_require_mounted || return 1
    orb_ask "Criterio [SCN|TIME|SEQUENCE]" "TIME"
    _c=`orb_upper "$ORB_ANSWER"`
    case "$_c" in
        SCN)      orb_ask "SCN" "" ; _u="  SET UNTIL SCN $ORB_ANSWER;" ; _d="SCN $ORB_ANSWER" ;;
        SEQUENCE) orb_ask "Sequence" "" ; _sq="$ORB_ANSWER" ; orb_ask "Thread" "1"
                  _u="  SET UNTIL SEQUENCE $_sq THREAD $ORB_ANSWER;" ; _d="SEQ $_sq" ;;
        *)        orb_ask "Data/hora (DD-MM-YYYY HH24:MI:SS)" ""
                  _u="  SET UNTIL TIME \"TO_DATE('$ORB_ANSWER','DD-MM-YYYY HH24:MI:SS')\";"
                  _d="TIME $ORB_ANSWER" ;;
    esac
    _f="$ORB_RUNDIR/cmd_ra_until.rman"
    orb_rman_build "$_f" "$_u" "  RESTORE DATABASE PREVIEW SUMMARY;" "  RESTORE DATABASE;"
    orb_plan_begin "RESTORE ate $_d"
    orb_plan_cmd_file "Restore ao ponto" "$_f"
    orb_plan_risk "Restaura a versao dos datafiles anterior ao ponto - o recover completa."
    orb_plan_risk "Termina em OPEN RESETLOGS."
    orb_plan_confirm "RESTAURAR" || return 1
    orb_exec_rman "restore_until" "$_f"
    return $?
}

# ---------------------------------------------------------------------------
orb_ra_noarchivelog()
{
    orb_title "RESTORE DE BANCO NOARCHIVELOG"
    orb_field "Log mode atual" "`_orb_or_na "$ORB_D_LOGMODE"`"
    orb_item "Em NOARCHIVELOG so existe restore CONSISTENTE: o banco volta"
    orb_item "exatamente ao momento do backup, e nao ha recover possivel."
    orb_item "Tudo que aconteceu depois do backup esta perdido - nao ha redo."
    orb_log_raw ""
    orb_require_mounted || return 1

    _f="$ORB_RUNDIR/cmd_ra_noarch.rman"
    orb_rman_build "$_f" "  RESTORE DATABASE;"

    orb_plan_begin "RESTORE CONSISTENTE (NOARCHIVELOG)"
    orb_plan_cmd_file "Restore" "$_f"
    orb_plan_cmd "Abertura" "sqlplus / as sysdba <<EOF
alter database open resetlogs;
EOF"
    orb_plan_risk "PERDA DE DADOS GARANTIDA: tudo apos o backup se perde."
    orb_plan_risk "Nao ha recover - NOARCHIVELOG nao gera redo arquivado."
    orb_plan_risk "Confirme com o dono do sistema quanto tempo de dado sera perdido."
    orb_plan_confirm "ACEITO-PERDA-DE-DADOS" || return 1
    orb_exec_rman "restore_noarchivelog" "$_f" || return 1
    orb_status_line warn "Abra com RESETLOGS pelo menu POS-RESTORE."
    orb_status_line info "Considere migrar este banco para ARCHIVELOG."
    return 0
}

# ---------------------------------------------------------------------------
orb_ra_cdb_root()
{
    orb_title "RESTORE DE CDB\$ROOT / PDB\$SEED"
    if [ "$ORB_D_CDB" != "Y" ]; then
        orb_status_line warn "Este banco nao e CDB."
        return 1
    fi
    orb_item "CDB\$ROOT e PDB\$SEED sao a base do container. Se eles precisam de"
    orb_item "restore, TODOS os PDBs ficam indisponiveis durante a operacao."
    orb_require_mounted || return 1

    orb_ask "Alvo [ROOT|SEED|AMBOS]" "ROOT"
    case "`orb_upper $ORB_ANSWER`" in
        SEED)  _obj='  RESTORE PLUGGABLE DATABASE "PDB$SEED";
  RECOVER PLUGGABLE DATABASE "PDB$SEED";' ; _d='PDB$SEED' ;;
        AMBOS) _obj='  RESTORE PLUGGABLE DATABASE "CDB$ROOT", "PDB$SEED";
  RECOVER PLUGGABLE DATABASE "CDB$ROOT", "PDB$SEED";' ; _d='CDB$ROOT + PDB$SEED' ;;
        *)     _obj='  RESTORE PLUGGABLE DATABASE "CDB$ROOT";
  RECOVER PLUGGABLE DATABASE "CDB$ROOT";' ; _d='CDB$ROOT' ;;
    esac

    _f="$ORB_RUNDIR/cmd_ra_cdbroot.rman"
    orb_rman_build "$_f" "$_obj"

    orb_plan_begin "RESTORE $_d"
    orb_plan_cmd_file "Restore do container" "$_f"
    orb_plan_risk "TODOS os PDBs ficam indisponiveis durante a operacao."
    orb_plan_risk "O CDB precisa estar em MOUNT."
    orb_plan_risk "Apos o restore do ROOT, os PDBs podem precisar de recover proprio."
    orb_plan_confirm "RESTAURAR-CONTAINER" || return 1
    orb_exec_rman "restore_cdb_root" "$_f"
    return $?
}

orb_ra_system_undo()
{
    orb_title "RESTORE DE SYSTEM / UNDO"
    orb_item "SYSTEM e UNDO nao podem ficar OFFLINE com o banco aberto."
    orb_item "O restore deles exige o banco em MOUNT."
    orb_log_raw ""
    _st=`orb_instance_state`
    if [ "$_st" = "OPEN" ]; then
        orb_status_line fail "Banco ABERTO. Feche e monte antes:"
        orb_item "  shutdown immediate ; startup mount"
        return 1
    fi
    orb_require_mounted || return 1

    orb_ask "Alvo [SYSTEM|UNDO|AMBOS]" "SYSTEM"
    _a=`orb_upper "$ORB_ANSWER"`
    _undo=`orb_sql_value "(select value from v\\$parameter where name='undo_tablespace')"`
    case "$_a" in
        UNDO)  _ts="$_undo" ;;
        AMBOS) _ts="SYSTEM, $_undo" ;;
        *)     _ts="SYSTEM" ;;
    esac
    orb_field "Tablespaces alvo" "$_ts"

    _f="$ORB_RUNDIR/cmd_ra_sysundo.rman"
    orb_rman_build "$_f" "  RESTORE TABLESPACE $_ts;" "  RECOVER TABLESPACE $_ts;"

    orb_plan_begin "RESTORE TABLESPACE $_ts"
    orb_plan_cmd_file "Restore e recover" "$_f"
    orb_plan_risk "O banco fica indisponivel durante toda a operacao."
    orb_plan_risk "UNDO corrompida pode exigir recriacao da tablespace em vez de restore."
    orb_plan_confirm "RESTAURAR" || return 1
    orb_exec_rman "restore_system_undo" "$_f"
    _rc=$?
    orb_postcheck_database
    return $_rc
}
