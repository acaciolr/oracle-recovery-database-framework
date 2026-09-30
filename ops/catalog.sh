#!/usr/bin/sh
###############################################################################
# ops/catalog.sh - catalogo, retencao e configuracao persistente do RMAN
#
# Motivado por dois achados de campo:
#
#  1. "PL/SQL package USR_CATALOG.DBMS_RCVCAT version 19.22 is not current"
#     Client 19.30 com catalogo 19.22. E aviso, nao erro - mas RMAN com
#     catalogo downlevel tem comportamento degradado documentado.
#
#  2. Catalogo dizendo AVAILABLE para pieces que o media manager ja expirou.
#     CROSSCHECK e o unico jeito de alinhar as duas visoes - e ele muda o que
#     o RMAN considera restauravel, entao nao pode ser rodado no automatico.
###############################################################################

orb_op_catalog_menu()
{
    while :
    do
        orb_title "CATALOGO E MANUTENCAO"
        orb_field "Catalogo" "`orb_rman_has_catalog && echo SIM || echo NAO`"
        orb_field "cf_record_keep_time" "${ORB_D_CFKEEP:-?} dias"
        orb_menu_begin
        orb_menu_group "CATALOGO"
        orb_menu_add  1 "Status e versao do catalogo"
        orb_menu_add  2 "REGISTER DATABASE (registrar este banco)"
        orb_menu_add  3 "RESYNC CATALOG"
        orb_menu_add  4 "UPGRADE CATALOG"
        orb_menu_add  5 "UNREGISTER DATABASE"                         danger
        orb_menu_group "ALINHAMENTO COM A MIDIA"
        orb_menu_add  6 "CROSSCHECK (backup, archivelog, copy)"
        orb_menu_add  7 "Listar EXPIRED"
        orb_menu_add  8 "DELETE EXPIRED"                              danger
        orb_menu_add  9 "REPORT OBSOLETE"
        orb_menu_add 10 "DELETE OBSOLETE"                             danger
        orb_menu_add 11 "CATALOG START WITH (importar pieces de um diretorio)"
        orb_menu_group "CONFIGURACAO PERSISTENTE"
        orb_menu_add 12 "SHOW ALL"
        orb_menu_add 13 "Politica de retencao"
        orb_menu_add 14 "Autobackup de controlfile"
        orb_menu_add 15 "Paralelismo e canais persistentes"
        orb_menu_add 16 "Block change tracking"
        orb_menu_add  0 "Voltar"
        orb_menu_render
        orb_log_raw ""
        orb_ask "Opcao" "" || return 0
        case "$ORB_ANSWER" in
            1)  orb_cat_status ;;
            2)  orb_cat_simple "REGISTER DATABASE;" "REGISTER DATABASE" \
                    "Registra este banco no catalogo. Idempotente-ish: falha se ja registrado." ;;
            3)  orb_cat_simple "RESYNC CATALOG;" "RESYNC CATALOG" \
                    "Sincroniza o catalogo com o controlfile atual. Seguro." ;;
            4)  orb_cat_upgrade ;;
            5)  orb_cat_unregister ;;
            6)  orb_cat_crosscheck ;;
            7)  orb_cat_list_expired ;;
            8)  orb_cat_delete_expired ;;
            9)  orb_cat_simple "REPORT OBSOLETE;" "REPORT OBSOLETE" \
                    "Lista o que a politica de retencao considera dispensavel. Nao apaga." ;;
            10) orb_cat_delete_obsolete ;;
            11) orb_cat_catalog_start_with ;;
            12) orb_cat_simple "SHOW ALL;" "SHOW ALL" "Configuracao persistente atual." ;;
            13) orb_cat_retention ;;
            14) orb_cat_autobackup ;;
            15) orb_cat_parallelism ;;
            16) orb_cat_bct ;;
            0)  return 0 ;;
            "") continue ;;
            *)  orb_status_line warn "Opcao invalida." ;;
        esac
        orb_pause
    done
}

# ---------------------------------------------------------------------------
orb_cat_simple()
{
    _cmd="$1" ; _name="$2" ; _note="$3"
    _f="$ORB_RUNDIR/cmd_cat.rman"
    { echo "$_cmd" ; echo "EXIT;" ; } > "$_f"
    [ -n "$_note" ] && orb_item "$_note"
    orb_rman_run "cat_`echo $_name | tr ' ' '_' | orb_lower`" "$_f"
    return $?
}

