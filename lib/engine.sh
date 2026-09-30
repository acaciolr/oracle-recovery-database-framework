#!/usr/bin/sh
###############################################################################
# lib/engine.sh - EXECUTION ENGINE
#
# O ciclo obrigatorio de toda operacao que altera estado:
#
#     DISCOVER -> VALIDATE -> PLAN -> SHOW COMMANDS -> SHOW RISKS
#              -> CONFIRM -> EXECUTE -> POST-CHECK -> REPORT
#
# Nunca DISCOVER -> EXECUTE.
#
# Um modulo de operacao NAO chama rman/sqlplus diretamente para alterar estado.
# Ele descreve o plano e o engine executa. Isso e o que garante que o DBA veja
# o comando real antes de autorizar, e que o dry-run funcione de graca.
###############################################################################

ORB_MODE="${ORB_MODE:-EXECUTE}"     # EXECUTE | DRYRUN | GENERATE
ORB_RUNDIR="${ORB_RUNDIR:-/tmp}"
ORB_SCRIPTDIR="${ORB_SCRIPTDIR:-}"

_ORB_PLAN_TITLE=""
_ORB_PLAN_FIELDS=""
_ORB_PLAN_CMDS=""
_ORB_PLAN_RISKS=""
_ORB_PLAN_N=0

ORB_STEP_OK=0
ORB_STEP_FAIL=0

# ---------------------------------------------------------------------------
# PLAN
# ---------------------------------------------------------------------------
orb_plan_begin()
{
    _ORB_PLAN_TITLE="$*"
    _ORB_PLAN_FIELDS="$ORB_RUNDIR/plan.fields"
    _ORB_PLAN_CMDS="$ORB_RUNDIR/plan.cmds"
    _ORB_PLAN_RISKS="$ORB_RUNDIR/plan.risks"
    : > "$_ORB_PLAN_FIELDS"
    : > "$_ORB_PLAN_CMDS"
    : > "$_ORB_PLAN_RISKS"
    _ORB_PLAN_N=0
    return 0
}

orb_plan_field()
{
    _l="$1" ; shift
    printf "%s|%s\n" "$_l" "$*" >> "$_ORB_PLAN_FIELDS"
}

# orb_plan_cmd <descricao> <comando ou bloco multilinha>
orb_plan_cmd()
{
    _ORB_PLAN_N=`expr $_ORB_PLAN_N + 1`
    {
        echo "### $_ORB_PLAN_N. $1"
        shift
        printf "%s\n" "$*"
        echo ""
    } >> "$_ORB_PLAN_CMDS"
}

# orb_plan_cmd_file <descricao> <arquivo>
orb_plan_cmd_file()
{
    _ORB_PLAN_N=`expr $_ORB_PLAN_N + 1`
    {
        echo "### $_ORB_PLAN_N. $1"
        cat "$2"
        echo ""
    } >> "$_ORB_PLAN_CMDS"
}

orb_plan_risk()
{
    echo "  - $*" >> "$_ORB_PLAN_RISKS"
}

# ---------------------------------------------------------------------------
# orb_plan_show
# ---------------------------------------------------------------------------
orb_plan_show()
{
    orb_title "PLANO DE EXECUCAO"
    orb_log_raw " Operacao : $_ORB_PLAN_TITLE"
    orb_log_raw " Modo     : $ORB_MODE"
    orb_log_raw ""

    if [ -s "$_ORB_PLAN_FIELDS" ]; then
        orb_section "CONTEXTO"
        while IFS='|' read _l _v
        do
            orb_field "$_l" "$_v"
        done < "$_ORB_PLAN_FIELDS"
    fi

    orb_section "COMANDOS QUE SERAO EXECUTADOS"
    if [ -s "$_ORB_PLAN_CMDS" ]; then
        while IFS= read _l ; do orb_log_raw "$_l" ; done < "$_ORB_PLAN_CMDS"
    else
        orb_log_raw "  (nenhum)"
    fi

    if [ -s "$_ORB_PLAN_RISKS" ]; then
        orb_section "RISCOS"
        while IFS= read _l ; do orb_log_raw "$_l" ; done < "$_ORB_PLAN_RISKS"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# orb_plan_confirm [palavra]
#
# Retorna 0 = autorizado a executar
#         1 = nao autorizado (cancelado, dry-run ou modo GENERATE)
# ---------------------------------------------------------------------------
orb_plan_confirm()
{
    _word="${1:-EXECUTAR}"
    orb_plan_show

    case "$ORB_MODE" in
        DRYRUN)
            orb_section "DRY RUN"
            orb_log "Modo DRY RUN: nada foi executado."
            return 1
            ;;
        GENERATE)
            orb_engine_generate
            return 1
            ;;
    esac

    orb_log_raw ""
    orb_rule "!"
    orb_log_raw " ATENCAO: a operacao acima altera o estado do banco."
    orb_rule "!"
    orb_confirm "Autoriza a execucao de: $_ORB_PLAN_TITLE ?" "$_word"
    return $?
}

