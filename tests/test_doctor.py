"""Fixture tests for scripts/codex-doctor.sh (and scripts/codex-doctor.ps1 when pwsh exists).

Run from the repository root:

    python3 -m unittest discover -s tests -v

Every run uses a throw-away HOME / CODEX_HOME and a fake `codex` binary, so your real
~/.codex is never read. Nothing leaves the machine: the --live cases talk to
tests/mock_gateway.py on 127.0.0.1.

The bash doctor is exercised with both TOML parsers:
  * "fallback" (awk line parser) - always
  * "python"   (tomllib)         - when this interpreter is Python 3.11+
The PowerShell doctor runs the same table when `pwsh` is on PATH (CI does this).
"""

import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests" / "fixtures"
BASH_DOCTOR = ROOT / "scripts" / "codex-doctor.sh"
PS_DOCTOR = ROOT / "scripts" / "codex-doctor.ps1"
MOCK = ROOT / "tests" / "mock_gateway.py"

ROW = re.compile(r"^\s*(\d+[ab]?)\s+(PASS|WARN|FAIL|SKIP)\s+(.*)$")
TEST_KEY = "doctor-test-key-0123456789"
HAS_TOMLLIB = sys.version_info >= (3, 11)
WINDOWS = os.name == "nt"
BASH = None if WINDOWS else (os.environ.get("DOCTOR_TEST_BASH") or shutil.which("bash"))  # CI: /bin/bash 3.2 on macOS
PWSH = shutil.which("pwsh")
WINPS = shutil.which("powershell") if WINDOWS else None  # Windows PowerShell 5.1
ENGINE_FILTER = [e for e in os.environ.get("DOCTOR_TEST_ENGINES", "").split(",") if e]


def engines():
    """(name, runner-kind, parser) combinations available on this machine."""
    out = []
    if BASH:
        out.append(("bash/fallback", "bash", "fallback"))
        if HAS_TOMLLIB:
            out.append(("bash/python", "bash", "python"))
    if PWSH:
        out.append(("pwsh", "pwsh", None))
    if WINPS:
        out.append(("powershell-5.1", "powershell", None))
    if ENGINE_FILTER:
        out = [e for e in out if e[1] in ENGINE_FILTER]
    return out


class Sandbox:
    """A temporary HOME with .codex/, a project dir with .git/, and a fake codex binary."""

    def __init__(self, codex_version="codex-cli 0.158.0"):
        self.tmp = tempfile.TemporaryDirectory(prefix="codex-doctor-test-")
        base = Path(self.tmp.name)
        self.home = base / "home"
        self.codex_home = self.home / ".codex"
        self.project = base / "project"
        self.codex_home.mkdir(parents=True)
        (self.project / ".git").mkdir(parents=True)
        (base / "bin").mkdir()
        if codex_version is None:
            self.codex_bin = base / "bin" / "no-such-codex"
        elif WINDOWS:
            self.codex_bin = base / "bin" / "codex.cmd"
            self.codex_bin.write_text("@echo %s\r\n" % codex_version)
        else:
            self.codex_bin = base / "bin" / "codex"
            self.codex_bin.write_text("#!/bin/sh\necho '%s'\n" % codex_version)
            self.codex_bin.chmod(self.codex_bin.stat().st_mode | stat.S_IEXEC)

    def write_config(self, text, name="config.toml"):
        (self.codex_home / name).write_text(text, encoding="utf-8")

    def use_fixture(self, fixture, name="config.toml"):
        self.write_config((FIXTURES / fixture).read_text(encoding="utf-8"), name)

    def write_project_config(self, fixture):
        target = self.project / ".codex"
        target.mkdir(exist_ok=True)
        shutil.copy(str(FIXTURES / fixture), str(target / "config.toml"))

    def close(self):
        self.tmp.cleanup()


