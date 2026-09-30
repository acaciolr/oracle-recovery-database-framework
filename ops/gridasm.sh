#!/usr/bin/sh
###############################################################################
# ops/gridasm.sh - GRID INFRASTRUCTURE, ASM, OCR E VOTING DISK
#
# Em RAC, metade dos desastres nao e do banco: e do clusterware. Perder o OCR,
# perder o voting disk, perder o spfile do ASM ou desmontar um diskgroup
# derruba tudo, e nenhum backup RMAN de banco resolve.
#
# Este modulo cuida da camada de baixo:
#
#   - OCR            backup automatico, backup manual, restore
#   - Voting disk    listagem e substituicao
#   - ASM spfile     onde esta, como salvar, como restaurar
#   - ASM metadata   md_backup / md_restore (a estrutura do diskgroup)
#   - Diskgroups     estado, espaco, rebalance, mount/dismount
#   - Recursos CRS   o que esta no ar e o que caiu
#
# Quase tudo aqui exige ROOT ou o usuario do Grid. O framework NAO tenta
# escalar privilegio sozinho: quando o comando precisa de root, ele e exibido
# para execucao manual, com o caminho completo.
###############################################################################

orb_op_gridasm_menu()
{
    while :
    do
        orb_title "GRID INFRASTRUCTURE / ASM / OCR"
        orb_field "RAC"        "$ORB_D_RAC"
        orb_field "Grid Home"  "`_orb_or_na "$ORB_D_GRIDHOME"`"
        orb_field "Clusterware" "$ORB_D_CRS"
        orb_field "ASM"        "$ORB_D_ASM"
        orb_log_raw ""

        orb_menu_begin
        orb_menu_group "SITUACAO (somente leitura)"
        orb_menu_add  1 "Estado do clusterware e dos recursos"
        orb_menu_add  2 "Diskgroups: espaco, redundancia, discos"
        orb_menu_add  3 "OCR: localizacao e integridade"
        orb_menu_add  4 "Voting disks"
        orb_menu_add  5 "Onde esta o spfile do ASM"

        orb_menu_group "PROTEGER (fazer ANTES do problema)"
        orb_menu_add  6 "Backup manual do OCR"                    danger
        orb_menu_add  7 "Backup dos metadados do ASM (md_backup)" danger
        orb_menu_add  8 "Backup do spfile do ASM"                 danger
        orb_menu_add  9 "Listar backups automaticos do OCR"

        orb_menu_group "RESTAURAR (roteiros guiados)"
        orb_menu_add 10 "Restore do OCR"                          danger
        orb_menu_add 11 "Substituir/recriar voting disk"          danger
        orb_menu_add 12 "Restore dos metadados do ASM (md_restore)" danger
        orb_menu_add 13 "Restore do spfile do ASM"                danger

        orb_menu_group "OPERACAO DE DISKGROUP"
        orb_menu_add 14 "Montar / desmontar diskgroup"            danger
        orb_menu_add 15 "Acompanhar rebalance"
        orb_menu_add 16 "Discos com problema (offline / forcing)"
        orb_menu_add  0 "Voltar"
        orb_menu_render
        orb_log_raw ""

        orb_ask "Opcao" "1" || return 0
        case "$ORB_ANSWER" in
            1)  orb_grid_status ;;
            2)  orb_asm_diskgroups ;;
            3)  orb_ocr_status ;;
            4)  orb_voting_status ;;
            5)  orb_asm_spfile_where ;;
            6)  orb_ocr_backup ;;
            7)  orb_asm_md_backup ;;
            8)  orb_asm_spfile_backup ;;
            9)  orb_ocr_list_backups ;;
            10) orb_ocr_restore ;;
            11) orb_voting_replace ;;
            12) orb_asm_md_restore ;;
            13) orb_asm_spfile_restore ;;
            14) orb_asm_dg_mount ;;
            15) orb_asm_rebalance ;;
            16) orb_asm_bad_disks ;;
            0)  return 0 ;;
            "") ;;
            *)  orb_warn "Opcao invalida." ;;
        esac
        orb_pause
    done
}

