#!/usr/bin/sh
###############################################################################
# lib/ui.sh - interface de terminal
#
# Objetivo: parecer moderno onde da, e degradar sem quebrar onde nao da.
#
# Tres capacidades sao detectadas em runtime, nao assumidas:
#
#   LARGURA  tput cols -> stty -> COLUMNS -> 80
#   COR      probe real de tput setaf; se falhar, tudo vira texto puro
#   CHARSET  UTF-8 so se o locale disser E ORB_UI_UTF8 permitir.
#            Console de HMC, ILO e sessao serial costumam nao ter UTF-8:
#            o padrao e ASCII, e UTF-8 e opt-in.
#
# Sem cor e sem UTF-8 o layout continua alinhado - as bordas viram + - |
# e os badges viram [OK] [!!] [XX].
###############################################################################

ORB_W=78
ORB_UI_COLOR="N"
ORB_UI_UTF8="${ORB_UI_UTF8:-auto}"

# caracteres de moldura (preenchidos por orb_ui_init)
_BX_H="-" ; _BX_V="|" ; _BX_TL="+" ; _BX_TR="+" ; _BX_BL="+" ; _BX_BR="+"
_BX_ML="+" ; _BX_MR="+" ; _BX_DH="=" ; _BX_DOT="."

# sequencias de cor (vazias quando sem cor)
C_OFF="" ; C_BOLD="" ; C_DIM=""
C_RED="" ; C_GRN="" ; C_YEL="" ; C_BLU="" ; C_CYA="" ; C_MAG=""

# ---------------------------------------------------------------------------
# orb_ui_init  -  chamada uma vez no arranque
# ---------------------------------------------------------------------------
orb_ui_init()
{
    # --- largura ----------------------------------------------------------
    _w=""
    if orb_have tput; then
        _w=`tput cols 2>/dev/null`
    fi
    case "$_w" in ''|*[!0-9]*) _w="" ;; esac
    if [ -z "$_w" ] && orb_have stty; then
        _w=`stty size 2>/dev/null | awk '{print $2}'`
        case "$_w" in ''|*[!0-9]*) _w="" ;; esac
    fi
    [ -z "$_w" ] && _w="${COLUMNS:-80}"
    case "$_w" in ''|*[!0-9]*) _w=80 ;; esac
    [ "$_w" -lt 72 ] && _w=72
    [ "$_w" -gt 110 ] && _w=110
    ORB_W=`expr $_w - 2`

    # --- cor --------------------------------------------------------------
    ORB_UI_COLOR="N"
    if [ "${ORB_COLOR:-N}" = "Y" ] && [ -t 1 ] && [ -n "$TERM" ] && [ "$TERM" != "dumb" ]; then
        if orb_have tput && tput setaf 1 >/dev/null 2>&1; then
            C_OFF=`tput sgr0  2>/dev/null`
            C_BOLD=`tput bold 2>/dev/null`
            C_DIM=`tput dim   2>/dev/null`
            C_RED=`tput setaf 1 2>/dev/null`
            C_GRN=`tput setaf 2 2>/dev/null`
            C_YEL=`tput setaf 3 2>/dev/null`
            C_BLU=`tput setaf 4 2>/dev/null`
            C_MAG=`tput setaf 5 2>/dev/null`
            C_CYA=`tput setaf 6 2>/dev/null`
            [ -n "$C_OFF" ] && ORB_UI_COLOR="Y"
        fi
    fi
    if [ "$ORB_UI_COLOR" != "Y" ]; then
        C_OFF="" ; C_BOLD="" ; C_DIM=""
        C_RED="" ; C_GRN="" ; C_YEL="" ; C_BLU="" ; C_CYA="" ; C_MAG=""
    fi

    # --- charset ----------------------------------------------------------
    _utf="N"
    case "$ORB_UI_UTF8" in
        Y|y|YES|yes) _utf="Y" ;;
        N|n|NO|no)   _utf="N" ;;
        *)
            case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
                *UTF-8*|*utf8*|*UTF8*) [ -t 1 ] && _utf="Y" ;;
            esac
            ;;
    esac
    if [ "$_utf" = "Y" ]; then
        _BX_H=`printf '\342\224\200'`   # ─
        _BX_V=`printf '\342\224\202'`   # │
        _BX_TL=`printf '\342\224\214'`  # ┌
        _BX_TR=`printf '\342\224\220'`  # ┐
        _BX_BL=`printf '\342\224\224'`  # └
        _BX_BR=`printf '\342\224\230'`  # ┘
        _BX_ML=`printf '\342\224\234'`  # ├
        _BX_MR=`printf '\342\224\244'`  # ┤
        _BX_DH=`printf '\342\224\200'`
        _BX_DOT=`printf '\302\267'`     # ·
    fi
    ORB_UI_UTF8_ACTIVE="$_utf"
    return 0
}

