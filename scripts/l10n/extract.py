#!/usr/bin/env python3
"""Every string in Sources/ that can reach the screen, as l10n/keys.json.

The app's own Text/Button/Label/... overloads (Localization.swift) look each
displayed String up in the language's table, so the table needs every UI
string in the source: single-line literals that start like UI text. An
interpolation becomes %@ (Localization matches those as patterns). Strings
that are not UI (identifiers, Python) are harmless extras: nothing looks
them up."""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# A message inside generated Python: raise RuntimeError(\"…\"), shown as is.
INNER = re.compile(r'\\"((?:[^"\\\n])+)\\"')
LIT = re.compile(r'(?<![\\#])"((?:[^"\\\n]|\\.)*)"')
INTERP = re.compile(r'\\\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)')
# "Text " + "more text" (across lines): shown joined, so looked up joined.
CONCAT = re.compile(r'"(?:[^"\\\n]|\\.)*"(?:\s*\+\s*"(?:[^"\\\n]|\\.)*")+')
SKIP_LINE = re.compile(r'^\s*(//|print\(|NSLog|log\(|debugPrint|assert|precondition|fatalError)')

def keys():
    out = set()
    for root, _, files in os.walk(os.path.join(ROOT, 'Sources')):
        for f in files:
            if not f.endswith('.swift'):
                continue
            src = open(os.path.join(root, f), encoding='utf-8').read()
            src = re.sub(r'"""[\s\S]*?"""', '', src)
            for seq in CONCAT.finditer(src):
                joined = ''.join(m.group(1) for m in LIT.finditer(seq.group(0)))
                if (k := clean(joined)):
                    out.add(k)
            for line in src.split('\n'):
                if SKIP_LINE.match(line):
                    continue
                for m in LIT.finditer(line):
                    if (k := clean(m.group(1))):
                        out.add(k)
                for m in INNER.finditer(line):
                    if ' ' in m.group(1) and (k := clean(m.group(1))):
                        out.add(k)
    return sorted(out)

def clean(raw):
    v = INTERP.sub('%@', raw)
    v = v.replace('\\"', '"').replace('\\\\', '\\').replace('\\n', '\n')
    if '\\' in v or not re.search(r'[A-Za-z]{2}', v):
        return None
    if not re.match(r'^(%@ ?)?[A-Z0-9(…]|^%@ [a-z]', v):
        return None
    if re.fullmatch(r'[A-Z0-9_]+', v):              # ENUM_IDENTIFIERS
        return None
    if ' ' not in v and re.search(r'[./_:=]', v) and not v.endswith('…'):
        return None                                   # paths, ids, code
    if v.startswith(('bpy', 'import ', 'from ', 'def ')):
        return None
    if v.replace('%@', '').strip() == '':
        return None
    return v

if __name__ == '__main__':
    # Strings the code builds from parts ("XYZ" + " Euler"), listed by hand.
    k = sorted(set(keys()) | set(json.load(open(os.path.join(ROOT, 'l10n', 'computed.json')))))
    json.dump(k, open(os.path.join(ROOT, 'l10n', 'keys.json'), 'w'), ensure_ascii=False, indent=1)
    print(f'{len(k)} keys, {sum("%@" in x for x in k)} with %@')
