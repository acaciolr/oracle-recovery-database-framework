#!/usr/bin/sh
###############################################################################
# ops/validate_backup.sh - validacao de backup
#
# LEIA ISTO ANTES DE CONFIAR NO RESULTADO:
#
# RESTORE ... PREVIEW e RESTORE ... VALIDATE HEADER consultam o REPOSITORIO
# (catalogo ou controlfile). Eles dizem que o RMAN acha que os pieces existem.
# NAO provam que a midia responde.
#
# Num incidente real, VALIDATE HEADER passou listando todos os pieces como
# AVAILABLE, e o restore falhou minutos depois com
# "not found in NetBackup catalog" - as imagens tinham expirado na fita.
#
# O unico teste que le a midia de verdade e RESTORE ... VALIDATE (sem HEADER),
# que percorre os backupsets inteiros. E lento, e e o unico que vale como
# garantia.
###############################################################################

orb_op_validate_menu()
{
    while :
    do
        orb_title "VALIDACAO DE BACKUP"
        orb_menu_begin
        orb_menu_group "NIVEL 1 - SO O REPOSITORIO (segundos, NAO prova nada)"
        orb_menu_add  1 "RESTORE DATABASE PREVIEW SUMMARY"
        orb_menu_add  2 "RESTORE DATABASE VALIDATE HEADER"

        orb_menu_group "NIVEL 2 - LE A MIDIA (lento, e o unico que prova)"
        orb_menu_add  3 "RESTORE DATABASE VALIDATE"
        orb_menu_add  4 "RESTORE ARCHIVELOG ALL VALIDATE"
        orb_menu_add  5 "VALIDATE BACKUPSET (por chave)"

        orb_menu_group "BLOCOS DOS DATAFILES ATUAIS"
        orb_menu_add  6 "VALIDATE DATABASE"
        orb_menu_add  7 "VALIDATE DATABASE CHECK LOGICAL"
        orb_menu_add  8 "Blocos corrompidos conhecidos"

        orb_menu_group "COERENCIA DO REPOSITORIO"
        orb_menu_add  9 "VALIDATE ARCHIVELOG ALL"
        orb_menu_add 10 "CROSSCHECK BACKUP + REPORT"
        orb_menu_add 11 "Por que HEADER nao basta (leia antes de confiar)"
        orb_menu_add  0 "Voltar"
        orb_menu_render
        orb_log_raw ""

        orb_ask "Opcao" "1" || return 0
        case "$ORB_ANSWER" in
            1)  orb_validate_preview ;;
            2)  orb_validate_header ;;
            3)  orb_validate_media ;;
            4)  orb_validate_arch_media ;;
            5)  orb_validate_backupset ;;
            6)  orb_validate_db "" ;;
            7)  orb_validate_db "CHECK LOGICAL" ;;
            8)  orb_validate_corrupt ;;
            9)  orb_validate_archivelog ;;
            10) orb_validate_crosscheck ;;
            11) orb_validate_why ;;
            0)  return 0 ;;
            "") ;;
            *)  orb_warn "Opcao invalida." ;;
        esac
        orb_pause
    done
}

orb_validate_preview()
{
    _f="$ORB_RUNDIR/cmd_preview.rman"
    orb_rman_build "$_f" "  RESTORE DATABASE PREVIEW SUMMARY;"
    orb_rman_run "preview" "$_f"
    orb_section "INTERPRETACAO"
    orb_item "Confirme que aparece um backup NIVEL 0 seguido dos incrementais."
    orb_item "So incremental, sem nivel 0 = cadeia quebrada, restore impossivel."
    orb_item "Some os tamanhos: e o volume que sera lido da midia."
    orb_item "Isto consultou o REPOSITORIO. Nao prova que a midia responde."
    return 0
}

orb_validate_header()
{
    _f="$ORB_RUNDIR/cmd_valhdr.rman"
    orb_rman_build "$_f" "  RESTORE DATABASE VALIDATE HEADER;"
    orb_rman_run "validate_header" "$_f"
    orb_section "INTERPRETACAO"
    orb_warn "Status AVAILABLE aqui NAO garante que a midia tem o arquivo."
    orb_item "Para garantia real, use a opcao 3 (RESTORE DATABASE VALIDATE)."
    return 0
}

orb_validate_media()
{
    orb_plan_begin "RESTORE DATABASE VALIDATE (leitura real da midia)"
    orb_plan_field "Database" "${ORB_D_DBNAME:-?}"
    orb_plan_field "Media"    "`orb_media_summary`"
    _f="$ORB_RUNDIR/cmd_valmedia.rman"
    orb_rman_build "$_f" "  RESTORE DATABASE VALIDATE;"
    orb_plan_cmd_file "Validacao lendo a midia" "$_f"
    orb_plan_risk "Le TODOS os backupsets. Em backup de fita grande leva horas."
    orb_plan_risk "Consome drives do media manager durante a execucao."
    orb_plan_risk "Nao altera o banco - so le."
    orb_plan_confirm "VALIDAR" || return 1
    orb_exec_rman "validate_media" "$_f"
    return $?
}