orb_ui_color_on()  { ORB_COLOR="Y" ; orb_ui_init ; }
orb_ui_color_off() { ORB_COLOR="N" ; orb_ui_init ; }

# ---------------------------------------------------------------------------
# primitivas de linha
# ---------------------------------------------------------------------------
_orb_repeat()
{
    # _orb_repeat <char> <n>
    _c="$1" ; _n="$2" ; _o="" ; _i=0
    while [ $_i -lt $_n ] ; do _o="${_o}${_c}" ; _i=`expr $_i + 1` ; done
    printf "%s" "$_o"
}

orb_rule()
{
    _ch="${1:-$_BX_H}"
    orb_log_raw "`_orb_repeat "$_ch" $ORB_W`"
}

# Aninhar crase dentro de crase e legal no ksh e traicoeiro no sh. Toda linha
# abaixo calcula em variavel antes de compor - custa uma linha a mais e nunca
# mais quebra numa maquina diferente.
_orb_box_line()
{
    # _orb_box_line <esquerda> <direita>
    _n=`expr $ORB_W - 2`
    _f=`_orb_repeat "$_BX_H" $_n`
    orb_log_raw "${1}${_f}${2}"
}

orb_box_top()  { _orb_box_line "$_BX_TL" "$_BX_TR" ; }
orb_box_mid()  { _orb_box_line "$_BX_ML" "$_BX_MR" ; }
orb_box_bot()  { _orb_box_line "$_BX_BL" "$_BX_BR" ; }

# _orb_vislen <texto>  -  comprimento VISIVEL, ignorando sequencias ANSI.
# Sem isso, qualquer linha colorida desalinha a borda direita.
_ORB_ESC=`printf '\033'`

_orb_vislen()
{
    _s=`printf "%s" "$1" | sed "s/${_ORB_ESC}\[[0-9;]*m//g"`
    _n=`printf "%s" "$_s" | wc -c`
    echo "$_n" | tr -d ' '
}

# orb_box_row <texto>  -  preenche ate a borda (ciente de cor)
orb_box_row()
{
    _t="$1"
    _len=`_orb_vislen "$_t"`
    _pad=`expr $ORB_W - 4 - $_len`
    [ "$_pad" -lt 0 ] && _pad=0
    orb_log_raw "${_BX_V} ${_t}`_orb_repeat " " $_pad` ${_BX_V}"
}

# orb_pad_cell <texto> <largura>  -  preenche OU TRUNCA para caber na coluna.
# Truncar e melhor que estourar: um campo longo nao pode empurrar o vizinho.
orb_pad_cell()
{
    _t="$1" ; _w="$2"
    _l=`_orb_vislen "$_t"`
    if [ "$_l" -gt "$_w" ]; then
        _cut=`expr $_w - 1`
        printf "%.${_cut}s~" "$_t"
        return 0
    fi
    _p=`expr $_w - $_l`
    printf "%s%s" "$_t" "`_orb_repeat " " $_p`"
}

# ---------------------------------------------------------------------------
# titulos
# ---------------------------------------------------------------------------
orb_title()
{
    orb_log_raw ""
    orb_box_top
    orb_box_row "`printf '%s' "$*"`"
    orb_box_bot
}

orb_section()
{
    _txt="$*"
    _tl=`_orb_vislen "$_txt"`
    _n=`expr $ORB_W - 6 - $_tl`
    [ "$_n" -lt 0 ] && _n=0
    _f=`_orb_repeat "$_BX_H" $_n`
    orb_log_raw ""
    orb_log_raw "${_BX_ML}${_BX_H}${_BX_H} ${_txt} ${_f}"
}

orb_banner()
{
    orb_log_raw ""
    orb_box_top
    orb_box_row "$*"
    orb_box_bot
    orb_log_raw ""
}

# ---------------------------------------------------------------------------
# campos e itens
# ---------------------------------------------------------------------------
orb_field()
{
    _lbl="$1" ; shift
    _l="`printf '  %-22s %s %s' "$_lbl" "$_BX_DOT" "$*"`"
    orb_log_raw "$_l"
}

orb_item() { orb_log_raw "    $*" ; }