# ---------------------------------------------------------------------------
# helper: exige Grid Home localizado
# ---------------------------------------------------------------------------
orb_grid_require()
{
    if [ -z "$ORB_D_GRIDHOME" ]; then
        orb_err "Grid Home nao localizado."
        orb_item "Procuro em /etc/oracle/olr.loc e /var/opt/oracle/olr.loc."
        orb_item "Defina ORB_D_GRIDHOME manualmente se o cluster usa outro caminho."
        return 1
    fi
    if [ ! -x "$ORB_D_GRIDHOME/bin/crsctl" ]; then
        orb_err "crsctl nao encontrado em $ORB_D_GRIDHOME/bin"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 1 - ESTADO DO CLUSTERWARE
# ---------------------------------------------------------------------------
orb_grid_status()
{
    orb_grid_require || return 1

    orb_section "crsctl check crs"
    _o="$ORB_RUNDIR/grid_check.out"
    "$ORB_D_GRIDHOME/bin/crsctl" check crs > "$_o" 2>&1
    _rc=$?
    while IFS= read _l ; do orb_log_raw "  $_l" ; done < "$_o"
    orb_log_file "$_o"

    if [ $_rc -ne 0 ]; then
        orb_err "crsctl retornou $_rc - clusterware NAO esta saudavel."
        orb_item "Sem CRS, o estado do banco nao pode ser avaliado por srvctl."
        orb_item "Isto nao e o mesmo que 'banco parado'. Resolva o CRS primeiro."
        return 1
    fi
    for _c in CRS-4638 CRS-4537 CRS-4529
    do
        grep "$_c" "$_o" >/dev/null 2>&1 || orb_warn "componente ausente: $_c"
    done

    orb_section "RECURSOS COM PROBLEMA"
    _r="$ORB_RUNDIR/grid_res.out"
    "$ORB_D_GRIDHOME/bin/crsctl" stat res -t > "$_r" 2>&1
    orb_log_file "$_r"
    _bad=0
    grep -i "OFFLINE\|INTERMEDIATE\|UNKNOWN" "$_r" > "$ORB_RUNDIR/grid_bad.out" 2>/dev/null
    if [ -s "$ORB_RUNDIR/grid_bad.out" ]; then
        while IFS= read _l ; do orb_log_raw "  $_l" ; done < "$ORB_RUNDIR/grid_bad.out"
        _bad=1
    else
        orb_ok "Todos os recursos ONLINE."
    fi

    orb_section "NODES"
    "$ORB_D_GRIDHOME/bin/olsnodes" -n -s -t 2>/dev/null \
        | while IFS= read _l ; do orb_log_raw "  $_l" ; done

    orb_section "VERSAO DO CLUSTER"
    _v=`"$ORB_D_GRIDHOME/bin/crsctl" query crs activeversion 2>/dev/null`
    orb_field "Active version" "`_orb_or_na "$_v"`"

    [ $_bad -eq 1 ] && orb_item "Veja o relatorio completo em $_r"
    return 0
}

# ---------------------------------------------------------------------------
# 2 - DISKGROUPS
# ---------------------------------------------------------------------------
orb_asm_diskgroups()
{
    orb_section "DISKGROUPS"
    if [ "$ORB_D_ASM" != "Y" ]; then
        orb_warn "ASM nao detectado a partir deste banco."
        orb_item "Se o ASM existe mas nao aparece, conecte com o usuario do Grid."
        return 1
    fi

    orb_log_raw "  `printf '%-16s %-12s %10s %10s %6s %6s' NOME TIPO TOTAL_MB LIVRE_MB DISCOS %%LIVRE`"
    orb_sql_query "select 'ORBR|'||name||'|'||type||'|'||to_char(total_mb)||'|'||to_char(free_mb)||'|'||
                          to_char((select count(*) from v\$asm_disk d where d.group_number=g.group_number))||'|'||
                          to_char(round(free_mb*100/decode(total_mb,0,1,total_mb)))
                     from v\$asm_diskgroup g order by name;" \
        | while IFS='|' read _n _t _tm _fm _nd _pc
        do
            orb_log_raw "  `printf '%-16s %-12s %10s %10s %6s %5s%%' "$_n" "$_t" "$_tm" "$_fm" "$_nd" "$_pc"`"
        done

    orb_section "ESPACO UTILIZAVEL APOS FALHA DE DISCO"
    orb_sql_query "select 'ORBR|'||name||'|'||to_char(required_mirror_free_mb)||'|'||to_char(usable_file_mb)
                     from v\$asm_diskgroup order by name;" \
        | while IFS='|' read _n _rq _us
        do
            orb_field "$_n" "usable=$_us MB (reserva de mirror: $_rq MB)"
            case "$_us" in
                -*) orb_err "  $_n com usable_file_mb NEGATIVO: nao sobrevive a perda de um disco." ;;
            esac
        done
    orb_item "usable_file_mb negativo significa que a redundancia ja nao pode ser"
    orb_item "restaurada apos uma falha - trate como incidente, nao como aviso."

    orb_section "DISKGROUPS NAO MONTADOS NESTE NODE"
    orb_sql_query "select 'ORBR|'||name||'|'||state from v\$asm_diskgroup where state<>'MOUNTED' and state<>'CONNECTED';" \
        | while IFS='|' read _n _s ; do orb_warn "  $_n esta $_s" ; done
    return 0
}

