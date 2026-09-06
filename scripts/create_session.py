#!/usr/bin/env python3
"""Create a local Nitter session using upstream's browser helper.

Credentials are read from the ignored .env file and passed directly to the
upstream helper in this Python process. They are never command-line arguments.
"""

from __future__ import annotations

import argparse
import asyncio
import importlib.util
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


REQUIRED_SESSION_KEYS = ("kind", "username", "id", "auth_token", "ct0")
NITTER_REPOSITORY = "https://github.com/zedeus/nitter.git"
SHA_PATTERN = re.compile(r"^[0-9a-fA-F]{40}$")
ENV_KEY_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def project_root() -> Path:
    return Path(__file__).resolve().parents[1]


def fail(message: str) -> "NoReturn":
    raise RuntimeError(message)


def parse_dotenv(path: Path) -> dict[str, str]:
    """Parse simple dotenv assignments without executing shell code."""

    if not path.is_file():
        fail(".env not found. Run 'cp .env.example .env' and fill in the local values.")

    mode = stat.S_IMODE(path.stat().st_mode)
    if mode & 0o077:
        fail(f"{path} is readable by group or other users; run 'chmod 600 {path}'.")

    values: dict[str, str] = {}
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        if "=" not in line:
            fail(f"Invalid .env line {line_number}: expected KEY=VALUE.")
        key, value = line.split("=", 1)
        key = key.strip()
        if not ENV_KEY_PATTERN.fullmatch(key):
            fail(f"Invalid .env key on line {line_number}.")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] == '"':
            try:
                value = json.loads(value)
            except json.JSONDecodeError as error:
                fail(f"Invalid quoted value for {key} on line {line_number}: {error}")
        elif len(value) >= 2 and value[0] == value[-1] == "'":
            value = value[1:-1]
        values[key] = value
    return values


def required_config(values: dict[str, str]) -> tuple[str, str, str | None, str]:
    username = values.get("X_USERNAME", "").strip()
    password = values.get("X_PASSWORD", "")
    totp_seed = values.get("X_TOTP_SECRET", "").strip() or None
    nitter_ref = values.get("NITTER_REF", "").strip()
    if not username:
        fail("X_USERNAME is required in .env.")
    if not password:
        fail("X_PASSWORD is required in .env.")
    if not SHA_PATTERN.fullmatch(nitter_ref):
        fail("NITTER_REF must be an exact 40-character upstream Git commit SHA.")
    return username, password, totp_seed, nitter_ref


def run(command: list[str], *, cwd: Path | None = None) -> None:
    subprocess.run(command, cwd=cwd, check=True)


def ensure_nitter_checkout(root: Path, nitter_ref: str) -> Path:
    cache_dir = root / ".cache"
    nitter_dir = cache_dir / "nitter"
    cache_dir.mkdir(mode=0o700, exist_ok=True)
    if not (nitter_dir / ".git").is_dir():
        if nitter_dir.exists():
            fail(f"{nitter_dir} exists but is not a Git checkout.")
        run(["git", "clone", "--filter=blob:none", NITTER_REPOSITORY, str(nitter_dir)])
    run(["git", "-C", str(nitter_dir), "fetch", "--depth=1", "origin", nitter_ref])
    run(["git", "-C", str(nitter_dir), "checkout", "--detach", nitter_ref])
    return nitter_dir


def ensure_virtualenv(root: Path, nitter_dir: Path) -> Path:
    venv_dir = root / ".venv"
    venv_python = venv_dir / "bin" / "python"
    if not venv_python.is_file():
        run([sys.executable, "-m", "venv", str(venv_dir)])
    run([
        str(venv_python),
        "-m",
        "pip",
        "install",
        "--disable-pip-version-check",
        "-r",
        str(nitter_dir / "tools" / "requirements.txt"),
    ])
    return venv_python


def reexec_in_virtualenv(root: Path, venv_python: Path) -> None:
    venv_dir = root / ".venv"
    if Path(sys.prefix).resolve() == venv_dir.resolve():
        return
    os.execv(str(venv_python), [str(venv_python), str(Path(__file__).resolve()), *sys.argv[1:]])


def load_upstream_helper(nitter_dir: Path):
    helper_path = nitter_dir / "tools" / "create_session_browser.py"
    if not helper_path.is_file():
        fail(f"Upstream browser session helper not found at {helper_path}.")
    spec = importlib.util.spec_from_file_location("nitter_create_session_browser", helper_path)
    if spec is None or spec.loader is None:
        fail("Could not load upstream browser session helper.")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if not hasattr(module, "login_and_get_session"):
        fail("Upstream browser helper has no login_and_get_session function.")
    return module


