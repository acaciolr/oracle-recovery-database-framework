#!/usr/bin/sh
###############################################################################
# lib/channels.sh - configuracao de canais e media manager
#
# Este modulo e deliberadamente separado da logica de restore. O mesmo
# RESTORE DATABASE deve poder ser montado para DISK, SBT+NetBackup, SBT+TSM ou
# uma biblioteca SBT customizada sem que nenhum modulo de recovery mude.
#
# A fonte da verdade e conf/media.conf, carregado em ORB_MEDIA_*.
###############################################################################

ORB_MEDIA_NAME="${ORB_MEDIA_NAME:-DISK}"
ORB_MEDIA_TYPE="${ORB_MEDIA_TYPE:-DISK}"
ORB_MEDIA_LIBRARY="${ORB_MEDIA_LIBRARY:-}"
ORB_MEDIA_SEND="${ORB_MEDIA_SEND:-}"
ORB_MEDIA_PARMS="${ORB_MEDIA_PARMS:-}"
ORB_MEDIA_FORMAT="${ORB_MEDIA_FORMAT:-}"
ORB_CHANNELS="${ORB_CHANNELS:-4}"
ORB_MAXPIECESIZE="${ORB_MAXPIECESIZE:-}"
ORB_SECTION_SIZE="${ORB_SECTION_SIZE:-}"
ORB_FILESPERSET="${ORB_FILESPERSET:-}"
ORB_RATE="${ORB_RATE:-}"

# ---------------------------------------------------------------------------
# orb_media_load <arquivo> [perfil]
#
# media.conf pode ter varios perfis, delimitados por [NOME].
# Sem perfil, carrega o primeiro.
# ---------------------------------------------------------------------------
orb_media_load()
{
    _f="$1" ; _want="$2"
    [ -f "$_f" ] || { orb_warn "media.conf nao encontrado: $_f (usando DISK)" ; return 1 ; }

    # Reset obrigatorio: sem isso, carregar um perfil por cima de outro deixa
    # residuo (ex: PARMS do TSM com SEND do NetBackup).
    ORB_MEDIA_NAME="" ; ORB_MEDIA_TYPE="DISK" ; ORB_MEDIA_LIBRARY=""
    ORB_MEDIA_SEND="" ; ORB_MEDIA_PARMS=""    ; ORB_MEDIA_FORMAT=""
    ORB_MAXPIECESIZE="" ; ORB_SECTION_SIZE="" ; ORB_FILESPERSET="" ; ORB_RATE=""

    _in=0
    _found=0
    while IFS= read _line
    do
        case "$_line" in
            \#*|'') continue ;;
            \[*\])
                _sec=`echo "$_line" | tr -d '[]' | orb_trim`
                if [ -z "$_want" ] || [ "$_sec" = "$_want" ]; then
                    _in=1 ; _found=1 ; ORB_MEDIA_PROFILE="$_sec"
                    [ -z "$_want" ] && _want="$_sec"
                else
                    _in=0
                fi
                continue
                ;;
        esac
        [ $_in -eq 1 ] || continue
        _k=`echo "$_line" | cut -d= -f1 | orb_trim`
        _v=`echo "$_line" | cut -d= -f2- | orb_trim`
        # tira aspas externas se houver
        _v=`echo "$_v" | sed 's/^"//; s/"$//'`
        case "$_k" in
            MEDIA_NAME)     ORB_MEDIA_NAME="$_v"     ;;
            MEDIA_TYPE)     ORB_MEDIA_TYPE="$_v"     ;;
            LIBRARY)        ORB_MEDIA_LIBRARY="$_v"  ;;
            SEND)           ORB_MEDIA_SEND="$_v"     ;;
            PARMS)          ORB_MEDIA_PARMS="$_v"    ;;
            FORMAT)         ORB_MEDIA_FORMAT="$_v"   ;;
            CHANNELS)       ORB_CHANNELS="$_v"       ;;
            MAXPIECESIZE)   ORB_MAXPIECESIZE="$_v"   ;;
            SECTION_SIZE)   ORB_SECTION_SIZE="$_v"   ;;
            FILESPERSET)    ORB_FILESPERSET="$_v"    ;;
            RATE)           ORB_RATE="$_v"           ;;
        esac
    done < "$_f"

    [ $_found -eq 1 ] || { orb_warn "Perfil de media nao encontrado: $_want" ; return 1 ; }
    return 0
}

orb_media_profiles()
{
    _f="$1"
    [ -f "$_f" ] || return 1
    grep '^\[' "$_f" 2>/dev/null | tr -d '[]'
}

