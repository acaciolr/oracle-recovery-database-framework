#!/usr/bin/sh
###############################################################################
# lib/discover.sh - descoberta do ambiente
#
# PRINCIPIO: nada aqui inventa valor. Se uma informacao nao puder ser obtida
# do SO, do Oracle ou do RMAN, a variavel fica vazia e o campo aparece como
# <nao detectado>. Um framework de recovery que chuta e pior que nenhum.
###############################################################################

ORB_D_OS=""          ; ORB_D_OSVER=""      ; ORB_D_HOST=""
ORB_D_USER=""        ; ORB_D_SHELL=""
ORB_D_OHOME=""       ; ORB_D_OBASE=""      ; ORB_D_SID=""
ORB_D_VERSION=""     ; ORB_D_VERSHORT=""
ORB_D_DBNAME=""      ; ORB_D_DBUNIQUE=""   ; ORB_D_DBID=""
ORB_D_STATUS=""      ; ORB_D_OPENMODE=""   ; ORB_D_ROLE=""
ORB_D_CFTYPE=""      ; ORB_D_LOGMODE=""    ; ORB_D_FLASHBACK=""
ORB_D_RAC="N"        ; ORB_D_INSTANCES=""  ; ORB_D_NODES=""
ORB_D_GRIDHOME=""    ; ORB_D_CRS="N"
ORB_D_ASM="N"        ; ORB_D_DISKGROUPS=""
ORB_D_CDB="N"        ; ORB_D_PDBS=""
ORB_D_DBCREATE=""    ; ORB_D_DBCREATE_LOG="" ; ORB_D_FRA="" ; ORB_D_FRASIZE=""
ORB_D_DIAGDEST=""    ; ORB_D_AUDITDEST=""
ORB_D_CFKEEP=""      ; ORB_D_DATAFILES=""
ORB_D_TDE="N"        ; ORB_D_TDE_STATUS=""  ; ORB_D_TDE_LOC=""
ORB_D_PLATFORM=""    ; ORB_D_ENDIAN=""      ; ORB_D_PLATID=""
ORB_D_BCT=""         ; ORB_D_BCTFILE=""
ORB_D_RETENTION=""   ; ORB_D_AUTOBACKUP=""  ; ORB_D_DEVTYPE=""

# ---------------------------------------------------------------------------
orb_discover_os()
{
    ORB_D_OS=`orb_os`
    ORB_D_OSVER=`orb_os_version`
    ORB_D_HOST=`hostname 2>/dev/null`
    ORB_D_USER=`id -un 2>/dev/null`
    ORB_D_SHELL=`orb_shell`
    return 0
}

# ---------------------------------------------------------------------------
# orb_discover_oracle_home
#
# Ordem: variavel de ambiente -> oratab -> caminho do sqlplus no PATH.
# oratab fica em /etc/oratab (Linux/AIX) ou /var/opt/oracle/oratab (Solaris).
# ---------------------------------------------------------------------------
orb_oratab_path()
{
    for _f in /etc/oratab /var/opt/oracle/oratab
    do
        [ -f "$_f" ] && { echo "$_f" ; return 0 ; }
    done
    return 1
}

orb_discover_oracle_home()
{
    if [ -n "$ORACLE_HOME" ] && [ -x "$ORACLE_HOME/bin/sqlplus" ]; then
        ORB_D_OHOME="$ORACLE_HOME"
    else
        _tab=`orb_oratab_path`
        if [ -n "$_tab" ] && [ -n "$ORACLE_SID" ]; then
            ORB_D_OHOME=`grep "^${ORACLE_SID}:" "$_tab" 2>/dev/null | head -1 | cut -d: -f2`
        fi
        if [ -z "$ORB_D_OHOME" ]; then
            _sp=`command -v sqlplus 2>/dev/null`
            if [ -n "$_sp" ]; then
                _bd=`dirname "$_sp" 2>/dev/null`
                ORB_D_OHOME=`dirname "$_bd" 2>/dev/null`
            fi
        fi
        [ -n "$ORB_D_OHOME" ] && export ORACLE_HOME="$ORB_D_OHOME"
    fi
    ORB_D_OBASE="${ORACLE_BASE:-}"
    [ -n "$ORB_D_OHOME" ] || return 1
    return 0
}

