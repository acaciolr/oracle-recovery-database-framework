#!/usr/bin/sh
###############################################################################
# lib/rman.sh - wrapper de RMAN
#
# Duas regras que este modulo existe para impor:
#
# 1. O return code do rman NAO e confiavel sozinho. A pilha RMAN-00571 na
#    saida e o sinal de falha. Avaliamos os dois.
#
# 2. Codigos tolerados sao declarados POR PASSO, nunca globalmente.
#    RMAN-06054 e fim normal de recover de standby e falha em qualquer
#    outro lugar.
###############################################################################

ORB_CATALOG_CONNECT="${ORB_CATALOG_CONNECT:-}"
ORB_RMAN_LAST_LOG=""

# ---------------------------------------------------------------------------
# orb_rman_conn_args  -  monta os argumentos de conexao
#
# Sem catalogo o RMAN so enxerga o que esta no controlfile, limitado por
# control_file_record_keep_time. Foi exatamente isso que produziu o
# ORA-01180 no ECP: incrementais recentes sem o nivel 0 pai.
# ---------------------------------------------------------------------------
orb_rman_conn_args()
{
    if [ -n "$ORB_CATALOG_CONNECT" ]; then
        echo "target / catalog $ORB_CATALOG_CONNECT"
    else
        echo "target /"
    fi
}

orb_rman_has_catalog()
{
    [ -n "$ORB_CATALOG_CONNECT" ]
}

# ---------------------------------------------------------------------------
# orb_rman_run <passo> <cmdfile> [codigo_tolerado]
# ---------------------------------------------------------------------------
orb_rman_run()
{
    _step="$1" ; _cmdf="$2" ; _tol="$3"
    [ -f "$_cmdf" ] || { orb_err "cmdfile nao encontrado: $_cmdf" ; return 1 ; }
    [ -x "$ORACLE_HOME/bin/rman" ] || { orb_err "rman nao encontrado" ; return 1 ; }

    _out="${ORB_RUNDIR:-/tmp}/rman_${_step}.log"
    ORB_RMAN_LAST_LOG="$_out"

    orb_section "RMAN [$_step]"
    orb_log "catalogo: `orb_rman_has_catalog && echo SIM || echo NAO`"
    orb_log "saida   : $_out"
    orb_log_raw "--- comandos enviados ---"
    cat "$_cmdf" | while IFS= read _l ; do orb_log_raw "$_l" ; done
    orb_log_raw "-------------------------"

    _t0=`orb_epoch`
    : > "$_out"
    tail -f "$_out" &
    _tpid=$!

    if orb_rman_has_catalog; then
        "$ORACLE_HOME/bin/rman" target / catalog "$ORB_CATALOG_CONNECT" \
            cmdfile="$_cmdf" log="$_out" >/dev/null 2>&1
    else
        "$ORACLE_HOME/bin/rman" target / \
            cmdfile="$_cmdf" log="$_out" >/dev/null 2>&1
    fi
    _rc=$?

    sleep 2
    kill $_tpid 2>/dev/null
    wait $_tpid 2>/dev/null

    _t1=`orb_epoch`
    _dur=`expr $_t1 - $_t0`
    orb_log_file "$_out"
    orb_log "duracao [$_step]: `orb_elapsed $_t0 $_t1`"
    orb_audit "RMAN:$_step" "rman cmdfile=$_cmdf" "$_rc" "$_dur"

    if grep "RMAN-00571" "$_out" >/dev/null 2>&1; then
        if [ -n "$_tol" ] && grep "$_tol" "$_out" >/dev/null 2>&1; then
            orb_warn "RMAN [$_step] terminou com $_tol - esperado NESTE passo."
            return 0
        fi
        orb_err "RMAN [$_step] FALHOU (rc=$_rc)"
        orb_rman_errors "$_out"
        orb_diag_explain "$_out"
        return 1
    fi

    if [ $_rc -ne 0 ]; then
        if [ -n "$_tol" ] && grep "$_tol" "$_out" >/dev/null 2>&1; then
            orb_warn "RMAN [$_step] rc=$_rc com $_tol - esperado."
            return 0
        fi
        orb_err "RMAN [$_step] rc=$_rc"
        orb_rman_errors "$_out"
        orb_diag_explain "$_out"
        return 1
    fi

    orb_ok "RMAN [$_step] concluido."
    return 0
}

# ---------------------------------------------------------------------------
# orb_rman_errors <log>  -  extrai a lista de codigos, sem alternacao BRE
# ---------------------------------------------------------------------------
orb_rman_errors()
{
    _f="$1"
    [ -f "$_f" ] || return 1
    orb_log_raw ""
    orb_log_raw "  Codigos encontrados:"
    grep -E "^(RMAN|ORA|PRCD|PRCR|PRCN|PRKH|CRS)-[0-9]" "$_f" 2>/dev/null \
        | sort -u | while IFS= read _l
    do
        orb_log_raw "    $_l"
    done
    return 0
}

# ---------------------------------------------------------------------------
# orb_rman_capture <nome> <comandos...>  -  roda RMAN so para LER
#
# Usado pelo discovery e pelos modulos de informacao. Nao passa pelo engine
# porque nao altera estado.
# ---------------------------------------------------------------------------
orb_rman_capture()
{
    _name="$1" ; shift
    _cmdf="${ORB_RUNDIR:-/tmp}/.orb_rc_${_name}.rman"
    _out="${ORB_RUNDIR:-/tmp}/rman_${_name}.log"
    printf "%s\n" "$@" > "$_cmdf"

    if orb_rman_has_catalog; then
        "$ORACLE_HOME/bin/rman" target / catalog "$ORB_CATALOG_CONNECT" \
            cmdfile="$_cmdf" log="$_out" >/dev/null 2>&1
    else
        "$ORACLE_HOME/bin/rman" target / cmdfile="$_cmdf" log="$_out" >/dev/null 2>&1
    fi
    _rc=$?
    ORB_RMAN_LAST_LOG="$_out"
    echo "$_out"
    return $_rc
}

# ---------------------------------------------------------------------------
# orb_rman_build <arquivo> <corpo...>  -  monta cmdfile com bloco RUN e canais
# ---------------------------------------------------------------------------
orb_rman_build()
{
    _file="$1" ; shift
    {
        echo "RUN {"
        orb_channels_block
        for _c in "$@"
        do
            echo "$_c"
        done
        echo "}"
        echo "EXIT;"
    } > "$_file"
    return 0
}