# ---------------------------------------------------------------------------
orb_cat_status()
{
    orb_title "STATUS DO CATALOGO"
    if ! orb_rman_has_catalog; then
        orb_status_line warn "Nenhum catalogo configurado."
        orb_item "Sem catalogo o RMAN so enxerga a janela de control_file_record_keep_time"
        orb_item "(atual: ${ORB_D_CFKEEP:-?} dias). Backup mais antigo que isso fica invisivel."
        orb_item "Foi assim que um restore tentou CRIAR o datafile 1 - ORA-01180."
        return 1
    fi

    _l=`orb_rman_capture "catstatus" "LIST INCARNATION;" "EXIT;"`
    orb_log_file "$_l"

    if grep -i "is not current" "$_l" >/dev/null 2>&1; then
        orb_status_line warn "Catalogo em versao ANTERIOR ao client RMAN."
        grep -i "not current" "$_l" | sort -u | while IFS= read _x ; do orb_item "$_x" ; done
        orb_item "RMAN com catalogo downlevel tem comportamento degradado documentado."
        orb_item "Corrija com UPGRADE CATALOG (opcao 4) - mas leia o aviso de la."
    else
        orb_status_line ok "Catalogo na versao do client."
    fi
    return 0
}

orb_cat_upgrade()
{
    orb_title "UPGRADE CATALOG"
    orb_status_line warn "Isto afeta TODOS os bancos registrados nesse catalogo."
    orb_item "Nao e uma acao local: outros times dependem do mesmo repositorio."
    orb_item "O comando precisa ser executado DUAS vezes - o RMAN pede confirmacao."
    orb_item "Combine antes com quem administra o catalogo."
    orb_log_raw ""
    _f="$ORB_RUNDIR/cmd_upgrade_cat.rman"
    { echo "UPGRADE CATALOG;" ; echo "UPGRADE CATALOG;" ; echo "EXIT;" ; } > "$_f"
    orb_plan_begin "UPGRADE CATALOG"
    orb_plan_cmd_file "Upgrade (duas vezes, como o RMAN exige)" "$_f"
    orb_plan_risk "Afeta TODOS os bancos registrados no catalogo, nao so este."
    orb_plan_risk "Altera o schema do repositorio - faca backup do catalogo antes."
    orb_plan_risk "Nunca rode isso no meio de um incidente de outro banco."
    orb_plan_confirm "UPGRADE-CATALOGO" || return 1
    orb_exec_rman "upgrade_catalog" "$_f"
    return $?
}

orb_cat_unregister()
{
    orb_title "UNREGISTER DATABASE"
    orb_status_line crit "Remove do catalogo TODO o historico de backup deste banco."
    orb_item "Database: ${ORB_D_DBNAME:-?}  DBID: ${ORB_D_DBID:-?}"
    orb_item "Depois disso, so resta o que couber no controlfile."
    _f="$ORB_RUNDIR/cmd_unreg.rman"
    { echo "UNREGISTER DATABASE ${ORB_D_DBNAME} NOPROMPT;" ; echo "EXIT;" ; } > "$_f"
    orb_plan_begin "UNREGISTER DATABASE ${ORB_D_DBNAME}"
    orb_plan_cmd_file "Unregister" "$_f"
    orb_plan_risk "IRREVERSIVEL sem restore do catalogo."
    orb_plan_risk "Todo o historico de backupsets deste banco some do repositorio."
    orb_plan_risk "Backups antigos ficam orfaos: existem na midia, invisiveis ao RMAN."
    orb_plan_confirm "REMOVER-DO-CATALOGO" || return 1
    orb_exec_rman "unregister" "$_f"
    return $?
}

