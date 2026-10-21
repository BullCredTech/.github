"""Conta as dependências declaradas num pyproject.toml, sem executar nada do projeto.

Uso: pyproject_deps.py <pyproject.toml>
Saída: um inteiro (0 = nada declarado). Códigos: 1 = TOML ilegível, 3 = dependência por URL/caminho
direto (`pkg @ https://...`), que o gate não aceita. Falha fechado: dúvida vira erro.
"""
import sys

try:
    import tomllib
except ImportError:  # Python < 3.11
    print('Python 3.11+ é necessário para ler o pyproject.toml', file=sys.stderr)
    sys.exit(1)


def main():
    try:
        with open(sys.argv[1], 'rb') as fh:
            dados = tomllib.load(fh)
    except (OSError, tomllib.TOMLDecodeError) as e:
        print(f'pyproject.toml ilegível: {e}', file=sys.stderr)
        return 1
    projeto = dados.get('project') or {}
    principais = list(projeto.get('dependencies') or [])
    extras = [d for lista in (projeto.get('optional-dependencies') or {}).values() for d in lista]
    poetry = ((dados.get('tool') or {}).get('poetry') or {}).get('dependencies') or {}
    poetry = {k: v for k, v in poetry.items() if k.lower() != 'python'}
    total = len(principais) + len(poetry) + (1 if 'dependencies' in (projeto.get('dynamic') or []) else 0)
    for d in principais + extras:
        if isinstance(d, str) and ('@' in d or '://' in d):
            print(f'dependência por URL direta não permitida: {d}', file=sys.stderr)
            return 3
    for k, v in poetry.items():
        if isinstance(v, dict) and any(c in v for c in ('git', 'url', 'path')):
            print(f'dependência por URL/caminho direto não permitida: {k}', file=sys.stderr)
            return 3
    print(total)
    return 0


if __name__ == '__main__':
    sys.exit(main())