orb_discover_sid()
{
    ORB_D_SID="${ORACLE_SID:-}"
    if [ -z "$ORB_D_SID" ]; then
        _tab=`orb_oratab_path`
        [ -n "$_tab" ] && ORB_D_SID=`grep -v "^#" "$_tab" 2>/dev/null | grep -v "^$" | head -1 | cut -d: -f1`
        [ -n "$ORB_D_SID" ] && export ORACLE_SID="$ORB_D_SID"
    fi
    [ -n "$ORB_D_SID" ] || return 1
    return 0
}

# ---------------------------------------------------------------------------
orb_discover_version()
{
    # Preferimos o dicionario; se a instancia estiver down, caimos no binario.
    ORB_D_VERSION=`orb_sql_value "(select version_full from v\\$instance)" 2>/dev/null`
    [ -z "$ORB_D_VERSION" ] && ORB_D_VERSION=`orb_sql_value "(select version from v\\$instance)" 2>/dev/null`
    if [ -z "$ORB_D_VERSION" ] && [ -f "$ORB_D_OHOME/inventory/ContentsXML/oraclehomeproperties.xml" ]; then
        ORB_D_VERSION=`grep -i "ARU_ID_DESCRIPTION\|VERSION" "$ORB_D_OHOME/inventory/ContentsXML/oraclehomeproperties.xml" 2>/dev/null | head -1 | sed 's/.*VERSION="\([^"]*\)".*/\1/'`
    fi
    ORB_D_VERSHORT=`echo "$ORB_D_VERSION" | cut -d. -f1`
    return 0
}

# ---------------------------------------------------------------------------
orb_discover_instance()
{
    ORB_D_STATUS=`orb_sql_value "(select status from v\\$instance)"`
    [ -z "$ORB_D_STATUS" ] && { ORB_D_STATUS="DOWN" ; return 1 ; }

    ORB_D_DBNAME=`orb_sql_value "(select name from v\\$database)"`
    ORB_D_DBID=`orb_sql_value "(select to_char(dbid) from v\\$database)"`
    ORB_D_OPENMODE=`orb_sql_value "(select open_mode from v\\$database)"`
    ORB_D_ROLE=`orb_sql_value "(select database_role from v\\$database)"`
    ORB_D_CFTYPE=`orb_sql_value "(select controlfile_type from v\\$database)"`
    ORB_D_LOGMODE=`orb_sql_value "(select log_mode from v\\$database)"`
    ORB_D_FLASHBACK=`orb_sql_value "(select flashback_on from v\\$database)"`
    ORB_D_DBUNIQUE=`orb_sql_value "(select value from v\\$parameter where name='db_unique_name')"`
    ORB_D_DATAFILES=`orb_sql_value "(select to_char(count(*)) from v\\$datafile)"`
    return 0
}

orb_discover_params()
{
    ORB_D_DBCREATE=`orb_sql_value     "(select value from v\\$parameter where name='db_create_file_dest')"`
    ORB_D_DBCREATE_LOG=`orb_sql_value "(select value from v\\$parameter where name='db_create_online_log_dest_1')"`
    ORB_D_FRA=`orb_sql_value          "(select value from v\\$parameter where name='db_recovery_file_dest')"`
    ORB_D_FRASIZE=`orb_sql_value      "(select value from v\\$parameter where name='db_recovery_file_dest_size')"`
    ORB_D_DIAGDEST=`orb_sql_value     "(select value from v\\$parameter where name='diagnostic_dest')"`
    ORB_D_AUDITDEST=`orb_sql_value    "(select value from v\\$parameter where name='audit_file_dest')"`
    ORB_D_CFKEEP=`orb_sql_value       "(select value from v\\$parameter where name='control_file_record_keep_time')"`
    return 0
}