# ---------------------------------------------------------------------------
# badges de estado
#
#  cor     ASCII       significado
#  verde   [  OK  ]    tudo certo
#  amarelo [ AVISO]    atencao, nao bloqueia
#  vermelho[ FALHA]    erro
#  ciano   [ INFO ]    informativo
# ---------------------------------------------------------------------------
orb_badge()
{
    case "$1" in
        ok)    printf "%s[  OK  ]%s" "$C_GRN$C_BOLD" "$C_OFF" ;;
        warn)  printf "%s[ AVISO]%s" "$C_YEL$C_BOLD" "$C_OFF" ;;
        fail)  printf "%s[ FALHA]%s" "$C_RED$C_BOLD" "$C_OFF" ;;
        crit)  printf "%s[ CRIT ]%s" "$C_RED$C_BOLD" "$C_OFF" ;;
        info)  printf "%s[ INFO ]%s" "$C_CYA" "$C_OFF" ;;
        *)     printf "[      ]" ;;
    esac
}

# ---------------------------------------------------------------------------
# confirmacao forte
# ---------------------------------------------------------------------------
orb_confirm()
{
    _q="$1" ; _word="$2"
    if [ "${ORB_ASSUME_YES:-N}" = "Y" ]; then
        orb_warn "Confirmacao dispensada por --yes: $_q"
        return 0
    fi
    orb_log_raw ""
    orb_log_raw "${C_BOLD}${_q}${C_OFF}"
    printf "%sDigite %s%s%s para prosseguir (qualquer outra coisa cancela): %s" \
        "$C_DIM" "$C_OFF$C_BOLD$C_YEL" "$_word" "$C_OFF$C_DIM" "$C_OFF"
    if read _ans; then
        :
    else
        orb_eof_mark
        orb_warn "Fim de stdin durante a confirmacao - operacao CANCELADA."
        return 1
    fi
    if [ "$_ans" = "$_word" ]; then
        orb_log "Operador confirmou: $_word"
        return 0
    fi
    orb_warn "Cancelado pelo operador."
    return 1
}

# ---------------------------------------------------------------------------
# LEITURA DE ENTRADA E FIM DE STDIN
#
# read devolve status != 0 no EOF. Ignorar esse status foi a causa do bug
# corrigido na v1.3: sem TTY (cron, pipe, ssh sem -t, stdin em /dev/null) o
# menu lia EOF, caia no default vazio, nao casava nenhuma opcao e redesenhava
# para sempre - gravando log ate encher o filesystem. Num servidor de banco
# isso derruba /var ou a FRA, ou seja: a ferramenta de resolver incidente
# virava o incidente.
#
# Agora o EOF trava a flag ORB_EOF e todo prompt passa a devolver 1 na hora.
# Quem chama um menu deve encerrar o laco com  || return 0  (ou || break).
# orb_menu_begin tem uma parada dura como ultima linha de defesa.
# ---------------------------------------------------------------------------
ORB_EOF="${ORB_EOF:-N}"

orb_eof_mark()
{
    [ "$ORB_EOF" = "Y" ] && return 0
    ORB_EOF="Y"
    orb_log_raw ""
    orb_log "Fim de stdin (EOF) - encerrando a interacao."
    return 0
}

orb_ask()
{
    _q="$1" ; _def="$2"
    if [ "$ORB_EOF" = "Y" ]; then
        ORB_ANSWER="$_def"
        return 1
    fi
    if [ -n "$_def" ]; then
        printf "%s%s%s [%s%s%s]: " "$C_BOLD" "$_q" "$C_OFF" "$C_CYA" "$_def" "$C_OFF"
    else
        printf "%s%s%s: " "$C_BOLD" "$_q" "$C_OFF"
    fi
    if read ORB_ANSWER; then
        [ -z "$ORB_ANSWER" ] && ORB_ANSWER="$_def"
        return 0
    fi
    ORB_ANSWER="$_def"
    orb_eof_mark
    return 1
}

orb_pause()
{
    [ "${ORB_ASSUME_YES:-N}" = "Y" ] && return 0
    [ "$ORB_EOF" = "Y" ] && return 1
    printf "\n%sENTER para continuar...%s " "$C_DIM" "$C_OFF"
    if read _x; then
        return 0
    fi
    orb_eof_mark
    return 1
}

# ---------------------------------------------------------------------------
# MENU
#
# Duas colunas quando a largura permite. Itens marcados como perigosos saem
# em vermelho, para que uma operacao destrutiva nunca pareca igual a um
# relatorio de leitura.
# ---------------------------------------------------------------------------
ORB_MENU_FILE=""

