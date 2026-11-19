#!/usr/bin/env python3
"""Escolhe os projetos (workspaces) que o Infracost precisa estimar num PR.

Rodar o Infracost no repo inteiro leva dezenas de minutos em monorepo de Terragrunt
(centenas de workspaces). Este script olha os arquivos que o PR mudou e devolve só os
workspaces afetados, em dois arquivos de config do Infracost (um para a árvore da base,
outro para a do PR), com os mesmos nomes de projeto, para o `infracost diff` casar um com
o outro.

Uso:
  projects.py --head <dir> --base <dir> --changes <arquivo> --root <subdir> \
              --max-projects N [--no-dependents] [--usage-file-name infracost-usage.yml] \
              --out-head head.yml --out-base base.yml --out-summary resumo.md --out-env env

  --changes: saída de `git diff --name-status -M <base> <head>` (TAB entre campos).

Regras (as mesmas nas duas árvores; o resultado é a união):
  1. Workspace = diretório com um terragrunt.hcl que tem bloco `include` ou `terraform`.
     Sem nenhum terragrunt.hcl, workspace = diretório com .tf que não é usado como módulo
     local por outro diretório (Terraform puro).
  2. Arquivo dentro de um workspace (ou de um subdiretório dele): esse workspace.
  3. Arquivo dentro de um módulo local (diretório com .tf usado por `source` local): todo
     workspace que usa o módulo, direta ou indiretamente (módulo que usa módulo).
  4. Outro .hcl/.tf/.tfvars/.json (account.hcl, region.hcl, root.hcl...): todo workspace
     abaixo do diretório do arquivo, se couber no limite; senão vira "global, não estimado".
  5. Dependentes diretos (1 nível) dos workspaces acima, via `dependency { config_path }`,
     quando o caminho dá para resolver sem avaliar HCL.
  6. Acima de --max-projects, corta: primeiro os afetados diretamente, depois dependentes.
Saída em --out-env: has_projects, head_count, base_count, total, omitted, global (chave=valor).
"""
from __future__ import annotations

import argparse
import os
import posixpath
import re
import sys

SKIP_DIRS = {".git", ".terragrunt-cache", ".terraform", ".infracost", "node_modules", ".claude", ".org-infracost"}
IAC_EXT = (".hcl", ".tf", ".tfvars", ".json", ".tf.json")
LEAF_RE = re.compile(r"^\s*(include|terraform)\b", re.M)
SOURCE_RE = re.compile(r"^\s*source\s*=\s*\"(.*)\"\s*$", re.M)
CONFIG_PATH_RE = re.compile(r"^\s*config_path\s*=\s*(.+?)\s*$", re.M)


def walk(root: str):
    """Devolve (dir relativo à raiz, nomes de arquivos) de cada diretório."""
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        rel = os.path.relpath(dirpath, root)
        yield ("" if rel == "." else rel.replace(os.sep, "/")), filenames


def read(path: str) -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def norm(p: str) -> str:
    p = posixpath.normpath(p)
    return "" if p == "." else p


def literal_tail(expr: str) -> str | None:
    """Caminho de um `config_path`, na forma que dependencies_of entende.

    find_in_parent_folders("a/b/main")                         -> "^a/b/main" (ancestral + caminho)
    "${get_repo_root()}/accounts/x"                            -> "/accounts/x" (raiz ou ancestral)
    "${dirname(find_in_parent_folders("region.hcl"))}/db/main" -> "/db/main"
    "${get_terragrunt_dir()}/../main" ou "../main"             -> "../main" (relativo ao workspace)
    "${local.x}/main"                                          -> None (precisa avaliar o HCL)
    """
    expr = expr.strip()
    m = re.fullmatch(r'find_in_parent_folders\(\s*"([^"$]+)"\s*\)', expr)
    if m:
        return "^" + m.group(1)
    if not (expr.startswith('"') and expr.endswith('"')):
        return None
    s = expr[1:-1]
    if "${" in s:
        # ${local.x}/... não dá para resolver sem avaliar o HCL.
        if re.search(r"\$\{\s*local\.", s):
            return None
        m = re.fullmatch(r"\$\{\s*get_terragrunt_dir\(\)\s*\}/(.*)", s)
        if m:
            return m.group(1)  # relativo ao próprio workspace
        s = s[s.rfind("}") + 1:]
        if not s.startswith("/"):
            return None
    return s


