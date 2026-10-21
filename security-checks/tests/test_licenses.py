import json, subprocess, sys, pathlib
SCRIPT = pathlib.Path(__file__).parent.parent / "scripts" / "licenses.py"
ALLOW = "MIT;Apache-2.0;BSD-3-Clause"

def run(args, stdin=""):
    return subprocess.run([sys.executable, str(SCRIPT), *args], input=stdin, capture_output=True, text=True)

def pip_json(*pairs):
    return json.dumps([{"Name": n, "Version": "1.0", "License": l} for n, l in pairs])

def test_pip_tudo_permitido():
    r = run(["pip", "--allow", ALLOW], pip_json(("a", "MIT License"), ("b", "BSD License"), ("c", "Apache Software License")))
    assert r.returncode == 0, r.stdout + r.stderr

def test_pip_reprova_gpl():
    r = run(["pip", "--allow", ALLOW], pip_json(("a", "MIT"), ("ruim", "GNU General Public License v3 (GPLv3)")))
    assert r.returncode == 1
    assert "ruim" in r.stdout

def test_pip_and_or_exige_todos_os_termos():
    r = run(["pip", "--allow", ALLOW], pip_json(("x", "MIT AND GPL-3.0")))
    assert r.returncode == 1

def test_pip_extra_allowed():
    r = run(["pip", "--allow", ALLOW + ";MPL-2.0"], pip_json(("x", "Mozilla Public License 2.0 (MPL 2.0)")))
    assert r.returncode == 0, r.stdout

def test_pip_licenca_desconhecida_avisa_sem_reprovar():
    r = run(["pip", "--allow", ALLOW], pip_json(("x", "UNKNOWN")))
    assert r.returncode == 0
    assert "sem licença declarada" in r.stdout

def test_dart_detecta_pelo_LICENSE(tmp_path):
    pkg = tmp_path / "cache" / "pkg_mit"; pkg.mkdir(parents=True)
    (pkg / "LICENSE").write_text("Permission is hereby granted, free of charge, to any person obtaining a copy")
    proj = tmp_path / "app" / ".dart_tool"; proj.mkdir(parents=True)
    (proj / "package_config.json").write_text(json.dumps({"packages": [{"name": "pkg_mit", "rootUri": pkg.as_uri()}]}))
    r = run(["dart", "--allow", ALLOW, str(tmp_path / "app")])
    assert r.returncode == 0, r.stdout

# extras acrescentados
def test_allowlist_vem_so_do_argumento():
    r = run(["pip", "--allow", "MIT"], pip_json(("x", "ISC License")))
    assert r.returncode == 1

def test_pip_json_invalido_falha():
    r = run(["pip", "--allow", ALLOW], "isto não é json")
    assert r.returncode != 0

def test_pip_parenteses_na_expressao_spdx():
    r = run(["pip", "--allow", ALLOW], pip_json(("x", "(MIT OR Apache-2.0)")))
    assert r.returncode == 0, r.stdout
    r = run(["pip", "--allow", ALLOW], pip_json(("x", "(MIT AND GPL-3.0)")))
    assert r.returncode == 1

def _dart(tmp_path, texto, root_uri):
    proj = tmp_path / "app" / ".dart_tool"; proj.mkdir(parents=True)
    (proj / "package_config.json").write_text(json.dumps({"packages": [{"name": "p", "rootUri": root_uri}]}))
    return run(["dart", "--allow", ALLOW, str(tmp_path / "app")])

def test_dart_creative_commons_que_nao_e_cc0_nao_vira_cc0(tmp_path):
    pkg = tmp_path / "app" / "pkgs" / "p"; pkg.mkdir(parents=True)
    (pkg / "LICENSE").write_text("Creative Commons Attribution 4.0 International Public License")
    r = _dart(tmp_path, "", "../pkgs/p")
    assert "sem licença declarada" in r.stdout

def test_dart_cc0_e_reconhecido(tmp_path):
    pkg = tmp_path / "app" / "pkgs" / "p"; pkg.mkdir(parents=True)
    (pkg / "LICENSE").write_text("CC0 1.0 Universal\n\nStatement of Purpose")
    proj = tmp_path / "app" / ".dart_tool"; proj.mkdir(parents=True)
    (proj / "package_config.json").write_text(json.dumps({"packages": [{"name": "p", "rootUri": "../pkgs/p"}]}))
    r = run(["dart", "--allow", ALLOW + ";CC0-1.0", str(tmp_path / "app")])
    assert r.returncode == 0, r.stdout

def test_dart_rooturi_relativo_resolve_contra_dart_tool(tmp_path):
    # rootUri "../pkgs/p" é relativo a .dart_tool/, e "pkgs/p" sem ../ também
    for uri, base in (("../pkgs/p", tmp_path / "app" / "pkgs" / "p"), ("sub/p", tmp_path / "app" / ".dart_tool" / "sub" / "p")):
        base.mkdir(parents=True, exist_ok=True)
        (base / "LICENSE").write_text("Permission is hereby granted, free of charge, to any person obtaining a copy")
        r = _dart(tmp_path, "", uri) if not (tmp_path / "app" / ".dart_tool").exists() else None
        cfg = tmp_path / "app" / ".dart_tool" / "package_config.json"
        cfg.parent.mkdir(parents=True, exist_ok=True)
        cfg.write_text(json.dumps({"packages": [{"name": "p", "rootUri": uri}]}))
        r = run(["dart", "--allow", ALLOW, str(tmp_path / "app")])
        assert r.returncode == 0 and "sem licença declarada" not in r.stdout, (uri, r.stdout)
