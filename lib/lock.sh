#!/usr/bin/sh
###############################################################################
# lib/lock.sh - exclusao mutua por database
#
# Duas sessoes rodando RESTORE no mesmo banco ao mesmo tempo e um cenario que
# ninguem planeja e que acontece: dois DBAs no incidente, ou um nohup esquecido
# de uma tentativa anterior.
#
# mkdir e a primitiva atomica portavel. Nao depende de flock (inexistente em
# AIX/Solaris) nem de noclobber.
###############################################################################

ORB_LOCK_DIR=""
ORB_LOCK_HELD="N"

# ---------------------------------------------------------------------------
# orb_lock_acquire <chave>
# ---------------------------------------------------------------------------
orb_lock_acquire()
{
    _key="$1"
    [ -n "$_key" ] || _key="${ORACLE_SID:-orb}"
    ORB_LOCK_DIR="${ORB_LOCK_BASE:-/tmp}/.orb_lock_${_key}"

    if mkdir "$ORB_LOCK_DIR" 2>/dev/null; then
        {
            echo "pid=$$"
            echo "user=`id -un 2>/dev/null`"
            echo "host=`hostname 2>/dev/null`"
            echo "sid=${ORACLE_SID:-}"
            echo "since=`orb_now`"
            echo "log=${ORB_LOG:-}"
        } > "$ORB_LOCK_DIR/info" 2>/dev/null
        ORB_LOCK_HELD="Y"
        return 0
    fi

    # Ja existe. Pode ser lock legitimo ou orfao de execucao que morreu.
    _pid="" ; _usr="" ; _since="" ; _hst=""
    if [ -f "$ORB_LOCK_DIR/info" ]; then
        _pid=`grep '^pid='   "$ORB_LOCK_DIR/info" 2>/dev/null | cut -d= -f2`
        _usr=`grep '^user='  "$ORB_LOCK_DIR/info" 2>/dev/null | cut -d= -f2`
        _hst=`grep '^host='  "$ORB_LOCK_DIR/info" 2>/dev/null | cut -d= -f2`
        _since=`grep '^since=' "$ORB_LOCK_DIR/info" 2>/dev/null | cut -d= -f2-`
    fi

    _alive="?"
    _me=`hostname 2>/dev/null`
    if [ -n "$_pid" ] && [ "$_hst" = "$_me" ]; then
        if ps -p "$_pid" >/dev/null 2>&1; then _alive="Y" ; else _alive="N" ; fi
    fi

    orb_err "Ja existe operacao ORB em andamento para '$_key'."
    orb_item "lock  : $ORB_LOCK_DIR"
    orb_item "pid   : ${_pid:-?}   host: ${_hst:-?}   usuario: ${_usr:-?}"
    orb_item "desde : ${_since:-?}"

    case "$_alive" in
        Y)
            orb_item "O processo $_pid esta VIVO neste host. Nao remova o lock."
            return 1
            ;;
        N)
            orb_warn "O processo $_pid nao existe mais - lock provavelmente orfao."
            orb_item "Confirme que nenhum RMAN daquela execucao continua rodando:"
            orb_item "  ps -ef | grep rman | grep -v grep"
            if [ "${ORB_ASSUME_YES:-N}" = "Y" ]; then
                orb_err "Modo --yes nao remove lock automaticamente. Remova a mao se for orfao."
                return 1
            fi
            orb_confirm "Remover o lock orfao de '$_key'?" "REMOVER-LOCK" || return 1
            rm -rf "$ORB_LOCK_DIR" 2>/dev/null
            orb_lock_acquire "$_key"
            return $?
            ;;
        *)
            orb_item "Lock de outro host - nao consigo verificar se esta vivo daqui."
            return 1
            ;;
    esac
}

orb_lock_release()
{
    [ "$ORB_LOCK_HELD" = "Y" ] || return 0
    [ -n "$ORB_LOCK_DIR" ] || return 0
    rm -rf "$ORB_LOCK_DIR" 2>/dev/null
    ORB_LOCK_HELD="N"
    return 0
}

# ---------------------------------------------------------------------------
# orb_lock_trap  -  garante liberacao em saida normal ou sinal
# ---------------------------------------------------------------------------
orb_lock_trap()
{
    trap 'orb_lock_release' 0
    trap 'orb_warn "Interrompido (SIGINT)."  ; orb_lock_release ; exit 130' 2
    trap 'orb_warn "Terminado (SIGTERM)."    ; orb_lock_release ; exit 143' 15
    trap 'orb_warn "Hangup (SIGHUP) - a operacao continua se estiver em nohup."' 1
    return 0
}