def run_doctor(kind, parser, sandbox, args=(), env_extra=None, set_key=True):
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": str(sandbox.home),
        "USERPROFILE": str(sandbox.home),
        "NO_COLOR": "1",
        "CODEX_DOCTOR_CODEX_BIN": str(sandbox.codex_bin),
        "CODEX_DOCTOR_TIMEOUT": "10",
    }
    for name in ("SYSTEMROOT", "WINDIR", "TEMP", "TMP", "PATHEXT", "PSModulePath"):
        if os.environ.get(name):
            env[name] = os.environ[name]
    if WINDOWS:
        # [Environment]::GetFolderPath('UserProfile') ignores USERPROFILE, so point Codex's home explicitly.
        env["CODEX_HOME"] = str(sandbox.codex_home)
    if set_key:
        env["DOCTOR_TEST_API_KEY"] = TEST_KEY
    if kind == "bash":
        env["CODEX_DOCTOR_PARSER"] = parser
        env["CODEX_DOCTOR_PYTHON"] = sys.executable
        cmd = [BASH, str(BASH_DOCTOR)] + list(args)
    elif kind == "pwsh":
        cmd = [PWSH, "-NoProfile", "-NonInteractive", "-File", str(PS_DOCTOR)] + [ps_arg(a) for a in args]
    else:
        cmd = [WINPS, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(PS_DOCTOR)] + \
            [ps_arg(a) for a in args]
    if env_extra:
        env.update(env_extra)
    proc = subprocess.run(cmd, cwd=str(sandbox.project), env=env, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, universal_newlines=True, timeout=120)
    rows = {}
    for line in proc.stdout.splitlines():
        m = ROW.match(line)
        if m:
            rows[m.group(1)] = (m.group(2), m.group(3))
    return proc, rows


def ps_arg(arg):
    """Translate bash-style flags to the PowerShell parameter names."""
    return {"--live": "-Live", "--profile": "-ProfileName", "--config": "-Config",
            "--model": "-Model", "--project": "-Project", "--no-color": "-NoColor"}.get(arg, arg)


# fixture -> (expected statuses for some checks, expected exit code)
FIXTURE_CASES = {
    "ok.toml": ({"1": "PASS", "2": "PASS", "3": "PASS", "4": "PASS", "5": "PASS", "6": "PASS", "7": "PASS",
                 "8": "PASS", "9": "PASS", "10": "PASS", "11a": "SKIP", "11b": "SKIP"}, 0),
    "reserved-id.toml": ({"5": "FAIL", "6": "SKIP", "9": "SKIP"}, 1),
    "missing-env.toml": ({"5": "PASS", "9": "FAIL"}, 1),
    "key-order.toml": ({"4": "FAIL", "5": "FAIL"}, 2),
    "double-v1.toml": ({"7": "FAIL", "9": "PASS"}, 1),
    "responses-suffix.toml": ({"7": "FAIL"}, 1),
    "wire-api-chat.toml": ({"8": "FAIL"}, 1),
    "legacy-profile.toml": ({"10": "FAIL", "5": "PASS"}, 1),
    "env-key-is-secret.toml": ({"9": "FAIL"}, 1),
    "api-key-field.toml": ({"6": "WARN", "9": "FAIL"}, 1),
    "broken-syntax.toml": ({"3": "FAIL", "4": "SKIP"}, 1),
}

SECRETS_IN_FIXTURES = ["sk-not-a-real-key-doctor-fixture-7f3a", "sk-not-a-real-key-doctor-fixture-9c1e"]


