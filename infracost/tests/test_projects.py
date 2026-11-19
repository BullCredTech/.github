import pathlib
import subprocess
import sys

SCRIPT = pathlib.Path(__file__).parent.parent / "scripts" / "projects.py"

LEAF = 'include {\n  path = find_in_parent_folders("root.hcl")\n}\n'


def w(root, rel, txt=""):
    p = root / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(txt)


def monorepo(root):
    """Terragrunt no formato da base-infra."""
    w(root, "root.hcl", "locals {}\n")
    w(root, "accounts/prod/account.hcl", "locals {}\n")
    w(root, "accounts/prod/sa/region.hcl", "locals {}\n")
    w(root, "accounts/prod/sa/net/vpc/main/terragrunt.hcl",
      LEAF + 'terraform {\n  source = "tfr:///terraform-aws-modules/vpc/aws?version=5.0.0"\n}\n')
    w(root, "accounts/prod/sa/db/pg/main/terragrunt.hcl", LEAF + '''
dependency "vpc" {
  config_path = find_in_parent_folders("net/vpc/main")
  mock_outputs = { id = "x" }
}
terraform {
  source = "${get_repo_root()}/modules/bull-rds"
}
''')
    w(root, "accounts/prod/sa/db/pg/alarms/terragrunt.hcl", LEAF + '''
dependency "db" {
  config_path = "${get_terragrunt_dir()}/../main"
}
terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}/modules/bull-alarm"
}
''')
    w(root, "accounts/prod/sa/app/lambda/main/terragrunt.hcl", LEAF + '''
dependency "db" {
  config_path = "${dirname(find_in_parent_folders("region.hcl"))}/db/pg/main"
}
terraform {
  source = "git@github.com:Org/mods.git//lambda?ref=lambda/v1"
}
''')
    w(root, "accounts/prod/sa/app/other/main/terragrunt.hcl", LEAF + '''
terraform {
  source = "${local.repo_root}/modules/bull-alarm"
}
''')
    w(root, "modules/bull-rds/main.tf", 'module "inner" {\n  source = "../bull-common"\n}\n')
    w(root, "modules/bull-alarm/main.tf", 'resource "aws_cloudwatch_metric_alarm" "a" {}\n')
    w(root, "modules/bull-common/main.tf", 'resource "aws_db_instance" "x" {}\n')
    w(root, "modules/bull-common/templates/policy.json", "{}\n")
    w(root, "modules/unused/main.tf", "")
    w(root, "docs/README.md", "doc\n")


