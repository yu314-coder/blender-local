"""Every desktop Blender a check script starts has a HOME and
BLENDER_USER_RESOURCES of its own.

The user asked that automated Blender runs never write this Mac's own Blender
settings (~/Library/Application Support/Blender). Fifteen check scripts and the
animation check's main run started Blender with the user's HOME. Measured in
5.2.1: even a bare `-b --factory-startup --python-expr "import bpy"` writes
~/.thumbnails into HOME, and an operator can write the settings themselves.
`--version` writes nothing (0 files in an empty HOME), so it is not counted.

A launch counts as sandboxed when its command (continuation lines joined)
sets both variables, or when an `export` earlier in the script set both. A
Python driver that starts Blender itself (tests/modeguard/blender/drive.py)
counts as a launch, sandboxed when the driver sets HOME and
BLENDER_USER_RESOURCES for each Blender on its own
(tests/budget/blender/freed_drive.py, fix round 3).

    python3 tests/sandbox/check.py scripts/run-*-blender-check.sh
"""
import os
import re
import sys
import tempfile

# Blender started with anything but --version: `"$BLENDER" -b`, a clone's
# `".../MacOS/Blender" -b`. A test `[ -x "$BLENDER" ]` or an echo of the path
# has no dash after the closing quote, so it is not a launch.
LAUNCH = re.compile(r'("\$BLENDER"|/MacOS/Blender")\s+(?!--version\b)-')
DRIVER = re.compile(r'\bpython3\s+(\S+\.py)\b')
EXPORT = re.compile(r'^\s*export\b')


def sandboxes(command):
    return bool(re.search(r'\bHOME=', command)) and 'BLENDER_USER_RESOURCES=' in command


def commands(text):
    """(first line number, command) for each logical command, comments dropped."""
    out, buf, start = [], [], None
    for number, line in enumerate(text.split('\n'), 1):
        if not buf and line.lstrip().startswith('#'):
            continue
        if not buf:
            start = number
        buf.append(line.rstrip('\\').rstrip() if line.rstrip().endswith('\\') else line)
        if not line.rstrip().endswith('\\'):
            out.append((start, ' '.join(buf)))
            buf = []
    if buf:
        out.append((start, ' '.join(buf)))
    return out


def driver_starts_blender(path, root):
    """(whether the Python driver at `path` starts Blender, whether it gives
    each Blender the sandbox itself)."""
    full = os.path.join(root, path)
    if not os.path.isfile(full):
        return False, False
    source = open(full).read()
    starts = 'MacOS/Blender' in source or 'BLENDER' in source
    return starts, starts and 'BLENDER_USER_RESOURCES' in source and 'HOME=' in source


def unsandboxed(text, root):
    """Line numbers of Blender launches that would get the user's HOME."""
    exported, bad, launches = False, [], 0
    for number, command in commands(text):
        if EXPORT.match(command) and sandboxes(command):
            exported = True
            continue
        driver = DRIVER.search(command)
        starts, own = driver_starts_blender(driver.group(1), root) if driver else (False, False)
        if LAUNCH.search(command) or starts:
            launches += 1
            # A driver that gives each Blender a HOME and resources of its own
            # (freed_drive.py, opdrive.py) is a sandboxed launch.
            if not (exported or sandboxes(command) or own):
                bad.append(number)
    return launches, bad


failures = 0


def check(name, ok, detail=''):
    global failures
    print(f"  {'PASS' if ok else 'FAIL'}  {name}" + (f"  ({detail})" if detail and not ok else ''))
    failures += 0 if ok else 1


root = os.getcwd()
scripts = sys.argv[1:]

print('== the checker can fail')
with tempfile.TemporaryDirectory() as scratch:
    with open(os.path.join(scratch, 'drive.py'), 'w') as f:
        f.write('import subprocess\nsubprocess.run(["/Applications/Blender.app/Contents/MacOS/Blender", "-b"])\n')
    with open(os.path.join(scratch, 'own.py'), 'w') as f:
        f.write('import os, subprocess\nenv = dict(os.environ, HOME=h, BLENDER_USER_RESOURCES=r)\n'
                'subprocess.run(["/Applications/Blender.app/Contents/MacOS/Blender", "-b"], env=env)\n')
    cases = [
        ('a bare launch is caught', '"$BLENDER" -b --factory-startup --python x.py', [1]),
        ('so is a launch in exec, in a pipe and in an if',
         'exec "$BLENDER" -b --python a.py | grep x\nif ! "$BLENDER" -b --python b.py; then :; fi', [1, 2]),
        ('so is a clone of Blender.app', '  "$CLONE/Contents/MacOS/Blender" -b --python n.py', [1]),
        ('HOME alone is not enough', 'HOME="$h" "$BLENDER" -b --python x.py', [1]),
        ('so is a Python driver that starts Blender', 'exec python3 drive.py calls.txt', [1]),
        ('a driver that sandboxes each Blender itself passes', 'exec python3 own.py rounds=6', []),
        ('the sandbox inline passes', 'HOME="$h" BLENDER_USER_RESOURCES="$h/res" "$BLENDER" -b --python x.py', []),
        ('on the line before, as a continuation',
         'HOME="$h" BLENDER_USER_RESOURCES="$h/res" \\\n  "$BLENDER" -b --python x.py', []),
        ('through exec env', 'exec env HOME="$h" BLENDER_USER_RESOURCES="$h/res" python3 drive.py c', []),
        ('or exported earlier', 'export HOME="$h" BLENDER_USER_RESOURCES="$h/res"\n"$BLENDER" -b --python x.py', []),
        ('--version is not a launch', 'echo "$("$BLENDER" --version | head -1)"', []),
        ('nor a test of the path', '[ -x "$BLENDER" ] || { echo "  SKIP  not at $BLENDER"; exit 0; }', []),
        ('a commented launch is not one', '# "$BLENDER" -b --python x.py', []),
    ]
    for name, text, expected in cases:
        _, bad = unsandboxed(text, scratch)
        check(name, bad == expected, f'flagged lines {bad}, expected {expected}')

print('\n== every check script')
check('the scripts were found', len(scripts) > 0, 'no scripts/run-*-blender-check.sh given')
total = 0
for path in scripts:
    launches, bad = unsandboxed(open(path).read(), root)
    total += launches
    check(f'{os.path.basename(path)}: {launches} launch(es), each with its own HOME',
          launches > 0 and not bad,
          f'no launch found' if not launches else 'line ' + ', '.join(map(str, bad)) + ' starts Blender with the user\'s HOME')
print(f'\n{len(scripts)} scripts, {total} Blender launches')
print('ALL PASS' if not failures else f'{failures} FAILED')
sys.exit(1 if failures else 0)