# ---------------------------------------------------------------------------
orb_cat_crosscheck()
{
    orb_title "CROSSCHECK"
    orb_item "Confere, item a item, se o que o repositorio conhece existe na midia."
    orb_item "O que nao existir e marcado EXPIRED. Nada e apagado."
    orb_log_raw ""
    orb_status_line info "Este e o comando que revela expiracao silenciosa de fita."
    orb_log_raw ""
    orb_ask "Escopo [TUDO|BACKUP|ARCHIVELOG|COPY]" "TUDO"
    _e=`orb_upper "$ORB_ANSWER"`
    _f="$ORB_RUNDIR/cmd_crosscheck.rman"
    case "$_e" in
        BACKUP)     orb_rman_build "$_f" "  CROSSCHECK BACKUP;" ;;
        ARCHIVELOG) orb_rman_build "$_f" "  CROSSCHECK ARCHIVELOG ALL;" ;;
        COPY)       orb_rman_build "$_f" "  CROSSCHECK COPY;" ;;
        *)          orb_rman_build "$_f" "  CROSSCHECK BACKUP;" "  CROSSCHECK ARCHIVELOG ALL;" "  CROSSCHECK COPY;" ;;
    esac
    orb_plan_begin "CROSSCHECK $_e"
    orb_plan_cmd_file "Crosscheck" "$_f"
    orb_plan_risk "Nao apaga nada, mas muda o que o RMAN considera disponivel."
    orb_plan_risk "Se o time de backup reimportar imagens depois, rode de novo."
    orb_plan_risk "Em fita, o crosscheck pode demorar - ele consulta o media manager."
    orb_plan_confirm "CROSSCHECK" || return 1
    orb_exec_rman "crosscheck" "$_f" || return 1
    orb_cat_list_expired
    return 0
}

orb_cat_list_expired()
{
    _f="$ORB_RUNDIR/cmd_listexp.rman"
    { echo "LIST EXPIRED BACKUP SUMMARY;" ; echo "LIST EXPIRED ARCHIVELOG ALL;" ; echo "LIST EXPIRED COPY;" ; echo "EXIT;" ; } > "$_f"
    orb_rman_run "list_expired" "$_f"
    orb_item "EXPIRED = o repositorio conhece, a midia nao tem."
    orb_item "Antes de apagar o registro, confirme com o time de backup se a"
    orb_item "imagem pode ser reimportada. Registro apagado nao volta."
    return 0
}

orb_cat_delete_expired()
{
    orb_title "DELETE EXPIRED"
    orb_status_line warn "Remove do repositorio o registro do que a midia nao tem mais."
    orb_item "Nao apaga dado nenhum - o dado ja nao existe. Apaga a MEMORIA dele."
    orb_item "Depois disso voce perde a lista dos handles que faltaram, e ela pode"
    orb_item "ser exatamente o que o time de backup precisa para reimportar."
    orb_log_raw ""
    orb_ask "Salvar a lista antes de apagar? [S/N]" "S"
    if [ "`orb_upper $ORB_ANSWER`" = "S" ]; then
        orb_cat_list_expired
        orb_status_line ok "Lista preservada em $ORB_RMAN_LAST_LOG"
    fi
    _f="$ORB_RUNDIR/cmd_delexp.rman"
    { echo "DELETE NOPROMPT EXPIRED BACKUP;" ; echo "DELETE NOPROMPT EXPIRED ARCHIVELOG ALL;" ; echo "DELETE NOPROMPT EXPIRED COPY;" ; echo "EXIT;" ; } > "$_f"
    orb_plan_begin "DELETE EXPIRED"
    orb_plan_cmd_file "Delete expired" "$_f"
    orb_plan_risk "Perde-se a lista de handles ausentes - util para reimportacao."
    orb_plan_risk "Se a expiracao foi engano (client name errado no SEND), voce apaga registro bom."
    orb_plan_confirm "APAGAR-EXPIRED" || return 1
    orb_exec_rman "delete_expired" "$_f"
    return $?
}

orb_cat_delete_obsolete()
{
    orb_title "DELETE OBSOLETE"
    orb_item "Apaga da MIDIA o que a politica de retencao considera dispensavel."
    orb_log_raw ""
    orb_cat_simple "REPORT OBSOLETE;" "REPORT_OBSOLETE_PREVIA" \
        "Isto e o que seria apagado. Leia antes de confirmar."
    _f="$ORB_RUNDIR/cmd_delobs.rman"
    orb_rman_build "$_f" "  DELETE NOPROMPT OBSOLETE;"
    orb_plan_begin "DELETE OBSOLETE"
    orb_plan_cmd_file "Delete obsolete" "$_f"
    orb_plan_risk "APAGA DADO REAL da midia. Nao e so registro."
    orb_plan_risk "Se a politica de retencao estiver mal configurada, voce apaga o unico nivel 0."
    orb_plan_risk "Confira a politica (opcao 13) ANTES de rodar isso."
    orb_plan_risk "Em Data Guard, considere se o standby ainda precisa daqueles archives."
    orb_plan_confirm "APAGAR-OBSOLETOS" || return 1
    orb_exec_rman "delete_obsolete" "$_f"
    return $?
}