# ---------------------------------------------------------------------------
# 3 - OCR
# ---------------------------------------------------------------------------
orb_ocr_status()
{
    orb_grid_require || return 1

    orb_section "LOCALIZACAO DO OCR"
    for _f in /etc/oracle/ocr.loc /var/opt/oracle/ocr.loc
    do
        [ -f "$_f" ] || continue
        orb_field "Arquivo" "$_f"
        grep -v "^#" "$_f" 2>/dev/null | while IFS= read _l
        do
            [ -n "$_l" ] && orb_item "$_l"
        done
    done

    orb_section "ocrcheck"
    if [ -x "$ORB_D_GRIDHOME/bin/ocrcheck" ]; then
        _o="$ORB_RUNDIR/ocrcheck.out"
        "$ORB_D_GRIDHOME/bin/ocrcheck" > "$_o" 2>&1
        _rc=$?
        while IFS= read _l ; do orb_log_raw "  $_l" ; done < "$_o"
        orb_log_file "$_o"
        if [ $_rc -ne 0 ]; then
            orb_warn "ocrcheck retornou $_rc."
            orb_item "A verificacao logica completa exige root:"
            orb_item "  $ORB_D_GRIDHOME/bin/ocrcheck"
        fi
        grep -i "integrity check succeeded" "$_o" >/dev/null 2>&1 \
            && orb_ok "Integridade do OCR verificada." \
            || orb_warn "Nao confirmei 'integrity check succeeded' na saida."
    else
        orb_warn "ocrcheck nao encontrado."
    fi

    orb_section "REDUNDANCIA"
    orb_item "Um unico OCR e ponto unico de falha. Em producao, use pelo menos"
    orb_item "dois locais (ou um diskgroup com redundancia NORMAL/HIGH)."
    orb_item "Adicionar um espelho (como root):"
    orb_item "  $ORB_D_GRIDHOME/bin/ocrconfig -add +OCRDG2"
    return 0
}

orb_ocr_list_backups()
{
    orb_grid_require || return 1

    orb_section "BACKUPS AUTOMATICOS DO OCR"
    orb_item "O clusterware faz backup do OCR sozinho a cada 4 horas e mantem"
    orb_item "diario e semanal. Isso NAO dispensa backup manual antes de mudanca."
    orb_log_raw ""
    _o="$ORB_RUNDIR/ocr_backups.out"
    "$ORB_D_GRIDHOME/bin/ocrconfig" -showbackup > "$_o" 2>&1
    while IFS= read _l ; do orb_log_raw "  $_l" ; done < "$_o"
    orb_log_file "$_o"

    if [ ! -s "$_o" ]; then
        orb_warn "Sem saida - o comando pode exigir root."
        orb_item "  $ORB_D_GRIDHOME/bin/ocrconfig -showbackup"
    fi
    return 0
}

orb_ocr_backup()
{
    orb_title "BACKUP MANUAL DO OCR"
    orb_grid_require || return 1

    orb_ask "Diretorio de destino (vazio = local padrao do CRS)" ""
    _d="$ORB_ANSWER"

    if [ -n "$_d" ]; then
        _cmd="$ORB_D_GRIDHOME/bin/ocrconfig -manualbackup"
        _extra="$ORB_D_GRIDHOME/bin/ocrconfig -backuploc $_d"
    else
        _cmd="$ORB_D_GRIDHOME/bin/ocrconfig -manualbackup"
        _extra=""
    fi

    orb_plan_begin "BACKUP MANUAL DO OCR"
    orb_plan_field "Grid Home" "$ORB_D_GRIDHOME"
    [ -n "$_d" ] && orb_plan_field "Destino" "$_d"
    [ -n "$_extra" ] && orb_plan_cmd "Definir local do backup (root)" "$_extra"
    orb_plan_cmd "Backup manual (root)" "$_cmd"
    orb_plan_risk "EXIGE ROOT. Nao executo por voce."
    orb_plan_risk "Faca isto ANTES de: adicionar/remover node, aplicar patch de GI,"
    orb_plan_risk "mudar recursos do cluster ou mexer em diskgroup do OCR."
    orb_plan_confirm "MOSTRAR-COMANDO" >/dev/null

    orb_section "EXECUTE COMO ROOT"
    [ -n "$_extra" ] && orb_log_raw "  $_extra"
    orb_log_raw "  $_cmd"
    orb_log_raw "  $ORB_D_GRIDHOME/bin/ocrconfig -showbackup"
    orb_log_raw ""
    orb_item "Guarde a saida: o nome do arquivo de backup e o que voce vai"
    orb_item "precisar informar no restore."
    return 0
}

