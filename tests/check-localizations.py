#!/usr/bin/env python3
"""Check catalog coverage and format placeholders without launching the app."""
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
literal = r'"(?:[^"\\]|\\.)*"'
catalogs = {}
for language in ["en", "zh-Hans"]:
    values = {}
    for line in (root / "Panelet/Resources" / f"{language}.lproj/Localizable.strings").read_text().splitlines():
        if not line.strip():
            continue
        match = re.fullmatch(f'({literal}) = ({literal});', line)
        assert match, line
        key, value = map(json.loads, match.groups())
        assert key not in values, key
        assert key.count("%@") == value.count("%@"), (key, value)
        if language == "en":
            assert not re.search(r"[\u3400-\u9fff]", value), value
        values[key] = value
    catalogs[language] = values
assert catalogs["en"].keys() == catalogs["zh-Hans"].keys()
for path in (root / "Panelet").glob("*.swift"):
    for match in re.finditer(r'\bL\((' + literal + ')', path.read_text()):
        key = json.loads(match[1])
        assert key in catalogs["en"], (path.name, key)
print(f"Localization: {len(catalogs['en'])} bilingual strings, source coverage and placeholder parity passed")
