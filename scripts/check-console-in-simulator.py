#!/usr/bin/env python3
"""Drives the Scripting tab's console in the simulator and checks what it shows.

  scripts/check-console-in-simulator.py <udid> <outdir> [scenario ...]

Install a Debug build first. Each scenario launches the app on the Scripting
tab with -console64 keys (and -eval64 where a script has to be running). The
app prints the terminal's text when the keys are done — "[bk] screen| …" lines
between screen-begin and screen-end — and each printed screen is photographed
into <outdir> as well. Scenarios: basic, completion, search (which finds a
statement basic typed in an earlier launch), paste, tall, running.
"""
import base64, os, re, subprocess, sys, time

UDID, OUT = sys.argv[1], sys.argv[2]
ONLY = set(sys.argv[3:])
os.makedirs(OUT, exist_ok=True)

SEP = "\x1f"             # one write per piece, as SwiftTerm sends a key
DUMP = "\x1ddump"        # print the screen now
ENTER, TAB, CTRL_C, CTRL_R = "\r", "\t", "\x03", "\x12"
PASTE_START, PASTE_END = "\x1b[200~", "\x1b[201~"


def wait(ms):
    return "\x1d" + str(ms)


def b64(text):
    return base64.b64encode(text.encode()).decode()


failures = 0


def check(label, ok, detail=""):
    global failures
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "   " + detail))
    if not ok:
        failures += 1


def simctl(*args):
    return subprocess.run(["xcrun", "simctl", *args], capture_output=True, text=True)


def run(name, steps, extra=(), dumps=1, timeout=120):
    log = os.path.join(OUT, name + ".log")
    simctl("terminate", UDID, "euleryu.blenderkit")
    with open(log, "w") as f:
        proc = subprocess.Popen(
            ["xcrun", "simctl", "launch", "--console-pty", UDID, "euleryu.blenderkit",
             "-workspace", "Scripting", "-console64", b64(SEP.join(steps)), *extra],
            stdout=f, stderr=subprocess.STDOUT)
    shot = 0
    start = time.time()
    while shot < dumps and time.time() - start < timeout:
        time.sleep(0.4)
        done = open(log, errors="replace").read().count("[bk] screen-end")
        while shot < done:
            shot += 1
            simctl("io", UDID, "screenshot", os.path.join(OUT, f"{name}-{shot}.png"))
    text = open(log, errors="replace").read().replace("\r", "")
    proc.kill()
    simctl("terminate", UDID, "euleryu.blenderkit")
    screens = []
    for part in text.split("[bk] screen-begin")[1:]:
        body = part.split("[bk] screen-end")[0]
        screens.append([m.group(1) for m in re.finditer(r"^\[bk\] screen\|(?: (.*))?$", body, re.M)])
        screens[-1] = [line or "" for line in screens[-1]]
    check(f"{name}: the screen was printed {dumps} time(s)", len(screens) >= dumps,
          f"got {len(screens)}; see {log}")
    while len(screens) < dumps:
        screens.append([])
    return screens


def count(lines, text):
    return sum(1 for line in lines if line == text)


def after(lines, text):
    """The lines that follow the first line equal to text."""
    return lines[lines.index(text) + 1:] if text in lines else []


def live(lines):
    """The prompt at the bottom, wrapped rows joined back together."""
    for i in range(len(lines) - 1, -1, -1):
        if lines[i].startswith((">>> ", "(reverse-i-search)", "(failed reverse-i-search)")):
            return "".join(lines[i:])
    return ""


def show(label, lines):
    print(f"    {label}: last rows")
    for line in lines[-14:]:
        print("      | " + line)


if not ONLY or "basic" in ONLY:
    print("== basic ==")
    s, = run("basic", [
        'print("hello from the console")', ENTER, wait(700),
        "for i in range(3):", ENTER, "print(i * 10)", ENTER, ENTER, wait(700),
        "x = (1,", ENTER, "2)", ENTER, "print(x)", ENTER, wait(700),
        "1/0", ENTER, wait(900),
        's = "' + "x" * 100,
    ])
    show("basic", s)
    check("a statement is echoed once", count(s, '>>> print("hello from the console")') == 1)
    check("and its output follows", after(s, '>>> print("hello from the console")')[:1] == ["hello from the console"],
          str(after(s, '>>> print("hello from the console")')[:2]))
    check("a block is echoed with its continuation prompt, indent kept",
          count(s, ">>> for i in range(3):") == 1 and count(s, "...     print(i * 10)") == 1)
    check("and runs once the blank line closes it", after(s, "...     print(i * 10)")[:3] == ["0", "10", "20"],
          str(after(s, "...     print(i * 10)")[:3]))
    check("an open bracket continues the line", count(s, ">>> x = (1,") == 1 and count(s, "... 2)") == 1)
    check("and the statement runs whole", "(1, 2)" in after(s, ">>> print(x)")[:1], str(after(s, ">>> print(x)")[:1]))
    check("an error prints its traceback", any("ZeroDivisionError" in line for line in s))
    check("a long line wraps and reads back whole", live(s) == '>>> s = "' + "x" * 100, repr(live(s)))

if not ONLY or "completion" in ONLY:
    print("== completion ==")
    s, = run("completion", [
        "import bpy", ENTER, wait(900),
        "bpy.ops.mesh.prim", TAB, wait(600), TAB, wait(900),
        "cu", TAB, wait(600),
    ])
    show("completion", s)
    listing = [line for line in s if "primitive_cube_add" in line and "primitive_" in line.replace("primitive_cube_add", "", 1)]
    check("a second Tab lists the candidates side by side", bool(listing), "no listing row")
    check("a unique candidate is typed out with its bracket",
          live(s) == ">>> bpy.ops.mesh.primitive_cube_add(", repr(live(s)))

