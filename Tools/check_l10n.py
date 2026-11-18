#!/usr/bin/env python3
"""Localization and language judge for All Menus.

1) every L("...") key in the sources has a Korean translation in Tools/strings.py,
2) format specifiers in each Korean value match its English key (same count and types),
3) no Korean text anywhere in the project except where it *is* the Korean-language feature:
   the Korean translations, the Hangul tables behind Korean search and the 2-set keyboard
   mapping, and the names Korean macOS gives to system items (needed to recognize them).
Exit code 0 = pass."""
import re, glob, os, sys
sys.path.insert(0, os.path.dirname(__file__))
from strings import KO

root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
hangul = re.compile(r'[가-힣ㄱ-ㆎ]')
keypat = re.compile(r'\bL\("((?:[^"\\]|\\.)*)"')

# Korean that *is* the Korean-language feature: lines tagged "// ko-data" in the sources (Hangul
# tables for Korean search, the 2-set keyboard map, names Korean macOS gives system items), the
# Korean translations, and this checker's own character class.
ALLOWED_FILES = ("Tools/strings.py", "Resources/ko.lproj/", "spike/")
SKIP_DIRS = {".git", "TestFrames", "__pycache__"}

def allowed(rel, line):
    if "ko-data" in line: return True
    if rel == "Tools/check_l10n.py" and "re.compile" in line: return True
    return rel.startswith(ALLOWED_FILES)

problems = []
for dirpath, dirs, files in os.walk(root):
    dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.endswith(".app")]
    for f in files:
        p = os.path.join(dirpath, f); rel = os.path.relpath(p, root)
        if f.endswith((".png", ".icns")) or (os.access(p, os.X_OK) and not f.endswith((".sh", ".py", ".swift"))): continue
        try: lines = open(p, encoding="utf-8").read().split("\n")
        except (UnicodeDecodeError, IsADirectoryError): continue
        for i, line in enumerate(lines, 1):
            if hangul.search(line) and not allowed(rel, line):
                problems.append(f"{rel}:{i}: Korean outside the Korean-language feature: {line.strip()[:70]}")

used = []
for f in sorted(glob.glob(os.path.join(root, "Sources", "*.swift"))):
    for i, line in enumerate(open(f), 1):
        for m in keypat.finditer(line):
            used.append((m.group(1), os.path.basename(f), i))

spec = re.compile(r'%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(l{0,2}|h{0,2})([@dDuUxXoOfeEgGcCsSpaAF])')
def specs(s): return sorted(spec.findall(s))
for key, name, line in used:
    if key not in KO:
        problems.append(f"{name}:{line}: no Korean translation for \"{key[:60]}\"")
    elif specs(key) != specs(KO[key]):
        problems.append(f"{name}:{line}: format mismatch \"{key[:40]}\" vs \"{KO[key][:40]}\"")
unused = [k for k in KO if k not in {u[0] for u in used}]
print(f"{len({u[0] for u in used})} keys used · {len(KO)} translated · {len(unused)} unused")
for p in problems: print("FAIL", p)
for u in unused: print("note: unused translation", u[:60])
print("RESULT", "PASS" if not problems else f"FAIL ({len(problems)})")
sys.exit(1 if problems else 0)
