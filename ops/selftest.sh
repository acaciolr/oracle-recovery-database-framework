#!/usr/bin/sh
###############################################################################
# ops/selftest.sh - autoteste de integridade
#
# Existe por causa de um episodio concreto: um script de 709 linhas chegou ao
# servidor com 470, sem shebang e sem as definicoes de funcao, porque foi
# colado pelo terminal. O sintoma foi "command not found" em runtime, no meio
# de um incidente.
#
# Este modulo responde, antes de qualquer operacao: o pacote esta inteiro?
# o shell aguenta? as ferramentas existem? o ambiente Oracle responde?
###############################################################################

ORB_ST_OK=0
ORB_ST_WARN=0
ORB_ST_FAIL=0

_st_ok()   { orb_status_line ok   "$*" ; ORB_ST_OK=`expr $ORB_ST_OK + 1` ; }
_st_warn() { orb_status_line warn "$*" ; ORB_ST_WARN=`expr $ORB_ST_WARN + 1` ; }
_st_fail() { orb_status_line fail "$*" ; ORB_ST_FAIL=`expr $ORB_ST_FAIL + 1` ; }

# ---------------------------------------------------------------------------
# _orb_has_cr <arquivo>  -  0 se o arquivo tem CR (veio do Windows)
#
# grep '\015' NAO serve: em GNU grep isso casa com o texto "015" e acusa CR
# em qualquer arquivo que mencione ORA-01547. Comparar com a versao sem CR e
# o unico jeito portavel de responder a pergunta certa.
# ---------------------------------------------------------------------------
_orb_has_cr()
{
    [ -f "$1" ] || return 1
    tr -d '\015' < "$1" | cmp -s - "$1" && return 1
    return 0
}

# ---------------------------------------------------------------------------
orb_selftest_files()
{
    orb_section "INTEGRIDADE DO PACOTE"

    for _m in compat logging ui sqlplus rman channels discover validate engine diag lock
    do
        _f="$ORB_LIB/$_m.sh"
        if [ ! -f "$_f" ]; then
            _st_fail "lib/$_m.sh AUSENTE"
            continue
        fi
        if _orb_has_cr "$_f"; then
            _st_fail "lib/$_m.sh tem CR (arquivo veio do Windows) - rode: tr -d '\\r'"
            continue
        fi
        if ! sh -n "$_f" 2>/dev/null; then
            _st_fail "lib/$_m.sh nao passa no sh -n (arquivo truncado ou corrompido)"
            continue
        fi
        _st_ok "lib/$_m.sh"
    done

    for _m in backup_health backup_info validate_backup restore_database \
              restore_parts restore_advanced pitr postrestore duplicate \
              dataguard flashback pdb backup catalog tts datapump gridasm \
              selftest fleet drill
    do
        _f="$ORB_OPS/$_m.sh"
        if [ ! -f "$_f" ]; then
            _st_warn "ops/$_m.sh ausente (funcionalidade indisponivel)"
            continue
        fi
        if _orb_has_cr "$_f"; then
            _st_fail "ops/$_m.sh tem CR (arquivo veio do Windows) - rode: tr -d '\\r'"
            continue
        fi
        if ! sh -n "$_f" 2>/dev/null; then
            _st_fail "ops/$_m.sh nao passa no sh -n"
            continue
        fi
        _st_ok "ops/$_m.sh"
    done

    for _c in orb.conf media.conf
    do
        [ -f "$ORB_CONF/$_c" ] && _st_ok "conf/$_c" || _st_warn "conf/$_c ausente"
    done
}

# ---------------------------------------------------------------------------
orb_selftest_functions()
{
    orb_section "FUNCOES CARREGADAS"
    _miss=0
    for _fn in orb_log orb_ok orb_warn orb_err orb_title orb_section orb_field \
               orb_confirm orb_ask orb_epoch orb_elapsed orb_human_mb \
               orb_media_load orb_channels_block orb_rman_run orb_sql_value \
               orb_discover_all orb_plan_begin orb_plan_confirm orb_exec_rman \
               orb_diag_explain orb_instance_state orb_lock_acquire \
               orb_op_restore_database orb_op_recover_database orb_op_pitr_database \
               orb_op_pdb_restore orb_op_postrestore_menu orb_op_backup_menu \
               orb_op_catalog_menu orb_op_tts_menu orb_op_dataguard_menu \
               orb_op_duplicate_menu orb_op_flashback_menu orb_op_validate_menu \
               orb_ra_other_host orb_ra_by_tag orb_pr_tempfiles \
               orb_op_datapump_menu orb_op_gridasm_menu
    do
        if command -v "$_fn" >/dev/null 2>&1; then
            :
        else
            _st_fail "funcao ausente: $_fn"
            _miss=1
        fi
    done
    [ $_miss -eq 0 ] && _st_ok "todas as funcoes essenciais carregadas"
}