orb_ocr_restore()
{
    orb_title "RESTORE DO OCR"
    orb_grid_require || return 1

    orb_log_raw ""
    orb_status_line crit "Restore de OCR derruba o CLUSTER INTEIRO."
    orb_item "Todos os nodes precisam ter o CRS parado. Nao ha restore parcial."
    orb_log_raw ""

    orb_ask "Caminho do backup do OCR (backup_NNNNNN_NNNNNN.ocr)" ""
    _b="$ORB_ANSWER"
    [ -z "$_b" ] && { orb_err "Sem o caminho do backup nao ha o que restaurar." ; return 1 ; }

    _nodes="${ORB_D_NODES:-<todos os nodes>}"

    orb_plan_begin "RESTORE DO OCR"
    orb_plan_field "Backup"     "$_b"
    orb_plan_field "Grid Home"  "$ORB_D_GRIDHOME"
    orb_plan_field "Nodes"      "$_nodes"
    orb_plan_cmd "Roteiro" "ver a sequencia abaixo"
    orb_plan_risk "EXIGE ROOT EM TODOS OS NODES."
    orb_plan_risk "O cluster inteiro fica fora durante a operacao."
    orb_plan_risk "Se o OCR estiver em ASM, o diskgroup precisa estar montado -"
    orb_plan_risk "e isso pode exigir subir o CRS em modo exclusivo antes."
    orb_plan_risk "Um OCR restaurado de um backup antigo desconhece recursos"
    orb_plan_risk "criados depois: bancos, servicos e listeners podem sumir da"
    orb_plan_risk "configuracao. Tenha 'crsctl stat res -t' salvo ANTES."
    orb_plan_confirm "MOSTRAR-ROTEIRO" >/dev/null

    orb_section "ROTEIRO (execute como root)"
    orb_log_raw "  1. Em TODOS os nodes, parar o clusterware:"
    orb_log_raw "     $ORB_D_GRIDHOME/bin/crsctl stop crs -f"
    orb_log_raw ""
    orb_log_raw "  2. Em UM node, subir o CRS em modo exclusivo (sem CRSD):"
    orb_log_raw "     $ORB_D_GRIDHOME/bin/crsctl start crs -excl -nocrs"
    orb_log_raw ""
    orb_log_raw "  3. Se o OCR estiver em ASM, montar o diskgroup:"
    orb_log_raw "     asmcmd mount <DG_DO_OCR>"
    orb_log_raw ""
    orb_log_raw "  4. Restaurar:"
    orb_log_raw "     $ORB_D_GRIDHOME/bin/ocrconfig -restore $_b"
    orb_log_raw ""
    orb_log_raw "  5. Conferir:"
    orb_log_raw "     $ORB_D_GRIDHOME/bin/ocrcheck"
    orb_log_raw ""
    orb_log_raw "  6. Parar o CRS exclusivo:"
    orb_log_raw "     $ORB_D_GRIDHOME/bin/crsctl stop crs -f"
    orb_log_raw ""
    orb_log_raw "  7. Subir normalmente em TODOS os nodes:"
    orb_log_raw "     $ORB_D_GRIDHOME/bin/crsctl start crs"
    orb_log_raw ""
    orb_log_raw "  8. Validar:"
    orb_log_raw "     $ORB_D_GRIDHOME/bin/crsctl stat res -t"
    orb_log_raw "     $ORB_D_GRIDHOME/bin/cluvfy comp ocr -n all"

    orb_section "DEPOIS"
    orb_item "Compare 'crsctl stat res -t' com o que voce salvou antes."
    orb_item "Bancos ausentes voltam com:  srvctl add database ..."
    orb_item "Confira tambem os servicos:  srvctl config service -db <DB>"
    return 0
}

# ---------------------------------------------------------------------------
# 4 - VOTING DISK
# ---------------------------------------------------------------------------
orb_voting_status()
{
    orb_grid_require || return 1

    orb_section "VOTING DISKS"
    _o="$ORB_RUNDIR/votedisk.out"
    "$ORB_D_GRIDHOME/bin/crsctl" query css votedisk > "$_o" 2>&1
    while IFS= read _l ; do orb_log_raw "  $_l" ; done < "$_o"
    orb_log_file "$_o"

    _n=`grep -c "^ *[0-9]" "$_o" 2>/dev/null`
    _n=`orb_trim "$_n"`
    orb_field "Quantidade" "`_orb_or_na "$_n"`"
    case "$_n" in
        1) orb_warn "Um unico voting disk e ponto unico de falha." ;;
        2) orb_warn "Numero PAR de voting disks nao ajuda no quorum - use 3 ou 5." ;;
    esac

    orb_section "COMO FUNCIONA"
    orb_item "O node precisa enxergar MAIS DA METADE dos voting disks para"
    orb_item "continuar no cluster. Com 3, sobrevive a perda de 1."
    orb_item "Voting disk NAO tem backup por arquivo desde a 11.2: ele e"
    orb_item "reconstruido a partir do OCR quando voce recria o diskgroup."
    return 0
}