async def _safe_find_visible_input(tab, name: str, timeout: int = 15):
    """Select the actually visible input when X renders duplicate forms.

    X currently renders responsive/transitioning duplicate inputs. The pinned
    upstream helper only checks the bounding box, so it can select an input
    with opacity 0 and leave keyboard focus on the account field. Keep the
    login flow upstream-owned, but make this selector require a visible,
    topmost element before upstream types into it.
    """

    selector = f'input[name="{name}"]'
    for _ in range(timeout * 2):
        try:
            active_index = await tab.evaluate(
                f"""(() => {{
                    const inputs = Array.from(document.querySelectorAll('{selector}'));
                    const visible = (element) => {{
                        const rect = element.getBoundingClientRect();
                        const style = getComputedStyle(element);
                        return rect.width > 0 && rect.height > 0
                            && style.display !== 'none'
                            && style.visibility !== 'hidden'
                            && style.opacity !== '0';
                    }};
                    const active = inputs.findIndex((element) =>
                        visible(element) && document.activeElement === element);
                    if (active >= 0) return active;
                    return inputs.findIndex(visible);
                }})()"""
            )
            if isinstance(active_index, int) and active_index >= 0:
                candidates = await tab.select_all(selector)
                if active_index < len(candidates):
                    return candidates[active_index]
        except Exception:
            pass
        await asyncio.sleep(0.5)
    return None


async def _safe_click_continue(tab):
    """Click the topmost visible Continue button in duplicate X forms."""

    try:
        return await tab.evaluate(
            """(() => {
                for (const paragraph of document.querySelectorAll('p.jf-element')) {
                    const text = paragraph.textContent.trim();
                    if (!['Continue', 'Log in', 'Next'].includes(text)) continue;
                    const rect = paragraph.getBoundingClientRect();
                    const style = getComputedStyle(paragraph);
                    if (rect.width <= 0 || rect.height <= 0
                        || style.display === 'none'
                        || style.visibility === 'hidden'
                        || style.opacity === '0') continue;
                    const clickable = paragraph.parentElement?.parentElement?.parentElement;
                    if (!clickable) continue;
                    clickable.click();
                    return true;
                }
                return false;
            })()"""
        )
    except Exception:
        return False


def harden_upstream_login_helper(helper) -> None:
    """Patch only fragile selectors while retaining upstream login behavior."""

    if hasattr(helper, "_find_visible_input"):
        helper._find_visible_input = _safe_find_visible_input
    if hasattr(helper, "_click_continue"):
        helper._click_continue = _safe_click_continue


def validate_session_record(record: Any, line_number: int = 1) -> None:
    if not isinstance(record, dict):
        fail(f"Session line {line_number} is not a JSON object.")
    missing = [key for key in REQUIRED_SESSION_KEYS if not record.get(key)]
    if missing:
        fail(f"Session line {line_number} is missing required fields: {', '.join(missing)}")
    if record.get("kind") != "cookie":
        fail(f"Session line {line_number} has unsupported kind; expected cookie.")


def validate_sessions_file(path: Path) -> int:
    if not path.is_file():
        fail(f"Session file not found: {path}")
    count = 0
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not raw_line.strip():
            fail(f"Session line {line_number} is empty.")
        try:
            record = json.loads(raw_line)
        except json.JSONDecodeError as error:
            fail(f"Session line {line_number} is invalid JSON: {error.msg}")
        validate_session_record(record, line_number)
        count += 1
    if count == 0:
        fail("Session file contains no sessions.")
    return count


def atomically_write_session(root: Path, session: dict[str, Any]) -> tuple[Path, int]:
    secrets_dir = root / "secrets"
    secrets_dir.mkdir(mode=0o700, exist_ok=True)
    os.chmod(secrets_dir, 0o700)
    target = secrets_dir / "sessions.jsonl"
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=secrets_dir,
            prefix=".sessions.",
            suffix=".jsonl",
            delete=False,
        ) as temporary:
            temporary_path = Path(temporary.name)
            json.dump(session, temporary, separators=(",", ":"))
            temporary.write("\n")
        os.chmod(temporary_path, 0o600)
        count = validate_sessions_file(temporary_path)
        os.replace(temporary_path, target)
        os.chmod(target, 0o600)
        temporary_path = None
        return target, count
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--validate-only",
        action="store_true",
        help="Validate the existing local sessions.jsonl without logging in.",
    )
    parser.add_argument(
        "--headless",
        action="store_true",
        help="Run the upstream browser helper headlessly (may increase detection risk).",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    root = project_root()
    if args.validate_only:
        count = validate_sessions_file(root / "secrets" / "sessions.jsonl")
        print(f"Sessions found: {count}")
        print("Required fields: present")
        return 0
    values = parse_dotenv(root / ".env")
    username, password, totp_seed, nitter_ref = required_config(values)
    nitter_dir = ensure_nitter_checkout(root, nitter_ref)
    venv_python = ensure_virtualenv(root, nitter_dir)
    reexec_in_virtualenv(root, venv_python)

    helper = load_upstream_helper(nitter_dir)
    harden_upstream_login_helper(helper)
    session = asyncio.run(
        helper.login_and_get_session(
            username,
            password,
            totp_seed,
            headless=args.headless,
        )
    )
    if not session:
        fail("Upstream browser helper did not return a session.")
    target, count = atomically_write_session(root, session)
    print("Session file created")
    print(f"Sessions found: {count}")
    print(f"Session path: {target}")
    print("Required fields: present")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("ERROR: session creation cancelled.", file=sys.stderr)
        raise SystemExit(130)
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