# ---------------------------------------------------------------------------
orb_selftest_shell()
{
    orb_section "SHELL E FERRAMENTAS"
    _st_ok "shell interpretando: `orb_shell`"
    _st_ok "SO: `orb_os` `orb_os_version`"

    for _t in awk sed grep cut tr sort head tail printf id hostname ps df expr
    do
        orb_have "$_t" && continue
        _st_fail "ferramenta ausente no PATH: $_t"
    done
    _st_ok "utilitarios POSIX presentes"

    _e=`orb_epoch`
    case "$_e" in
        ''|0|*[!0-9]*) _st_warn "orb_epoch nao funcionou - duracoes ficarao zeradas" ;;
        *)             _st_ok "relogio: epoch=$_e" ;;
    esac

    orb_have tput && _st_ok "tput disponivel (largura e cor)" \
                  || _st_warn "tput ausente - largura fixa em 80, sem cor"

    _h=`orb_human_mb 1048576`
    [ "$_h" = "1.00 TB" ] && _st_ok "aritmetica de tamanho OK" \
                          || _st_warn "orb_human_mb devolveu '$_h' (esperado 1.00 TB)"
}

# ---------------------------------------------------------------------------
orb_selftest_dirs()
{
    orb_section "DIRETORIOS"
    for _d in "$ORB_LOGDIR" "$ORB_SCRIPTDIR" "$ORB_RUNDIR"
    do
        [ -n "$_d" ] || continue
        if [ -d "$_d" ] && [ -w "$_d" ]; then
            _fr=`orb_free_mb "$_d"`
            _st_ok "$_d gravavel (livre: `orb_human_mb ${_fr:-0}`)"
        else
            _st_fail "$_d nao existe ou nao e gravavel"
        fi
    done
}

# ---------------------------------------------------------------------------
orb_selftest_oracle()
{
    orb_section "AMBIENTE ORACLE"

    if [ -z "$ORACLE_HOME" ]; then
        _st_fail "ORACLE_HOME nao definido nem descoberto"
    elif [ -x "$ORACLE_HOME/bin/rman" ] && [ -x "$ORACLE_HOME/bin/sqlplus" ]; then
        _st_ok "ORACLE_HOME=$ORACLE_HOME (rman e sqlplus presentes)"
    else
        _st_fail "ORACLE_HOME=$ORACLE_HOME sem rman ou sqlplus"
    fi

    [ -n "$ORACLE_SID" ] && _st_ok "ORACLE_SID=$ORACLE_SID" \
                         || _st_warn "ORACLE_SID nao definido"

    _s=`orb_instance_state`
    case "$_s" in
        OPEN|MOUNTED|STARTED) _st_ok "instancia responde: $_s" ;;
        DOWN)                 _st_warn "instancia parada (discovery limitado)" ;;
        UNKNOWN)              _st_fail "estado INDETERMINADO - ha pmon mas o dicionario nao responde" ;;
    esac

    if orb_rman_has_catalog; then
        _st_ok "recovery catalog configurado"
    else
        _st_warn "sem recovery catalog - visibilidade limitada a ${ORB_D_CFKEEP:-?} dias de controlfile"
    fi

    if [ "$ORB_D_RAC" = "Y" ]; then
        if [ -n "$ORB_D_GRIDHOME" ] && [ -x "$ORB_D_GRIDHOME/bin/crsctl" ]; then
            _st_ok "RAC: Grid Home em $ORB_D_GRIDHOME"
        else
            _st_fail "RAC detectado mas Grid Home nao localizado"
        fi
    fi

    if [ "$ORB_MEDIA_TYPE" != "DISK" ]; then
        if [ -n "$ORB_MEDIA_LIBRARY" ] && [ -f "$ORB_MEDIA_LIBRARY" ]; then
            _st_ok "biblioteca de media: $ORB_MEDIA_LIBRARY"
        elif [ -n "$ORB_MEDIA_LIBRARY" ]; then
            _st_warn "biblioteca de media nao encontrada: $ORB_MEDIA_LIBRARY"
        fi
        case "$ORB_MEDIA_SEND$ORB_MEDIA_PARMS" in
            *"<"*">"*) _st_fail "media.conf ainda tem placeholder <...> por preencher" ;;
        esac
    fi
}

