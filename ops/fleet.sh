#!/usr/bin/sh
###############################################################################
# ops/fleet.sh - saude do backup de TODOS os bancos do catalogo
#
# O health local so enxerga o banco onde voce esta logado. Um catalogo
# corporativo costuma ter dezenas de bancos registrados - e o que ficou 17
# meses sem nivel 0 nao avisa ninguem.
#
# Este modulo pergunta ao CATALOGO, de uma vez, quando foi o ultimo backup
# base de cada database registrado. E o unico relatorio do framework capaz de
# encontrar o problema ANTES do dia do restore.
#
# Requer conexao ao recovery catalog. Nao precisa de acesso aos bancos.
###############################################################################

ORB_FLEET_RC=0

# ---------------------------------------------------------------------------
# Consulta as views RC_* do catalogo.
#
# rc_backup_datafile guarda incremental_level; nivel 0 e full (nulo) contam
# como backup base. Agrupamos por db_key/name/db_id.
# ---------------------------------------------------------------------------
orb_fleet_sql()
{
    cat <<'EOSQL'
set heading off feedback off verify off pagesize 0 linesize 400 trimspool on
whenever sqlerror exit 1
select 'ORBR|'
       || d.name                                              || '|'
       || d.dbid                                              || '|'
       || nvl(to_char(l0.last_l0,'YYYY-MM-DD'),'NUNCA')       || '|'
       || nvl(to_char(trunc(sysdate - l0.last_l0)),'-1')      || '|'
       || nvl(to_char(ar.last_arch,'YYYY-MM-DD HH24:MI'),'NUNCA') || '|'
       || nvl(to_char(round((sysdate - ar.last_arch)*24)),'-1')   || '|'
       || nvl(to_char(nf.nfiles),'?')
  from ( select distinct db_key, name, dbid from rc_database ) d,
       ( select db_key, max(completion_time) last_l0
           from rc_backup_datafile
          where (incremental_level = 0 or incremental_level is null)
          group by db_key ) l0,
       ( select db_key, max(completion_time) last_arch
           from rc_backup_redolog
          group by db_key ) ar,
       ( select db_key, count(distinct file#) nfiles
           from rc_datafile
          group by db_key ) nf
 where l0.db_key(+) = d.db_key
   and ar.db_key(+) = d.db_key
   and nf.db_key(+) = d.db_key
 order by nvl(l0.last_l0, to_date('1900-01-01','YYYY-MM-DD')) asc;
exit
EOSQL
}

# ---------------------------------------------------------------------------
orb_op_fleet()
{
    orb_title "SAUDE DO BACKUP - TODOS OS BANCOS DO CATALOGO"

    if ! orb_rman_has_catalog; then
        orb_status_line fail "Sem recovery catalog configurado."
        orb_item "Este relatorio consulta as views RC_* do catalogo."
        orb_item "Configure ORB_CATALOG_CONNECT em conf/orb.conf."
        return 2
    fi

    # O connect string tem a forma user/"senha"@tns ; extraimos para o sqlplus.
    _conn="$ORB_CATALOG_CONNECT"
    _f="$ORB_RUNDIR/fleet.sql"
    orb_fleet_sql > "$_f"
    _o="$ORB_RUNDIR/fleet.out"

    orb_log "Consultando o catalogo..."
    eval "\"$ORACLE_HOME/bin/sqlplus\" -s -L $_conn @\"$_f\"" > "$_o" 2>&1
    _rc=$?

    if grep -E "^(ORA|SP2)-" "$_o" >/dev/null 2>&1; then
        orb_status_line fail "Falha ao consultar o catalogo."
        grep -E "^(ORA|SP2)-" "$_o" | sort -u | while IFS= read _l ; do orb_item "$_l" ; done
        orb_item "Confira ORB_CATALOG_CONNECT (aspas simples fora, duplas na senha)."
        return 2
    fi

    _n=`grep -c '^ORBR|' "$_o" 2>/dev/null`
    case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
    if [ "$_n" = "0" ]; then
        orb_status_line warn "Nenhum database retornado pelo catalogo."
        orb_item "Saida bruta em $_o"
        return 1
    fi

    orb_field "Bancos registrados" "$_n"
    orb_field "Limite AVISO"       "${ORB_HEALTH_L0_WARN_DAYS:-8} dias sem nivel 0"
    orb_field "Limite CRITICO"     "${ORB_HEALTH_L0_CRIT_DAYS:-31} dias sem nivel 0"

    orb_section "ORDENADO PELO NIVEL 0 MAIS ANTIGO"
    orb_log_raw ""
    orb_log_raw "  `printf '%-8s %-14s %-12s %7s  %-17s %7s %6s' 'ESTADO' 'DATABASE' 'ULT.NIVEL0' 'DIAS' 'ULT.ARCHIVE' 'HORAS' 'FILES'`"
    _n=`expr $ORB_W - 4`
    _f=`_orb_repeat "$_BX_H" $_n`
    orb_log_raw "  $_f"

    _crit=0 ; _warn=0 ; _ok=0
    _critlist="$ORB_RUNDIR/fleet_crit.txt"
    : > "$_critlist"

    grep '^ORBR|' "$_o" | sed 's/^ORBR|//' | while IFS='|' read _name _dbid _l0 _d0 _ar _ah _nf
    do
        _name=`orb_trim "$_name"` ; _d0=`orb_trim "$_d0"` ; _ah=`orb_trim "$_ah"`
        _l0=`orb_trim "$_l0"`     ; _ar=`orb_trim "$_ar"` ; _nf=`orb_trim "$_nf"`

        _state="ok"
        if [ "$_l0" = "NUNCA" ] || [ "$_d0" = "-1" ]; then
            _state="crit" ; _d0="-"
        elif [ "$_d0" -ge "${ORB_HEALTH_L0_CRIT_DAYS:-31}" ] 2>/dev/null; then
            _state="crit"
        elif [ "$_d0" -ge "${ORB_HEALTH_L0_WARN_DAYS:-8}" ] 2>/dev/null; then
            _state="warn"
        fi

        case "$_state" in
            crit) _tag="${C_RED}${C_BOLD}CRITICO ${C_OFF}" ; echo "$_name|$_l0|$_d0" >> "$_critlist" ;;
            warn) _tag="${C_YEL}AVISO   ${C_OFF}" ;;
            *)    _tag="${C_GRN}OK      ${C_OFF}" ;;
        esac

        orb_log_raw "  ${_tag}`printf '%-14s %-12s %7s  %-17s %7s %6s' "$_name" "$_l0" "$_d0" "$_ar" "$_ah" "$_nf"`"
    done

    # subshell do pipe nao propaga contadores; recontamos pelo arquivo
    _crit=`wc -l < "$_critlist" 2>/dev/null | tr -d ' '`
    case "$_crit" in ''|*[!0-9]*) _crit=0 ;; esac

    orb_title "VEREDITO DA FROTA"
    orb_field "Bancos analisados" "$_n"
    orb_field "Em estado critico" "$_crit"

    if [ "$_crit" -gt 0 ]; then
        orb_log_raw ""
        orb_status_line crit "$_crit banco(s) sem backup base utilizavel."
        orb_log_raw ""
        while IFS='|' read _nm _dt _dd
        do
            orb_item "$_nm - ultimo nivel 0 em $_dt ($_dd dias)"
        done < "$_critlist"
        orb_log_raw ""
        orb_item "Para cada um: confirme com o time de backup se a midia daquele"
        orb_item "nivel 0 ainda existe. Retencao de fita costuma ser menor que a"
        orb_item "idade desses backups - e a cadeia pode ja estar quebrada."
        ORB_FLEET_RC=2
    else
        orb_status_line ok "Nenhum banco em estado critico."
        ORB_FLEET_RC=0
    fi

    orb_item "Saida bruta: $_o"

    if [ -n "$ORB_HEALTH_MAIL" ] && [ "$ORB_FLEET_RC" -gt 0 ] && orb_have mailx; then
        mailx -s "[ORB] frota: $_crit banco(s) sem backup base" \
              "$ORB_HEALTH_MAIL" < "$ORB_LOG" 2>/dev/null
        orb_log "Alerta enviado para $ORB_HEALTH_MAIL"
    fi
    return $ORB_FLEET_RC
}