class DoctorFixtureTests(unittest.TestCase):
    def setUp(self):
        if not engines():
            self.skipTest("neither bash nor pwsh is available")

    def assert_rows(self, proc, rows, expected, code, label):
        out = proc.stdout + proc.stderr
        for check, status in expected.items():
            self.assertIn(check, rows, "%s: row %s missing\n%s" % (label, check, out))
            self.assertEqual(rows[check][0], status, "%s: check %s\n%s" % (label, check, out))
        fails = sum(1 for s, _ in rows.values() if s == "FAIL")
        self.assertEqual(proc.returncode, fails, "%s: exit code must equal FAIL rows\n%s" % (label, out))
        self.assertEqual(proc.returncode, code, "%s: exit code\n%s" % (label, out))
        self.assertNotIn(TEST_KEY, out, "%s: key leaked" % label)
        for secret in SECRETS_IN_FIXTURES:
            self.assertNotIn(secret, out, "%s: secret from config leaked" % label)

    def test_fixtures(self):
        for fixture, (expected, code) in sorted(FIXTURE_CASES.items()):
            for label, kind, parser in engines():
                with self.subTest(fixture=fixture, engine=label):
                    box = Sandbox()
                    try:
                        box.use_fixture(fixture)
                        proc, rows = run_doctor(kind, parser, box)
                        self.assert_rows(proc, rows, expected, code, "%s [%s]" % (fixture, label))
                    finally:
                        box.close()

    def test_project_level_config_warns(self):
        for label, kind, parser in engines():
            with self.subTest(engine=label):
                box = Sandbox()
                try:
                    box.use_fixture("ok.toml")
                    box.write_project_config("project-level.toml")
                    proc, rows = run_doctor(kind, parser, box)
                    self.assert_rows(proc, rows, {"9": "PASS", "10": "WARN"}, 0, label)
                    self.assertIn("model_provider", rows["10"][1])
                finally:
                    box.close()

    def test_project_level_config_only(self):
        """Provider only in the project file and no user config: Codex never sees it."""
        for label, kind, parser in engines():
            with self.subTest(engine=label):
                box = Sandbox()
                try:
                    box.write_project_config("project-level.toml")
                    proc, rows = run_doctor(kind, parser, box)
                    self.assert_rows(proc, rows, {"2": "FAIL", "3": "SKIP", "10": "WARN"}, 1, label)
                finally:
                    box.close()

    def test_missing_env_var(self):
        for label, kind, parser in engines():
            with self.subTest(engine=label):
                box = Sandbox()
                try:
                    box.use_fixture("ok.toml")
                    proc, rows = run_doctor(kind, parser, box, set_key=False)
                    self.assert_rows(proc, rows, {"9": "FAIL"}, 1, label)
                    self.assertIn("DOCTOR_TEST_API_KEY", rows["9"][1])
                finally:
                    box.close()

    def test_codex_home_missing_dir(self):
        for label, kind, parser in engines():
            with self.subTest(engine=label):
                box = Sandbox()
                try:
                    missing = str(box.home / "nope")
                    proc, rows = run_doctor(kind, parser, box, env_extra={"CODEX_HOME": missing})
                    self.assert_rows(proc, rows, {"2": "FAIL"}, 1, label)
                    self.assertIn("CODEX_HOME", rows["2"][1])
                finally:
                    box.close()

    def test_config_saved_as_txt(self):
        for label, kind, parser in engines():
            with self.subTest(engine=label):
                box = Sandbox()
                try:
                    box.use_fixture("ok.toml", name="config.toml.txt")
                    proc, rows = run_doctor(kind, parser, box)
                    self.assert_rows(proc, rows, {"2": "FAIL"}, 1, label)
                    self.assertIn("config.toml.txt", rows["2"][1])
                finally:
                    box.close()

    def test_codex_version(self):
        cases = [("codex-cli 0.120.3", "WARN"), (None, "WARN"), ("codex-cli 10.2.3", "PASS")]
        for version, status in cases:
            for label, kind, parser in engines():
                with self.subTest(version=version, engine=label):
                    box = Sandbox(codex_version=version)
                    try:
                        box.use_fixture("ok.toml")
                        proc, rows = run_doctor(kind, parser, box)
                        self.assert_rows(proc, rows, {"1": status}, 0, label)
                    finally:
                        box.close()

    def test_bom_and_crlf(self):
        text = (FIXTURES / "ok.toml").read_text(encoding="utf-8").replace("\n", "\r\n")
        for label, kind, parser in engines():
            with self.subTest(engine=label):
                box = Sandbox()
                try:
                    (box.codex_home / "config.toml").write_bytes(b"\xef\xbb\xbf" + text.encode("utf-8"))
                    proc, rows = run_doctor(kind, parser, box)
                    self.assert_rows(proc, rows, {"3": "PASS", "5": "PASS", "7": "PASS"}, 0, label)
                finally:
                    box.close()

    def test_usage_error(self):
        if not BASH:
            self.skipTest("bash not available")
        box = Sandbox()
        try:
            proc, _ = run_doctor("bash", "fallback", box, args=["--bogus"])
            self.assertEqual(proc.returncode, 64)
        finally:
            box.close()