# ---------------------------------------------------------------------------
# orb_media_summary  -  linha unica para o cabecalho do plano
# ---------------------------------------------------------------------------
orb_media_summary()
{
    if [ "$ORB_MEDIA_TYPE" = "DISK" ]; then
        echo "DISK / $ORB_CHANNELS canais"
    else
        echo "$ORB_MEDIA_TYPE / $ORB_MEDIA_NAME / $ORB_CHANNELS canais"
    fi
}

# ---------------------------------------------------------------------------
# orb_channels_block [qtd]
#
# Emite as linhas ALLOCATE CHANNEL + SEND para dentro de um bloco RUN{}.
# Respeita PARMS, MAXPIECESIZE, RATE e FORMAT quando configurados.
# ---------------------------------------------------------------------------
orb_channels_block()
{
    _n="${1:-$ORB_CHANNELS}"
    case "$_n" in ''|*[!0-9]*) _n=4 ;; esac

    _i=0
    while [ $_i -lt $_n ]
    do
        _ch=`printf "ch%02d" $_i`
        _line="  ALLOCATE CHANNEL $_ch TYPE '$ORB_MEDIA_TYPE'"
        [ -n "$ORB_MEDIA_PARMS" ]  && _line="$_line PARMS=\"$ORB_MEDIA_PARMS\""
        [ -n "$ORB_MEDIA_FORMAT" ] && _line="$_line FORMAT '$ORB_MEDIA_FORMAT'"
        [ -n "$ORB_MAXPIECESIZE" ] && _line="$_line MAXPIECESIZE $ORB_MAXPIECESIZE"
        [ -n "$ORB_RATE" ]         && _line="$_line RATE $ORB_RATE"
        echo "$_line;"
        _i=`expr $_i + 1`
    done

    # SEND aplica-se a todos os canais alocados; um so basta.
    if [ -n "$ORB_MEDIA_SEND" ]; then
        echo "  SEND \"$ORB_MEDIA_SEND\";"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# orb_channels_release [qtd]
# ---------------------------------------------------------------------------
orb_channels_release()
{
    _n="${1:-$ORB_CHANNELS}"
    _i=0
    while [ $_i -lt $_n ]
    do
        printf "  RELEASE CHANNEL ch%02d;\n" $_i
        _i=`expr $_i + 1`
    done
}

# ---------------------------------------------------------------------------
# orb_channels_configure  -  forma persistente (CONFIGURE em vez de ALLOCATE)
# ---------------------------------------------------------------------------
orb_channels_configure()
{
    echo "CONFIGURE DEVICE TYPE $ORB_MEDIA_TYPE PARALLELISM $ORB_CHANNELS BACKUP TYPE TO BACKUPSET;"
    if [ -n "$ORB_MEDIA_PARMS" ]; then
        echo "CONFIGURE CHANNEL DEVICE TYPE $ORB_MEDIA_TYPE PARMS=\"$ORB_MEDIA_PARMS\";"
    fi
}

# ---------------------------------------------------------------------------
# orb_channels_interactive  -  ajuste na hora, sem editar arquivo
# ---------------------------------------------------------------------------
orb_channels_interactive()
{
    orb_section "CONFIGURACAO DE CANAIS"
    orb_field "Perfil de media"  "${ORB_MEDIA_PROFILE:-<nenhum>}"
    orb_field "Tipo"             "$ORB_MEDIA_TYPE"
    orb_field "Canais"           "$ORB_CHANNELS"
    orb_field "SEND"             "${ORB_MEDIA_SEND:-<nenhum>}"
    orb_field "PARMS"            "${ORB_MEDIA_PARMS:-<nenhum>}"

    orb_ask "Quantidade de canais" "$ORB_CHANNELS"
    case "$ORB_ANSWER" in
        ''|*[!0-9]*) orb_warn "Valor invalido, mantendo $ORB_CHANNELS" ;;
        *) ORB_CHANNELS="$ORB_ANSWER" ;;
    esac

    orb_ask "String do SEND (vazio = nenhum SEND)" "$ORB_MEDIA_SEND"
    ORB_MEDIA_SEND="$ORB_ANSWER"

    orb_ask "String do PARMS (vazio = nenhum)" "$ORB_MEDIA_PARMS"
    ORB_MEDIA_PARMS="$ORB_ANSWER"

    orb_section "BLOCO DE CANAIS RESULTANTE"
    orb_channels_block | while IFS= read _l ; do orb_log_raw "$_l" ; done
    return 0
}