orb_validate_db()
{
    _extra="$1"
    _f="$ORB_RUNDIR/cmd_valdb.rman"
    orb_rman_build "$_f" "  VALIDATE DATABASE $_extra;"
    orb_rman_run "validate_db" "$_f"
    _c=`orb_sql_value "(select to_char(count(*)) from v\\$database_block_corruption)"`
    [ -n "$_c" ] && orb_field "Blocos corrompidos" "$_c"
    [ -n "$_c" ] && [ "$_c" != "0" ] && orb_warn "Use BLOCK MEDIA RECOVERY para tratar."
    return 0
}

orb_validate_archivelog()
{
    _f="$ORB_RUNDIR/cmd_valarch.rman"
    orb_rman_build "$_f" "  VALIDATE ARCHIVELOG ALL;"
    orb_rman_run "validate_archivelog" "$_f"
    return 0
}

orb_validate_crosscheck()
{
    orb_plan_begin "CROSSCHECK BACKUP"
    orb_plan_field "Database" "${ORB_D_DBNAME:-?}"
    _f="$ORB_RUNDIR/cmd_crosscheck.rman"
    orb_rman_build "$_f" \
        "  CROSSCHECK BACKUP;" \
        "  CROSSCHECK ARCHIVELOG ALL;" \
        "  CROSSCHECK COPY;"
    orb_plan_cmd_file "Crosscheck" "$_f"
    orb_plan_risk "Marca como EXPIRED tudo que o repositorio conhece e a midia nao tem."
    orb_plan_risk "Nao apaga nada, mas muda o que o RMAN considera disponivel."
    orb_plan_risk "Se o time de backup reimportar imagens depois, rode o crosscheck de novo."
    orb_plan_confirm "CROSSCHECK" || return 1
    orb_exec_rman "crosscheck" "$_f" || return 1

    _f2="$ORB_RUNDIR/cmd_afterx.rman"
    { echo "LIST EXPIRED BACKUP SUMMARY;" ; echo "REPORT NEED BACKUP;" ; echo "EXIT;" ; } > "$_f2"
    orb_rman_run "after_crosscheck" "$_f2"
    return 0
}

# ---------------------------------------------------------------------------
# POR QUE HEADER NAO BASTA
#
# Esta tela existe por causa de um erro concreto, cometido durante um restore
# de producao: o VALIDATE HEADER passou, eu li aquilo como "as fitas
# respondem", e tratei ~95 mensagens "could not locate pieces of backup set"
# como ruido do media manager. O restore real falhou em TODA peca com
# ORA-19511 - as imagens tinham expirado no catalogo do NetBackup.
#
# O sinal estava la. Foi lido como ruido. A hora seguinte foi perdida.
# ---------------------------------------------------------------------------
orb_validate_why()
{
    orb_title "O QUE CADA VALIDACAO REALMENTE PROVA"

    orb_section "RESTORE ... PREVIEW"
    orb_item "Le APENAS o repositorio (catalogo ou controlfile)."
    orb_item "Prova: existe registro do backup."
    orb_item "NAO prova: que a fita/disco ainda tem os bytes."

    orb_section "RESTORE ... VALIDATE HEADER"
    orb_item "Le o cabecalho das pecas que o media manager conseguir abrir."
    orb_item "Prova: as pecas que ele abriu tem cabecalho coerente."
    orb_item "NAO prova: que TODAS as pecas existem."
    orb_log_raw ""
    orb_status_line crit "ARMADILHA"
    orb_item "Mensagens do tipo:"
    orb_item "    could not locate pieces of backup set key NNN"
    orb_item "aparecem no meio da saida e o comando ainda termina com sucesso."
    orb_item "Isso NAO e ruido do media manager. E a peca faltando."
    orb_item "Se aparecer UMA que seja, trate como falha e va para o nivel 2."

    orb_section "RESTORE ... VALIDATE (sem HEADER)"
    orb_item "Le os backupsets INTEIROS, bloco a bloco, sem gravar nada."
    orb_item "Prova: o restore vai funcionar."
    orb_item "Custo: tempo proximo ao do restore real."
    orb_item "E o unico teste que vale como garantia."

    orb_section "VALIDATE DATABASE"
    orb_item "Olha os datafiles ATUAIS, nao o backup."
    orb_item "Responde outra pergunta: 'meu banco tem bloco corrompido?'"

    orb_section "REGRA PRATICA"
    orb_item "Antes de prometer RTO para alguem, rode o nivel 2 pelo menos uma"
    orb_item "vez por trimestre - ou use o SIMULADO (menu de diagnostico)."
    orb_item "Backup nao testado nao e backup, e esperanca."
    return 0
}