# ---------------------------------------------------------------------------
orb_discover_rac()
{
    _cl=`orb_sql_value "(select value from v\\$parameter where name='cluster_database')" 2>/dev/null`
    if [ "$_cl" = "TRUE" ]; then
        ORB_D_RAC="Y"
        ORB_D_INSTANCES=`orb_sql_query "select 'ORBR|'||instance_name||'@'||host_name from gv\\$instance order by instance_number;" 2>/dev/null | tr '\n' ' '`
    fi

    # Grid Infrastructure: independente do banco estar no ar
    for _f in /etc/oracle/olr.loc /var/opt/oracle/olr.loc
    do
        [ -f "$_f" ] || continue
        ORB_D_GRIDHOME=`grep "^crs_home=" "$_f" 2>/dev/null | cut -d= -f2`
        break
    done
    if [ -n "$ORB_D_GRIDHOME" ] && [ -x "$ORB_D_GRIDHOME/bin/crsctl" ]; then
        "$ORB_D_GRIDHOME/bin/crsctl" check crs >/dev/null 2>&1 && ORB_D_CRS="Y"
        ORB_D_NODES=`"$ORB_D_GRIDHOME/bin/olsnodes" 2>/dev/null | tr '\n' ' '`
        [ -n "$ORB_D_NODES" ] && ORB_D_RAC="Y"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# orb_discover_asm  -  diskgroups com espaco. Le de v$asm_diskgroup, que a
# instancia de banco tambem enxerga quando usa ASM.
# ---------------------------------------------------------------------------
orb_discover_asm()
{
    _n=`orb_sql_value "(select to_char(count(*)) from v\\$asm_diskgroup)" 2>/dev/null`
    case "$_n" in ''|0|*[!0-9]*) ORB_D_ASM="N" ; return 1 ;; esac
    ORB_D_ASM="Y"
    ORB_D_DISKGROUPS=`orb_sql_query "select 'ORBR|'||name||'|'||to_char(total_mb)||'|'||to_char(free_mb) from v\\$asm_diskgroup order by name;" 2>/dev/null`
    return 0
}

# orb_asm_free_mb <+DG>  -  MB livres, vazio se nao souber
orb_asm_free_mb()
{
    _dg=`echo "$1" | sed 's/^+//'`
    echo "$ORB_D_DISKGROUPS" | while IFS='|' read _n _t _f
    do
        [ "$_n" = "$_dg" ] && { echo "$_f" ; break ; }
    done
}

# ---------------------------------------------------------------------------
# orb_discover_tde
#
# Ponto cego classico em restore para outro host: o wallet nao esta no backup
# RMAN. Restaurar datafile criptografado sem o wallet produz bytes inuteis -
# e o restore "termina com sucesso".
# ---------------------------------------------------------------------------
orb_discover_tde()
{
    ORB_D_TDE_STATUS=`orb_sql_value "(select status from v\\$encryption_wallet where rownum=1)" 2>/dev/null`
    case "$ORB_D_TDE_STATUS" in
        ""|NOT_AVAILABLE) ORB_D_TDE="N" ; return 1 ;;
    esac
    ORB_D_TDE="Y"
    ORB_D_TDE_LOC=`orb_sql_value "(select wrl_parameter from v\\$encryption_wallet where rownum=1)" 2>/dev/null`
    return 0
}

# ---------------------------------------------------------------------------
# orb_discover_platform  -  plataforma e endianness
#
# Decide se um CONVERT entre plataformas e reescrita de cabecalho (mesma
# endianness) ou reescrita de todos os blocos (endianness diferente).
# ---------------------------------------------------------------------------
orb_discover_platform()
{
    ORB_D_PLATFORM=`orb_sql_value "(select platform_name from v\\$database)" 2>/dev/null`
    [ -n "$ORB_D_PLATFORM" ] || return 1
    ORB_D_PLATID=`orb_sql_value "(select to_char(platform_id) from v\\$database)" 2>/dev/null`
    ORB_D_ENDIAN=`orb_sql_value "(select tp.endian_format from v\\$transportable_platform tp, v\\$database d where tp.platform_name = d.platform_name)" 2>/dev/null`
    return 0
}