def resolve_local_source(src: str, file_dir: str) -> list[str]:
    """Candidatos (relativos à raiz do repo) a diretório de um `source` local, do mais próximo
    ao mais distante de `file_dir`. Lista vazia se a fonte é remota."""
    interpolated = "${" in src
    # Com interpolação (${get_repo_root()}, ${local.repo_root}, ${dirname(...root.hcl)}), o que
    # vem depois dela é relativo à raiz do repo OU a um ancestral (o diretório do root.hcl, que
    # num módulo de domínio fica em infra/). Quem chama fica com o primeiro candidato que existe
    # e tem .tf, então um palpite errado só é descartado.
    tail = src[src.rfind("}") + 1:] if interpolated else src
    if interpolated and not tail.startswith("/"):
        return []
    # Remoto: registry, git, http, s3...
    if re.match(r"^[a-zA-Z][\w+.-]*::|^[a-z]+://|^git@|^tfr:|^[\w.-]+\.[a-z]{2,}/", tail):
        return []
    tail = tail.split("?", 1)[0]
    # `dir//sub`: o Terragrunt copia `dir` inteiro e roda em `dir/sub`, que é o módulo de fato.
    if "//" in tail:
        head, sub = tail.split("//", 1)
        tail = head.rstrip("/") + "/" + sub
    if interpolated:
        rel = tail.strip("/")
        out: list[str] = []
        d = file_dir
        while True:
            out.append(norm(posixpath.join(d, rel)))
            if not d:
                return out
            d = posixpath.dirname(d)
    if tail.startswith("./") or tail.startswith("../"):
        return [norm(posixpath.join(file_dir, tail))]
    return []


class Tree:
    def __init__(self, repo: str, root: str):
        self.repo = repo
        self.root = norm(root)
        base = os.path.join(repo, self.root) if self.root else repo
        self.leaves: set[str] = set()
        self.tf_dirs: set[str] = set()
        self.hcl_files: dict[str, str] = {}  # dir -> conteúdo do terragrunt.hcl
        self.module_users: dict[str, set[str]] = {}  # dir do módulo -> dirs que o usam
        tf_sources: list[tuple[str, str]] = []
        if not os.path.isdir(base):
            return
        for rel, files in walk(base):
            d = norm(posixpath.join(self.root, rel)) if self.root else rel
            if "terragrunt.hcl" in files:
                txt = read(os.path.join(repo, d, "terragrunt.hcl"))
                if LEAF_RE.search(txt):
                    self.leaves.add(d)
                    self.hcl_files[d] = txt
                    for s in SOURCE_RE.findall(txt):
                        tf_sources.append((d, s))
            tfs = [f for f in files if f.endswith(".tf")]
            if tfs:
                self.tf_dirs.add(d)
                for f in tfs:
                    for s in SOURCE_RE.findall(read(os.path.join(repo, d, f))):
                        tf_sources.append((d, s))
        for d, s in tf_sources:
            for target in resolve_local_source(s, d):
                if target != d and target in self.tf_dirs:
                    self.module_users.setdefault(target, set()).add(d)
                    break
        self.terraform_only = not self.leaves
        if self.terraform_only:
            used = set(self.module_users)
            self.leaves = {d for d in self.tf_dirs if d not in used}

    def exists(self, d: str) -> bool:
        return d in self.leaves

    def owner_leaf(self, path: str) -> str | None:
        d = posixpath.dirname(path)
        while True:
            if d in self.leaves:
                return d
            if not d:
                return None
            d = posixpath.dirname(d)

    def owner_module(self, path: str) -> str | None:
        d = posixpath.dirname(path)
        while d:
            if d in self.module_users:
                return d
            d = posixpath.dirname(d)
        return None

    def module_consumers(self, module_dir: str) -> set[str]:
        out: set[str] = set()
        seen = {module_dir}
        stack = [module_dir]
        while stack:
            m = stack.pop()
            for user in self.module_users.get(m, ()):
                if user in self.leaves:
                    out.add(user)
                if user not in seen:
                    seen.add(user)
                    stack.append(user)
        return out

    def leaves_under(self, d: str) -> set[str]:
        if not d:
            return set(self.leaves)
        return {l for l in self.leaves if l == d or l.startswith(d + "/")}

    def dependencies_of(self, leaf: str) -> set[str]:
        """Workspaces dos quais `leaf` depende (config_path resolvível)."""
        txt = self.hcl_files.get(leaf, "")
        out: set[str] = set()
        for expr in CONFIG_PATH_RE.findall(txt):
            tail = literal_tail(expr)
            if not tail:
                continue
            if tail.startswith("^"):
                # find_in_parent_folders("x"): x num ancestral de leaf.
                rel = tail[1:].strip("/")
                d = posixpath.dirname(leaf)
                while True:
                    cand = norm(posixpath.join(d, rel))
                    if cand in self.leaves:
                        out.add(cand)
                        break
                    if not d:
                        break
                    d = posixpath.dirname(d)
            elif tail.startswith("/"):
                # ${get_repo_root()}/x ou ${dirname(find_in_parent_folders("region.hcl"))}/x:
                # o prefixo é a raiz ou um ancestral de leaf; pega o mais próximo que existe.
                rel = tail.strip("/")
                d = posixpath.dirname(leaf)
                while True:
                    cand = norm(posixpath.join(d, rel))
                    if cand in self.leaves:
                        out.add(cand)
                        break
                    if not d:
                        break
                    d = posixpath.dirname(d)
            else:
                cand = norm(posixpath.join(leaf, tail))
                if cand in self.leaves:
                    out.add(cand)
        return out

    def dependents(self) -> dict[str, set[str]]:
        rev: dict[str, set[str]] = {}
        for leaf in self.leaves:
            for dep in self.dependencies_of(leaf):
                rev.setdefault(dep, set()).add(leaf)
        return rev


