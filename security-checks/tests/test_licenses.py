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

# ---- modo site: inventário das distribuições instaladas, sem importar código instalado ----
def _dist(site, nome, versao, metadata_extra):
    d = site / f"{nome}-{versao}.dist-info"; d.mkdir(parents=True)
    (d / "METADATA").write_text(f"Metadata-Version: 2.1\nName: {nome}\nVersion: {versao}\n{metadata_extra}\n")

def test_site_inventaria_expressao_classificador_e_texto(tmp_path):
    site = tmp_path / "site-packages"; site.mkdir()
    _dist(site, "comexpr", "1.0", "License-Expression: MIT-0")
    _dist(site, "comclass", "2.0", "Classifier: License :: OSI Approved :: BSD License\nClassifier: License :: OSI Approved\n")
    _dist(site, "comtexto", "3.0", "License: Permission is hereby granted, free of charge, to any person obtaining a copy\n of this software")
    _dist(site, "semnada", "4.0", "License: UNKNOWN")
    _dist(site, "pip", "99", "License-Expression: MIT")
    r = run(["site", "--allow", "x", str(site)])
    assert r.returncode == 0, r.stderr
    inv = {p["Name"]: p["License"] for p in json.loads(r.stdout)}
    assert inv["comexpr"] == "MIT-0"
    assert inv["comclass"] == "BSD License"
    assert inv["comtexto"] == "mit"
    assert inv["semnada"] in ("", "UNKNOWN")
    assert "pip" not in inv

def test_site_nao_executa_codigo_instalado(tmp_path):
    site = tmp_path / "site-packages"; site.mkdir()
    marcador = tmp_path / "EXECUTOU"
    (site / "evil.pth").write_text(f"import os; open({str(marcador)!r}, 'w').write('x')\n")
    _dist(site, "x", "1.0", "License-Expression: MIT")
    r = subprocess.run([sys.executable, "-I", "-S", str(SCRIPT), "site", str(site)], capture_output=True, text=True)
    assert r.returncode == 0 and not marcador.exists()

def test_site_licenca_longa_nao_reconhecida_reprova_e_vazia_so_avisa(tmp_path):
    site = tmp_path / "site-packages"; site.mkdir()
    texto = "Este software e propriedade da empresa X.\n Proibida a redistribuicao sem autorizacao. " * 5
    _dist(site, "proprietario", "1.0", "License: " + texto.replace("\n", "\n        "))
    inv = run(["site", str(site)])
    assert inv.returncode == 0
    lic = json.loads(inv.stdout)[0]["License"]
    assert lic and "\n" not in lic and len(lic) <= 200
    r = run(["pip", "--allow", ALLOW], inv.stdout)
    assert r.returncode == 1 and "proprietario" in r.stdout
    # vazio / UNKNOWN continua só avisando
    site2 = tmp_path / "s2"; site2.mkdir()
    _dist(site2, "semnada", "1.0", "License: UNKNOWN")
    r2 = run(["pip", "--allow", ALLOW], run(["site", str(site2)]).stdout)
    assert r2.returncode == 0 and "sem licença declarada" in r2.stdout

# ---- classificadores do PyPI viram ids SPDX antes de separar em termos ----
sys.path.insert(0, str(SCRIPT.parent))
import licenses as L  # noqa: E402

def test_classificadores_gnu_viram_spdx():
    casos = {
        "GNU General Public License v2 or later (GPLv2+)": ["gpl-2.0-or-later"],
        "GNU General Public License v2 (GPLv2)": ["gpl-2.0-only"],
        "GNU General Public License v3 (GPLv3)": ["gpl-3.0-only"],
        "GNU General Public License v3 or later (GPLv3+)": ["gpl-3.0-or-later"],
        "GNU General Public License (GPL)": ["gpl-2.0-or-later"],
        "GNU Lesser General Public License v2 (LGPLv2)": ["lgpl-2.0-only"],
        "GNU Lesser General Public License v2 or later (LGPLv2+)": ["lgpl-2.0-or-later"],
        "GNU Lesser General Public License v3 (LGPLv3)": ["lgpl-3.0-only"],
        "GNU Lesser General Public License v3 or later (LGPLv3+)": ["lgpl-3.0-or-later"],
        "GNU Library or Lesser General Public License (LGPL)": ["lgpl-2.0-or-later"],
        "GNU Affero General Public License v3": ["agpl-3.0-only"],
        "GNU Affero General Public License v3 or later (AGPLv3+)": ["agpl-3.0-or-later"],
        "Mozilla Public License 2.0 (MPL 2.0)": ["mpl-2.0"],
        "Eclipse Public License 2.0 (EPL-2.0)": ["epl-2.0"],
        "European Union Public Licence 1.2 (EUPL 1.2)": ["eupl-1.2"],
        "Python Software Foundation License": ["psf-2.0"],
        "Academic Free License (AFL)": ["afl-3.0"],
    }
    for texto, esperado in casos.items():
        assert L.termos(texto) == esperado, (texto, L.termos(texto))