orb_cat_catalog_start_with()
{
    orb_title "CATALOG START WITH"
    orb_item "Importa para o repositorio backup pieces que estao em disco mas"
    orb_item "o RMAN nao conhece - tipico depois de copiar backup de outro host,"
    orb_item "ou de reimportacao feita pelo time de backup."
    orb_ask "Diretorio (o RMAN varre recursivamente)" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _d="$ORB_ANSWER"
    _f="$ORB_RUNDIR/cmd_catalogsw.rman"
    { echo "CATALOG START WITH '$_d' NOPROMPT;" ; echo "EXIT;" ; } > "$_f"
    orb_plan_begin "CATALOG START WITH '$_d'"
    orb_plan_cmd_file "Catalogar" "$_f"
    orb_plan_risk "Adiciona ao repositorio tudo que parecer backup piece naquele caminho."
    orb_plan_risk "Cuidado com diretorio que contenha backup de OUTRO banco."
    orb_plan_confirm "CATALOGAR" || return 1
    orb_exec_rman "catalog_start_with" "$_f"
    return $?
}

# ---------------------------------------------------------------------------
orb_cat_retention()
{
    orb_title "POLITICA DE RETENCAO"
    orb_cat_simple "SHOW RETENTION POLICY;" "SHOW_RETENTION" ""
    orb_log_raw ""
    orb_item "REDUNDANCY n   mantem n copias de cada arquivo"
    orb_item "RECOVERY WINDOW OF n DAYS  mantem o necessario para voltar n dias"
    orb_item "NONE           nada e considerado obsoleto (nada e apagado sozinho)"
    orb_log_raw ""
    orb_ask "Nova politica [REDUNDANCY|WINDOW|NONE|cancelar]" "cancelar"
    _p=`orb_upper "$ORB_ANSWER"`
    case "$_p" in
        REDUNDANCY) orb_ask "Quantas copias" "2" ; _new="REDUNDANCY $ORB_ANSWER" ;;
        WINDOW)     orb_ask "Janela em dias" "31" ; _new="RECOVERY WINDOW OF $ORB_ANSWER DAYS" ;;
        NONE)       _new="NONE" ;;
        *)          return 0 ;;
    esac
    _f="$ORB_RUNDIR/cmd_retention.rman"
    { echo "CONFIGURE RETENTION POLICY TO $_new;" ; echo "SHOW RETENTION POLICY;" ; echo "EXIT;" ; } > "$_f"
    orb_plan_begin "CONFIGURE RETENTION POLICY TO $_new"
    orb_plan_cmd_file "Retencao" "$_f"
    orb_plan_risk "Define o que DELETE OBSOLETE vai apagar da midia."
    orb_plan_risk "Politica curta demais apaga o backup base que voce precisaria."
    orb_plan_risk "A retencao do RMAN e independente da retencao do media manager - as duas precisam conversar."
    orb_plan_confirm "CONFIGURAR" || return 1
    orb_exec_rman "retention" "$_f"
    return $?
}

