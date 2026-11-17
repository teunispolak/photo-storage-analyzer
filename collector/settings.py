"""
Settings file for the collector and the catalog check.

Format: one KEY="value" per line; blank lines and lines starting with #
are ignored. The file is read, not executed: $HOME, ${HOME} and a leading ~
are expanded, nothing else.

Keys:
  CATALOG    path to the .lrcat file, once
  SCAN_ROOT  root of a photo folder tree, one line per root

Any error (a line that is not KEY="value", an unknown key, CATALOG twice,
an empty value, a missing file) raises SettingsError; the caller stops.

Requires Python 3.9+, standard library only.
"""

import hashlib
import os
import re
from pathlib import Path
from typing import Dict, List, Optional

KEYS = {"CATALOG": "single", "SCAN_ROOT": "list"}
LINE = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)="([^"]*)"$')


class SettingsError(Exception):
    pass


class Settings:
    def __init__(self, path: Path, sha256: str, values: Dict[str, List[str]]):
        self.path = path
        self.sha256 = sha256
        self.values = values  # key -> list of expanded values, in file order

    def get(self, key: str) -> Optional[str]:
        v = self.values.get(key)
        return v[0] if v else None

    def get_list(self, key: str) -> List[str]:
        return list(self.values.get(key, []))


def expand(value: str, home: str) -> str:
    if value == "~" or value.startswith("~/"):
        value = home + value[1:]
    return value.replace("${HOME}", home).replace("$HOME", home)


def load(path: Path) -> Settings:
    path = Path(os.path.abspath(os.path.expanduser(str(path))))
    if not path.is_file():
        raise SettingsError(f"settings file not found: {path}")
    raw = path.read_bytes()
    home = os.path.expanduser("~")
    values: Dict[str, List[str]] = {}
    problems = []
    for n, line in enumerate(raw.decode("utf-8").splitlines(), 1):
        text = line.strip()
        if not text or text.startswith("#"):
            continue
        m = LINE.match(text)
        if not m:
            problems.append(f'line {n}: not KEY="value": {text}')
            continue
        key, value = m.group(1), m.group(2)
        if key not in KEYS:
            problems.append(f"line {n}: unknown key {key}; known keys: {', '.join(KEYS)}")
            continue
        if not value:
            problems.append(f"line {n}: empty value for {key}")
            continue
        if KEYS[key] == "single" and key in values:
            problems.append(f"line {n}: {key} given more than once")
            continue
        values.setdefault(key, []).append(expand(value, home))
    if problems:
        raise SettingsError(f"settings file {path} has errors:\n  - " + "\n  - ".join(problems))
    return Settings(path, hashlib.sha256(raw).hexdigest(), values)


def module_sha256() -> str:
    return hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