class ExampleConfigTests(unittest.TestCase):
    """The shipped examples must pass the doctor's offline checks."""

    def run_example(self, files, env_key, args=()):
        for label, kind, parser in engines():
            with self.subTest(files=files, engine=label):
                box = Sandbox()
                try:
                    for src, dst in files:
                        box.write_config((ROOT / src).read_text(encoding="utf-8"), dst)
                    proc, rows = run_doctor(kind, parser, box, args=args, env_extra={env_key: TEST_KEY})
                    for check in ("2", "3", "4", "5", "6", "7", "8", "9", "10"):
                        self.assertEqual(rows.get(check, ("?",))[0], "PASS",
                                         "%s check %s\n%s" % (label, check, proc.stdout))
                    self.assertEqual(proc.returncode, 0, proc.stdout)
                finally:
                    box.close()

    def test_generic_example(self):
        self.run_example([("config/config.toml.example", "config.toml")], "YOUR_GATEWAY_API_KEY")

    def test_gptzzz_example(self):
        self.run_example([("config/gptzzz.toml", "config.toml")], "GPTZZZ_API_KEY")

    def test_gptzzz_as_profile(self):
        self.run_example([("config/config.toml.example", "config.toml"), ("config/gptzzz.toml", "gptzzz.config.toml")],
                         "GPTZZZ_API_KEY", args=["--profile", "gptzzz"])

    def test_profiles_base(self):
        self.run_example([("config/profiles/config.toml.example", "config.toml")], "GATEWAY_A_API_KEY")

    def test_profiles_switch(self):
        self.run_example([("config/profiles/config.toml.example", "config.toml"),
                          ("config/profiles/gateway-b.config.toml.example", "gateway-b.config.toml")],
                         "GATEWAY_B_API_KEY", args=["--profile", "gateway-b"])

    def test_profile_file_missing(self):
        for label, kind, parser in engines():
            with self.subTest(engine=label):
                box = Sandbox()
                try:
                    box.use_fixture("ok.toml")
                    proc, rows = run_doctor(kind, parser, box, args=["--profile", "nope"])
                    self.assertEqual(rows["2"][0], "FAIL", proc.stdout)
                    self.assertEqual(proc.returncode, 1, proc.stdout)
                finally:
                    box.close()


class LiveCheckTests(unittest.TestCase):
    """--live against the local mock gateway (127.0.0.1 only, no real key, nothing billed)."""

    def start_mock(self, mode):
        env = dict(os.environ, MOCK_GATEWAY_KEY=TEST_KEY)
        proc = subprocess.Popen([sys.executable, str(MOCK), mode], stdout=subprocess.PIPE,
                                universal_newlines=True, env=env)
        port = int(proc.stdout.readline().strip())
        self.addCleanup(proc.stdout.close)
        self.addCleanup(proc.wait)
        self.addCleanup(proc.terminate)
        time.sleep(0.1)
        return port

    def run_live(self, mode, expected, code, model=None, key=TEST_KEY):
        port = self.start_mock(mode)
        config = (FIXTURES / "ok.toml").read_text(encoding="utf-8").replace(
            "https://gateway.example.com/v1", "http://127.0.0.1:%d/v1" % port)
        args = ["--live"] + (["--model", model] if model else [])
        for label, kind, parser in engines():
            if kind == "bash" and shutil.which("curl") is None:
                continue  # the bash doctor needs curl for --live
            with self.subTest(mode=mode, engine=label):
                box = Sandbox()
                try:
                    box.write_config(config)
                    proc, rows = run_doctor(kind, parser, box, args=args,
                                            env_extra={"DOCTOR_TEST_API_KEY": key})
                    out = proc.stdout + proc.stderr
                    for check, status in expected.items():
                        self.assertEqual(rows.get(check, ("?",))[0], status, "%s %s\n%s" % (label, check, out))
                    self.assertEqual(proc.returncode, code, out)
                    self.assertNotIn(key, out, "key leaked")
                finally:
                    box.close()

    def test_ok(self):
        self.run_live("ok", {"7": "PASS", "11a": "PASS", "11b": "PASS"}, 0)

    def test_stream_without_completed(self):
        self.run_live("no-completed", {"11a": "PASS", "11b": "FAIL"}, 1)

    def test_json_instead_of_sse(self):
        self.run_live("json-not-sse", {"11b": "FAIL"}, 1)

    def test_gateway_without_responses(self):
        self.run_live("no-responses", {"11a": "PASS", "11b": "FAIL"}, 1)

    def test_response_failed(self):
        self.run_live("failed", {"11b": "FAIL"}, 1)

    def test_wrong_key(self):
        self.run_live("ok", {"9": "PASS", "11a": "FAIL", "11b": "FAIL"}, 2, key="wrong-key-for-doctor-test")

    def test_unknown_model(self):
        self.run_live("ok", {"11a": "WARN", "11b": "FAIL"}, 1, model="not-a-model")


if __name__ == "__main__":
    unittest.main()
