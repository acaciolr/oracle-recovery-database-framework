#!/usr/bin/sh
###############################################################################
# lib/validate.sh - PRECHECK
#
# Toda operacao chama orb_require_* antes de montar o plano. A regra que este
# modulo existe para impor:
#
#   estado indeterminado NAO e "pode seguir".
#
# No incidente que originou este framework, o script anterior avaliava o
# estado do banco por grep na saida do srvctl. Com o CRS fora, o srvctl
# devolvia erro, o grep nao casava, e o script concluia "banco parado" e
# seguia para um chown recursivo. Aqui, indeterminado aborta.
###############################################################################

orb_v_fail() { orb_err "PRECHECK: $*" ; return 1 ; }

# ---------------------------------------------------------------------------
orb_require_oracle_home()
{
    [ -n "$ORACLE_HOME" ] || { orb_v_fail "ORACLE_HOME nao definido." ; return 1 ; }
    [ -x "$ORACLE_HOME/bin/rman" ]    || { orb_v_fail "rman nao encontrado em $ORACLE_HOME/bin" ; return 1 ; }
    [ -x "$ORACLE_HOME/bin/sqlplus" ] || { orb_v_fail "sqlplus nao encontrado em $ORACLE_HOME/bin" ; return 1 ; }
    return 0
}

orb_require_sid()
{
    [ -n "$ORACLE_SID" ] || { orb_v_fail "ORACLE_SID nao definido." ; return 1 ; }
    return 0
}

# ---------------------------------------------------------------------------
# orb_instance_state  ->  DOWN | STARTED | MOUNTED | OPEN | UNKNOWN
#
# UNKNOWN nunca e tratado como equivalente a DOWN.
# ---------------------------------------------------------------------------
orb_instance_state()
{
    if ! orb_sql_alive; then
        # Nao responde: pode estar down, ou pode ser problema de ambiente.
        _p=`ps -ef 2>/dev/null | grep "ora_pmon_${ORACLE_SID}" | grep -v grep | wc -l`
        _p=`orb_trim "$_p"`
        if [ "$_p" = "0" ]; then
            echo "DOWN"
        else
            echo "UNKNOWN"
        fi
        return 0
    fi
    _s=`orb_sql_value "(select status from v\\$instance)"`
    [ -z "$_s" ] && { echo "UNKNOWN" ; return 0 ; }
    echo "$_s"
    return 0
}

orb_require_state()
{
    _want="$1"
    _got=`orb_instance_state`
    if [ "$_got" = "UNKNOWN" ]; then
        orb_err "PRECHECK: estado da instancia INDETERMINADO."
        orb_item "Ha processo pmon mas o dicionario nao responde."
        orb_item "Isso nao e o mesmo que 'parado'. Resolva antes de prosseguir."
        return 1
    fi
    if [ "$_got" != "$_want" ]; then
        orb_err "PRECHECK: instancia em '$_got', esperado '$_want'."
        return 1
    fi
    orb_ok "Instancia em $_got."
    return 0
}

orb_require_mounted() { orb_require_state "MOUNTED" ; }
orb_require_open()    { orb_require_state "OPEN" ; }
orb_require_nomount() { orb_require_state "STARTED" ; }

orb_require_down()
{
    _got=`orb_instance_state`
    case "$_got" in
        DOWN)    orb_ok "Instancia parada." ; return 0 ;;
        UNKNOWN) orb_err "PRECHECK: estado INDETERMINADO - nao prossigo." ; return 1 ;;
        *)       orb_err "PRECHECK: instancia esta $_got, precisa estar parada." ; return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# orb_require_crs  -  Clusterware integralmente online