# ---------------------------------------------------------------------------
orb_selftest_redact()
{
    orb_section "PROTECAO DE CREDENCIAL"
    _t=`orb_log_redact 'rman target / catalog cat_user/"MinhaSenha#123"@CAT'`
    case "$_t" in
        *MinhaSenha*) _st_fail "orb_log_redact VAZOU senha: $_t" ;;
        *)            _st_ok "redact de catalogo funcionando" ;;
    esac
    _t=`orb_log_redact 'sqlplus sys/Outra456@PRIMARY as sysdba'`
    case "$_t" in
        *Outra456*) _st_fail "orb_log_redact VAZOU senha de sys" ;;
        *)          _st_ok "redact de sqlplus funcionando" ;;
    esac
}

# ---------------------------------------------------------------------------
# orb_selftest_sqlquote
#
# Procura o erro de escape que nao aparece em `sh -n` e nao aparece na leitura:
#
#     fora de crase :  "... from v\$view ..."      uma barra
#     dentro de crase: `f "... from v\\$view ..."`  duas barras
#
# Errar isso faz o shell comer o nome da view. O SQL vira "from v\" e o
# framework passa a devolver <nao detectado> em tudo, sem avisar que ficou
# cego. Este teste conta crases a esquerda de cada ocorrencia e cobra a
# quantidade certa de barras.
# ---------------------------------------------------------------------------
orb_selftest_sqlquote()
{
    orb_section "ESCAPE DE v\$ NO SQL GERADO"
    orb_have awk || { _st_warn "awk ausente - nao consigo verificar o escape" ; return 0 ; }

    _bad="${ORB_RUNDIR:-/tmp}/sqlquote.bad"
    : > "$_bad"

    for _f in "$ORB_HOME"/lib/*.sh "$ORB_HOME"/ops/*.sh "$ORB_HOME"/orb.sh
    do
        [ -f "$_f" ] || continue
        awk -v F="$_f" -v Q="'" '
        BEGIN { depth = 0 ; inq = 0 }
        /^[ \t]*#/ { if (inq == 0) next }
        {
            line = $0
            n = length(line)
            i = 1
            while (i <= n) {
                c = substr(line, i, 1)
                if (inq == 1) {
                    if (c == Q) inq = 0
                    i++
                    continue
                }
                if (c == Q) { inq = 1 ; i++ ; continue }
                if (c == "\\") { i += 2 ; continue }
                if (c == "`") { depth = 1 - depth ; i++ ; continue }
                if (c == "v" && substr(line, i+1, 1) == "\\") {
                    j = i + 1
                    b = 0
                    while (substr(line, j, 1) == "\\") { b++ ; j++ }
                    if (substr(line, j, 1) == "$") {
                        want = 1
                        if (depth == 1) want = 2
                        if (b != want)
                            printf "%s:%d: %d barra(s), deveriam ser %d (dentro de crase=%d)\n", F, NR, b, want, depth
                    }
                    i = j
                    continue
                }
                i++
            }
        }' "$_f" >> "$_bad" 2>/dev/null
    done

    if [ -s "$_bad" ]; then
        _n=`wc -l < "$_bad" | tr -d " "`
        _st_fail "$_n ocorrencia(s) de v\$ com escape errado"
        head -10 "$_bad" | while IFS= read _l ; do orb_item "$_l" ; done
        orb_item "Veja $_bad"
    else
        _st_ok "escape de v\$ / gv\$ correto em todos os modulos"
    fi
    return 0
}

# ---------------------------------------------------------------------------
orb_op_selftest()
{
    orb_title "AUTOTESTE"
    ORB_ST_OK=0 ; ORB_ST_WARN=0 ; ORB_ST_FAIL=0

    orb_selftest_files
    orb_selftest_functions
    orb_selftest_shell
    orb_selftest_dirs
    orb_selftest_redact
    orb_selftest_sqlquote
    orb_selftest_oracle

    orb_title "RESULTADO DO AUTOTESTE"
    orb_field "OK"      "$ORB_ST_OK"
    orb_field "Avisos"  "$ORB_ST_WARN"
    orb_field "Falhas"  "$ORB_ST_FAIL"

    if [ "$ORB_ST_FAIL" -gt 0 ]; then
        orb_status_line fail "Ha falhas. NAO use o framework antes de resolver."
        return 2
    fi
    if [ "$ORB_ST_WARN" -gt 0 ]; then
        orb_status_line warn "Utilizavel, com limitacoes nos itens marcados."
        return 1
    fi
    orb_status_line ok "Pacote integro e ambiente pronto."
    return 0
}