def test_or_later_generico_nao_separa_e_or_continua_separando():
    assert len(L.termos("GNU Foo Public License v9 or later")) == 1
    assert L.termos("GPL-2.0-or-later") == ["gpl-2.0-or-later"]
    assert L.termos("GPL-2.0+") == ["gpl-2.0-or-later"]
    assert L.termos("MIT OR GPL-3.0") == ["mit", "gpl-3.0-only"]
    assert L.termos("MIT or Apache-2.0") == ["mit", "apache-2.0"]

def test_mutagen_so_passa_com_extra_allowed_exato():
    gpl = pip_json(("mutagen", "GNU General Public License v2 or later (GPLv2+)"))
    r = run(["pip", "--allow", ALLOW], gpl)
    assert r.returncode == 1 and "gpl-2.0-or-later" in r.stdout
    assert run(["pip", "--allow", ALLOW + ";GPL-2.0-or-later"], gpl).returncode == 0
    # GPL-2.0-only não cobre "or later"
    assert run(["pip", "--allow", ALLOW + ";GPL-2.0-only"], gpl).returncode == 1

def test_lgpl_variantes_e_ids_spdx_only_no_extra_allowed():
    lg = pip_json(("a", "GNU Lesser General Public License v3 (LGPLv3)"))
    assert run(["pip", "--allow", ALLOW], lg).returncode == 1
    assert run(["pip", "--allow", ALLOW + ";LGPL-3.0-only"], lg).returncode == 0
    assert run(["pip", "--allow", ALLOW + ";LGPL-3.0"], lg).returncode == 0   # id antigo equivale a -only
    bib = pip_json(("b", "GNU Library or Lesser General Public License (LGPL)"))
    assert run(["pip", "--allow", ALLOW + ";LGPL-2.0-or-later"], bib).returncode == 0

def npm_json(*itens):
    return json.dumps([{"Name": n, "Version": "1.0", "Path": c, "License": l} for n, c, l in itens])

def test_npm_interno_bull_unlicensed_passa_e_sai_listado():
    r = run(["npm", "--allow", ALLOW], npm_json(
        ("@bull-exemplo/sdk", "node_modules/@bull-exemplo/sdk", "UNLICENSED"),
        ("@bull-outro/lib", "apps/api/node_modules/@bull-outro/lib", "UNLICENSED"),
        ("lodash", "node_modules/lodash", "MIT")))
    assert r.returncode == 0, r.stdout + r.stderr
    assert "@bull-exemplo/sdk" in r.stdout and "interno" in r.stdout

def test_npm_unlicensed_fora_do_escopo_bull_reprova():
    r = run(["npm", "--allow", ALLOW], npm_json(("@outra/pkg", "node_modules/@outra/pkg", "UNLICENSED")))
    assert r.returncode == 1 and "@outra/pkg" in r.stdout

def test_npm_nome_bull_em_outro_caminho_nao_vira_interno():
    r = run(["npm", "--allow", ALLOW], npm_json(("@bull-exemplo/sdk", "node_modules/qualquer", "UNLICENSED")))
    assert r.returncode == 1

def test_npm_interno_com_licenca_fora_da_allowlist_reprova():
    r = run(["npm", "--allow", ALLOW], npm_json(("@bull-outro/x", "node_modules/@bull-outro/x", "GPL-3.0-only")))
    assert r.returncode == 1

def test_pip_unlicensed_com_nome_bull_nao_ganha_excecao():
    r = run(["pip", "--allow", ALLOW], pip_json(("@bull-outro/x", "UNLICENSED")))
    assert r.returncode == 1

ALLOWLIST = (pathlib.Path(__file__).parent.parent / "license-allowlist.txt").read_text()
ALLOW_PADRAO = ";".join(l.strip() for l in ALLOWLIST.splitlines() if l.strip() and not l.strip().startswith("#"))

def test_or_com_uma_opcao_permitida_passa():
    r = run(["npm", "--allow", ALLOW], npm_json(
        ("jszip", "node_modules/jszip", "(MIT OR GPL-3.0-or-later)"),
        ("dompurify", "node_modules/dompurify", "(MPL-2.0 OR Apache-2.0)")))
    assert r.returncode == 0, r.stdout

