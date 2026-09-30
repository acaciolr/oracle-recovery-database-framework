#!/usr/bin/sh
###############################################################################
# lib/diag.sh - diagnostico inteligente de erros
#
# Nao basta imprimir o codigo. Para cada erro conhecido: causa provavel,
# evidencia a coletar, e proximo passo. NUNCA executa acao corretiva sozinho.
#
# Os textos abaixo nao sao genericos: varios foram escritos a partir de um
# incidente real de restore de standby.
###############################################################################

# orb_diag_code <codigo>  -  imprime a explicacao daquele codigo
orb_diag_code()
{
    case "$1" in

    ORA-01180)
        cat <<'EOT'
  ORA-01180: can not create datafile N
  CAUSA   : o RMAN nao encontrou backup do datafile e caiu no caminho de
            CRIAR o arquivo do zero. Datafile 1 (SYSTEM) nunca pode ser criado.
            Quase sempre significa que a sessao RMAN nao esta enxergando os
            backupsets - tipicamente por conectar SEM recovery catalog, vendo
            so a janela de control_file_record_keep_time.
  EVIDENCIA: procure "using target database control file instead of recovery
            catalog" e "creating datafile" logo acima do erro.
  PROXIMO : reconecte com catalogo e rode RESTORE DATABASE PREVIEW para
            confirmar que existe um NIVEL 0 na cadeia.
EOT
        ;;

    ORA-01110)
        cat <<'EOT'
  ORA-01110: data file N: '<nome>'
  CAUSA   : acompanha outro erro; identifica qual arquivo falhou. Se o nome
            aparecer como o proprio diskgroup (ex '+DATA'), o SET NEWNAME
            estava em efeito e o arquivo ainda nao existia.
  PROXIMO : trate o erro que veio junto.
EOT
        ;;

    ORA-19511|ORA-19507|ORA-27029|ORA-19870)
        cat <<'EOT'
  ORA-19870 / ORA-19507 / ORA-27029 / ORA-19511
  CAUSA   : falha do MEDIA MANAGER, nao do RMAN. O texto do vendor no fim da
            pilha e o que importa.
            "not found in <MM> catalog" = o piece nao existe mais na midia,
            OU esta catalogado sob outro client name / catalog host.
  ATENCAO : o catalogo RMAN dizer Status: AVAILABLE NAO prova que a midia tem
            o arquivo. RESTORE ... VALIDATE HEADER tambem consulta o
            repositorio. So o restore real prova.
  PROXIMO : 1) confirme com o time de backup se a imagem existe e se pode ser
               reimportada;
            2) confira client name / catalog host nos parametros SEND;
            3) se a midia expirou mesmo, considere origem alternativa
               (RESTORE ... FROM SERVICE a partir do primary).
EOT
        ;;

    RMAN-20010)
        cat <<'EOT'
  RMAN-20010: database incarnation not found
  CAUSA   : o numero passado em RESET DATABASE TO INCARNATION nao existe no
            catalogo. O erro mais comum e usar o Reset SCN, ou o Inc Key que
            aparece quando se lista pelo controlfile.
  CORRETO : conecte ao CATALOGO, rode LIST INCARNATION OF DATABASE '<db>' e
            use a coluna "Inc Key" da linha desejada.
  PERGUNTA: voce precisa mesmo resetar? Se a incarnation CURRENT ja e a
            desejada (refresh normal de standby), o comando nao deve existir.
EOT
        ;;

    RMAN-06023)
        cat <<'EOT'
  RMAN-06023: no backup or copy of datafile N found to restore
  CAUSA   : nao ha backup restauravel do arquivo no repositorio visivel.
  EVIDENCIA: LIST BACKUP OF DATAFILE N SUMMARY (com catalogo).
  PROXIMO : verifique catalogo vs controlfile, incarnation, e se existe um
            NIVEL 0 - incrementais sozinhos nao restauram nada.
EOT
        ;;

    RMAN-06026)
        cat <<'EOT'
  RMAN-06026: some targets not found - aborting restore
  CAUSA   : parte dos objetos pedidos nao tem backup disponivel.
  PROXIMO : RESTORE ... PREVIEW para ver o que o RMAN acha que usaria.
EOT
        ;;

    RMAN-06054)
        cat <<'EOT'
  RMAN-06054: media recovery requesting unknown archived log
  CONTEXTO: em recover de STANDBY isso e o FIM NORMAL. O RMAN aplicou tudo o
            que havia em backup e pediu o proximo log, que ainda esta no
            primary.
  CUIDADO : e falha em qualquer outro contexto. Nunca tolere este codigo
            globalmente - so no passo de recover de standby.
  PROXIMO : inicie o managed recovery para alcancar o primary.
EOT
        ;;

    RMAN-06094)
        cat <<'EOT'
  RMAN-06094: datafile N must be restored
  CAUSA   : tentativa de recover sobre um arquivo que nao foi restaurado.
            Quase sempre consequencia de um restore que falhou antes.
  PROXIMO : olhe o erro do RESTORE, nao o do RECOVER.
EOT
        ;;

    RMAN-06025)
        cat <<'EOT'
  RMAN-06025: no backup of archived log found
  CAUSA   : falta archivelog na sequencia necessaria.
  PROXIMO : LIST BACKUP OF ARCHIVELOG ALL; verifique gaps e a origem
            alternativa (primary, FRA, outra copia).