# ---------------------------------------------------------------------------
orb_validate_arch_media()
{
    orb_title "RESTORE ARCHIVELOG ALL VALIDATE"
    orb_item "Le a midia dos archives. Sem archive nao ha recovery - validar so"
    orb_item "os datafiles deixa metade da prova de fora."
    orb_log_raw ""

    orb_ask "Validar a partir de que SCN (vazio = todos disponiveis)" ""
    _from=""
    [ -n "$ORB_ANSWER" ] && _from=" FROM SCN $ORB_ANSWER"

    _f="$ORB_RUNDIR/cmd_val_arch.rman"
    orb_rman_build "$_f" "  RESTORE ARCHIVELOG ALL${_from} VALIDATE;"

    orb_plan_begin "VALIDACAO DE ARCHIVELOG NA MIDIA"
    orb_plan_field "Escopo" "ALL${_from}"
    orb_plan_cmd_file "Validacao" "$_f"
    orb_plan_risk "Le a midia inteira dos archives: demorado e gera carga."
    orb_plan_risk "Nao grava nada - e seguro rodar em producao fora de pico."
    orb_plan_confirm "VALIDAR-ARCHIVES" || return 1
    orb_exec_rman "val_arch" "$_f"
    return $?
}

# ---------------------------------------------------------------------------
orb_validate_backupset()
{
    orb_title "VALIDATE BACKUPSET"
    orb_item "Valida um backupset especifico - util quando o restore falhou numa"
    orb_item "peca so e voce quer saber se o problema e daquela peca."
    orb_log_raw ""

    orb_section "BACKUPSETS RECENTES"
    orb_sql_query "select 'ORBR|'||to_char(bs.recid)||'|'||bs.backup_type||'|'||
                          to_char(bs.completion_time,'DD/MM/YYYY HH24:MI')||'|'||
                          to_char(round(bs.bytes/1024/1024))
                     from v\$backup_set bs
                    where bs.completion_time > sysdate - 30
                    order by bs.completion_time desc;" \
        | head -25 \
        | while IFS='|' read _k _t _d _m
        do
            orb_log_raw "  `printf 'key=%-10s %-12s %-18s %8s MB' "$_k" "$_t" "$_d" "$_m"`"
        done
    orb_log_raw ""

    orb_ask "Chave(s) do backupset, separadas por virgula" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _k="$ORB_ANSWER"

    _f="$ORB_RUNDIR/cmd_val_bs.rman"
    orb_rman_build "$_f" "  VALIDATE BACKUPSET $_k;"

    orb_plan_begin "VALIDATE BACKUPSET $_k"
    orb_plan_field "Chaves" "$_k"
    orb_plan_cmd_file "Validacao" "$_f"
    orb_plan_risk "Le a midia daquele backupset - nao grava nada."
    orb_plan_confirm "VALIDAR-BACKUPSET" || return 1
    orb_exec_rman "val_bs" "$_f"
    return $?
}

# ---------------------------------------------------------------------------
orb_validate_corrupt()
{
    orb_title "BLOCOS CORROMPIDOS CONHECIDOS"

    orb_section "v\$database_block_corruption"
    _n=`orb_sql_value "(select to_char(count(*)) from v\\$database_block_corruption)"`
    orb_field "Blocos listados" "`_orb_or_na "$_n"`"
    if [ -z "$_n" ] || [ "$_n" = "0" ]; then
        orb_ok "Nenhuma corrupcao registrada."
        orb_item "A view so lista o que ja foi DETECTADO. Rodar VALIDATE DATABASE"
        orb_item "e o que popula essa lista."
        return 0
    fi

    orb_sql_query "select 'ORBR|'||to_char(file#)||'|'||to_char(block#)||'|'||to_char(blocks)||'|'||corruption_type
                     from v\$database_block_corruption order by file#, block#;" \
        | while IFS='|' read _fi _bl _nb _ty
        do
            orb_log_raw "  `printf 'file=%-5s block=%-10s qtd=%-6s tipo=%s' "$_fi" "$_bl" "$_nb" "$_ty"`"
        done

    orb_section "OBJETOS AFETADOS"
    orb_sql_query "select 'ORBR|'||nvl(e.owner,'?')||'.'||nvl(e.segment_name,'?')||'|'||nvl(e.segment_type,'?')||'|'||to_char(c.file#)||'|'||to_char(c.block#)
                     from v\$database_block_corruption c, dba_extents e
                    where e.file_id = c.file#
                      and c.block# between e.block_id and e.block_id + e.blocks - 1;" \
        | while IFS='|' read _o _t _fi _bl
        do
            orb_log_raw "  $_o ($_t)  file=$_fi block=$_bl"
        done

    orb_section "COMO CORRIGIR"
    orb_item "RECOVER CORRUPTION LIST;   -- recupera todos os blocos da lista"
    orb_item "RECOVER DATAFILE <n> BLOCK <b>;"
    orb_item "Exige backup + archives que cubram o bloco."
    orb_item "Use a opcao de Block Media Recovery no menu de RECOVERY."
    orb_log_raw ""
    orb_item "Se a corrupcao for de NOLOGGING, recovery nao resolve: o bloco nunca"
    orb_item "existiu no redo. Nesse caso, recriar o objeto e o caminho."
    return 0
}
