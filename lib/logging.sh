#!/usr/bin/sh
###############################################################################
# lib/logging.sh - log e trilha de auditoria
#
# Dois destinos distintos, de proposito:
#
#   ORB_LOG    log operacional, legivel, e o que o DBA acompanha com tail -f
#   ORB_AUDIT  trilha em pipe-delimited, uma linha por comando executado,
#              feita para ser lida por script depois (quem, quando, o que,
#              retorno, duracao)
#
# Nenhuma senha entra em nenhum dos dois. orb_log_redact() e obrigatoria em
# qualquer string que possa carregar credencial.
###############################################################################

ORB_LOG="${ORB_LOG:-}"
ORB_AUDIT="${ORB_AUDIT:-}"

# ---------------------------------------------------------------------------
# orb_log_init <logdir> <operacao>
# ---------------------------------------------------------------------------
orb_log_init()
{
    _dir="$1" ; _op="$2"
    mkdir -p "$_dir" 2>/dev/null || {
        echo "FATAL: nao consegui criar $_dir" >&2
        return 1
    }
    _ts=`orb_timestamp`
    ORB_LOG="$_dir/${_op}_${_ts}.log"
    ORB_AUDIT="$_dir/${_op}_${_ts}.audit"
    : > "$ORB_LOG"
    : > "$ORB_AUDIT"
    echo "# timestamp|usuario|host|oracle_sid|acao|comando|rc|duracao_s" >> "$ORB_AUDIT"
    return 0
}

# ---------------------------------------------------------------------------
# orb_log_redact <string>
#
# Remove credenciais de qualquer string antes dela tocar disco ou tela.
# Cobre os formatos que aparecem em linha de comando RMAN e sqlplus:
#   user/senha@tns        ->  user/***@tns
#   catalog user/senha    ->  catalog user/***
#   sys/senha as sysdba   ->  sys/*** as sysdba
# ---------------------------------------------------------------------------
orb_log_redact()
{
    echo "$*" | sed \
        -e 's|\([A-Za-z0-9_]*\)/"[^"]*"@|\1/***@|g' \
        -e 's|\([A-Za-z0-9_]*\)/[^ @"]*@|\1/***@|g' \
        -e 's|\(catalog  *[A-Za-z0-9_]*\)/[^ ]*|\1/***|g' \
        -e 's|\(PASSWORD *FILE.*\)|\1|g'
}

# ---------------------------------------------------------------------------
# saida operacional
# ---------------------------------------------------------------------------
orb_log()
{
    _m=`orb_log_redact "$*"`
    _l="[`orb_now`] $_m"
    echo "$_l"
    [ -n "$ORB_LOG" ] && echo "$_l" >> "$ORB_LOG"
    return 0
}

orb_ok()   { orb_log "[  OK  ] $*" ; }
orb_warn() { orb_log "[ AVISO] $*" ; }
orb_err()  { orb_log "[ ERRO ] $*" ; }

orb_log_raw()
{
    echo "$*"
    [ -n "$ORB_LOG" ] && echo "$*" >> "$ORB_LOG"
    return 0
}

# ---------------------------------------------------------------------------
# orb_log_file <arquivo>  -  despeja um arquivo no log operacional
# ---------------------------------------------------------------------------
orb_log_file()
{
    [ -f "$1" ] || return 1
    [ -n "$ORB_LOG" ] && cat "$1" >> "$ORB_LOG"
    return 0
}

# ---------------------------------------------------------------------------
# orb_audit <acao> <comando> <rc> <duracao_s>
# ---------------------------------------------------------------------------
orb_audit()
{
    [ -n "$ORB_AUDIT" ] || return 0
    _cmd=`orb_log_redact "$2"`
    _cmd=`echo "$_cmd" | tr '|' ';' | tr '\n' ' '`
    printf "%s|%s|%s|%s|%s|%s|%s|%s\n" \
        "`orb_now`" \
        "`id -un 2>/dev/null`" \
        "`hostname 2>/dev/null`" \
        "${ORACLE_SID:-}" \
        "$1" \
        "$_cmd" \
        "$3" \
        "$4" >> "$ORB_AUDIT"
    return 0
}

# ---------------------------------------------------------------------------
# orb_log_paths  -  para o relatorio final
# ---------------------------------------------------------------------------
orb_log_paths()
{
    echo "Log operacional : ${ORB_LOG:-<nao inicializado>}"
    echo "Trilha auditoria: ${ORB_AUDIT:-<nao inicializado>}"
}