# ---------------------------------------------------------------------------
# orb_discover_bct  -  block change tracking
# ---------------------------------------------------------------------------
orb_discover_bct()
{
    ORB_D_BCT=`orb_sql_value "(select status from v\\$block_change_tracking)" 2>/dev/null`
    [ "$ORB_D_BCT" = "ENABLED" ] || return 1
    ORB_D_BCTFILE=`orb_sql_value "(select filename from v\\$block_change_tracking)" 2>/dev/null`
    return 0
}

# ---------------------------------------------------------------------------
orb_discover_cdb()
{
    _c=`orb_sql_value "(select cdb from v\\$database)" 2>/dev/null`
    if [ "$_c" = "YES" ]; then
        ORB_D_CDB="Y"
        ORB_D_PDBS=`orb_sql_query "select 'ORBR|'||con_id||'|'||name||'|'||open_mode||'|'||restricted from v\\$pdbs order by con_id;" 2>/dev/null`
    fi
    return 0
}

# ---------------------------------------------------------------------------
# orb_discover_all
# ---------------------------------------------------------------------------
orb_discover_all()
{
    orb_discover_os
    orb_discover_sid
    orb_discover_oracle_home || orb_warn "ORACLE_HOME nao detectado."
    if orb_sql_alive; then
        orb_discover_version
        orb_discover_instance
        orb_discover_params
        orb_discover_rac
        orb_discover_asm
        orb_discover_cdb
        orb_discover_tde
        orb_discover_platform
        orb_discover_bct
    else
        orb_warn "Instancia nao responde. Discovery limitado ao sistema operacional."
        ORB_D_STATUS="DOWN"
        orb_discover_version
        orb_discover_rac
    fi
    return 0
}

# ---------------------------------------------------------------------------
# orb_discover_show
# ---------------------------------------------------------------------------
_orb_or_na() { [ -n "$1" ] && echo "$1" || echo "<nao detectado>" ; }

