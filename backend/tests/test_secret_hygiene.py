from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
OPENAI_SECRET = re.compile(r"sk-[A-Za-z0-9_-]{20,}")
SECRET_OUTPUT = re.compile(
    r"print\(\s*(?:API_KEY|api_key|self\.api_key)"
    r"|logger\.(?:debug|info|warning|error|critical)\([^\n]*self\.api_key"
    r"|(?:print|logger\.(?:debug|info|warning|error|critical))\([^\n]*api_key\s*\[\s*:",
    re.IGNORECASE,
)


class SecretHygieneTests(unittest.TestCase):
    @staticmethod
    def backend_sources():
        for path in (ROOT / "backend").rglob("*.py"):
            if "venv" not in path.parts and "__pycache__" not in path.parts:
                yield path

    def test_backend_source_contains_no_openai_secret_literals(self) -> None:
        offenders = []
        for path in self.backend_sources():
            if OPENAI_SECRET.search(path.read_text(encoding="utf-8", errors="ignore")):
                offenders.append(str(path.relative_to(ROOT)))

        self.assertEqual(offenders, [])

    def test_backend_source_does_not_print_or_log_api_keys(self) -> None:
        offenders = []
        for path in self.backend_sources():
            if SECRET_OUTPUT.search(path.read_text(encoding="utf-8", errors="ignore")):
                offenders.append(str(path.relative_to(ROOT)))

        self.assertEqual(offenders, [])


if __name__ == "__main__":
    unittest.main()
