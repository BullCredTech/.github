import subprocess, sys, pathlib, textwrap
SCRIPT = pathlib.Path(__file__).parent.parent / "scripts" / "pyproject_deps.py"

def run(tmp_path, toml, modo="reqs"):
    f = tmp_path / "pyproject.toml"; f.write_text(textwrap.dedent(toml))
    return subprocess.run([sys.executable, "-I", str(SCRIPT), modo, str(f)], capture_output=True, text=True)

def test_pep621_dependencies(tmp_path):
    r = run(tmp_path, '[project]\nname="x"\nversion="1"\ndependencies=["six>=1", "requests[security]==2.31 ; python_version>=\\"3.8\\""]\n')
    assert r.returncode == 0 and r.stdout.splitlines() == ['six>=1', 'requests[security]==2.31 ; python_version>="3.8"']

def test_extras_opcionais_nao_sao_instalados(tmp_path):
    r = run(tmp_path, '[project]\nname="x"\nversion="1"\ndependencies=["six"]\n[project.optional-dependencies]\ndev=["pytest"]\n')
    assert r.stdout.splitlines() == ["six"]

def test_dynamic_dependencies_sai_4(tmp_path):
    r = run(tmp_path, '[project]\nname="x"\ndynamic=["dependencies"]\n')
    assert r.returncode == 4

def test_poetry_converte_constraints(tmp_path):
    r = run(tmp_path, '''
        [tool.poetry.dependencies]
        python = "^3.11"
        a = "^1.2.3"
        b = "^0.2.3"
        c = "~1.4"
        d = "*"
        e = ">=1,<2"
        f = {version = "^2.0", extras = ["x"]}
        g = "1.5.0"
    ''')
    assert r.returncode == 0, r.stderr
    assert r.stdout.splitlines() == ["a>=1.2.3,<2.0.0", "b>=0.2.3,<0.3.0", "c>=1.4,<1.5", "d", "e>=1,<2", "f[x]>=2.0,<3.0", "g==1.5.0"]

def test_poetry_git_e_url_sao_recusados(tmp_path):
    r = run(tmp_path, '[tool.poetry.dependencies]\nx = {git = "https://example.com/x.git"}\n')
    assert r.returncode == 3

def test_url_direta_pep508_sai_3(tmp_path):
    r = run(tmp_path, '[project]\nname="x"\nversion="1"\ndependencies=["six @ https://evil/six.whl"]\n')
    assert r.returncode == 3

def test_toml_invalido_sai_1(tmp_path):
    r = run(tmp_path, '[project\n')
    assert r.returncode == 1

def test_modo_count_continua_funcionando(tmp_path):
    r = run(tmp_path, '[project]\nname="x"\nversion="1"\ndependencies=["a","b"]\n', modo="count")
    assert r.stdout.strip() == "2"