if not ONLY or "search" in ONLY:
    print("== ⌃R ==")
    s, = run("search", [CTRL_R, "hello", wait(600)])
    show("search", s)
    check("⌃R finds an earlier statement from a previous launch",
          live(s) == '(reverse-i-search)`hello\': print("hello from the console")', repr(live(s)))

if not ONLY or "paste" in ONLY:
    print("== paste ==")
    body = 'def greet(name):\n    message = "hi " + name\n\n    return message\n\nprint(greet("blender"))\n'
    s, = run("paste", [PASTE_START, body, PASTE_END, wait(600), ENTER, wait(1200)])
    show("paste", s)
    check("a pasted function arrives whole, blank line inside and all, and runs on one Return",
          count(s, ">>> def greet(name):") == 1 and count(s, "hi blender") == 1, "")
    check("the prompt is back and empty", live(s) == ">>> ", repr(live(s)))

if not ONLY or "tall" in ONLY:
    print("== a paste taller than the pane ==")
    tall = "\n".join(f'print("line {i:02d}")' for i in range(1, 46))
    a, = run("tall-a", [PASTE_START, tall, PASTE_END, wait(700), "  # edited", wait(500), CTRL_C, wait(900)])
    show("tall-a", a)
    check("every pasted line is on screen once after editing and ⌃C",
          count(a, '>>> print("line 01")') == 1
          and all(count(a, f'... print("line {i:02d}")') == 1 for i in range(2, 45))
          and count(a, '... print("line 45")  # edited^C') == 1,
          f"line 01 x{count(a, '>>> print(\"line 01\")')}, line 02 x{count(a, '... print(\"line 02\")')}")
    b, = run("tall-b", [PASTE_START, tall, PASTE_END, wait(700), ENTER, wait(2500)])
    show("tall-b", b)
    check("running it echoes each line once and prints each output once",
          count(b, '>>> print("line 01")') == 1
          and all(count(b, f'... print("line {i:02d}")') == 1 for i in range(2, 46))
          and all(count(b, f"line {i:02d}") == 1 for i in range(1, 46)),
          f"echo 02 x{count(b, '... print(\"line 02\")')}, output 02 x{count(b, 'line 02')}")

if not ONLY or "running" in ONLY:
    print("== typing while a script runs ==")
    script = 'import time\nprint("script started")\ntime.sleep(4)\nprint("script finished")\n'
    mid, end = run("running", ["half typed", wait(2300), DUMP, wait(5500)],
                   extra=["-eval64", b64(script)], dumps=2)
    show("mid-run", mid)
    show("after", end)
    check("mid-run the output streams and the prompt is off the screen",
          "script started" in mid and not any(line.startswith(">>> ") for line in mid[-3:]), str(mid[-3:]))
    check("after the run the prompt returns with what was typed",
          "script finished" in end and live(end) == ">>> half typed", repr(live(end)))

if not ONLY or "shell" in ONLY:
    print("== shell commands ==")
    s, = run("shell", [
        "cd ~/Documents", ENTER, wait(700),
        "rm -rf bk_shell_check", ENTER, wait(700),
        "mkdir bk_shell_check", ENTER, wait(700),
        "cd bk_shell_check", ENTER, wait(700),
        "touch a.txt", ENTER, wait(700),
        "ls -la", ENTER, wait(900),
        "pwd", ENTER, wait(700),
        "cat", ENTER, wait(900), "typed line", ENTER, wait(700), "\x04", wait(900),
        "import sys; sys.exit(0)", ENTER, wait(900),
        "echo still here", ENTER, wait(900),
    ])
    show("shell", s)
    check("ls -la lists the file just made", "a.txt" in " ".join(after(s, ">>> ls -la")[:8]),
          str(after(s, ">>> ls -la")[:8]))
    def printed(prompt):
        """What a command printed: the rows after its prompt, up to the next
        prompt, joined. A long line wraps onto several rows of a narrow pane,
        and each row is trimmed, so spaces at a wrap are gone — compare without
        them."""
        rows = after(s, prompt)
        end = next((i for i, row in enumerate(rows) if row.startswith((">>> ", "... "))), len(rows))
        return "".join(rows[:end]).replace(" ", "")
    check("pwd follows cd", printed(">>> pwd").endswith("/Documents/bk_shell_check"), printed(">>> pwd"))
    check("cat reads what is typed until ⌃D, then the prompt returns",
          sum(1 for line in after(s, ">>> cat") if line == "typed line") >= 2
          and ">>> import sys; sys.exit(0)" in s, str(after(s, ">>> cat")[:4]))
    check("sys.exit() does not close the app",
          "consolestaysopen" in printed(">>> import sys; sys.exit(0)")
          and printed(">>> echo still here").startswith("stillhere"), printed(">>> import sys; sys.exit(0)"))

if not ONLY or "top" in ONLY:
    print("== top ==")
    mid, end = run("top", ["top", ENTER, wait(2600), DUMP, "q", wait(1800)], dumps=2)
    show("top running", mid)
    show("after q", end)
    check("top draws CPU and memory", any("cpu" in line.lower() for line in mid) and any("mem" in line.lower() for line in mid))
    check("q quits back to an empty prompt", live(end) == ">>> ", repr(live(end)))

print("\nALL PASS" if failures == 0 else f"\n{failures} FAILED")
sys.exit(1 if failures else 0)