# ---------------------------------------------------------------------------
# orb_engine_generate  -  grava o plano como script, sem executar
# ---------------------------------------------------------------------------
orb_engine_generate()
{
    [ -n "$ORB_SCRIPTDIR" ] || ORB_SCRIPTDIR="$ORB_RUNDIR"
    mkdir -p "$ORB_SCRIPTDIR" 2>/dev/null
    _ts=`orb_timestamp`
    _base=`echo "$_ORB_PLAN_TITLE" | tr ' /' '__' | tr -d ':' | orb_lower`
    _f="$ORB_SCRIPTDIR/${_base}_${_ts}.txt"
    {
        echo "# ORACLE RECOVERY BRABO - script gerado"
        echo "# operacao : $_ORB_PLAN_TITLE"
        echo "# gerado em: `orb_now`"
        echo "# host     : `hostname 2>/dev/null`  usuario: `id -un 2>/dev/null`"
        echo "# ORACLE_SID=$ORACLE_SID  ORACLE_HOME=$ORACLE_HOME"
        echo "#"
        echo "# CONTEXTO"
        [ -s "$_ORB_PLAN_FIELDS" ] && sed 's/^/#   /' "$_ORB_PLAN_FIELDS"
        echo "#"
        echo "# RISCOS"
        [ -s "$_ORB_PLAN_RISKS" ] && sed 's/^/# /' "$_ORB_PLAN_RISKS"
        echo ""
        cat "$_ORB_PLAN_CMDS"
    } > "$_f"
    orb_section "SCRIPT GERADO"
    orb_ok "$_f"
    orb_log "Nada foi executado (modo GENERATE)."
    return 0
}

# ---------------------------------------------------------------------------
# EXECUTE
# ---------------------------------------------------------------------------

# orb_exec_os <descricao> <comando...>
orb_exec_os()
{
    _d="$1" ; shift
    if [ "$ORB_MODE" != "EXECUTE" ]; then
        orb_log "[$ORB_MODE] nao executado: $*"
        return 0
    fi
    orb_log "EXECUTANDO ($_d): $*"
    _t0=`orb_epoch`
    "$@" 2>&1 | while IFS= read _l ; do orb_log_raw "  $_l" ; done
    _rc=$?
    _t1=`orb_epoch`
    orb_audit "OS:$_d" "$*" "$_rc" "`expr $_t1 - $_t0`"
    if [ $_rc -ne 0 ]; then
        orb_err "$_d falhou (rc=$_rc)"
        ORB_STEP_FAIL=`expr $ORB_STEP_FAIL + 1`
        return 1
    fi
    ORB_STEP_OK=`expr $ORB_STEP_OK + 1`
    return 0
}

# orb_exec_rman <passo> <cmdfile> [tolerado]
orb_exec_rman()
{
    if [ "$ORB_MODE" != "EXECUTE" ]; then
        orb_log "[$ORB_MODE] RMAN [$1] nao executado."
        return 0
    fi
    orb_rman_run "$1" "$2" "$3"
    _rc=$?
    if [ $_rc -ne 0 ]; then
        ORB_STEP_FAIL=`expr $ORB_STEP_FAIL + 1`
    else
        ORB_STEP_OK=`expr $ORB_STEP_OK + 1`
    fi
    return $_rc
}

# orb_exec_sql <nome> <arquivo.sql>
orb_exec_sql()
{
    if [ "$ORB_MODE" != "EXECUTE" ]; then
        orb_log "[$ORB_MODE] SQL [$1] nao executado."
        return 0
    fi
    orb_sql_run "$1" "$2"
    _rc=$?
    if [ $_rc -ne 0 ]; then
        ORB_STEP_FAIL=`expr $ORB_STEP_FAIL + 1`
    else
        ORB_STEP_OK=`expr $ORB_STEP_OK + 1`
    fi
    return $_rc
}

# ---------------------------------------------------------------------------
# POST-CHECK padrao apos restore/recover
# ---------------------------------------------------------------------------
orb_postcheck_database()
{
    [ "$ORB_MODE" = "EXECUTE" ] || return 0
    orb_section "POST-CHECK"

    _st=`orb_sql_value "(select status from v\\$instance)"`
    orb_field "Instancia"  "`_orb_or_na "$_st"`"

    _rl=`orb_sql_value "(select database_role from v\\$database)"`
    _om=`orb_sql_value "(select open_mode from v\\$database)"`
    orb_field "Role"       "`_orb_or_na "$_rl"`"
    orb_field "Open mode"  "`_orb_or_na "$_om"`"

    _fz=`orb_sql_value "(select to_char(count(*)) from v\\$datafile_header where fuzzy='YES')"`
    orb_field "Datafiles fuzzy" "`_orb_or_na "$_fz"`"
    if [ -n "$_fz" ] && [ "$_fz" != "0" ]; then
        orb_warn "Ha $_fz datafiles com fuzziness pendente - recovery ainda incompleto."
    fi

    _nr=`orb_sql_value "(select to_char(count(*)) from v\\$recover_file where error is not null)"`
    if [ -n "$_nr" ] && [ "$_nr" != "0" ]; then
        orb_warn "$_nr datafiles com erro em v\$recover_file."
        orb_sql_query "select 'ORBR|'||file#||'|'||error from v\$recover_file where error is not null;" \
            | while IFS='|' read _f _e ; do orb_log_raw "    file $_f : $_e" ; done
    fi
    return 0
}

# ---------------------------------------------------------------------------
# REPORT final
# ---------------------------------------------------------------------------
orb_report()
{
    orb_title "RELATORIO FINAL"
    orb_field "Operacao"     "$_ORB_PLAN_TITLE"
    orb_field "Modo"         "$ORB_MODE"
    orb_field "Passos OK"    "$ORB_STEP_OK"
    orb_field "Passos FALHA" "$ORB_STEP_FAIL"
    orb_field "Diretorio"    "$ORB_RUNDIR"
    orb_log_paths | while IFS= read _l ; do orb_item "$_l" ; done

    if [ "$ORB_STEP_FAIL" -gt 0 ]; then
        orb_log_raw ""
        orb_err "A operacao teve falhas. NAO considere concluida."
        return 1
    fi
    orb_log_raw ""
    orb_ok "Operacao concluida sem falhas registradas."
    return 0
}