orb_cat_autobackup()
{
    orb_title "AUTOBACKUP DE CONTROLFILE"
    orb_cat_simple "SHOW CONTROLFILE AUTOBACKUP;
SHOW CONTROLFILE AUTOBACKUP FORMAT;" "SHOW_AUTOBACKUP" ""
    orb_item "Sem autobackup, um restore do zero fica muito mais dificil:"
    orb_item "e do autobackup que sai o controlfile quando nao ha mais nada."
    orb_ask "Ligar autobackup? [S/N/cancelar]" "S"
    case "`orb_upper $ORB_ANSWER`" in
        S) _c="CONFIGURE CONTROLFILE AUTOBACKUP ON;" ;;
        N) _c="CONFIGURE CONTROLFILE AUTOBACKUP OFF;" ;;
        *) return 0 ;;
    esac
    orb_ask "FORMAT (vazio = manter atual)" ""
    _fmt=""
    [ -n "$ORB_ANSWER" ] && _fmt="CONFIGURE CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE $ORB_MEDIA_TYPE TO '$ORB_ANSWER';"
    _f="$ORB_RUNDIR/cmd_autobk.rman"
    { echo "$_c" ; [ -n "$_fmt" ] && echo "$_fmt" ; echo "SHOW CONTROLFILE AUTOBACKUP;" ; echo "EXIT;" ; } > "$_f"
    orb_plan_begin "CONFIGURE CONTROLFILE AUTOBACKUP"
    orb_plan_cmd_file "Autobackup" "$_f"
    orb_plan_confirm "CONFIGURAR" || return 1
    orb_exec_rman "autobackup" "$_f"
    return $?
}

orb_cat_parallelism()
{
    orb_title "PARALELISMO E CANAIS PERSISTENTES"
    orb_cat_simple "SHOW DEVICE TYPE;
SHOW CHANNEL;" "SHOW_CHANNEL" ""
    orb_log_raw ""
    orb_item "Bloco que o perfil de media atual geraria:"
    orb_channels_configure | while IFS= read _l ; do orb_item "$_l" ; done
    orb_log_raw ""
    orb_ask "Aplicar essa configuracao de forma persistente? [S/N]" "N"
    [ "`orb_upper $ORB_ANSWER`" = "S" ] || return 0
    _f="$ORB_RUNDIR/cmd_configch.rman"
    { orb_channels_configure ; echo "SHOW ALL;" ; echo "EXIT;" ; } > "$_f"
    orb_plan_begin "CONFIGURE CHANNEL / PARALLELISM"
    orb_plan_cmd_file "Configuracao persistente" "$_f"
    orb_plan_risk "Passa a valer para TODA sessao RMAN deste banco, inclusive jobs existentes."
    orb_plan_confirm "CONFIGURAR" || return 1
    orb_exec_rman "configure_channel" "$_f"
    return $?
}

orb_cat_bct()
{
    orb_title "BLOCK CHANGE TRACKING"
    _st=`orb_sql_value "(select status from v\\$block_change_tracking)"`
    _fl=`orb_sql_value "(select nvl(filename,'-') from v\\$block_change_tracking)"`
    orb_field "Status"   "`_orb_or_na "$_st"`"
    orb_field "Arquivo"  "`_orb_or_na "$_fl"`"
    orb_item "Com BCT, incremental nivel 1 le so os blocos alterados em vez de"
    orb_item "varrer o banco inteiro. Em banco grande a diferenca e de horas."
    orb_log_raw ""
    if [ "$_st" = "ENABLED" ]; then
        orb_status_line ok "Ja habilitado."
        orb_ask "Desabilitar? [S/N]" "N"
        [ "`orb_upper $ORB_ANSWER`" = "S" ] || return 0
        _sql="alter database disable block change tracking;"
        _t="DESABILITAR"
    else
        orb_ask "Habilitar? [S/N]" "S"
        [ "`orb_upper $ORB_ANSWER`" = "S" ] || return 0
        orb_ask "Destino (+DG ou caminho; vazio = OMF)" "${ORB_D_DBCREATE}"
        if [ -n "$ORB_ANSWER" ]; then
            _sql="alter database enable block change tracking using file '$ORB_ANSWER' reuse;"
        else
            _sql="alter database enable block change tracking;"
        fi
        _t="HABILITAR"
    fi
    _s="$ORB_RUNDIR/bct.sql"
    printf "%s\nexit\n" "$_sql" > "$_s"
    orb_plan_begin "BLOCK CHANGE TRACKING - $_t"
    orb_plan_cmd_file "BCT" "$_s"
    orb_plan_risk "Apos habilitar, o PRIMEIRO incremental ainda varre tudo - o ganho vem do segundo."
    orb_plan_risk "O arquivo de BCT precisa ser recriado apos restore do banco."
    orb_plan_confirm "APLICAR" || return 1
    orb_exec_sql "bct" "$_s"
    return $?
}
