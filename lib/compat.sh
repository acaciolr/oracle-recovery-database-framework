#!/usr/bin/sh
###############################################################################
# lib/compat.sh - camada de compatibilidade Unix
#
# Nada aqui pode depender de GNU coreutils. O alvo inclui AIX, Solaris e HP-UX,
# onde 'readlink -f', 'sed -i', 'grep -P', 'date +%s' e 'date --date' ou nao
# existem ou se comportam de outra forma.
#
# Regra do modulo: se uma funcao nao consegue cumprir o contrato, ela devolve
# vazio e retorna 1. Nunca inventa valor.
###############################################################################

# ---------------------------------------------------------------------------
# orb_os  ->  LINUX | AIX | SUNOS | HPUX | UNKNOWN
# ---------------------------------------------------------------------------
orb_os()
{
    _u=`uname -s 2>/dev/null`
    case "$_u" in
        Linux)   echo "LINUX"  ;;
        AIX)     echo "AIX"    ;;
        SunOS)   echo "SUNOS"  ;;
        HP-UX)   echo "HPUX"   ;;
        *)       echo "UNKNOWN" ;;
    esac
}

# ---------------------------------------------------------------------------
# orb_os_version  -  string de versao do SO, formato varia por plataforma
# ---------------------------------------------------------------------------
orb_os_version()
{
    case `orb_os` in
        AIX)    oslevel -s 2>/dev/null || oslevel 2>/dev/null ;;
        LINUX)  uname -r 2>/dev/null ;;
        SUNOS)  uname -v 2>/dev/null ;;
        HPUX)   uname -r 2>/dev/null ;;
        *)      uname -a 2>/dev/null ;;
    esac
}

# ---------------------------------------------------------------------------
# orb_epoch  -  segundos desde 1970. 0 se nenhum metodo funcionar.
# ---------------------------------------------------------------------------
orb_epoch()
{
    _e=`date +%s 2>/dev/null`
    case "$_e" in
        ''|*[!0-9]*) _e=`perl -e 'print time' 2>/dev/null` ;;
    esac
    case "$_e" in
        ''|*[!0-9]*) _e=0 ;;
    esac
    echo "$_e"
}

# ---------------------------------------------------------------------------
# orb_elapsed <ini> <fim>  ->  HH:MM:SS
# ---------------------------------------------------------------------------
orb_elapsed()
{
    _d=`expr "$2" - "$1" 2>/dev/null`
    [ -z "$_d" ] && _d=0
    [ "$_d" -lt 0 ] && _d=0
    _h=`expr $_d / 3600`
    _m=`expr \( $_d % 3600 \) / 60`
    _s=`expr $_d % 60`
    printf "%02d:%02d:%02d" "$_h" "$_m" "$_s"
}

# ---------------------------------------------------------------------------
# orb_timestamp  -  YYYYMMDD_HHMMSS
# orb_now        -  YYYY-MM-DD HH:MM:SS
# ---------------------------------------------------------------------------
orb_timestamp() { date "+%Y%m%d_%H%M%S" ; }
orb_now()       { date "+%Y-%m-%d %H:%M:%S" ; }

# ---------------------------------------------------------------------------
# orb_realpath <caminho>  -  caminho absoluto sem depender de readlink -f
# ---------------------------------------------------------------------------
orb_realpath()
{
    [ -z "$1" ] && return 1
    _p="$1"
    if [ -d "$_p" ]; then
        ( cd "$_p" 2>/dev/null && pwd )
        return $?
    fi
    _dir=`dirname "$_p" 2>/dev/null`
    _base=`basename "$_p" 2>/dev/null`
    _abs=`( cd "$_dir" 2>/dev/null && pwd )`
    [ -z "$_abs" ] && return 1
    echo "$_abs/$_base"
}

# ---------------------------------------------------------------------------
# orb_sed_replace <arquivo> <regex_ere> <substituicao>
#
# AIX e Solaris nao tem 'sed -i'. Esta funcao faz o ciclo tmp+mv preservando
# o arquivo original em caso de falha.
# ---------------------------------------------------------------------------
orb_sed_replace()
{
    _f="$1" ; _re="$2" ; _to="$3"
    [ -f "$_f" ] || return 1
    _tmp="${_f}.orb.$$"
    sed "s${orb_sed_delim:-|}${_re}${orb_sed_delim:-|}${_to}${orb_sed_delim:-|}g" "$_f" > "$_tmp" 2>/dev/null || {
        rm -f "$_tmp" 2>/dev/null
        return 1
    }
    mv "$_tmp" "$_f" || { rm -f "$_tmp" 2>/dev/null ; return 1 ; }
    return 0
}