# ---------------------------------------------------------------------------
orb_require_crs()
{
    [ "$ORB_D_RAC" = "Y" ] || return 0
    [ -n "$ORB_D_GRIDHOME" ] || { orb_v_fail "RAC detectado mas Grid Home nao encontrado." ; return 1 ; }
    _o="$ORB_RUNDIR/crscheck.out"
    "$ORB_D_GRIDHOME/bin/crsctl" check crs > "$_o" 2>&1
    _rc=$?
    if [ $_rc -ne 0 ]; then
        orb_log_file "$_o"
        orb_v_fail "Clusterware nao responde. Sem CRS nao ha como avaliar o estado real."
        return 1
    fi
    for _c in CRS-4638 CRS-4537 CRS-4529
    do
        grep "$_c" "$_o" >/dev/null 2>&1 || {
            orb_log_file "$_o"
            orb_v_fail "Clusterware incompleto: $_c ausente."
            return 1
        }
    done
    orb_ok "Clusterware integralmente ONLINE."
    return 0
}

# ---------------------------------------------------------------------------
# orb_require_catalog  -  exige catalogo para operacoes que dependem do
# historico completo de backup
# ---------------------------------------------------------------------------
orb_require_catalog()
{
    if orb_rman_has_catalog; then
        orb_ok "Recovery catalog configurado."
        return 0
    fi
    orb_err "PRECHECK: operacao sem recovery catalog."
    orb_item "O controlfile so guarda registros por control_file_record_keep_time"
    orb_item "(atual: ${ORB_D_CFKEEP:-?} dias). Backups mais antigos que isso ficam"
    orb_item "invisiveis, e o RMAN pode tentar CRIAR o datafile em vez de restaurar."
    orb_item "Configure ORB_CATALOG_CONNECT em conf/orb.conf, ou confirme que a"
    orb_item "janela do controlfile cobre o backup que voce precisa."
    return 1
}

# ---------------------------------------------------------------------------
# orb_check_space <destino> <mb_necessarios>
#
# Aceita +DG (ASM) ou caminho de filesystem. Sem informacao confiavel,
# avisa e devolve 2 - o chamador decide, mas fica registrado.
# ---------------------------------------------------------------------------
orb_check_space()
{
    _dest="$1" ; _need="$2"
    case "$_dest" in
        +*)
            _free=`orb_asm_free_mb "$_dest"`
            ;;
        *)
            _free=`orb_free_mb "$_dest"`
            ;;
    esac
    if [ -z "$_free" ]; then
        orb_warn "Nao consegui medir espaco livre em $_dest."
        return 2
    fi
    orb_field "Espaco livre em $_dest" "`orb_human_mb $_free`"
    case "$_need" in ''|*[!0-9]*) return 2 ;; esac
    orb_field "Necessario estimado"    "`orb_human_mb $_need`"
    if [ "$_free" -lt "$_need" ]; then
        orb_err "PRECHECK: espaco insuficiente em $_dest."
        return 1
    fi
    orb_ok "Espaco suficiente em $_dest."
    return 0
}

# ---------------------------------------------------------------------------
# orb_check_version <minimo>  -  ex: orb_check_version 12
# ---------------------------------------------------------------------------
orb_check_version()
{
    _min="$1"
    case "$ORB_D_VERSHORT" in
        ''|*[!0-9]*)
            orb_warn "Versao Oracle nao detectada - nao posso validar suporte ao recurso."
            return 2
            ;;
    esac
    if [ "$ORB_D_VERSHORT" -lt "$_min" ]; then
        orb_err "PRECHECK: recurso exige Oracle ${_min}c ou superior (detectado $ORB_D_VERSION)."
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# orb_precheck_summary  -  bateria padrao, so leitura
# ---------------------------------------------------------------------------
orb_precheck_summary()
{
    orb_section "PRECHECK"
    orb_require_oracle_home || return 1
    orb_require_sid         || return 1
    orb_field "Estado da instancia" "`orb_instance_state`"
    [ "$ORB_D_RAC" = "Y" ] && orb_require_crs
    if orb_rman_has_catalog; then
        orb_ok "Recovery catalog configurado."
    else
        orb_warn "Sem recovery catalog: visibilidade limitada a ${ORB_D_CFKEEP:-?} dias."
    fi
    return 0
}
