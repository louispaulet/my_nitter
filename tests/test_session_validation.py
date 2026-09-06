import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "create_session.py"
SPEC = importlib.util.spec_from_file_location("create_session", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class SessionValidationTests(unittest.TestCase):
    def test_cookie_session_is_valid(self):
        record = {
            "kind": "cookie",
            "username": "foo",
            "id": "123",
            "auth_token": "abc",
            "ct0": "xyz",
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sessions.jsonl"
            path.write_text(json.dumps(record) + "\n", encoding="utf-8")
            self.assertEqual(MODULE.validate_sessions_file(path), 1)

    def test_missing_auth_token_is_rejected(self):
        record = {
            "kind": "cookie",
            "username": "foo",
            "id": "123",
            "ct0": "xyz",
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sessions.jsonl"
            path.write_text(json.dumps(record) + "\n", encoding="utf-8")
            with self.assertRaises(RuntimeError):
                MODULE.validate_sessions_file(path)


if __name__ == "__main__":
    unittest.main()

