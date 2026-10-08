"""Build CNC G-Coder/Localizable.xcstrings from the translation tables
fr.json / es.json / tr.json (English source string → translation).

    cd docs/l10n && python3 make_catalog.py [path/to/en.xliff]

With an XLIFF export (xcodebuild -exportLocalizations) the script also lists
source strings that have no translation yet and translations whose source
string no longer exists in the app. Format specifiers (%@, %1$lld, …) must
match between source and translation; mismatches abort."""
import json, os, re, sys
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(ROOT, "CNC G-Coder", "Localizable.xcstrings")
LANGS = ["fr", "es", "tr"]
SPEC = re.compile(r"%(?:\d+\$)?[@dfsl.0-9]*[@dfsux%]")

tables = {l: json.load(open(os.path.join(HERE, f"{l}.json"), encoding="utf-8")) for l in LANGS}

# optional: the current English string list from an XLIFF export
sources = None
if len(sys.argv) > 1:
    ns = {"x": "urn:oasis:names:tc:xliff:document:1.2"}
    root = ET.parse(sys.argv[1]).getroot()
    sources = []
    for f in root.findall(".//x:file", ns):
        if "Localizable" not in f.get("original", ""): continue
        for u in f.findall(".//x:trans-unit", ns):
            sources.append(u.find("x:source", ns).text or "")
    sources = list(dict.fromkeys(sources))

errors = 0
for lang, table in tables.items():
    for src, dst in table.items():
        a, b = sorted(SPEC.findall(src)), sorted(SPEC.findall(dst))
        if a != b:
            print(f"[{lang}] format mismatch: {src!r} -> {dst!r}"); errors += 1
if errors:
    sys.exit(f"{errors} format mismatches")

POSITIONAL = re.compile(r"%(\d+)\$")
def plain(k): return POSITIONAL.sub("%", k)

keys = set()
for t in tables.values(): keys |= set(t)
# A source whose only difference from a table key is the numbering of its
# format specifiers is covered by that key (the catalog gets both spellings).
by_plain = {plain(k): k for k in keys}
if sources:
    for src in sources:
        if src not in keys and plain(src) in by_plain:
            k = by_plain[plain(src)]
            for t in tables.values():
                if k in t and src not in t: t[src] = t[k]
            keys.add(src)
    missing = [s for s in sources if s not in keys and s.strip() and not re.fullmatch(r"[\W\d%@$lfsd.×–—+−]*", s)]
    stale = [k for k in keys if k not in sources and plain(k) not in {plain(s) for s in sources}]
    print(f"sources: {len(sources)}, translated keys: {len(keys)}, untranslated: {len(missing)}, stale: {len(stale)}")
    for s in missing: print("  untranslated:", s[:110])
    for s in stale[:20]: print("  stale:", s[:100])

strings = {}
for key in sorted(keys):
    loc = {}
    for lang, table in tables.items():
        if key in table and table[key] != key:
            loc[lang] = {"stringUnit": {"state": "translated", "value": table[key]}}
    if loc:
        strings[key] = {"localizations": loc}
        # SwiftUI looks interpolated Text up by its unnumbered key ("%@ … %lld"),
        # while the exporter prints positional ones ("%1$@ … %2$lld"): emit both.
        plain = POSITIONAL.sub("%", key)
        if plain != key and plain not in strings:
            strings[plain] = {"localizations": loc}
catalog = {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
with open(OUT, "w", encoding="utf-8") as f:
    json.dump(catalog, f, ensure_ascii=False, indent=2)
    f.write("\n")
print(f"wrote {OUT}: {len(strings)} keys, {sum(len(v['localizations']) for v in strings.values())} translations")