EOT
        ;;

    RMAN-06059)
        cat <<'EOT'
  RMAN-06059: expected archived log not found
  CAUSA   : o repositorio conhece o log mas ele nao esta no destino.
  PROXIMO : CROSSCHECK ARCHIVELOG ALL para alinhar o repositorio com a
            realidade antes de decidir qualquer coisa.
EOT
        ;;

    PRCN-2018)
        cat <<'EOT'
  PRCN-2018: Current user is not a privileged user
  CAUSA   : srvctl modify database -user precisa ser executado como ROOT.
  PROXIMO : repita o comando como root.
EOT
        ;;

    CRS-0184|CRS-4535|PRKH-1010|PRKH-3003|PRCD-1027|PRCR-1070)
        cat <<'EOT'
  CRS-0184 / CRS-4535 / PRKH-1010 / PRCD-1027
  CAUSA   : o Clusterware nao esta respondendo.
  CRITICO : com o CRS fora, srvctl e crsctl devolvem ERRO, nao "parado".
            Qualquer logica que decida por grep na saida vai concluir errado.
  PROXIMO : crsctl check crs; verifique ohasd; suba o stack antes de tudo.
EOT
        ;;

    ORA-09925)
        cat <<'EOT'
  ORA-09925: unable to create audit trail file
  CAUSA   : o usuario dono da instancia nao consegue escrever em
            audit_file_dest. Tipico depois de troca de owner ou quando o
            diretorio existe em um node e nao no outro.
  PROXIMO : compare audit_file_dest e diagnostic_dest com o ownership real
            do diretorio, nos DOIS nodes.
EOT
        ;;

    ORA-01547)
        cat <<'EOT'
  ORA-01547: recover succeeded but OPEN RESETLOGS would get error below
  CAUSA   : recovery incompleto - falta aplicar mais redo.
  PROXIMO : v$recover_file e v$datafile_header para ver o que falta.
EOT
        ;;

    ORA-01152|ORA-01113|ORA-01157|ORA-01207)
        cat <<'EOT'
  ORA-01152 / ORA-01113 / ORA-01157 / ORA-01207
  CAUSA   : inconsistencia entre controlfile e datafiles - arquivo nao
            recuperado, nao identificado, ou mais novo que o controlfile.
  PROXIMO : v$datafile_header (status, fuzzy, checkpoint_change#) antes de
            qualquer OPEN RESETLOGS.
EOT
        ;;

    ORA-00283|ORA-19504|ORA-19505)
        cat <<'EOT'
  ORA-00283 / ORA-19504 / ORA-19505
  CAUSA   : falha ao criar ou identificar arquivo no destino - normalmente
            permissao, espaco, ou diskgroup inexistente.
  PROXIMO : confira espaco no destino e ownership do caminho.
EOT
        ;;

    *)
        return 1
        ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# orb_diag_explain <log>
#
# Varre a saida, extrai codigos unicos e explica os conhecidos.
# ---------------------------------------------------------------------------
orb_diag_explain()
{
    _f="$1"
    [ -f "$_f" ] || return 1

    _codes=`grep -E -o "(RMAN|ORA|PRCD|PRCR|PRCN|PRKH|CRS)-[0-9]+" "$_f" 2>/dev/null | sort -u`
    [ -z "$_codes" ] && return 1

    orb_section "DIAGNOSTICO"
    _any=0
    for _c in $_codes
    do
        _t="$ORB_RUNDIR/.diag.$$"
        if orb_diag_code "$_c" > "$_t" 2>/dev/null; then
            _any=1
            orb_log_raw ""
            while IFS= read _l ; do orb_log_raw "$_l" ; done < "$_t"
        fi
        rm -f "$_t" 2>/dev/null
    done

    if [ $_any -eq 0 ]; then
        orb_log_raw "  Codigos sem entrada no dicionario:"
        for _c in $_codes ; do orb_log_raw "    $_c" ; done
    fi

    # Sinal especifico de media manager, que costuma passar despercebido
    if grep -i "not found in .* catalog" "$_f" >/dev/null 2>&1; then
        orb_log_raw ""
        orb_warn "O media manager reportou piece ausente no catalogo dele."
        orb_item "Isso e independente do Status AVAILABLE no catalogo RMAN."
        grep -i "not found in .* catalog" "$_f" 2>/dev/null | sort -u | head -5 \
            | while IFS= read _l ; do orb_log_raw "    $_l" ; done
    fi
    return 0
}

# ---------------------------------------------------------------------------
# orb_diag_lookup  -  consulta interativa do dicionario
# ---------------------------------------------------------------------------
orb_diag_lookup()
{
    orb_section "CONSULTA AO DICIONARIO DE ERROS"
    orb_ask "Codigo (ex: ORA-01180, RMAN-06054)" ""
    [ -z "$ORB_ANSWER" ] && return 1
    _c=`orb_upper "$ORB_ANSWER"`
    if orb_diag_code "$_c" > "$ORB_RUNDIR/.dg.$$" 2>/dev/null; then
        orb_log_raw ""
        while IFS= read _l ; do orb_log_raw "$_l" ; done < "$ORB_RUNDIR/.dg.$$"
    else
        orb_warn "Codigo sem entrada no dicionario: $_c"
    fi
    rm -f "$ORB_RUNDIR/.dg.$$" 2>/dev/null
    return 0
}