orb_voting_replace()
{
    orb_title "SUBSTITUIR / RECRIAR VOTING DISK"
    orb_grid_require || return 1

    orb_ask "Diskgroup de destino (ex: +OCRVOTE)" ""
    _dg="$ORB_ANSWER"
    [ -z "$_dg" ] && return 1

    orb_plan_begin "REPLACE VOTING DISK EM $_dg"
    orb_plan_field "Diskgroup" "$_dg"
    orb_plan_cmd "Comando (root)" "$ORB_D_GRIDHOME/bin/crsctl replace votedisk $_dg"
    orb_plan_risk "EXIGE ROOT."
    orb_plan_risk "O diskgroup precisa estar MONTADO e com redundancia adequada:"
    orb_plan_risk "  EXTERNAL = 1 voting disk   NORMAL = 3   HIGH = 5"
    orb_plan_risk "Se a redundancia do diskgroup nao comportar, o comando falha."
    orb_plan_risk "Faca backup do OCR antes - o voting disk e reconstruido a"
    orb_plan_risk "partir dele."
    orb_plan_confirm "MOSTRAR-COMANDO" >/dev/null

    orb_section "EXECUTE COMO ROOT"
    orb_log_raw "  $ORB_D_GRIDHOME/bin/ocrconfig -manualbackup"
    orb_log_raw "  $ORB_D_GRIDHOME/bin/crsctl replace votedisk $_dg"
    orb_log_raw "  $ORB_D_GRIDHOME/bin/crsctl query css votedisk"
    orb_log_raw ""
    orb_item "Nao e preciso parar o cluster para o replace, mas faca em janela."
    return 0
}

# ---------------------------------------------------------------------------
# 5 / 8 / 13 - SPFILE DO ASM
# ---------------------------------------------------------------------------
orb_asm_spfile_where()
{
    orb_section "SPFILE DA INSTANCIA ASM"
    if [ -n "$ORB_D_GRIDHOME" ] && [ -x "$ORB_D_GRIDHOME/bin/asmcmd" ]; then
        _o="$ORB_RUNDIR/asm_spfile.out"
        echo "spget" | "$ORB_D_GRIDHOME/bin/asmcmd" > "$_o" 2>&1
        while IFS= read _l ; do orb_log_raw "  $_l" ; done < "$_o"
        orb_log_file "$_o"
    else
        orb_warn "asmcmd nao disponivel - rode com o usuario do Grid."
    fi

    orb_section "POR QUE ISSO IMPORTA"
    orb_item "Se o spfile do ASM vive dentro de um diskgroup e aquele diskgroup"
    orb_item "nao monta, a instancia ASM nao sobe - e sem ASM nao ha banco."
    orb_item "E um ciclo que so quebra com uma copia pfile fora do ASM."
    orb_item "Guarde SEMPRE um pfile de emergencia em filesystem local."
    return 0
}

orb_asm_spfile_backup()
{
    orb_title "BACKUP DO SPFILE DO ASM"
    orb_grid_require || return 1

    orb_ask "Destino do pfile de emergencia" "/home/grid/initASM_emergencia.ora"
    _d="$ORB_ANSWER"

    orb_plan_begin "BACKUP DO SPFILE DO ASM"
    orb_plan_field "Destino" "$_d"
    orb_plan_cmd "Com o usuario do Grid" "sqlplus / as sysasm
  create pfile='$_d' from spfile;
  exit"
    orb_plan_risk "Guarde este arquivo FORA do ASM e fora do diskgroup do OCR."
    orb_plan_risk "Ele e o que permite subir o ASM quando o diskgroup nao monta."
    orb_plan_confirm "MOSTRAR-COMANDO" >/dev/null

    orb_section "EXECUTE COM O USUARIO DO GRID"
    orb_log_raw "  export ORACLE_HOME=$ORB_D_GRIDHOME"
    orb_log_raw "  export ORACLE_SID=+ASM1        # ajuste o numero do node"
    orb_log_raw "  \$ORACLE_HOME/bin/sqlplus / as sysasm"
    orb_log_raw "  SQL> create pfile='$_d' from spfile;"
    orb_log_raw ""
    orb_item "Repita em cada node - o SID muda (+ASM1, +ASM2)."
    return 0
}