orb_menu_begin()
{
    # ultima linha de defesa: se o EOF ja foi visto e ainda assim um menu
    # esta sendo montado, algum laco esqueceu o  || return 0 . Sair e a
    # unica resposta segura - redesenhar seria voltar ao loop infinito.
    if [ "$ORB_EOF" = "Y" ]; then
        orb_log "Menu solicitado depois do EOF - encerrando (rc=3)."
        exit 3
    fi
    ORB_MENU_FILE="${ORB_RUNDIR:-/tmp}/.menu.$$"
    : > "$ORB_MENU_FILE"
}

# orb_menu_group <titulo>
orb_menu_group() { printf "G|%s\n" "$1" >> "$ORB_MENU_FILE" ; }

# orb_menu_add <n> <texto> [danger]
orb_menu_add()
{
    printf "I|%s|%s|%s\n" "$1" "$2" "${3:-}" >> "$ORB_MENU_FILE"
}

orb_menu_item() { orb_log_raw "  `printf '%-4s' "$1"` $2" ; }

# orb_menu_render
orb_menu_render()
{
    [ -f "$ORB_MENU_FILE" ] || return 1

    # coluna dupla so acima de 96 colunas reais
    _two=0
    [ "$ORB_W" -ge 94 ] && _two=1

    _colw=`expr \( $ORB_W - 4 \) / 2`
    _pend=""

    while IFS='|' read _k _a _b _c
    do
        case "$_k" in
            G)
                [ -n "$_pend" ] && { orb_log_raw "  $_pend" ; _pend="" ; }
                orb_log_raw ""
                orb_log_raw "  ${C_BOLD}${C_BLU}${_a}${C_OFF}"
                ;;
            I)
                if [ -n "$_c" ]; then
                    _num="${C_RED}${C_BOLD}`printf '%3s' "$_a"`${C_OFF}"
                    _txt="${C_RED}${_b}${C_OFF}"
                    _plain="`printf '%3s' "$_a"`  $_b"
                else
                    _num="${C_BOLD}${C_CYA}`printf '%3s' "$_a"`${C_OFF}"
                    _txt="$_b"
                    _plain="`printf '%3s' "$_a"`  $_b"
                fi
                _cell="  ${_num}  ${_txt}"
                _plen=`_orb_vislen "  $_plain"`

                if [ $_two -eq 1 ]; then
                    if [ -z "$_pend" ]; then
                        _pad=`expr $_colw - $_plen`
                        [ "$_pad" -lt 1 ] && _pad=1
                        _pend="${_cell}`_orb_repeat " " $_pad`"
                    else
                        orb_log_raw "${_pend}${_cell}"
                        _pend=""
                    fi
                else
                    orb_log_raw "$_cell"
                fi
                ;;
        esac
    done < "$ORB_MENU_FILE"

    [ -n "$_pend" ] && orb_log_raw "$_pend"
    rm -f "$ORB_MENU_FILE" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------------------
# orb_status_line <estado> <texto>   estado: ok|warn|fail|crit|info
# ---------------------------------------------------------------------------
orb_status_line()
{
    _s="$1" ; shift
    orb_log_raw "  `orb_badge $_s`  $*"
}

# ---------------------------------------------------------------------------
# orb_progress_bar <atual> <total> [largura]
#
# Sem cursor addressing: imprime uma linha nova. Serve para relatorio, nao
# para animacao - console serial nao lida bem com \r em log redirecionado.
# ---------------------------------------------------------------------------
orb_progress_bar()
{
    _cur="$1" ; _tot="$2" ; _bw="${3:-40}"
    case "$_tot" in ''|0|*[!0-9]*) return 1 ;; esac
    case "$_cur" in ''|*[!0-9]*) _cur=0 ;; esac
    _pct=`expr $_cur \* 100 / $_tot`
    _fill=`expr $_cur \* $_bw / $_tot`
    [ "$_fill" -gt "$_bw" ] && _fill=$_bw
    _rest=`expr $_bw - $_fill`
    if [ "$ORB_UI_UTF8_ACTIVE" = "Y" ]; then
        _fc=`printf '\342\226\210'` ; _ec=`printf '\342\226\221'`
    else
        _fc="#" ; _ec="."
    fi
    printf "  [%s%s] %3s%%  (%s/%s)\n" \
        "`_orb_repeat "$_fc" $_fill`" "`_orb_repeat "$_ec" $_rest`" \
        "$_pct" "$_cur" "$_tot"
}