# ---------------------------------------------------------------------------
# orb_grep_any <arquivo> <padrao1> [padrao2 ...]
#
# O grep do AIX nao aceita '\|' como alternacao em BRE. Esta funcao percorre
# os padroes um a um em vez de montar uma alternacao.
# Retorna 0 se QUALQUER padrao casar.
# ---------------------------------------------------------------------------
orb_grep_any()
{
    _f="$1" ; shift
    [ -f "$_f" ] || return 1
    for _pat in "$@"
    do
        grep "$_pat" "$_f" >/dev/null 2>&1 && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# orb_strip_cr <arquivo>  -  remove CR de arquivos que vieram de Windows
# ---------------------------------------------------------------------------
orb_strip_cr()
{
    _f="$1"
    [ -f "$_f" ] || return 1
    _tmp="${_f}.orb.$$"
    tr -d '\015' < "$_f" > "$_tmp" 2>/dev/null || { rm -f "$_tmp" ; return 1 ; }
    mv "$_tmp" "$_f"
}

# ---------------------------------------------------------------------------
# orb_upper / orb_lower
# ---------------------------------------------------------------------------
orb_upper()
{
    if [ $# -gt 0 ]; then echo "$1" ; else cat ; fi \
        | tr 'abcdefghijklmnopqrstuvwxyz' 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
}

orb_lower()
{
    if [ $# -gt 0 ]; then echo "$1" ; else cat ; fi \
        | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz'
}

# ---------------------------------------------------------------------------
# orb_trim  -  remove espacos das pontas (le de stdin ou do argumento)
# ---------------------------------------------------------------------------
orb_trim()
{
    if [ $# -gt 0 ]; then
        echo "$1" | sed 's/^[ 	]*//; s/[ 	]*$//'
    else
        sed 's/^[ 	]*//; s/[ 	]*$//'
    fi
}

# ---------------------------------------------------------------------------
# orb_have <comando>  -  o comando existe e e executavel?
# ---------------------------------------------------------------------------
orb_have()
{
    command -v "$1" >/dev/null 2>&1 && return 0
    for _d in /usr/bin /bin /usr/sbin /sbin /usr/local/bin
    do
        [ -x "$_d/$1" ] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# orb_shell  -  qual shell esta interpretando
# ---------------------------------------------------------------------------
orb_shell()
{
    if [ -n "$KSH_VERSION" ]; then      echo "ksh"
    elif [ -n "$BASH_VERSION" ]; then   echo "bash"
    elif [ -n "$ZSH_VERSION" ]; then    echo "zsh"
    else                                echo "sh"
    fi
}

# ---------------------------------------------------------------------------
# orb_free_mb <diretorio>  -  espaco livre em MB, ou vazio se nao souber
#
# A saida do 'df' varia muito entre plataformas. Tratamos os casos conhecidos
# e devolvemos vazio no resto, em vez de chutar.
# ---------------------------------------------------------------------------
orb_free_mb()
{
    _dir="$1"
    [ -d "$_dir" ] || return 1
    case `orb_os` in
        AIX)
            df -m "$_dir" 2>/dev/null | awk 'NR==2 {print int($3)}'
            ;;
        LINUX)
            df -Pm "$_dir" 2>/dev/null | awk 'NR==2 {print int($4)}'
            ;;
        SUNOS|HPUX)
            df -k "$_dir" 2>/dev/null | awk 'NR==2 {print int($4/1024)}'
            ;;
        *)
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# orb_human_mb <mb>  -  formata MB como GB/TB legivel
# ---------------------------------------------------------------------------
orb_human_mb()
{
    _mb="$1"
    case "$_mb" in ''|*[!0-9]*) echo "?" ; return 1 ;; esac
    if [ "$_mb" -ge 1048576 ]; then
        echo "$_mb" | awk '{printf "%.2f TB", $1/1048576}'
    elif [ "$_mb" -ge 1024 ]; then
        echo "$_mb" | awk '{printf "%.2f GB", $1/1024}'
    else
        echo "${_mb} MB"
    fi
}
