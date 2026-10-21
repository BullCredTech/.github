"""Conferência de licenças de dependências Python (pip-licenses) e Dart/Flutter contra uma allowlist.

Origem: porte dos dois scripts `verificar_licencas.py` que já rodavam em CI:
  - BullCredTech/bull-web-cash-flow (Python, via pip-licenses);
  - BullCredTech/bull-mobile-platform (Dart/Flutter, detecção pelo texto do LICENSE).
As funções normalizar(), termos() e detectar_licenca() vêm do script do mobile
(nas funções de normalização os dois eram iguais). A diferença daqui: a allowlist
NÃO é fixa no código; vem só de `--allow` (SPDX separados por ';').

Por que normalizar em vez de comparar a string crua: o mesmo licenciamento chega
em grafias diferentes (`BSD-3-Clause`, `BSD License`, `3-Clause BSD License`), e
uma allowlist literal reprovaria duas delas. Sem isso o check falha por
formatação e ensina a equipe a ignorá-lo.

AND e OR: todo termo precisa estar na allowlist. No OR a exigência é mais forte
que o necessário, e é assim que se quer errar num gate de licença.

Dart: pacotes do pub não declaram SPDX em lugar nenhum; o único sinal é o
LICENSE na raiz do pacote, daí a detecção por marcador textual.

Uso:
  licenses.py pip  --allow "MIT;Apache-2.0" < saida-do-pip-licenses.json
  licenses.py dart --allow "MIT;Apache-2.0" <diretorio-do-projeto>
Saída: 0 se tudo permitido; 1 se há licença fora da lista. Licença vazia/UNKNOWN
só avisa ("sem licença declarada").
"""
import argparse
import json
import os
import re
import sys
from urllib.parse import unquote

# Famílias que reprovam de forma explícita, para a mensagem dizer o motivo.
NEGADAS = {
    'gpl-2.0', 'gpl-3.0', 'agpl-3.0', 'lgpl-2.1', 'lgpl-3.0',
    'sspl-1.0', 'busl-1.1', 'osl-3.0', 'eupl-1.2', 'cpal-1.0',
}

# Grafias equivalentes -> forma normalizada.
SINONIMOS = {
    'mit license': 'mit',
    'bsd license': 'bsd',
    '3-clause bsd license': 'bsd-3-clause',
    'bsd 3-clause': 'bsd-3-clause',
    'new bsd license': 'bsd-3-clause',
    '2-clause bsd license': 'bsd-2-clause',
    'simplified bsd license': 'bsd-2-clause',
    'apache software license': 'apache-2.0',
    'apache license 2.0': 'apache-2.0',
    'apache license, version 2.0': 'apache-2.0',
    'apache 2.0': 'apache-2.0',
    'the apache software license, version 2.0': 'apache-2.0',
    'isc license': 'isc',
    'isc license (iscl)': 'isc',
    'mozilla public license 2.0 (mpl 2.0)': 'mpl-2.0',
    'mozilla public license 2.0': 'mpl-2.0',
    'the unlicense (unlicense)': 'unlicense',
    'gnu general public license v2 (gplv2)': 'gpl-2.0',
    'gnu general public license v3 (gplv3)': 'gpl-3.0',
    'gnu lesser general public license v2 (lgplv2)': 'lgpl-2.1',
    'gnu lesser general public license v3 (lgplv3)': 'lgpl-3.0',
    'gnu affero general public license v3': 'agpl-3.0',
}

_SEPARADORES = re.compile(r'\s+AND\s+|\s+OR\s+|\s*;\s*|\s*/\s*', re.IGNORECASE)

# Títulos, casados só no cabeçalho do arquivo (a MPL-2.0 cita a GPL/AGPL no corpo).
_TITULOS = (
    ('mozilla public license', 'mpl-2.0'),
    ('gnu affero general public license', 'agpl-3.0'),
    ('gnu lesser general public license', 'lgpl-3.0'),
    ('gnu general public license', 'gpl-3.0'),
    ('apache license', 'apache-2.0'),
    ('cc0 1.0 universal', 'cc0-1.0'),
    ('creative commons zero', 'cc0-1.0'),
)

# Licenças curtas, sem linha de título. BSD-3 antes da BSD-2 (a 3 contém a 2).
_CORPO = (
    ('permission is hereby granted, free of charge', 'mit'),
    ('permission to use, copy, modify, and/or distribute', 'isc'),
    ('permission to use, copy, modify, and distribute', 'isc'),
    ('neither the name', 'bsd-3-clause'),
    ('redistribution and use in source and binary forms', 'bsd-2-clause'),
    ('this is free and unencumbered software released into the public domain',
     'unlicense'),
)


def normalizar(termo):
    """Uma grafia de licença -> a forma canônica. `''` quando não dá para dizer."""
    t = termo.strip().strip('.').strip().lower()
    if not t or t in ('unknown', 'n/a', 'none'):
        return ''
    if t in SINONIMOS:
        return SINONIMOS[t]
    # Parênteses de expressão SPDX, "(MIT OR Apache-2.0)": tira só os das pontas.
    t = t.strip('() ').strip()
    if not t:
        return ''
    return SINONIMOS.get(t, t)


def termos(licenca):
    """Todos os termos de um licenciamento, já normalizados e sem vazios."""
    return [n for n in (normalizar(p) for p in _SEPARADORES.split(licenca or '')) if n]


