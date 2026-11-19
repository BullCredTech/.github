"""Caminhos do run.sh que não chamam o CLI do Infracost (sem rede, sem chave)."""
import pathlib
import subprocess

RUN = pathlib.Path(__file__).parent.parent / "scripts" / "run.sh"


def w(root, rel, txt=""):
    p = root / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(txt)


def tree(root):
    w(root, "root.hcl", "locals {}\n")
    w(root, "accounts/prod/sa/net/vpc/main/terragrunt.hcl",
      'include {\n  path = find_in_parent_folders("root.hcl")\n}\n'
      'terraform {\n  source = "tfr:///terraform-aws-modules/vpc/aws?version=5.0.0"\n}\n')
    w(root, "modules/sem-uso/main.tf", 'resource "null_resource" "x" {}\n')


def run(tmp_path, changes):
    head, base, out = tmp_path / "head", tmp_path / "base", tmp_path / "out"
    tree(head)
    tree(base)
    ch = tmp_path / "changes.txt"
    ch.write_text(changes)
    r = subprocess.run(["bash", str(RUN), str(head), str(base), str(ch), str(out)],
                       capture_output=True, text=True)
    return r, out


def test_sem_workspace_afetado_gera_os_tres_arquivos(tmp_path):
    # Módulo sem nenhum workspace que o use: nada a estimar.
    r, out = run(tmp_path, "M\tmodules/sem-uso/main.tf\n")
    assert r.returncode == 0, r.stderr
    assert (out / "has_projects").read_text().strip() == "has_projects=false"
    comment = (out / "comment.md").read_text()
    assert comment.startswith("<!-- bull-infracost -->")
    assert "Nenhum workspace" in comment
    # O step do workflow faz `cat full.md` com set -e: precisa existir.
    assert (out / "full.md").read_text() == comment


def test_push_que_desfaz_a_mudanca_de_iac(tmp_path):
    # Diff vazio contra a base: o comentário antigo tem que ser atualizado, não o job quebrar.
    r, out = run(tmp_path, "")
    assert r.returncode == 0, r.stderr
    assert (out / "full.md").exists()
    assert (out / "has_projects").read_text().strip() == "has_projects=false"