def parse_changes(text: str) -> list[str]:
    paths: list[str] = []
    for line in text.splitlines():
        parts = line.rstrip("\n").split("\t")
        if len(parts) < 2:
            continue
        paths.extend(p for p in parts[1:] if p)  # rename/copy: origem e destino
    return paths


def affected(tree: Tree, paths: list[str], max_projects: int) -> tuple[set[str], set[str]]:
    direct: set[str] = set()
    global_files: set[str] = set()
    root = tree.root
    for p in paths:
        if root and not (p == root or p.startswith(root + "/")):
            continue
        leaf = tree.owner_leaf(p)
        if leaf:
            direct.add(leaf)
            continue
        mod = tree.owner_module(p)
        if mod is not None:
            direct |= tree.module_consumers(mod)
            continue
        if not p.endswith(IAC_EXT):
            continue
        scope = tree.leaves_under(posixpath.dirname(p))
        if len(scope) > max_projects:
            global_files.add(p)
        else:
            direct |= scope
    return direct, global_files


def write_config(path: str, projects: list[str], tree: Tree, usage_name: str) -> None:
    lines = ["version: 0.1", "projects:"]
    if not projects:
        lines[-1] = "projects: []"
    for p in projects:
        q = p or "."
        lines.append(f"  - path: {q!s}")
        lines.append(f"    name: {q!s}")
        if usage_name and os.path.isfile(os.path.join(tree.repo, p, usage_name)):
            lines.append(f"    usage_file: {posixpath.join(q, usage_name)}")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--head", required=True)
    ap.add_argument("--base", required=True)
    ap.add_argument("--changes", required=True)
    ap.add_argument("--root", default=".")
    ap.add_argument("--max-projects", type=int, default=40)
    ap.add_argument("--no-dependents", action="store_true")
    ap.add_argument("--usage-file-name", default="infracost-usage.yml")
    ap.add_argument("--out-head", required=True)
    ap.add_argument("--out-base", required=True)
    ap.add_argument("--out-summary", required=True)
    ap.add_argument("--out-env", required=True)
    a = ap.parse_args(argv)

    root = norm(a.root.strip("/")) if a.root not in ("", ".", "./") else ""
    if ".." in root.split("/"):
        print(f"::error::--root inválido: {a.root}", file=sys.stderr)
        return 2
    paths = parse_changes(read(a.changes))
    head, base = Tree(a.head, root), Tree(a.base, root)

    direct: set[str] = set()
    globals_: set[str] = set()
    for t in (head, base):
        d, g = affected(t, paths, a.max_projects)
        direct |= d
        globals_ |= g

    deps: set[str] = set()
    if not a.no_dependents:
        for t in (head, base):
            rev = t.dependents()
            for leaf in direct:
                deps |= rev.get(leaf, set())
        deps -= direct

    ordered = sorted(direct) + sorted(deps)
    chosen = ordered[: a.max_projects]
    omitted = ordered[a.max_projects:]
    head_projects = [p for p in chosen if head.exists(p)]
    base_projects = [p for p in chosen if base.exists(p)]

    write_config(a.out_head, head_projects, head, a.usage_file_name)
    write_config(a.out_base, base_projects, base, a.usage_file_name)

    s: list[str] = []
    s.append(f"Workspaces estimados: **{len(chosen)}** ({len(direct & set(chosen))} alterados, "
             f"{len(deps & set(chosen))} dependentes diretos).")
    for p in chosen:
        tag = "" if p in direct else " _(dependente)_"
        st = "novo" if p not in base_projects else ("removido" if p not in head_projects else "")
        s.append(f"- `{p or '.'}`{tag}{' — ' + st if st else ''}")
    if omitted:
        s.append(f"\n:warning: {len(omitted)} workspace(s) fora do limite de {a.max_projects} e **não estimados**:")
        s.extend(f"- `{p}`" for p in omitted)
    if globals_:
        s.append("\n:warning: Arquivo(s) compartilhado(s) por mais workspaces que o limite; o efeito deles "
                 "**não foi estimado** (normalmente só mexem em provider, state ou tags, sem efeito de preço):")
        s.extend(f"- `{p}`" for p in sorted(globals_))
    with open(a.out_summary, "w", encoding="utf-8") as f:
        f.write("\n".join(s) + "\n")

    env = {
        "has_projects": "true" if (head_projects or base_projects) else "false",
        "head_count": str(len(head_projects)),
        "base_count": str(len(base_projects)),
        "total": str(len(chosen)),
        "omitted": str(len(omitted)),
        "global": str(len(globals_)),
        "terraform_only": "true" if head.terraform_only and base.terraform_only else "false",
    }
    with open(a.out_env, "w", encoding="utf-8") as f:
        f.writelines(f"{k}={v}\n" for k, v in env.items())
    return 0


if __name__ == "__main__":
    sys.exit(main())
