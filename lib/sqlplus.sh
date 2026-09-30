#!/usr/bin/sh
###############################################################################
# lib/sqlplus.sh - wrapper de SQL*Plus
#
# Todo acesso a dicionario passa por aqui. Duas formas:
#
#   orb_sql_value "<select>"   -> uma unica string, para discovery
#   orb_sql_run <nome> <file>  -> executa script, saida vai para o log
#
# orb_sql_value usa marcador ORBV| para nao depender de formatacao do sqlplus.
###############################################################################

# ---------------------------------------------------------------------------
# orb_sql_value "<select sem ponto-e-virgula>"
#
# Devolve a primeira coluna da primeira linha. Vazio + rc 1 se nao obtiver.
# NUNCA inventa valor: se o banco nao responder, o chamador sabe.
# ---------------------------------------------------------------------------
orb_sql_value()
{
    [ -n "$ORACLE_HOME" ] || return 1
    [ -x "$ORACLE_HOME/bin/sqlplus" ] || return 1

    _f="${ORB_RUNDIR:-/tmp}/.orb_sqlv.$$.sql"
    cat > "$_f" <<EOSQL
set heading off feedback off verify off termout on pagesize 0 linesize 4000 trimspool on
whenever sqlerror exit 1
select 'ORBV|'||($1) from dual;
exit
EOSQL
    _out=`"$ORACLE_HOME/bin/sqlplus" -s -L "/ as sysdba" @"$_f" 2>/dev/null | grep '^ORBV|' | head -1 | cut -d'|' -f2-`
    rm -f "$_f" 2>/dev/null
    _out=`orb_trim "$_out"`
    [ -z "$_out" ] && return 1
    echo "$_out"
    return 0
}

# ---------------------------------------------------------------------------
# orb_sql_query "<select completo>"  -  varias linhas, marcador ORBR|
# Cada linha ja deve concatenar as colunas com '|'.
# ---------------------------------------------------------------------------
orb_sql_query()
{
    [ -n "$ORACLE_HOME" ] || return 1
    [ -x "$ORACLE_HOME/bin/sqlplus" ] || return 1

    _f="${ORB_RUNDIR:-/tmp}/.orb_sqlq.$$.sql"
    cat > "$_f" <<EOSQL
set heading off feedback off verify off pagesize 0 linesize 4000 trimspool on
whenever sqlerror exit 1
$1
exit
EOSQL
    "$ORACLE_HOME/bin/sqlplus" -s -L "/ as sysdba" @"$_f" 2>/dev/null | grep '^ORBR|' | sed 's/^ORBR|//'
    _rc=$?
    rm -f "$_f" 2>/dev/null
    return $_rc
}

# ---------------------------------------------------------------------------
# orb_sql_run <nome> <arquivo.sql>  -  executa e joga saida no log
# ---------------------------------------------------------------------------
orb_sql_run()
{
    _name="$1" ; _file="$2"
    [ -f "$_file" ] || { orb_err "SQL nao encontrado: $_file" ; return 1 ; }
    _out="${ORB_RUNDIR:-/tmp}/sql_${_name}.log"

    _t0=`orb_epoch`
    "$ORACLE_HOME/bin/sqlplus" -s -L "/ as sysdba" @"$_file" > "$_out" 2>&1
    _rc=$?
    _t1=`orb_epoch`

    cat "$_out"
    orb_log_file "$_out"
    orb_audit "SQL:$_name" "sqlplus @$_file" "$_rc" "`expr $_t1 - $_t0`"

    if grep "^ORA-" "$_out" >/dev/null 2>&1; then
        orb_warn "SQL [$_name] retornou ORA-. Veja $_out"
    fi
    return $_rc
}

# ---------------------------------------------------------------------------
# orb_sql_alive  -  a instancia responde?
# ---------------------------------------------------------------------------
orb_sql_alive()
{
    orb_sql_value "1" >/dev/null 2>&1
}