def run(tmp_path, changes, head=None, base=None, extra=()):
    head = head or tmp_path / "head"
    base = base or tmp_path / "base"
    ch = tmp_path / "changes.txt"
    ch.write_text("".join(f"{s}\t{p}\n" for s, p in changes))
    out = {k: tmp_path / f"{k}.out" for k in ("h", "b", "s", "e")}
    r = subprocess.run([sys.executable, "-I", str(SCRIPT), "--head", str(head), "--base", str(base),
                        "--changes", str(ch), "--out-head", str(out["h"]), "--out-base", str(out["b"]),
                        "--out-summary", str(out["s"]), "--out-env", str(out["e"]), *extra],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    env = dict(l.split("=", 1) for l in out["e"].read_text().split())
    names = lambda f: [l.split(": ", 1)[1] for l in f.read_text().splitlines() if l.strip().startswith("name:")]
    return names(out["h"]), names(out["b"]), env, out["s"].read_text(), out["h"].read_text()


def both(tmp_path):
    monorepo(tmp_path / "head")
    monorepo(tmp_path / "base")


def test_workspace_alterado_e_dependentes(tmp_path):
    both(tmp_path)
    h, b, env, _, _ = run(tmp_path, [("M", "accounts/prod/sa/db/pg/main/terragrunt.hcl")])
    # pg/main alterado; alarms (get_terragrunt_dir/..) e lambda (dirname(region.hcl)) dependem dele.
    assert h[0] == "accounts/prod/sa/db/pg/main"
    assert set(h) == {"accounts/prod/sa/db/pg/main", "accounts/prod/sa/db/pg/alarms", "accounts/prod/sa/app/lambda/main"}
    assert h == b
    assert env["has_projects"] == "true"


def test_sem_dependentes(tmp_path):
    both(tmp_path)
    h, _, _, _, _ = run(tmp_path, [("M", "accounts/prod/sa/net/vpc/main/terragrunt.hcl")], extra=["--no-dependents"])
    assert h == ["accounts/prod/sa/net/vpc/main"]


def test_dependente_via_find_in_parent_folders(tmp_path):
    both(tmp_path)
    h, _, _, _, _ = run(tmp_path, [("M", "accounts/prod/sa/net/vpc/main/terragrunt.hcl")])
    assert h == ["accounts/prod/sa/net/vpc/main", "accounts/prod/sa/db/pg/main"]


def test_modulo_local_transitivo(tmp_path):
    both(tmp_path)
    # bull-common é usado por bull-rds (../bull-common), que é usado por pg/main.
    h, _, _, _, _ = run(tmp_path, [("M", "modules/bull-common/templates/policy.json")], extra=["--no-dependents"])
    assert h == ["accounts/prod/sa/db/pg/main"]


def test_modulo_com_local_repo_root(tmp_path):
    both(tmp_path)
    h, _, _, _, _ = run(tmp_path, [("M", "modules/bull-alarm/main.tf")], extra=["--no-dependents"])
    assert h == ["accounts/prod/sa/app/other/main", "accounts/prod/sa/db/pg/alarms"]


def test_modulo_sem_uso_e_doc_nao_estimam(tmp_path):
    both(tmp_path)
    h, b, env, _, _ = run(tmp_path, [("M", "modules/unused/main.tf"), ("M", "docs/README.md")])
    assert h == [] and b == []
    assert env["has_projects"] == "false"


def test_arquivo_compartilhado_dentro_e_fora_do_limite(tmp_path):
    both(tmp_path)
    h, _, env, _, _ = run(tmp_path, [("M", "accounts/prod/sa/region.hcl")], extra=["--no-dependents"])
    assert len(h) == 5 and env["global"] == "0"
    h, _, env, s, _ = run(tmp_path, [("M", "root.hcl")], extra=["--no-dependents", "--max-projects", "3"])
    assert h == [] and env["global"] == "1"
    assert "root.hcl" in s and "não foi estimado" in s


def test_limite_corta_dependentes_primeiro(tmp_path):
    both(tmp_path)
    h, _, env, s, _ = run(tmp_path, [("M", "accounts/prod/sa/db/pg/main/terragrunt.hcl")], extra=["--max-projects", "1"])
    assert h == ["accounts/prod/sa/db/pg/main"]
    assert env["omitted"] == "2" and "não estimados" in s


def test_workspace_novo_e_removido(tmp_path):
    both(tmp_path)
    w(tmp_path / "head", "accounts/prod/sa/app/novo/main/terragrunt.hcl", LEAF)
    old = tmp_path / "head/accounts/prod/sa/app/other/main/terragrunt.hcl"
    old.unlink()
    h, b, _, s, _ = run(tmp_path, [("A", "accounts/prod/sa/app/novo/main/terragrunt.hcl"),
                                   ("D", "accounts/prod/sa/app/other/main/terragrunt.hcl")])
    assert h == ["accounts/prod/sa/app/novo/main"]
    assert b == ["accounts/prod/sa/app/other/main"]
    assert "novo/main` — novo" in s and "other/main` — removido" in s


def test_rename_conta_origem_e_destino(tmp_path):
    both(tmp_path)
    h, _, _, _, _ = run(tmp_path, [("R100\taccounts/prod/sa/net/vpc/main/terragrunt.hcl", "accounts/prod/sa/db/pg/main/terragrunt.hcl")],
                        extra=["--no-dependents"])
    assert h == ["accounts/prod/sa/db/pg/main", "accounts/prod/sa/net/vpc/main"]


def test_usage_file_por_workspace(tmp_path):
    both(tmp_path)
    w(tmp_path / "head", "accounts/prod/sa/db/pg/main/infracost-usage.yml", "version: 0.1\n")
    _, _, _, _, cfg = run(tmp_path, [("M", "accounts/prod/sa/db/pg/main/infracost-usage.yml")], extra=["--no-dependents"])
    assert "usage_file: accounts/prod/sa/db/pg/main/infracost-usage.yml" in cfg


def test_root_restringe_ao_subdiretorio(tmp_path):
    for t in ("head", "base"):
        monorepo(tmp_path / t / "infra")
    h, _, _, _, _ = run(tmp_path, [("M", "infra/accounts/prod/sa/net/vpc/main/terragrunt.hcl"), ("M", "outro/x.tf")],
                        extra=["--root", "infra", "--no-dependents"])
    assert h == ["infra/accounts/prod/sa/net/vpc/main"]


def test_terraform_puro(tmp_path):
    for t in ("head", "base"):
        r = tmp_path / t
        w(r, "stacks/app/main.tf", 'module "m" {\n  source = "../../modules/m"\n}\n')
        w(r, "stacks/db/main.tf", 'resource "aws_db_instance" "x" {}\n')
        w(r, "modules/m/main.tf", 'resource "aws_instance" "x" {}\n')
    h, _, env, _, _ = run(tmp_path, [("M", "modules/m/main.tf"), ("M", "stacks/db/main.tf")])
    assert h == ["stacks/app", "stacks/db"]
    assert env["terraform_only"] == "true"