def test_or_sem_opcao_permitida_reprova():
    r = run(["npm", "--allow", ALLOW], npm_json(("x", "node_modules/x", "GPL-3.0-only OR AGPL-3.0-only")))
    assert r.returncode == 1 and "copyleft forte" in r.stdout

def test_and_com_um_termo_fora_reprova():
    r = run(["npm", "--allow", ALLOW], npm_json(("x", "node_modules/x", "MIT AND GPL-3.0-only")))
    assert r.returncode == 1

def test_expressao_aninhada():
    ok = npm_json(("x", "node_modules/x", "(GPL-3.0-only OR (MIT AND Apache-2.0))"))
    assert run(["npm", "--allow", ALLOW], ok).returncode == 0
    ruim = npm_json(("y", "node_modules/y", "(GPL-3.0-only OR (MIT AND AGPL-3.0-only))"))
    assert run(["npm", "--allow", ALLOW], ruim).returncode == 1

def test_expressao_malformada_cai_na_regra_antiga():
    r = run(["npm", "--allow", ALLOW], npm_json(("x", "node_modules/x", "(MIT OR GPL-3.0-only")))
    assert r.returncode == 1

def test_opcao_sem_licenca_reconhecivel_nao_conta_como_permitida():
    r = run(["npm", "--allow", ALLOW], npm_json(("x", "node_modules/x", "UNKNOWN OR GPL-3.0-only")))
    assert r.returncode == 1

def test_allowlist_padrao_aceita_licencas_de_saas():
    pacotes = npm_json(
        ("caniuse-lite", "node_modules/caniuse-lite", "CC-BY-4.0"),
        ("spdx-exceptions", "node_modules/spdx-exceptions", "CC-BY-3.0"),
        ("@vercel/stega", "node_modules/@vercel/stega", "MPL-2.0"),
        ("@sentry/cli", "node_modules/@sentry/cli", "FSL-1.1-MIT"),
        ("@img/sharp-libvips-linux-x64", "node_modules/@img/sharp-libvips-linux-x64", "LGPL-3.0-or-later"),
        ("traverse", "node_modules/traverse", "MIT/X11"))
    r = run(["npm", "--allow", ALLOW_PADRAO], pacotes)
    assert r.returncode == 0, r.stdout
    py = pip_json(("psycopg2-binary", "GNU Library or Lesser General Public License (LGPL)"),
                  ("certifi", "Mozilla Public License 2.0 (MPL 2.0)"), ("paramiko", "LGPL-2.1"))
    assert run(["pip", "--allow", ALLOW_PADRAO], py).returncode == 0

def test_allowlist_padrao_segue_bloqueando_uso_em_rede_e_gpl():
    for lic in ("AGPL-3.0-only", "SSPL-1.0", "BUSL-1.1", "OSL-3.0", "EUPL-1.2", "GPL-3.0-only", "CC-BY-NC-4.0"):
        r = run(["npm", "--allow", ALLOW_PADRAO], npm_json(("x", "node_modules/x", lic)))
        assert r.returncode == 1, lic

def test_conhecidos_cobre_pacote_sem_licenca(tmp_path):
    lista = tmp_path / "known.txt"
    lista.write_text("# comentario\npause@1.0 MIT   # registry\n")
    sem = npm_json(("pause", "node_modules/pause", ""))
    assert run(["npm", "--allow", ALLOW], sem).returncode == 1
    r = run(["npm", "--allow", ALLOW, "--conhecidos", str(lista)], sem)
    assert r.returncode == 0, r.stdout
    assert "lista de conhecidos" in r.stdout

def test_conhecidos_nao_vale_para_outra_versao_nem_sobrepoe_licenca(tmp_path):
    lista = tmp_path / "known.txt"
    lista.write_text("pause@0.0.1 MIT\nx@1.0 MIT\n")
    outra = npm_json(("pause", "node_modules/pause", ""))
    outra = outra.replace('"1.0"', '"0.0.2"')
    assert run(["npm", "--allow", ALLOW, "--conhecidos", str(lista)], outra).returncode == 1
    declarada = npm_json(("x", "node_modules/x", "GPL-3.0-only"))
    assert run(["npm", "--allow", ALLOW, "--conhecidos", str(lista)], declarada).returncode == 1

def test_conhecidos_invalido_falha(tmp_path):
    lista = tmp_path / "known.txt"
    lista.write_text("pause MIT\n")
    r = run(["npm", "--allow", ALLOW, "--conhecidos", str(lista)], npm_json(("x", "node_modules/x", "MIT")))
    assert r.returncode == 2
