"""Lê as dependências declaradas num pyproject.toml, sem executar nada do projeto.

Uso: pyproject_deps.py [count|reqs] <pyproject.toml>   (padrão: count)
  count -> um inteiro (0 = nada declarado)
  reqs  -> uma linha de requisito por dependência de produção ([project].dependencies e
           [tool.poetry.dependencies] sem `python`, com as restrições do poetry convertidas para PEP 440)
Códigos de saída: 1 = TOML ilegível, 3 = dependência por URL/caminho direto (`pkg @ https://...`, git, path),
4 = dependências dinâmicas (`dynamic = ["dependencies"]`: só se conhecem executando o projeto), 5 = restrição
do poetry que não sei converter. Falha fechado: dúvida vira erro.
"""
import re
import sys

try:
    import tomllib
except ImportError:  # Python < 3.11
    print('Python 3.11+ é necessário para ler o pyproject.toml', file=sys.stderr)
    sys.exit(1)

_NUM = re.compile(r'^\d+(\.\d+)*$')


def _partes(v):
    return [int(x) for x in v.split('.')]


def _juntar(p):
    return '.'.join(str(x) for x in p)


def poetry_para_pep440(c):
    """Restrição de versão do poetry -> especificador PEP 440 ('' = qualquer). None se não souber."""
    c = c.strip()
    if c in ('', '*'):
        return ''
    if c[0] in '^~' and _NUM.match(c[1:]):
        base = _partes(c[1:])
        if c[0] == '^':
            i = next((k for k, x in enumerate(base) if x != 0), len(base) - 1)
        else:  # ~
            i = 1 if len(base) >= 2 else 0
        return f'>={c[1:]},<{_juntar(_cota(base, i))}'
    if _NUM.match(c):
        return f'=={c}'
    if re.match(r'^(<=|>=|==|!=|~=|<|>)', c):
        return c.replace(' ', '')
    return None


def _cota(base, i):
    """Cota superior: incrementa a posição i e zera o resto, mantendo o tamanho da versão informada.

    ^1.2.3 -> <2.0.0 ; ^1.2 -> <2.0 ; ^1 -> <2 ; ^0.2.3 -> <0.3.0 ; ~1.4 -> <1.5 ; ~1.4.2 -> <1.5.0
    """
    sup = base[:i] + [base[i] + 1]
    return sup + [0] * (len(base) - len(sup))


def main():
    args = sys.argv[1:]
    modo = 'count'
    if args and args[0] in ('count', 'reqs'):
        modo = args.pop(0)
    try:
        with open(args[0], 'rb') as fh:
            dados = tomllib.load(fh)
    except (OSError, tomllib.TOMLDecodeError, IndexError) as e:
        print(f'pyproject.toml ilegível: {e}', file=sys.stderr)
        return 1
    projeto = dados.get('project') or {}
    principais = list(projeto.get('dependencies') or [])
    extras = [d for lista in (projeto.get('optional-dependencies') or {}).values() for d in lista]
    poetry = ((dados.get('tool') or {}).get('poetry') or {}).get('dependencies') or {}
    poetry = {k: v for k, v in poetry.items() if k.lower() != 'python'}
    dinamico = 'dependencies' in (projeto.get('dynamic') or [])

    for d in principais + extras:
        if isinstance(d, str) and ('@' in d or '://' in d):
            print(f'dependência por URL direta não permitida: {d}', file=sys.stderr)
            return 3
    for k, v in poetry.items():
        if isinstance(v, dict) and any(c in v for c in ('git', 'url', 'path')):
            print(f'dependência por URL/caminho direto não permitida: {k}', file=sys.stderr)
            return 3

    if modo == 'count':
        print(len(principais) + len(poetry) + (1 if dinamico else 0))
        return 0

    if dinamico:
        print('dependências dinâmicas (dynamic = ["dependencies"])', file=sys.stderr)
        return 4
    linhas = [str(d) for d in principais]
    for nome, v in poetry.items():
        extra = ''
        if isinstance(v, dict):
            if v.get('extras'):
                extra = '[' + ','.join(v['extras']) + ']'
            v = v.get('version', '*')
        if not isinstance(v, str):
            print(f'restrição do poetry não suportada: {nome}', file=sys.stderr)
            return 5
        spec = poetry_para_pep440(v)
        if spec is None:
            print(f'restrição do poetry não suportada: {nome} = {v}', file=sys.stderr)
            return 5
        linhas.append(f'{nome}{extra}{spec}')
    print('\n'.join(linhas))
    return 0


if __name__ == '__main__':
    sys.exit(main())