def detectar_licenca(texto):
    """Texto de um LICENSE -> identificador SPDX-ish. `''` quando não reconhece."""
    cabecalho = ' '.join(texto[:300].lower().split())
    for marcador, licenca in _TITULOS:
        if marcador in cabecalho:
            return licenca
    corpo = ' '.join(texto[:4000].lower().split())
    for marcador, licenca in _CORPO:
        if marcador in corpo:
            return licenca
    return ''


def permitidas_normalizadas(allow):
    """`--allow` ("MIT;Apache-2.0") -> conjunto normalizado."""
    return {t for t in (normalizar(p) for p in allow.split(';')) if t}


def inventario_pip(texto):
    """`[{'Name','Version','License'}]` do JSON do `pip-licenses --format=json`."""
    dados = json.loads(texto)
    if not isinstance(dados, list):
        raise ValueError('esperava uma lista JSON')
    return dados


def inventario_dart(diretorio):
    """`[{'Name','Version','License'}]` dos pacotes resolvidos pelo pub."""
    caminho = os.path.join(diretorio, '.dart_tool', 'package_config.json')
    if not os.path.isfile(caminho):
        sys.exit(f'{caminho} não existe: rode `flutter pub get` em {diretorio} antes.')
    with open(caminho, encoding='utf-8') as fh:
        config = json.load(fh)

    pacotes = []
    for p in config.get('packages', []):
        raiz = p.get('rootUri', '')
        if raiz.startswith('file://'):
            raiz = unquote(raiz[len('file://'):])
        else:
            # rootUri sem esquema é relativo ao diretório .dart_tool/ (onde está o package_config.json)
            raiz = os.path.normpath(os.path.join(diretorio, '.dart_tool', unquote(raiz)))

        licenca = ''
        for nome_arquivo in ('LICENSE', 'LICENSE.md', 'LICENSE.txt', 'COPYING'):
            arquivo = os.path.join(raiz, nome_arquivo)
            if os.path.isfile(arquivo):
                with open(arquivo, encoding='utf-8', errors='replace') as fh:
                    licenca = detectar_licenca(fh.read())
                break

        # Versão: do nome do diretório do pub cache (`<pacote>-<versão>`); `local` para path deps.
        base = os.path.basename(os.path.normpath(raiz))
        versao = base.rsplit('-', 1)[1] if '-' in base else 'local'
        pacotes.append({'Name': p.get('name', '?'), 'Version': versao, 'License': licenca})
    return pacotes


def _permitido(termo, permitidas):
    if termo in permitidas:
        return True
    # "BSD" sem variante (grafia ambígua do PyPI) vale se alguma BSD-N-Clause está na lista.
    return termo == 'bsd' and any(p.startswith('bsd-') for p in permitidas)


def avaliar(pacotes, permitidas):
    """`(reprovados, indefinidos)`: cada item é `(nome, versão, licença, razão)`."""
    reprovados, indefinidos = [], []
    for p in pacotes:
        nome = p.get('Name', '?')
        versao = p.get('Version', '?')
        licenca = p.get('License', '') or ''
        lista = termos(licenca)
        if not lista:
            indefinidos.append((nome, versao, licenca or 'UNKNOWN', 'não declarada'))
            continue
        fora = [t for t in lista if not _permitido(t, permitidas)]
        if not fora:
            continue
        negadas = [t for t in fora if t in NEGADAS]
        razao = (f'copyleft forte: {", ".join(negadas)}' if negadas
                 else f'fora da allowlist: {", ".join(fora)}')
        reprovados.append((nome, versao, licenca, razao))
    return reprovados, indefinidos


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('modo', choices=['pip', 'dart'])
    ap.add_argument('--allow', required=True, help='SPDX separados por ";"')
    ap.add_argument('diretorio', nargs='?', default='.')
    args = ap.parse_args(argv)

    permitidas = permitidas_normalizadas(args.allow)
    if args.modo == 'pip':
        try:
            pacotes = inventario_pip(sys.stdin.read())
        except ValueError as e:  # JSONDecodeError é ValueError
            print(f'entrada inválida do pip-licenses: {e}', file=sys.stderr)
            return 2
        origem = 'pip-licenses'
    else:
        pacotes = inventario_dart(args.diretorio)
        origem = args.diretorio

    reprovados, indefinidos = avaliar(pacotes, permitidas)
    print(f'{len(pacotes)} pacotes inventariados em: {origem}')

    # Licença não declarada NÃO reprova (senão o check vira ruído); sai listada.
    if indefinidos:
        print(f'\n{len(indefinidos)} sem licença declarada (não reprovam):')
        for nome, versao, licenca, _ in sorted(indefinidos):
            print(f'  - {nome} {versao}: {licenca}')

    if not reprovados:
        print('\nOK: nenhuma licença fora da allowlist.')
        return 0

    print(f'\nREPROVADO: {len(reprovados)} pacote(s):')
    for nome, versao, licenca, razao in sorted(reprovados):
        print(f'  - {nome} {versao}: "{licenca}" ({razao})')
    print('\nDecida caso a caso: ou o pacote sai, ou a licença entra em '
          '`license.extra_allowed` no .github/security-checks.yml, com o motivo escrito.')
    return 1


if __name__ == '__main__':
    sys.exit(main())