orb_asm_spfile_restore()
{
    orb_title "RESTORE DO SPFILE DO ASM"
    orb_grid_require || return 1

    orb_ask "Pfile de emergencia (origem)" "/home/grid/initASM_emergencia.ora"
    _p="$ORB_ANSWER"
    orb_ask "Diskgroup de destino do spfile" "+OCRVOTE"
    _dg="$ORB_ANSWER"

    orb_plan_begin "RESTORE DO SPFILE DO ASM"
    orb_plan_field "Pfile"     "$_p"
    orb_plan_field "Diskgroup" "$_dg"
    orb_plan_cmd "Roteiro" "ver abaixo"
    orb_plan_risk "A instancia ASM sera reiniciada - e com ela, tudo neste node."
    orb_plan_risk "Em RAC, faca um node de cada vez."
    orb_plan_confirm "MOSTRAR-ROTEIRO" >/dev/null

    orb_section "ROTEIRO (usuario do Grid, exceto onde indicado)"
    orb_log_raw "  export ORACLE_HOME=$ORB_D_GRIDHOME"
    orb_log_raw "  export ORACLE_SID=+ASM1"
    orb_log_raw ""
    orb_log_raw "  # 1. subir o ASM com o pfile de emergencia"
    orb_log_raw "  sqlplus / as sysasm"
    orb_log_raw "  SQL> startup pfile='$_p';"
    orb_log_raw ""
    orb_log_raw "  # 2. recriar o spfile dentro do diskgroup"
    orb_log_raw "  SQL> create spfile='$_dg' from pfile='$_p';"
    orb_log_raw ""
    orb_log_raw "  # 3. apontar o CRS para o novo spfile (root)"
    orb_log_raw "  asmcmd spset $_dg/ASM/ASMPARAMETERFILE/registry.253.XXXXXXXXX"
    orb_log_raw ""
    orb_log_raw "  # 4. reiniciar o stack neste node (root)"
    orb_log_raw "  $ORB_D_GRIDHOME/bin/crsctl stop crs"
    orb_log_raw "  $ORB_D_GRIDHOME/bin/crsctl start crs"
    orb_log_raw ""
    orb_item "O nome exato do registry sai de 'asmcmd spget' apos o create spfile."
    return 0
}

# ---------------------------------------------------------------------------
# 7 / 12 - METADADOS DO ASM
# ---------------------------------------------------------------------------
orb_asm_md_backup()
{
    orb_title "BACKUP DOS METADADOS DO ASM (md_backup)"
    orb_grid_require || return 1

    orb_item "md_backup salva a ESTRUTURA do diskgroup: nome, redundancia, AU"
    orb_item "size, discos, failgroups, atributos, diretorios e aliases."
    orb_item "NAO salva os dados. Serve para RECRIAR o diskgroup identico depois"
    orb_item "de uma perda de storage - e entao restaurar o banco com RMAN."
    orb_log_raw ""

    orb_ask "Arquivo de saida" "/home/grid/asm_md_`orb_timestamp`.bkp"
    _f="$ORB_ANSWER"
    orb_ask "Diskgroups (separados por virgula, vazio = todos)" ""
    _g=""
    [ -n "$ORB_ANSWER" ] && _g=" -G $ORB_ANSWER"

    orb_plan_begin "MD_BACKUP DOS DISKGROUPS"
    orb_plan_field "Arquivo"    "$_f"
    orb_plan_field "Diskgroups" "${ORB_ANSWER:-todos}"
    orb_plan_cmd "Com o usuario do Grid" "asmcmd md_backup $_f$_g"
    orb_plan_risk "Guarde o arquivo FORA do ASM - senao ele some junto."
    orb_plan_risk "Refaca o backup sempre que adicionar disco ou diskgroup."
    orb_plan_confirm "MOSTRAR-COMANDO" >/dev/null

    orb_section "EXECUTE COM O USUARIO DO GRID"
    orb_log_raw "  export ORACLE_HOME=$ORB_D_GRIDHOME"
    orb_log_raw "  export ORACLE_SID=+ASM1"
    orb_log_raw "  \$ORACLE_HOME/bin/asmcmd md_backup $_f$_g"
    orb_log_raw ""
    orb_item "Copie o arquivo para fora do servidor tambem."
    return 0
}