orb_discover_show()
{
    orb_title "INVENTARIO DO AMBIENTE"

    orb_section "SISTEMA"
    orb_field "SO"              "`_orb_or_na "$ORB_D_OS"` `_orb_or_na "$ORB_D_OSVER"`"
    orb_field "Host"            "`_orb_or_na "$ORB_D_HOST"`"
    orb_field "Usuario"         "`_orb_or_na "$ORB_D_USER"`"
    orb_field "Shell"           "`_orb_or_na "$ORB_D_SHELL"`"

    orb_section "ORACLE"
    orb_field "ORACLE_HOME"     "`_orb_or_na "$ORB_D_OHOME"`"
    orb_field "ORACLE_BASE"     "`_orb_or_na "$ORB_D_OBASE"`"
    orb_field "ORACLE_SID"      "`_orb_or_na "$ORB_D_SID"`"
    orb_field "Versao"          "`_orb_or_na "$ORB_D_VERSION"`"
    orb_field "DB_NAME"         "`_orb_or_na "$ORB_D_DBNAME"`"
    orb_field "DB_UNIQUE_NAME"  "`_orb_or_na "$ORB_D_DBUNIQUE"`"
    orb_field "DBID"            "`_orb_or_na "$ORB_D_DBID"`"
    orb_field "Status"          "`_orb_or_na "$ORB_D_STATUS"`"
    orb_field "Open mode"       "`_orb_or_na "$ORB_D_OPENMODE"`"
    orb_field "Role"            "`_orb_or_na "$ORB_D_ROLE"`"
    orb_field "Controlfile"     "`_orb_or_na "$ORB_D_CFTYPE"`"
    orb_field "Log mode"        "`_orb_or_na "$ORB_D_LOGMODE"`"
    orb_field "Flashback"       "`_orb_or_na "$ORB_D_FLASHBACK"`"
    orb_field "Datafiles"       "`_orb_or_na "$ORB_D_DATAFILES"`"
    orb_field "Plataforma"      "`_orb_or_na "$ORB_D_PLATFORM"`"
    orb_field "Endianness"      "`_orb_or_na "$ORB_D_ENDIAN"`"

    orb_section "ARQUITETURA"
    orb_field "RAC"             "$ORB_D_RAC"
    [ "$ORB_D_RAC" = "Y" ] && orb_field "Instancias" "`_orb_or_na "$ORB_D_INSTANCES"`"
    [ -n "$ORB_D_NODES" ]  && orb_field "Nodes"      "$ORB_D_NODES"
    orb_field "Grid Home"       "`_orb_or_na "$ORB_D_GRIDHOME"`"
    orb_field "Clusterware"     "$ORB_D_CRS"
    orb_field "CDB"             "$ORB_D_CDB"
    if [ "$ORB_D_CDB" = "Y" ] && [ -n "$ORB_D_PDBS" ]; then
        orb_log_raw "  PDBs:"
        echo "$ORB_D_PDBS" | while IFS='|' read _id _nm _om _rs
        do
            [ -n "$_nm" ] && orb_log_raw "    con_id=$_id  $_nm  $_om  restricted=$_rs"
        done
    fi

    orb_section "STORAGE"
    orb_field "ASM"                 "$ORB_D_ASM"
    if [ "$ORB_D_ASM" = "Y" ] && [ -n "$ORB_D_DISKGROUPS" ]; then
        orb_log_raw "  Diskgroups:"
        echo "$ORB_D_DISKGROUPS" | while IFS='|' read _n _t _f
        do
            [ -n "$_n" ] || continue
            orb_log_raw "    +$_n  total `orb_human_mb $_t`  livre `orb_human_mb $_f`"
        done
    fi
    orb_field "db_create_file_dest" "`_orb_or_na "$ORB_D_DBCREATE"`"
    orb_field "FRA"                 "`_orb_or_na "$ORB_D_FRA"`"
    orb_field "diagnostic_dest"     "`_orb_or_na "$ORB_D_DIAGDEST"`"
    orb_field "audit_file_dest"     "`_orb_or_na "$ORB_D_AUDITDEST"`"

    if [ "$ORB_D_TDE" = "Y" ]; then
        orb_section "CRIPTOGRAFIA (TDE)"
        orb_field "Wallet"   "$ORB_D_TDE_STATUS"
        orb_field "Local"    "`_orb_or_na "$ORB_D_TDE_LOC"`"
        if [ "$ORB_D_TDE_STATUS" != "OPEN" ]; then
            orb_warn "Wallet nao esta OPEN - datafiles criptografados ficam ilegiveis."
        fi
        orb_item "O wallet NAO esta no backup RMAN. Em restore para outro host,"
        orb_item "ele precisa ser copiado separadamente."
    fi

    orb_section "BACKUP"
    orb_field "Perfil de media"     "${ORB_MEDIA_PROFILE:-<nenhum>}"
    orb_field "Media"               "`orb_media_summary`"
    orb_field "Recovery catalog"    "`orb_rman_has_catalog && echo SIM || echo NAO`"
    orb_field "cf_record_keep_time" "`_orb_or_na "$ORB_D_CFKEEP"` dias"
    if [ -n "$ORB_D_CFKEEP" ]; then
        orb_item "Sem catalogo, o RMAN so enxerga backups dentro dessa janela."
    fi
    orb_field "Block change tracking" "`_orb_or_na "$ORB_D_BCT"`"
    if [ "$ORB_D_BCT" = "ENABLED" ]; then
        orb_item "$ORB_D_BCTFILE"
    else
        orb_item "Sem BCT, todo incremental le o banco inteiro."
    fi
    return 0
}
