#!/usr/bin/sh
###############################################################################
# scripts/orb_sqlcheck.sh
#
# Verifica que o SQL que o framework GERA chega ao sqlplus intacto.
#
# Por que este teste existe
# -------------------------
# Em shell, dentro de aspas duplas:
#
#     "select status from v\$instance"     ->  v$instance     CORRETO
#     "select status from v\\$instance"    ->  v\             ERRADO
#
# ...mas dentro de crase o numero de barras muda:
#
#     X=`f "... v\\$instance"`             ->  v$instance     CORRETO
#     X=`f "... v\$instance"`              ->  v              ERRADO
#
# A diferenca nao aparece em `sh -n`, nao aparece em revisao visual e nao
# aparece em teste de menu. Aparece so na primeira execucao contra um banco
# de verdade, onde TODO campo vira "<nao detectado>" e o framework fica cego
# sem dizer que esta cego.
#
# Este script sobe um ORACLE_HOME falso: o sqlplus e o rman sao scripts que
# gravam o que receberam. Depois procuramos SQL truncado no que foi gravado.
#
# Uso:  sh scripts/orb_sqlcheck.sh
# Saida: 0 = todo SQL gerado esta integro
###############################################################################

_here=`dirname "$0"`
ORB_HOME=`cd "$_here/.." && pwd`
export ORB_HOME

WORK="${TMPDIR:-/tmp}/orb_sqlcheck.$$"
mkdir -p "$WORK/oh/bin" || exit 1
CAP="$WORK/captured.sql"
: > "$CAP"

# --- sqlplus falso ---------------------------------------------------------
cat > "$WORK/oh/bin/sqlplus" <<'EOF'
#!/bin/sh
# argumentos: -s -L "/ as sysdba" @arquivo.sql
for a in "$@"
do
    case "$a" in
        @*) f=`echo "$a" | cut -c2-`
            [ -f "$f" ] && cat "$f" >> "$ORB_CAPTURE"
            ;;
    esac
done
# devolve algo plausivel para o discovery seguir adiante
echo "ORBV|MOCK"
exit 0
EOF

# --- rman falso ------------------------------------------------------------
cat > "$WORK/oh/bin/rman" <<'EOF'
#!/bin/sh
echo "Recovery Manager: mock"
exit 0
EOF

cp "$WORK/oh/bin/sqlplus" "$WORK/oh/bin/expdp" 2>/dev/null
cp "$WORK/oh/bin/sqlplus" "$WORK/oh/bin/impdp" 2>/dev/null
chmod 755 "$WORK/oh/bin/"* 2>/dev/null

ORACLE_HOME="$WORK/oh"    ; export ORACLE_HOME
ORACLE_SID="MOCK"         ; export ORACLE_SID
ORB_CAPTURE="$CAP"        ; export ORB_CAPTURE
ORB_RUNDIR="$WORK/run"    ; mkdir -p "$ORB_RUNDIR"
ORB_LOGDIR="$WORK/logs"   ; mkdir -p "$ORB_LOGDIR"
ORB_COLOR="N"
ORB_UI_UTF8="N"
ORB_MODE="DRYRUN"

for _m in compat logging ui sqlplus rman channels discover validate engine diag lock
do
    . "$ORB_HOME/lib/$_m.sh" || { echo "FATAL: nao carreguei lib/$_m.sh" ; exit 1 ; }
done

orb_log_init "$ORB_LOGDIR" "sqlcheck" >/dev/null 2>&1
orb_ui_init

echo "Coletando SQL gerado pelo discovery..."
orb_discover_all           > /dev/null 2>&1
orb_discover_instance      > /dev/null 2>&1
orb_discover_params        > /dev/null 2>&1
orb_discover_rac           > /dev/null 2>&1
orb_discover_asm           > /dev/null 2>&1
orb_discover_cdb           > /dev/null 2>&1
orb_discover_tde           > /dev/null 2>&1
orb_discover_platform      > /dev/null 2>&1
orb_discover_bct           > /dev/null 2>&1
orb_discover_show          > /dev/null 2>&1
orb_instance_state         > /dev/null 2>&1
orb_precheck_summary       > /dev/null 2>&1

for _m in backup_health backup_info validate_backup dataguard flashback pdb \
          postrestore catalog tts
do
    [ -f "$ORB_HOME/ops/$_m.sh" ] && . "$ORB_HOME/ops/$_m.sh"
done

# funcoes de leitura pura: exercitam a maior parte do SQL do pacote
for _fn in orb_dg_status orb_dg_progress orb_dg_params orb_dg_switchover_checklist \
           orb_fb_status orb_pdb_list orb_op_backup_info orb_op_incarnation \
           orb_postrestore_checklist orb_cat_status orb_tts_platforms orb_tts_list \
           orb_health_check
do
    if command -v "$_fn" >/dev/null 2>&1 || type "$_fn" >/dev/null 2>&1; then
        "$_fn" > /dev/null 2>&1
    fi
done

echo ""
echo "SQL capturado: `wc -l < "$CAP" | tr -d ' '` linhas em $CAP"
echo ""

# --- analise ---------------------------------------------------------------
BAD="$WORK/bad.txt"
: > "$BAD"

# 1) referencia a v$/gv$ que perdeu o nome da view
grep -n 'v\\' "$CAP" >> "$BAD" 2>/dev/null

# 2) "from v" ou "from gv" sem nome de view logo depois
grep -n 'from *g*v *[,)]' "$CAP" >> "$BAD" 2>/dev/null
grep -n 'from *g*v *$'    "$CAP" >> "$BAD" 2>/dev/null

# 3) barra invertida sobrando em qualquer lugar do SQL
grep -n '\\\$' "$CAP" >> "$BAD" 2>/dev/null

if [ -s "$BAD" ]; then
    echo "FALHOU - SQL corrompido pela expansao do shell:"
    echo ""
    sort -u "$BAD" | head -40
    echo ""
    echo 'Regra: FORA de crase    ->  "... from v\$view ..."     (uma barra)'
    echo '       DENTRO de crase  ->  `f "... from v\\$view ..."` (duas barras)'
    echo ""
    echo "Artefatos em $WORK"
    exit 1
fi

echo "OK - nenhuma referencia v\$ / gv\$ corrompida no SQL gerado."

# --- conferencia positiva: as views esperadas apareceram? ------------------
_miss=""
for _v in 'v$instance' 'v$database' 'v$parameter' 'v$datafile'
do
    grep "$_v" "$CAP" >/dev/null 2>&1 || _miss="$_miss $_v"
done
if [ -n "$_miss" ]; then
    echo "AVISO: nao vi referencia a:$_miss"
    echo "       (pode ser so cobertura do teste, mas confira)"
fi

rm -rf "$WORK" 2>/dev/null
exit 0