orb_asm_md_restore()
{
    orb_title "RESTORE DOS METADADOS DO ASM (md_restore)"
    orb_grid_require || return 1

    orb_ask "Arquivo de backup do md_backup" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _f="$ORB_ANSWER"

    orb_ask "Diskgroup a recriar (vazio = todos do arquivo)" ""
    _g=""
    [ -n "$ORB_ANSWER" ] && _g=" -G $ORB_ANSWER"

    orb_ask "Modo [full|nodg|newdg]" "full"
    _m=`orb_lower "$ORB_ANSWER"`
    case "$_m" in
        full|nodg|newdg) : ;;
        *) orb_err "Modo invalido." ; return 1 ;;
    esac

    orb_plan_begin "MD_RESTORE ($_m)"
    orb_plan_field "Arquivo"    "$_f"
    orb_plan_field "Modo"       "$_m"
    orb_plan_cmd "Com o usuario do Grid" "asmcmd md_restore $_f --full$_g"
    orb_plan_risk "full  = CRIA o diskgroup do zero. Se ja existir, falha."
    orb_plan_risk "nodg  = restaura so os diretorios/aliases num DG existente."
    orb_plan_risk "newdg = cria com outro nome (use --newdg / -o)."
    orb_plan_risk "MD_RESTORE NAO TRAZ DADOS DE VOLTA. Depois dele, o diskgroup"
    orb_plan_risk "esta vazio: o banco vem do RMAN, os arquivos do Grid vem do"
    orb_plan_risk "restore do OCR/spfile."
    orb_plan_risk "Confirme que os DISCOS estao apresentados ao SO e com as"
    orb_plan_risk "permissoes certas antes - senao o create diskgroup falha."
    orb_plan_confirm "MOSTRAR-COMANDO" >/dev/null

    orb_section "EXECUTE COM O USUARIO DO GRID"
    orb_log_raw "  export ORACLE_HOME=$ORB_D_GRIDHOME"
    orb_log_raw "  export ORACLE_SID=+ASM1"
    orb_log_raw "  # conferir o conteudo do backup antes:"
    orb_log_raw "  \$ORACLE_HOME/bin/asmcmd lsdg"
    orb_log_raw "  \$ORACLE_HOME/bin/asmcmd md_restore $_f --$_m$_g"
    orb_log_raw ""
    orb_section "ORDEM DE UM DESASTRE COMPLETO DE STORAGE"
    orb_item "1. Discos apresentados e com owner/permissao corretos"
    orb_item "2. md_restore recria os diskgroups vazios"
    orb_item "3. restore do OCR e do spfile do ASM"
    orb_item "4. subir o clusterware"
    orb_item "5. RMAN restaura os bancos"
    orb_item "6. conferir tempfiles, servicos e jobs"
    return 0
}

# ---------------------------------------------------------------------------
# 14 - MOUNT / DISMOUNT
# ---------------------------------------------------------------------------
orb_asm_dg_mount()
{
    orb_title "MONTAR / DESMONTAR DISKGROUP"
    orb_asm_diskgroups >/dev/null 2>&1

    orb_sql_query "select 'ORBR|'||name||'|'||state from v\$asm_diskgroup order by name;" \
        | while IFS='|' read _n _s ; do orb_field "$_n" "$_s" ; done
    orb_log_raw ""

    orb_ask "Diskgroup (sem o +)" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _dg="$ORB_ANSWER"
    orb_ask "Acao [MOUNT|DISMOUNT|MOUNT FORCE|DISMOUNT FORCE]" "MOUNT"
    _act=`orb_upper "$ORB_ANSWER"`

    orb_plan_begin "$_act NO DISKGROUP $_dg"
    orb_plan_field "Diskgroup" "$_dg"
    orb_plan_field "Acao"      "$_act"
    orb_plan_cmd "Com o usuario do Grid (sysasm)" "alter diskgroup $_dg $_act;"
    case "$_act" in
        DISMOUNT*)
            orb_plan_risk "TUDO que estiver nesse diskgroup fica inacessivel:"
            orb_plan_risk "datafiles, redo, controlfile, archives, OCR, voting."
            orb_plan_risk "Se houver banco aberto usando o diskgroup, ele cai."
            orb_plan_risk "FORCE desmonta mesmo com arquivos abertos - use so quando"
            orb_plan_risk "souber exatamente o que esta perdendo."
            ;;
        *)
            orb_plan_risk "MOUNT FORCE monta com discos faltando: o diskgroup fica"
            orb_plan_risk "montado mas com redundancia comprometida. Trate como"
            orb_plan_risk "medida temporaria, nao como solucao."
            ;;
    esac
    orb_plan_confirm "MOSTRAR-COMANDO" >/dev/null

    orb_section "EXECUTE COM O USUARIO DO GRID"
    orb_log_raw "  export ORACLE_SID=+ASM1"
    orb_log_raw "  sqlplus / as sysasm"
    orb_log_raw "  SQL> alter diskgroup $_dg $_act;"
    orb_log_raw ""
    orb_item "Em RAC, monte em todos os nodes:  srvctl start diskgroup -g $_dg"
    return 0
}

# ---------------------------------------------------------------------------
# 15 - REBALANCE
# ---------------------------------------------------------------------------
orb_asm_rebalance()
{
    orb_section "OPERACOES DE REBALANCE EM ANDAMENTO"
    _n=`orb_sql_value "(select to_char(count(*)) from v\\$asm_operation)"`
    orb_field "Operacoes ativas" "`_orb_or_na "$_n"`"

    if [ -z "$_n" ] || [ "$_n" = "0" ]; then
        orb_ok "Nenhum rebalance em andamento."
    else
        orb_sql_query "select 'ORBR|'||g.name||'|'||o.operation||'|'||o.state||'|'||
                              to_char(o.sofar)||'|'||to_char(o.est_work)||'|'||to_char(o.est_minutes)||'|'||to_char(o.power)
                         from v\$asm_operation o, v\$asm_diskgroup g
                        where o.group_number = g.group_number;" \
            | while IFS='|' read _g _op _st _so _tw _em _pw
            do
                orb_field "$_g" "$_op $_st power=$_pw"
                orb_item "progresso: $_so de $_tw AU  -  faltam ~$_em min"
            done
        orb_item "Aumentar o power acelera e consome mais I/O:"
        orb_item "  alter diskgroup <DG> rebalance power <1-1024>;"
    fi

    orb_section "DISCOS EM DESEQUILIBRIO"
    orb_sql_query "select 'ORBR|'||g.name||'|'||to_char(min(round(d.free_mb*100/decode(d.total_mb,0,1,d.total_mb))))||'|'||
                          to_char(max(round(d.free_mb*100/decode(d.total_mb,0,1,d.total_mb))))
                     from v\$asm_disk d, v\$asm_diskgroup g
                    where d.group_number=g.group_number and d.total_mb>0
                    group by g.name;" \
        | while IFS='|' read _g _mn _mx
        do
            orb_field "$_g" "livre por disco: ${_mn}% a ${_mx}%"
        done
    orb_item "Diferenca grande entre o menor e o maior indica rebalance pendente"
    orb_item "ou interrompido."
    return 0
}

# ---------------------------------------------------------------------------
# 16 - DISCOS COM PROBLEMA
# ---------------------------------------------------------------------------
orb_asm_bad_disks()
{
    orb_section "DISCOS FORA DE NORMAL/CACHED"
    _n=0
    orb_sql_query "select 'ORBR|'||nvl(g.name,'<sem grupo>')||'|'||nvl(d.name,d.path)||'|'||d.mode_status||'|'||d.state||'|'||d.header_status
                     from v\$asm_disk d, v\$asm_diskgroup g
                    where d.group_number = g.group_number(+)
                      and (d.mode_status <> 'ONLINE' or d.state <> 'NORMAL' or d.header_status <> 'MEMBER');" \
        | while IFS='|' read _g _d _m _s _h
        do
            orb_log_raw "  $_g / $_d  mode=$_m state=$_s header=$_h"
        done

    orb_section "DISCOS CANDIDATOS (nao pertencem a nenhum diskgroup)"
    orb_sql_query "select 'ORBR|'||path||'|'||header_status||'|'||to_char(os_mb)
                     from v\$asm_disk where group_number=0 order by path;" \
        | while IFS='|' read _p _h _m
        do
            orb_log_raw "  `printf '%-40s %-12s %8s MB' "$_p" "$_h" "$_m"`"
        done

    orb_section "O QUE SIGNIFICA"
    orb_item "header_status=CANDIDATE ou PROVISIONED : disco livre, pode entrar."
    orb_item "header_status=FORMER    : ja pertenceu a um diskgroup e foi removido."
    orb_item "header_status=MEMBER com group_number=0 : o ASM enxerga o disco mas"
    orb_item "  NAO consegue associa-lo - tipico de disco de outro cluster, de"
    orb_item "  LUN duplicada ou de permissao errada no dispositivo."
    orb_item "mode_status=OFFLINE : o ASM parou de usar o disco. Se passar de"
    orb_item "  disk_repair_time, ele e removido e sera preciso rebalance completo."
    orb_log_raw ""
    orb_item "Religar um disco que voltou:"
    orb_item "  alter diskgroup <DG> online disk <DISCO>;"
    orb_item "Conferir a janela de reparo:"
    orb_item "  select name, value from v\$asm_attribute where name='disk_repair_time';"
    return 0
}
