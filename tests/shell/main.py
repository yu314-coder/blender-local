"""The console's shell commands, run on the Mac the way the app runs them.

Every test gets a throwaway home directory and a fresh pipe on fd 0, and calls
`_blenderkit_shell.run_b64` with a base64 command line while stdout and stderr
go to a text stream with no file descriptor, as they do in the app. Full-screen
commands are fed their keys through the pipe. Run with
scripts/run-shell-tests.sh.
"""

import ast
import base64
import builtins
import dis
import faulthandler
import getpass
import gzip
import hashlib
import io
import json
import os
import platform
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import threading
import time
import traceback
import types
import zipfile

sys.dont_write_bytecode = True   # the module ships inside the app; no .pyc beside it

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SITE = os.path.join(ROOT, "Resources", "python", "site")
MODULE_PATH = os.path.join(SITE, "_blenderkit_shell.py")
sys.path.insert(0, SITE)

import _blenderkit_shell as sh  # noqa: E402

failures = 0


def check(label, ok, detail=""):
    global failures
    if ok:
        print(f"  PASS  {label}")
    else:
        text = detail if isinstance(detail, str) else repr(detail)
        print(f"  FAIL  {label}  {text[:1500]}")
        failures += 1


ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")


def plain(text):
    return ANSI.sub("", text).replace("\r\n", "\n")


class Capture(io.TextIOBase):
    """The app's stdout: text in, no file descriptor behind it."""

    def __init__(self):
        super().__init__()
        self.parts = []

    def writable(self):
        return True

    def write(self, s):
        self.parts.append(s)
        return len(s)

    def getvalue(self):
        return "".join(self.parts)


class Pipe:
    """A fresh pipe on fd 0 for one run, as the app's ConsoleStdin makes."""

    def __init__(self, data=b"", keep_open=False):
        self.lock = threading.Lock()
        self.saved = os.dup(0)
        r, w = os.pipe()
        os.dup2(r, 0)
        os.close(r)
        self.w = w
        if data:
            os.write(w, data)
        if not keep_open:
            self.close()

    def write(self, data):
        with self.lock:
            if self.w is not None:
                os.write(self.w, data)

    def close(self):
        with self.lock:
            if self.w is None:
                return False
            os.close(self.w)
            self.w = None
            return True

    def restore(self):
        self.close()
        os.dup2(self.saved, 0)
        os.close(self.saved)


class Result:
    def __init__(self, rc, out, seconds, forced):
        self.rc = rc
        self.out = out
        self.text = plain(out)
        self.seconds = seconds
        self.forced = forced

    def __repr__(self):
        tail = self.out if len(self.out) < 900 else "…" + self.out[-900:]
        return f"<rc={self.rc} forced={self.forced} {self.seconds:.2f}s out={tail!r}>"


def run(line, stdin=b"", keep_open=False, columns=100, rows=30, feed=None, limit=20.0,
        thread=False):
    """One command line, called the way the app calls it.

    `stdin` goes into the pipe first, and the write end is then closed — the
    end of input — unless `keep_open`. `feed(pipe)` runs alongside the command.
    A command still running after `limit` seconds has its input closed under
    it, and `forced` says so. `thread` makes the call from a background thread,
    as the app does."""
    pipe = Pipe(stdin, keep_open)
    forced = []

    def force():
        if pipe.close():
            forced.append(True)

    timer = threading.Timer(limit, force)
    timer.daemon = True
    timer.start()
    feeder = None
    if feed is not None:
        feeder = threading.Thread(target=feed, args=(pipe,), daemon=True)
        feeder.start()
    cap = Capture()
    saved = sys.stdout, sys.stderr
    sys.stdout = sys.stderr = cap
    encoded = base64.b64encode(line.encode("utf-8")).decode("ascii")
    t0 = time.monotonic()
    try:
        if thread:
            box = []
            worker = threading.Thread(target=lambda: box.append(sh.run_b64(encoded, columns, rows)))
            worker.start()
            worker.join(limit + 5)
            rc = box[0] if box else None
        else:
            rc = sh.run_b64(encoded, columns, rows)
    finally:
        seconds = time.monotonic() - t0
        sys.stdout, sys.stderr = saved
        timer.cancel()
        if feeder is not None:
            feeder.join(2)
        pipe.restore()
    return Result(rc, cap.getvalue(), seconds, bool(forced))


def stop_after(seconds):
    """A trace function that raises KeyboardInterrupt once, after `seconds`,
    between two Python lines — what the app's Stop does."""
    deadline = time.monotonic() + seconds
    fired = []

    def tracer(frame, event, arg):
        if not fired and time.monotonic() >= deadline:
            fired.append(True)
            raise KeyboardInterrupt("Stopped by user")
        return tracer

    return tracer, fired


class Home:
    """A throwaway $HOME, which is also the working directory."""

    def __enter__(self):
        self.saved_home = os.environ.get("HOME")
        self.saved_cwd = os.getcwd()
        self.path = tempfile.mkdtemp(prefix="blenderlocal-shell-")
        self.real = os.path.realpath(self.path)
        os.environ["HOME"] = self.path
        os.chdir(self.path)
        return self

    def __exit__(self, *exc):
        os.chdir(self.saved_cwd)
        if self.saved_home is None:
            os.environ.pop("HOME", None)
        else:
            os.environ["HOME"] = self.saved_home
        shutil.rmtree(self.path, ignore_errors=True)

    def file(self, rel, data):
        path = os.path.join(self.path, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb" if isinstance(data, bytes) else "w") as f:
            f.write(data)
        return path


def fixture(home):
    home.file("a.txt", "hello\n")
    home.file("b.py", "print('b')\n")
    home.file(".hidden", "secret\n")
    home.file("sub/inner.txt", "inner\n")
    home.file("lines.txt", "".join(f"line {i}\n" for i in range(1, 21)))


EXPECTED_COMMANDS = {
    "help", "man", "pwd", "cd",
    "ls", "cat", "head", "tail", "wc", "grep", "find", "tree", "stat", "file", "xxd",
    "hexdump", "diff", "less", "more",
    "mkdir", "rm", "rmdir", "touch", "cp", "mv", "mktemp", "tee",
    "echo", "env", "export", "which", "date", "uptime", "uname", "whoami", "hostname",
    "id", "nproc", "basename", "dirname", "realpath",
    "sort", "uniq", "tr", "seq", "yes", "sleep", "time", "bc", "cal", "nl", "tac", "rev",
    "cut", "base64", "sha256sum", "sha1sum", "md5sum",
    "du", "df", "zip", "unzip", "tar", "gzip", "gunzip", "extract",
    "clear", "history", "ps", "kill", "watch", "top", "htop", "ncdu",
    "python", "python3", "py", "exit", "quit",
    "ll", "la", "cls",
}

EXCLUDED = [
    "pip", "pip3", "pip-install", "pip-uninstall", "pip-list", "pip-show", "pip-freeze",
    "pip-check", "git", "curl", "wget", "ping", "ai", "js", "node",
    "cc", "gcc", "clang", "c++", "g++", "clang++", "gfortran", "f77", "f90", "f95",
    "swift", "pdflatex", "latex", "tex", "pdftex", "xelatex", "latex-diagnose",
    "md", "markdown", "nb", "ipynb", "notebook", "manim", "repl", "debug", "debug-gui",
    "cpu-z", "cpuz", "gpu-z", "gpuz", "crash-log", "crashlog", "test-libs", "test_libs",
    "7z", "unar", "binwalk", "simg2img",
]

TOP_TITLE = "top — live system monitor"
TESTS = []


def section(fn):
    TESTS.append(fn)
    return fn


# ---------------------------------------------------------------------------

@section
def test_init():
    # First, before any run_b64: the first call moves to the working folder.
    with Home() as home:
        sh._initialized = False
        sh.init()
        scripts = os.path.join(home.real, "Documents", "Scripts")
        check("init moves to ~/Documents/Scripts, creating it",
              os.getcwd() == scripts and os.path.isdir(scripts), os.getcwd())
        os.chdir(home.path)
        sh.init()
        check("init moves only once", os.getcwd() == home.real, os.getcwd())
    with Home() as home:
        home.file("Documents/Scripts", "a file where the folder should be")
        sh._initialized = False
        sh.init()
        check("init falls back to ~/Documents when Scripts can't be made",
              os.getcwd() == os.path.join(home.real, "Documents"), os.getcwd())
    with Home() as home:
        sh._initialized = False
        r = run("pwd")
        check("the first run_b64 starts in ~/Documents/Scripts",
              r.rc == 0 and r.text.strip() == os.path.join(home.real, "Documents", "Scripts"), r)
    sh._initialized = True


@section
def test_api():
    check("COMMANDS is a frozenset of every command, aliases included",
          isinstance(sh.COMMANDS, frozenset) and set(sh.COMMANDS) == EXPECTED_COMMANDS,
          sorted(set(sh.COMMANDS) ^ EXPECTED_COMMANDS))
    check("ALIASES maps ll, la, cls and py",
          sh.ALIASES == {"ll": "ls -lah", "la": "ls -a", "cls": "clear", "py": "python"},
          sh.ALIASES)
    check("the raw and cooked markers are Blender Local's",
          sh.RAW_MARKER == "\x1b]blenderlocal;raw\x1b\\"
          and sh.COOKED_MARKER == "\x1b]blenderlocal;cooked\x1b\\")
    missing = [n for n in EXCLUDED if n not in sh.UNAVAILABLE]
    check("every left-out command has a reason", not missing, missing)
    check("no left-out command is in COMMANDS", not (set(sh.UNAVAILABLE) & set(sh.COMMANDS)),
          sorted(set(sh.UNAVAILABLE) & set(sh.COMMANDS)))


@section
def test_source():
    source = open(MODULE_PATH, encoding="utf-8").read()
    tree = ast.parse(source)
    forbidden = {"urllib", "http", "socket", "ssl", "requests", "subprocess", "pip", "ensurepip"}

    imported = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            imported |= {alias.name for alias in node.names}
        elif isinstance(node, ast.ImportFrom) and node.module:
            imported.add(node.module)
        elif isinstance(node, ast.Call):
            fn = node.func
            name = fn.id if isinstance(fn, ast.Name) else fn.attr if isinstance(fn, ast.Attribute) else ""
            if name in ("__import__", "import_module", "run_module") and node.args \
                    and isinstance(node.args[0], ast.Constant) and isinstance(node.args[0].value, str):
                imported.add(node.args[0].value)
    tops = {name.split(".")[0] for name in imported}
    check("the module imports nothing that reaches the network or starts a process",
          not (tops & forbidden) and "ctypes.util" not in imported,
          sorted((tops & forbidden) | ({"ctypes.util"} & imported)))

    names = {n.id for n in ast.walk(tree) if isinstance(n, ast.Name)} & forbidden
    check("the module uses no such module by name", not names, sorted(names))

    words = re.findall(r"codebench|benchcode|offlinai", source, re.IGNORECASE)
    check("the module never names the app it came from", not words, words)

    network = re.findall(r"\b(urllib|https?|socket|ssl|requests|subprocess|ensurepip)\b", source)
    check("the module's text never mentions network or process modules", not network, network)

    # Every global read is defined — the kind of slip that made a line of
    # output vanish when a colour name was misspelt. Module-level loops may
    # read their own temporaries.
    def code_objects(co):
        yield co
        for const in co.co_consts:
            if isinstance(const, types.CodeType):
                yield from code_objects(const)

    module_code = compile(source, MODULE_PATH, "exec")
    stored_at_module = {ins.argval for ins in dis.get_instructions(module_code)
                        if ins.opname in ("STORE_NAME", "STORE_GLOBAL")}
    undefined = set()
    for co in code_objects(module_code):
        for ins in dis.get_instructions(co):
            if ins.opname not in ("LOAD_GLOBAL", "LOAD_NAME"):
                continue
            name = ins.argval
            if name in vars(sh) or hasattr(builtins, name):
                continue
            if co is module_code and name in stored_at_module:
                continue
            undefined.add(f"{name} in {co.co_name}")
    check("every global name the module reads is defined", not undefined, sorted(undefined))

    # A clean interpreter: import the module, run commands across it, and see
    # what ended up in sys.modules.
    probe = textwrap.dedent(f"""
        import base64, io, json, os, sys
        sys.dont_write_bytecode = True
        sys.path.insert(0, {SITE!r})
        import _blenderkit_shell as s
        s._initialized = True
        r, w = os.pipe(); os.dup2(r, 0); os.write(w, b"q"); os.close(w)
        real = sys.stdout
        sys.stdout = sys.stderr = io.StringIO()
        for line in ("uname -a", "hostname", "whoami", "id", "ps", "top", "date", "cal",
                     "help", "python -c pass", "df", "file x", "extract x", "mktemp -d"):
            s.run_b64(base64.b64encode(line.encode()).decode(), 80, 24)
        sys.stdout = sys.stderr = real
        loaded = [m for m in ("subprocess", "socket", "ssl", "urllib", "http", "requests",
                              "pip", "ensurepip") if m in sys.modules]
        print(json.dumps(loaded))
    """)
    scratch = tempfile.mkdtemp(prefix="blenderlocal-shell-probe-")
    try:
        env = dict(os.environ, HOME=scratch, TMPDIR=scratch + "/")
        done = subprocess.run([sys.executable, "-B", "-c", probe], cwd=scratch, env=env,
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
        lines = done.stdout.strip().splitlines()
        loaded = json.loads(lines[-1]) if done.returncode == 0 and lines else None
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    check("running the commands loads no network or process module",
          loaded == [], (loaded, done.returncode, done.stderr[-800:]))


@section
def test_run_b64_contract():
    with Home():
        r = run("echo hi", columns=77, rows=21)
        check("run_b64 returns the status and prints", r.rc == 0 and r.text == "hi\n", r)
        check("run_b64 exports COLUMNS and LINES",
              os.environ.get("COLUMNS") == "77" and os.environ.get("LINES") == "21",
              (os.environ.get("COLUMNS"), os.environ.get("LINES")))
        r = run("echo hi", thread=True)
        check("run_b64 works from a background thread", r.rc == 0 and r.text == "hi\n", r)

        cap = Capture()
        saved = sys.stdout, sys.stderr
        sys.stdout = sys.stderr = cap
        try:
            rc1 = sh.run_b64("%%% not base64 %%%", 80, 24)
            rc2 = sh.run_b64(None, "wide", None)
        except BaseException as e:   # the point is that this never happens
            rc1 = rc2 = e
        finally:
            sys.stdout, sys.stderr = saved
        check("a line that isn't base64 gives a status, not an exception",
              isinstance(rc1, int) and rc1 != 0 and isinstance(rc2, int) and rc2 != 0,
              (rc1, rc2, cap.getvalue()))

        r = run("frobnicate now")
        check("an unknown command says so", r.rc == 127 and "frobnicate: command not found" in r.text, r)
        r = run("gerp x y")
        check("a misspelt command suggests the right one", "did you mean: grep" in r.text, r)
        r = run('echo "unclosed')
        check("an unbalanced quote is shown with a caret",
              r.rc == 2 and "unbalanced quote" in r.text and "^" in r.text, r)
        r = run("ls --help")
        check("--help prints the command's own docs", r.rc == 0 and "ls [-l] [-a] [-h]" in r.text, r)
        r = run("cat -H")
        check("help tokens are the same set: -H", r.rc == 0 and "cat [file…]" in r.text, r)
        r = run("  # a comment")
        check("a comment does nothing", r.rc == 0 and r.out == "", r)


@section
def test_ls():
    with Home() as home:
        fixture(home)
        r = run("ls")
        lines = r.text.splitlines()
        check("ls lists directories first, then files by name",
              lines == ["sub/", "a.txt", "b.py", "lines.txt"], lines)
        check("ls colours a directory blue", f"{sh.BLU}{sh.BOLD}sub/" in r.out, r)
        r = run("ls -la")
        check("ls -la shows dotfiles in the long form",
              ".hidden" in r.text and re.search(r"^-rw\S*\s+\d+\s+\w{3} \d\d \d\d:\d\d  a\.txt$", r.text, re.M)
              and re.search(r"^drwx.*  sub/$", r.text, re.M), r)
        r = run("ll")
        check("ll is ls -lah: dotfiles, long form, human sizes",
              ".hidden" in r.text and re.search(r"^-rw\S*\s+6B\s", r.text, re.M), r)
        r = run("la")
        check("la shows dotfiles without the long form",
              ".hidden" in r.text.splitlines() and not re.search(r"^-rw", r.text, re.M), r)
        r = run("ls sub")
        check("ls of a directory lists inside it", r.text == "inner.txt\n", r)
        r = run("ls a.txt sub")
        check("ls of several paths heads each directory", r.text == "a.txt\n\nsub:\ninner.txt\n", r)
        r = run("ls nothing-here")
        check("ls of a missing path fails", r.rc == 1 and "no such path: nothing-here" in r.text, r)


@section
def test_cd_pwd():
    with Home() as home:
        fixture(home)
        sub = os.path.join(home.real, "sub")
        r = run("pwd")
        check("pwd prints the working directory", r.rc == 0 and r.text.strip() == home.real, r)
        r = run("cd sub")
        check("cd into a directory", r.rc == 0 and os.getcwd() == sub, (r, os.getcwd()))
        check("pwd follows cd", run("pwd").text.strip() == sub)
        run("cd -")
        check("cd - goes back", os.getcwd() == home.real, os.getcwd())
        run("cd sub")
        run("cd")
        check("cd alone goes home", os.getcwd() == home.real, os.getcwd())
        run("cd ~/sub")
        check("cd ~/path", os.getcwd() == sub, os.getcwd())
        run("cd ..")
        check("cd .. inside home", os.getcwd() == home.real, os.getcwd())
        r = run("cd ..")
        check("cd refuses to leave home",
              r.rc == 1 and "can't leave the app sandbox" in r.text and os.getcwd() == home.real, r)
        r = run("cd /")
        check("cd / is refused as well", r.rc == 1 and os.getcwd() == home.real, r)
        r = run("cd nowhere")
        check("cd to a missing directory says so", r.rc == 1 and "no such directory: nowhere" in r.text, r)
        r = run("cd a.txt")
        check("cd to a file says so", r.rc == 1 and "not a directory: a.txt" in r.text, r)


@section
def test_file_ops():
    with Home() as home:
        fixture(home)
        r = run("mkdir -p x/y/z")
        check("mkdir -p makes the whole path", r.rc == 0 and os.path.isdir("x/y/z"), r)
        r = run("mkdir x")
        check("mkdir of an existing directory fails", r.rc == 1 and "mkdir:" in r.text, r)
        run("touch x/y/z/f.txt")
        check("touch creates an empty file",
              os.path.isfile("x/y/z/f.txt") and os.path.getsize("x/y/z/f.txt") == 0)
        run("cp a.txt x/copy.txt")
        check("cp copies a file", open("x/copy.txt").read() == "hello\n")
        r = run("cp sub elsewhere")
        check("cp of a directory needs -r", r.rc == 1 and "is a directory (use -r)" in r.text, r)
        run("cp -r x x2")
        check("cp -r copies a tree", os.path.isfile("x2/y/z/f.txt"))
        run("cp -r sub x2")
        check("cp -r into an existing directory copies inside it", os.path.isfile("x2/sub/inner.txt"))
        run("mv x2 x3")
        check("mv renames", os.path.isdir("x3") and not os.path.exists("x2"))
        run("mv a.txt x3")
        check("mv into a directory moves inside it",
              os.path.isfile("x3/a.txt") and not os.path.exists("a.txt"))
        r = run("rm x")
        check("rm of a directory needs -r",
              r.rc == 1 and "is a directory (use -r)" in r.text and os.path.isdir("x"), r)
        r = run("rm -Rf x3")
        check("rm -Rf removes a tree", r.rc == 0 and not os.path.exists("x3"), r)
        run("rm -r x")
        check("rm -r removes a tree", not os.path.exists("x"))
        r = run("rm ghost.txt")
        check("rm of a missing file fails", r.rc == 1 and "no such file: ghost.txt" in r.text, r)
        r = run("rm -f ghost.txt")
        check("rm -f of a missing file is quiet", r.rc == 0 and r.out == "", r)
        r = run("rm -rf ~")
        check("rm refuses the home directory",
              r.rc == 1 and "refusing" in r.text and os.path.isfile(os.path.join(home.path, "b.py")), r)
        os.mkdir("empty")
        run("rmdir empty")
        check("rmdir removes an empty directory", not os.path.exists("empty"))
        r = run("rmdir sub")
        check("rmdir of a non-empty directory fails", r.rc == 1 and os.path.isdir("sub"), r)
        r = run("mktemp")
        path = r.text.strip()
        check("mktemp makes a file and prints its path",
              r.rc == 0 and os.path.isfile(path) and "blenderlocal_" in path, r)
        if os.path.isfile(path):
            os.remove(path)
        r = run("mktemp -d")
        path = r.text.strip()
        check("mktemp -d makes a directory", r.rc == 0 and os.path.isdir(path), r)
        if os.path.isdir(path):
            os.rmdir(path)
        r = run("tee copy1.txt copy2.txt", stdin=b"typed\n")
        check("tee copies the input to the terminal and each file",
              r.text == "typed\n" and open("copy1.txt").read() == "typed\n"
              and open("copy2.txt").read() == "typed\n", r)
        run("tee -a copy1.txt", stdin=b"again\n")
        check("tee -a appends", open("copy1.txt").read() == "typed\nagain\n")


@section
def test_inspect():
    with Home() as home:
        fixture(home)
        home.file("a2.txt", "hello\nworld\n")
        home.file("pic.png", b"\x89PNG\r\n\x1a\n" + b"\0" * 8)
        home.file("scene.blend", b"BLENDER-v404REND")
        home.file("empty.txt", "")
        home.file("bin.dat", bytes(range(32)))
        home.file("junk.dat", b"\xff\xfe\x00\x80")

        r = run("cat a.txt b.py")
        check("cat prints files", r.rc == 0 and r.text == "hello\nprint('b')\n", r)
        r = run("cat", stdin=b"typed line\nsecond\n")
        check("cat with no file copies the pipe until the end of input",
              r.rc == 0 and r.text == "typed line\nsecond\n", r)
        r = run("cat -", stdin="naïve ✓\n".encode())
        check("cat - reads the pipe as UTF-8", r.rc == 0 and r.text == "naïve ✓\n", r)
        r = run("cat", stdin=b"partial\x03", keep_open=True)
        check("0x03 while cat reads is Ctrl-C", r.rc == 130 and "^C" in r.text and not r.forced, r)
        r = run("cat", stdin=b"before\x04after", keep_open=True)
        check("0x04 in the input ends it like ⌃D", r.rc == 0 and r.text == "before" and not r.forced, r)
        r = run("cat nope.txt")
        check("cat of a missing file fails", r.rc == 1 and "cat:" in r.text, r)

        check("head -n 3", run("head -n 3 lines.txt").text == "line 1\nline 2\nline 3\n")
        check("head -2", run("head -2 lines.txt").text == "line 1\nline 2\n")
        check("tail -n 2", run("tail -n 2 lines.txt").text == "line 19\nline 20\n")
        r = run("tail -n 0 lines.txt")
        check("tail -n 0 prints nothing", r.rc == 0 and r.text == "", r)
        r = run("head")
        check("head needs a file", r.rc == 1 and "usage" in r.text, r)

        size = len(open("lines.txt").read())
        r = run("wc lines.txt")
        check("wc counts lines, words and characters", r.text.split() == ["20", "40", str(size), "lines.txt"], r)
        r = run("wc", stdin=b"one two\nthree\n")
        check("wc counts the pipe", r.text.split()[:3] == ["2", "3", "14"], r)

        r = run("grep 'line 1[0-9]' lines.txt")
        check("grep prints file:line: for each match",
              r.rc == 0 and r.text.count("\n") == 10 and "lines.txt:10: line 10\n" in r.text, r)
        r = run("grep -i 'LINE 20' lines.txt")
        check("grep -i ignores case", r.rc == 0 and r.text == "lines.txt:20: line 20\n", r)
        r = run("grep nothing lines.txt")
        check("grep with no match returns 1", r.rc == 1 and r.text == "", r)
        r = run("grep '(' lines.txt")
        check("grep with a bad pattern returns 2", r.rc == 2 and "bad pattern" in r.text, r)

        r = run("find . -name '*.py'")
        check("find -name matches by pattern", r.rc == 0 and r.text == "./b.py\n", r)
        r = run("find sub")
        check("find lists a tree", r.text == "sub/inner.txt\n", r)
        r = run("find nowhere")
        check("find of a missing path fails", r.rc == 1, r)

        r = run("tree")
        check("tree draws the directory, hiding dotfiles",
              r.rc == 0 and "├── sub" in r.text and "│   └── inner.txt" in r.text
              and "└── scene.blend" in r.text and ".hidden" not in r.text, r)

        r = run("stat a.txt")
        check("stat shows type, size, permissions and time",
              "type   : file" in r.text and "size   : 6.0B (6 bytes)" in r.text
              and "perms  : -rw" in r.text and re.search(r"mtime  : \d{4}-\d\d-\d\d \d\d:\d\d:\d\d", r.text), r)

        r = run("file pic.png scene.blend empty.txt sub a.txt junk.dat")
        check("file names types by their contents", r.text.splitlines() == [
            "pic.png: PNG image", "scene.blend: Blender file", "empty.txt: empty",
            "sub: directory", "a.txt: ASCII / UTF-8 text", "junk.dat: data"], r)

        r = run("xxd bin.dat")
        dump = r.text.splitlines()
        check("xxd dumps offset, hex and text", dump == [
            "00000000  00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f  |................|",
            "00000010  10 11 12 13 14 15 16 17 18 19 1a 1b 1c 1d 1e 1f  |................|"], dump)
        check("hexdump is xxd", run("hexdump bin.dat").text == r.text)

        r = run("diff a.txt a2.txt")
        check("diff prints a unified diff and returns 1",
              r.rc == 1 and "--- a.txt" in r.text and "+++ a2.txt" in r.text and "\n+world\n" in r.text, r)
        r = run("diff a.txt a.txt")
        check("diff of identical files returns 0", r.rc == 0 and "(files identical)" in r.text, r)

        check("less prints the file", run("less a.txt").text == "hello\n")
        r = run("more a.txt b.py")
        check("more divides several files", "═" * 60 in r.text and "print('b')" in r.text, r)


@section
def test_text():
    with Home() as home:
        home.file("nums.txt", "10\n9\n100\n9\n")
        home.file("dups.txt", "a\na\nb\na\n")
        home.file("data.csv", "a,b,c\n1,2,3\n")
        home.file("blank.txt", "one\n\ntwo\n")

        check("echo", run("echo hello   world").text == "hello world\n")
        check("sort", run("sort nums.txt").text == "10\n100\n9\n9\n")
        check("sort -n", run("sort -n nums.txt").text == "9\n9\n10\n100\n")
        check("sort -rn", run("sort -rn nums.txt").text == "100\n10\n9\n9\n")
        check("sort -u", run("sort -u nums.txt").text == "10\n100\n9\n")
        check("sort reads the pipe", run("sort", stdin=b"b\nc\na\n").text == "a\nb\nc\n")
        r = run("sort", stdin=b"b\na\x03", keep_open=True)
        check("0x03 while sort reads is Ctrl-C", r.rc == 130 and "^C" in r.text, r)
        check("uniq", run("uniq dups.txt").text == "a\nb\na\n")
        check("uniq -c", run("uniq -c dups.txt").text == "   2 a\n   1 b\n   1 a\n")
        check("tr a-z A-Z", run("tr a-z A-Z", stdin=b"hello\n").text == "HELLO\n")
        check("tr -d 0-9", run("tr -d 0-9", stdin=b"a1b22c\n").text == "abc\n")
        check("seq 3", run("seq 3").text == "1\n2\n3\n")
        check("seq 0 2 6", run("seq 0 2 6").text == "0\n2\n4\n6\n")
        check("seq 1 0.5 2", run("seq 1 0.5 2").text == "1\n1.5\n2\n")
        check("yes prints y a hundred times", run("yes").text == "y\n" * 100)
        check("yes STRING", run("yes ok go").text == "ok go\n" * 100)

        r = run("sleep 0.3")
        check("sleep waits, even with the input already ended",
              r.rc == 0 and 0.28 <= r.seconds < 2, r)
        r = run("sleep 30", stdin=b"\x03", keep_open=True)
        check("0x03 cuts sleep short", r.rc == 130 and r.seconds < 2 and not r.forced, r)
        check("sleep needs a number", run("sleep soon").rc == 1)

        r = run("time echo hi")
        check("time runs the command and prints the real time",
              r.rc == 0 and r.text.startswith("hi\n") and re.search(r"real  \d+\.\d{3}s", r.text), r)
        check("time resolves aliases", run("time ll").rc == 0)

        check("bc", run("bc 2+3*4").text == "14\n")
        check("bc division", run("bc '(1+2)/4'").text == "0.75\n")
        check("bc big integers", run("bc 2**100").text == f"{2 ** 100}\n")
        r = run("bc 9**9**9")
        check("bc refuses a power too large to finish", r.rc == 1 and "too large" in r.text and r.seconds < 2, r)
        check("bc refuses names", run("bc import os").rc == 1)
        r = run("cal 2 2024")
        check("cal", r.rc == 0 and "February 2024" in r.text and "29" in r.text, r)
        check("nl numbers non-empty lines", run("nl blank.txt").text == "     1\tone\n\n     2\ttwo\n")
        check("tac", run("tac blank.txt").text == "two\n\none\n")
        check("rev", run("rev blank.txt").text == "eno\n\nowt\n")
        check("cut -d, -f", run("cut -d, -f 1,3 data.csv").text == "a,c\n1,3\n")
        check("cut -c", run("cut -c 1-3 data.csv").text == "a,b\n1,2\n")
        check("base64 encodes", run("base64 hello").text == "aGVsbG8=\n")
        check("base64 -d decodes", run("base64 -d aGVsbG8=").text == "hello\n")
        data = open("nums.txt", "rb").read()
        check("sha256sum", run("sha256sum nums.txt").text == f"{hashlib.sha256(data).hexdigest()}  nums.txt\n")
        check("sha1sum", run("sha1sum nums.txt").text == f"{hashlib.sha1(data).hexdigest()}  nums.txt\n")
        check("md5sum", run("md5sum nums.txt").text == f"{hashlib.md5(data).hexdigest()}  nums.txt\n")
        check("md5sum reads the pipe", run("md5sum", stdin=b"abc").text == f"{hashlib.md5(b'abc').hexdigest()}  -\n")
        check("basename", run("basename /a/b/c.txt .txt").text == "c\n")
        check("dirname", run("dirname /a/b/c.txt").text == "/a/b\n")
        check("realpath", run("realpath .").text.strip() == home.real)
        r = run("export BL_SHELL_TEST=on")
        check("export sets a variable", r.rc == 0 and os.environ.get("BL_SHELL_TEST") == "on", r)
        check("env lists it", "BL_SHELL_TEST=on" in run("env").text.splitlines())
        os.environ.pop("BL_SHELL_TEST", None)


@section
def test_archives():
    with Home() as home:
        fixture(home)
        r = run("zip out.zip a.txt sub")
        check("zip writes an archive", r.rc == 0 and zipfile.is_zipfile("out.zip") and "wrote out.zip" in r.text, r)
        r = run("unzip -l out.zip")
        check("unzip -l lists it", "a.txt" in r.text and "sub/inner.txt" in r.text, r)
        r = run("unzip -d unz out.zip")
        check("zip and unzip round-trip",
              r.rc == 0 and open("unz/a.txt").read() == "hello\n"
              and open("unz/sub/inner.txt").read() == "inner\n", r)

        r = run("tar -czf t.tar.gz a.txt sub")
        check("tar -czf writes a gzipped tar", r.rc == 0 and tarfile.is_tarfile("t.tar.gz"), r)
        r = run("tar -tzf t.tar.gz")
        check("tar -t lists it", "a.txt" in r.text and "sub/inner.txt" in r.text, r)
        os.mkdir("tx")
        r = run("tar -xzf t.tar.gz -C tx")
        check("tar round-trips",
              r.rc == 0 and open("tx/a.txt").read() == "hello\n"
              and open("tx/sub/inner.txt").read() == "inner\n", r)
        run("tar -cjf t.tar.bz2 sub")
        r = run("tar -xjf t.tar.bz2 -C unbz")
        check("tar -j (bzip2) round-trips", r.rc == 0 and os.path.isfile("unbz/sub/inner.txt"), r)
        run("tar -cJf t.tar.xz sub")
        r = run("tar -xJf t.tar.xz -C unxz")
        check("tar -J (xz) round-trips", r.rc == 0 and os.path.isfile("unxz/sub/inner.txt"), r)

        evil = io.BytesIO()
        with tarfile.open(fileobj=evil, mode="w") as tf:
            info = tarfile.TarInfo("../escaped.txt")
            info.size = 4
            tf.addfile(info, io.BytesIO(b"nope"))
        home.file("evil.tar", evil.getvalue())
        os.mkdir("safe")
        r = run("tar -xf evil.tar -C safe")
        check("tar won't write outside the destination",
              r.rc == 1 and not os.path.exists(os.path.join(home.path, "escaped.txt")), r)

        home.file("g.txt", "gzip me\n" * 50)
        r = run("gzip g.txt")
        check("gzip replaces the file with a .gz",
              r.rc == 0 and os.path.isfile("g.txt.gz") and not os.path.exists("g.txt"), r)
        r = run("gunzip g.txt.gz")
        check("gunzip restores it",
              r.rc == 0 and open("g.txt").read() == "gzip me\n" * 50 and not os.path.exists("g.txt.gz"), r)

        r = run("extract out.zip -oex1")
        check("extract unpacks a zip", r.rc == 0 and os.path.isfile("ex1/sub/inner.txt"), r)
        r = run("extract t.tar.gz -oex2")
        check("extract unpacks a tar.gz", r.rc == 0 and os.path.isfile("ex2/a.txt"), r)
        with gzip.open("single.txt.gz", "wb") as f:
            f.write(b"one stream\n")
        r = run("extract single.txt.gz -oex3")
        check("extract unpacks a lone .gz", r.rc == 0 and open("ex3/single.txt").read() == "one stream\n", r)
        home.file("fake.7z", b"7z\xbc\xaf\x27\x1c\0\0")
        r = run("extract fake.7z")
        check("extract refuses 7z and says why", r.rc == 1 and "aren't supported" in r.text, r)
        home.file("fake.rar", b"Rar!\x1a\x07\0")
        r = run("extract fake.rar")
        check("extract refuses RAR", r.rc == 1 and "RAR isn't supported" in r.text, r)


@section
def test_disk():
    with Home() as home:
        fixture(home)
        home.file("big/blob.bin", b"\0" * 2048)
        r = run("du")
        check("du lists each entry, then a total",
              r.rc == 0 and re.search(r"^\s*2\.0KiB  big$", r.text, re.M)
              and re.search(r"^\s*6\.0B  sub$", r.text, re.M) and r.text.splitlines()[-1].endswith("  ."), r)
        r = run("du -s big")
        check("du -s prints only the total", r.text.strip() == "2.0KiB  big", r)
        check("du of a missing path fails", run("du nowhere").rc == 1)
        r = run("df")
        check("df prints the sandbox filesystem",
              r.rc == 0 and "Filesystem      Size   Used   Free  Use%  Mounted on" in r.text
              and re.search(r"^iOS sandbox\s+\d+\.\d\w+ +\d+\.\d\w+ +\d+\.\d\w+ +\d+%  ", r.text, re.M), r)


@section
def test_system_info():
    with Home():
        r = run("date")
        check("date prints the time and the year", re.search(r"\d\d:\d\d:\d\d .*\d{4}$", r.text.strip()), r)
        r = run("uptime")
        check("uptime prints how long the shell has run", re.fullmatch(r"shell up \d+h \d+m \d+s", r.text.strip()), r)
        check("uname prints the kernel", run("uname").text.strip() == platform.system())
        r = run("uname -a")
        check("uname -a prints release and machine",
              os.uname().release in r.text and os.uname().machine in r.text, r)
        check("whoami", run("whoami").text.strip() == getpass.getuser())
        check("hostname", run("hostname").text.strip() == (os.uname().nodename or "localhost"))
        r = run("id")
        check("id prints uid and gid",
              re.fullmatch(rf"uid={os.getuid()}\({re.escape(getpass.getuser())}\) gid=\d+", r.text.strip()), r)
        check("nproc", run("nproc").text.strip() == str(os.cpu_count()))


@section
def test_help():
    with Home():
        r = run("help")
        words = set(r.text.split())
        missing = sorted(c for c in sh.COMMANDS if c not in words)
        check("help names every command", r.rc == 0 and not missing, missing)
        check("help doesn't mention the app it came from",
              not re.search(r"codebench|benchcode|offlinai", r.text, re.I))
        r = run("help ll")
        check("help on an alias explains it", "(ll is an alias for ls)" in r.text, r)
        r = run("help pip")
        check("help on a left-out command says why", r.rc == 127 and "isn't available in Blender Local" in r.text, r)
        check("help on an unknown name fails", run("help nothing").rc == 1)
        r = run("man grep")
        check("man prints a command's docs", r.rc == 0 and "grep [-i] <pattern> <file…>" in r.text, r)
        r = run("man nothing")
        check("man of an unknown command fails", r.rc == 1 and "no entry for nothing" in r.text, r)
        r = run("which ls ll os")
        lines = r.text.splitlines() + ["", "", ""]
        check("which ls is a builtin", lines[0] == "ls: shell builtin", r)
        check("which ll is an alias", lines[1] == "ll: aliased to 'ls -lah'", r)
        check("which os is a Python module", lines[2].startswith("os: Python module at "), r)
        check("which of an unknown name fails", run("which nothing").rc == 1)


@section
def test_terminal():
    with Home():
        r = run("clear")
        check("clear wipes the screen and scrollback", r.rc == 0 and r.out == "\x1b[3J\x1b[2J\x1b[H", r)
        check("cls is clear", run("cls").out == "\x1b[3J\x1b[2J\x1b[H")
        r = run("history")
        check("history points at ↑/↓", "↑" in r.text and "↓" in r.text, r)
        for command in ("exit", "quit", "exit 3"):
            r = run(command)
            check(f"`{command}` says the console stays open, and doesn't exit",
                  r.rc == 0 and "the console stays open" in r.text, r)


@section
def test_ps_kill():
    with Home():
        pid = os.getpid()
        r = run("ps")
        rows = r.text.splitlines()
        fields = rows[1].split() if len(rows) > 1 else []
        check("ps shows a header and this process",
              r.rc == 0 and rows and rows[0].split() == ["PID", "STATE", "CPU%", "RSS", "THR", "CMD"]
              and fields[:2] == [str(pid), "running"], r)
        check("ps fills in CPU, resident size and threads",
              len(fields) >= 5 and re.fullmatch(r"\d+\.\d%", fields[2])
              and re.fullmatch(r"\d+\.\d(B|KiB|MiB|GiB)", fields[3]) and fields[4].isdigit(), rows)

        got = []
        previous = signal.signal(signal.SIGTERM, lambda *_: got.append(True))
        try:
            r = run(f"kill {pid}")
            time.sleep(0.05)
        finally:
            signal.signal(signal.SIGTERM, previous)
        check("kill refuses this process", r.rc == 1 and "refusing" in r.text and not got, (r, got))
        r = run("kill -0 0")
        check("kill refuses 0, which would include this process", r.rc == 1 and "refusing" in r.text, r)
        r = run("kill -HUP 99999999")
        check("kill of a missing process fails", r.rc == 1 and "kill: 99999999:" in r.text, r)
        r = run("kill -NOPE 123")
        check("kill with an unknown signal fails", r.rc == 1 and "unknown signal" in r.text, r)


@section
def test_watch():
    with Home():
        r = run("watch -n 0.1 -c 3 echo tick", keep_open=True)
        check("watch -c runs the command that many times",
              r.rc == 0 and r.text.splitlines().count("tick") == 3 and not r.forced, r)
        check("watch clears and heads every run",
              r.out.count("\x1b[H\x1b[2J") == 3 and r.text.count("every 0.1s — echo tick") == 3, r)
        check("watch waits between runs", 0.18 <= r.seconds < 3, r.seconds)
        r = run("watch -n 5 -c 3 echo tick")
        check("the end of input stops watch",
              r.rc == 0 and r.text.splitlines().count("tick") == 1 and r.seconds < 2, r)
        r = run("watch -n 5 -c 3 echo tick", stdin=b"\x03", keep_open=True)
        check("0x03 stops watch", r.rc == 130 and "^C" in r.text and r.seconds < 2, r)
        r = run("watch -n 0.1 -c 2 ll", keep_open=True)
        check("watch resolves aliases", r.rc == 0 and not r.forced, r)
        r = run("watch nothing")
        check("watch of an unknown command fails", r.rc == 1 and "not a builtin" in r.text, r)


@section
def test_keys():
    sh._pushback.clear()
    pipe = Pipe(b"\x1b[5~\x1b[6~\x1b[3~\x1b[A\x1bOB\x1b[1;5Cx\r\x7f\x03\x04")
    keys = []
    try:
        for _ in range(20):
            key = sh._tui_read_key(1.0)
            keys.append(key)
            if key in ("", None):
                break
    finally:
        pipe.restore()
    check("raw keys are read whole, escape sequences to their final byte",
          keys == ["pageup", "pagedown", "delete", "up", "down", "right", "x", "enter",
                   "backspace", "ctrl-c", "ctrl-d", ""], keys)


def frames(out):
    return out.count(TOP_TITLE)


def restored(out):
    """The terminal was put back: cooked after the last raw, cursor shown
    after the last hide, and nothing left set."""
    return (out.rfind(sh.COOKED_MARKER) > out.rfind(sh.RAW_MARKER) >= 0
            and out.rfind("\x1b[?25h") > out.rfind("\x1b[?25l") >= 0
            and not any(sh._screen.values()))


@section
def test_top():
    with Home():
        cores = os.cpu_count()
        r = run("top", stdin=b"q", keep_open=True)
        check("top with q exits after one frame",
              r.rc == 0 and frames(r.out) == 1 and not r.forced and r.seconds < 5, r)
        positions = [r.out.find(s) for s in ("\x1b[?25l", sh.RAW_MARKER, sh.COOKED_MARKER, "\x1b[?25h")]
        check("top hides the cursor, goes raw, then cooked, then shows the cursor",
              0 <= positions[0] < positions[1] < positions[2] < positions[3]
              and r.out.endswith(sh.COOKED_MARKER + "\x1b[?25h"), (positions, repr(r.out[-60:])))
        t = r.text
        check("top shows total CPU with a real number", re.search(r"CPU total  \[[|·]{32}\]\s+\d+\.\d%", t), t)
        check("top shows a bar for every core",
              f"cores ({cores})" in t and len(re.findall(r"#\d+\s+\[[|·]{32}\]\s+\d+\.\d%", t)) == cores, t)
        check("top shows RAM used of total",
              re.search(r"RAM\s+\[[|·]{32}\]\s+\d+\.\d%\s+\d+\.\d(B|KiB|MiB|GiB) / \d+\.\dGiB", t), t)
        check("top shows swap or compressed memory", re.search(r"Swap/cmp|Compressed \d", t), t)
        check("top shows load average, uptime and the CPU time split",
              re.search(r"load avg\s+\d+\.\d\d\s+\d+\.\d\d\s+\d+\.\d\d", t)
              and re.search(r"Uptime\s+(\d+d \d+h \d+m|\d+h \d+m|\d+m)", t)
              and re.search(r"CPU time\s+.*idl=\d+\.\d%", t), t)
        check("top shows disk space in the home",
              re.search(r"Disk\s+\[[|·]{32}\]\s+\d+\.\d%\s+\d+\.\d\w+ / \d+\.\d\w+\s+\(app home\)", t), t)
        check("top shows this process's footprint, resident size, threads and CPU",
              re.search(rf"Process\s+pid={os.getpid()}\s+footprint=\d+\.\dMiB\s+rss=\d+\.\dMiB\s+"
                        rf"threads=\d+\s+cpu=\d+\.\d%", t), t)
        check("top names the device, chip and GPU",
              re.search(r"Device\s+\S", t) and re.search(r"Chip\s+\S", t) and "integrated" in t, t)
        check("top shows no line for battery or network", "Battery" not in t and "Net " not in t, t)
        check("every probe answered on this Mac", "–" not in t, t)

        r = run("htop", stdin=b"q", keep_open=True)
        check("htop is top", r.rc == 0 and frames(r.out) == 1, r)
        r = run("top", stdin=b"\x03", keep_open=True)
        check("0x03 on the pipe quits top after its frame",
              r.rc == 0 and frames(r.out) == 1 and not r.forced and restored(r.out), r)
        r = run("top")
        check("the end of input quits top", r.rc == 0 and frames(r.out) == 1 and r.seconds < 5, r)
        r = run("top", stdin=b" q", keep_open=True)
        check("space redraws at once", frames(r.out) == 2 and r.seconds < 3, r)
        r = run("top -d 0.2", keep_open=True, feed=lambda p: (time.sleep(0.9), p.write(b"q")))
        check("top -d sets the refresh interval", r.rc == 0 and frames(r.out) >= 3 and not r.forced,
              (frames(r.out), r))
        r = run("top", stdin=b"q", keep_open=True, thread=True)
        check("top runs from a background thread", r.rc == 0 and frames(r.out) == 1, r)

        tracer, fired = stop_after(0.6)
        sys.settrace(tracer)
        try:
            r = run("top", keep_open=True)
        finally:
            sys.settrace(None)
        check("Stop during top ends it with ^C and 130",
              fired and r.rc == 130 and "^C" in r.text and not r.forced, r)
        check("…and puts the terminal back", restored(r.out), repr(r.out[-120:]))

        calls = []
        real_exit = sh.tui_exit_raw

        def interrupted_once():
            calls.append(True)
            if len(calls) == 1:
                raise KeyboardInterrupt("Stopped by user")
            real_exit()

        sh.tui_exit_raw = interrupted_once
        try:
            r = run("top", stdin=b"q", keep_open=True)
        finally:
            sh.tui_exit_raw = real_exit
        check("Stop landing in top's own cleanup still puts the terminal back",
              r.rc == 130 and restored(r.out), (r, sh._screen))


@section
def test_probes_fail_soft():
    names = ["_cpu_ticks", "_vm_statistics", "_sysctl_raw", "_task_memory", "_thread_count",
             "_loadavg", "_boot_time", "_disk_usage", "_open_fd_count", "_process_start",
             "_proc_cpu_seconds", "_kinfo_proc"]
    saved = {name: getattr(sh, name) for name in names}
    saved_page = sh._page_size_cache
    try:
        for name in names:
            setattr(sh, name, lambda *a, **k: None)
        sh._page_size_cache = None
        with Home():
            r = run("top", stdin=b"q", keep_open=True)
            check("top with every probe failing still draws its frame, with –",
                  r.rc == 0 and frames(r.out) == 1 and r.text.count("–") >= 8
                  and "Traceback" not in r.text and restored(r.out), r)
            r = run("ps")
            check("ps with every probe failing shows –",
                  r.rc == 0 and "–" in r.text and str(os.getpid()) in r.text, r)
    finally:
        for name, fn in saved.items():
            setattr(sh, name, fn)
        sh._page_size_cache = saved_page

    saved_lib = (sh._libsys, sh._libsys_tried, sh._host_port, sh._page_size_cache)
    try:
        sh._libsys, sh._libsys_tried, sh._host_port, sh._page_size_cache = None, True, None, None
        with Home():
            r = run("top", stdin=b"q", keep_open=True)
            check("top without libSystem at all still draws, with –",
                  r.rc == 0 and frames(r.out) == 1 and "–" in r.text and "Traceback" not in r.text, r)
    finally:
        sh._libsys, sh._libsys_tried, sh._host_port, sh._page_size_cache = saved_lib


def highlighted(out):
    """The entry drawn in inverse video in each ncdu frame."""
    return re.findall(r"\x1b\[7m\s+[\d.]+ +(?:B|KiB|MiB|GiB) \[[# ]*\]\s+(\S+)", out)


@section
def test_ncdu():
    with Home() as home:
        for i in range(30):
            home.file(f"many/f{i:02d}.bin", b"\0" * ((i + 1) * 1000))
        os.chdir("many")

        r = run("ncdu", stdin=b"q", keep_open=True)
        check("ncdu with q quits", r.rc == 0 and not r.forced and r.seconds < 3, r)
        positions = [r.out.find(s) for s in ("\x1b[?1049h", sh.RAW_MARKER, sh.COOKED_MARKER, "\x1b[?1049l")]
        check("ncdu switches to the alternate screen, goes raw, and back again",
              0 <= positions[0] < positions[1] < positions[2] < positions[3], positions)
        check("ncdu hides the cursor on the way in and shows it on the way out",
              "\x1b[?1049h\x1b[?25l" in r.out and "\x1b[?25h\x1b[?1049l" in r.out and restored(r.out))
        check("ncdu draws its title, entries and totals",
              "ncdu 1.1 ~ Use the arrow keys" in r.text and "f29.bin" in r.text
              and "Items: 30" in r.text and "(ncdu exited — last path:" in r.text, r)

        # 30 rows leave 24 for entries, so a page moves the cursor 24 down.
        r = run("ncdu", stdin=b"\x1b[6~q", keep_open=True)
        check("PgDn (ESC [ 6 ~) moves a page", highlighted(r.out) == ["f29.bin", "f05.bin"], highlighted(r.out))
        r = run("ncdu", stdin=b"\x1b[6~\x1b[5~q", keep_open=True)
        check("PgUp (ESC [ 5 ~) moves back", highlighted(r.out) == ["f29.bin", "f05.bin", "f29.bin"],
              highlighted(r.out))
        r = run("ncdu", stdin=b"\x1b[3~jq", keep_open=True)
        check("Delete (ESC [ 3 ~) is one key, not a stray ~",
              highlighted(r.out) == ["f29.bin", "f29.bin", "f28.bin"], highlighted(r.out))
        r = run("ncdu", stdin=b"\x1bq", keep_open=True)
        check("a lone ESC is Escape, and the key after it still counts",
              r.rc == 0 and not r.forced and len(highlighted(r.out)) == 2, r)
        r = run("ncdu")
        check("the end of input quits ncdu", r.rc == 0 and not r.forced and r.seconds < 3, r)
        r = run("ncdu", stdin=b"\x03", keep_open=True)
        check("0x03 quits ncdu", r.rc == 0 and not r.forced, r)
        r = run("ncdu", stdin=b"?xq", keep_open=True)
        check("? shows the keys", "ncdu keys" in r.text and "cycle sort order" in r.text, r)
        r = run("ncdu", stdin=b"sq", keep_open=True)
        check("s sorts by name instead", highlighted(r.out) == ["f29.bin", "f00.bin"], highlighted(r.out))
        r = run("ncdu", stdin=b"ixq", keep_open=True)
        check("i shows the selected file's details, and a key returns",
              r.rc == 0 and not r.forced and "type   : file" in r.text and "f29.bin" in r.text
              and len(highlighted(r.out)) == 2, r)

        many = os.getcwd()
        r = run("ncdu", stdin=b"b" + b"echo from-mini-shell\npwd\nexit\n" + b"q", keep_open=True)
        check("b opens a shell in ncdu's directory, and exit returns to ncdu",
              r.rc == 0 and not r.forced and "ncdu:shell>" in r.text and "from-mini-shell" in r.text
              and (many + "\n") in r.text and len(highlighted(r.out)) == 2, r)
        check("…with cooked keys for the shell and raw keys again after",
              r.out.count(sh.RAW_MARKER) == 2 and r.out.count(sh.COOKED_MARKER) == 2
              and restored(r.out) and os.getcwd() == many,
              (r.out.count(sh.RAW_MARKER), r.out.count(sh.COOKED_MARKER), os.getcwd()))

        # cat reads what is already in the pipe, ^C and all; the rest comes later.
        r = run("ncdu", stdin=b"bcat\nabc\x03", keep_open=True,
                feed=lambda p: (time.sleep(0.6), p.write(b"exit\nq")))
        check("^C in the mini-shell stops that command, not ncdu",
              r.rc == 0 and not r.forced and "^C" in r.text and len(highlighted(r.out)) == 2, r)
        check("…and ncdu stays on its own screen until it quits",
              r.out.count("\x1b[?1049l") == 1 and r.out.rfind("\x1b[?1049l") > r.out.rfind(sh.RAW_MARKER),
              r.out.count("\x1b[?1049l"))

        r = run("ncdu", stdin=b"dnq", keep_open=True)
        check("d asks first, and anything but y keeps the file",
              "Delete file f29.bin? (y/N)" in r.text and os.path.exists("f29.bin") and not r.forced, r)
        r = run("ncdu", stdin=b"dyq", keep_open=True)
        check("d then y deletes the selected file",
              r.rc == 0 and not r.forced and not os.path.exists("f29.bin") and "Items: 29" in r.text, r)
        r = run("ncdu", stdin=b"q", keep_open=True, columns=40, rows=12)
        drawn = plain(r.out[r.out.find(sh.RAW_MARKER):r.out.find(sh.COOKED_MARKER)])
        widest = max((len(line) for line in drawn.split("\n")), default=0)
        check("ncdu fits a narrow terminal", r.rc == 0 and 0 < widest <= 40 and "more below" in drawn,
              (widest, drawn))

        os.chdir(home.path)
        # Wide enough for the whole path in each header. A temp home nested a
        # few directories deep is longer than 100 columns, and ncdu rightly
        # shortens it to "--- ...tail", which carries no path to compare.
        r = run("ncdu", stdin=b"\r\x1b[D\x1b[Dq", keep_open=True, columns=max(100, len(home.real) + 40))
        paths = re.findall(r"--- (\S+) -", r.text)
        check("ncdu opens a directory and goes back, but not above home",
              paths == [home.real, home.real + "/many", home.real, home.real], paths)

        r = run("ncdu nowhere")
        check("ncdu of a missing directory fails", r.rc == 1 and "not a directory" in r.text, r)


@section
def test_python():
    with Home() as home:
        home.file("args.py", "import sys\nprint('ARGV', sys.argv)\n")
        home.file("exits.py", "raise SystemExit(3)\n")
        home.file("msg.py", "import sys\nsys.exit('bad input')\n")
        home.file("boom.py", "x = 1\n\ndef f():\n    return x / 0\n\nf()\n")
        home.file("asks.py", "name = input('name? ')\nprint('hello', name)\n")
        home.file("helper_mod.py", "VALUE = 42\n")
        home.file("uses_helper.py", "import helper_mod\nprint('VALUE', helper_mod.VALUE)\n")
        home.file("spin.py", "while True:\n    pass\n")

        before = sys.argv[:]
        r = run("python args.py a b")
        check("python file.py a b passes argv", r.rc == 0 and "ARGV ['args.py', 'a', 'b']" in r.text, r)
        check("sys.argv is put back afterwards", sys.argv == before, sys.argv)
        check("py is python", "ARGV ['args.py', 'x']" in run("py args.py x").text)
        check("python3 is python", "ARGV ['args.py']" in run("python3 args.py").text)
        r = run("python exits.py")
        check("a script's exit status comes back", r.rc == 3 and "[exit 3]" in r.text, r)
        r = run("python msg.py")
        check("sys.exit('message') prints the message and fails", r.rc == 1 and "bad input" in r.text, r)
        r = run("python boom.py")
        check("an exception prints the script's own traceback and fails",
              r.rc == 1 and "ZeroDivisionError" in r.text and 'boom.py", line 4' in r.text
              and "runpy" not in r.text and "_blenderkit_shell" not in r.text, r)
        r = run("python asks.py", stdin=b"Ada\n")
        check("input() reads the pipe", r.rc == 0 and "hello Ada" in r.text, r)
        r = run("python uses_helper.py")
        check("a script imports modules beside it", r.rc == 0 and "VALUE 42" in r.text, r)
        check("…and its folder leaves sys.path afterwards",
              home.real not in sys.path and home.path not in sys.path,
              [p for p in sys.path if "blenderlocal-shell" in p])
        r = run("python")
        check("bare python says the console is already Python",
              r.rc == 0 and "This console is already Python" in r.text, r)
        r = run("python -c 'import sys; print(sys.argv)' q")
        check("python -c runs code with argv", r.text == "['-c', 'q']\n", r)
        check("python --version", run("python --version").text == f"Python {sys.version.split()[0]}\n")
        r = run("python nowhere.py")
        check("python of a missing file fails", r.rc == 2 and "no such file" in r.text, r)

        tracer, fired = stop_after(0.5)
        sys.settrace(tracer)
        try:
            r = run("python spin.py")
        finally:
            sys.settrace(None)
        check("Stop ends a spinning script with ^C and 130", fired and r.rc == 130 and "^C" in r.text, r)
        check("sys.stdin is put back after a script", not isinstance(sys.stdin, sh._Fd0Reader), sys.stdin)


@section
def test_excluded():
    with Home():
        bad = []
        for name in EXCLUDED:
            r = run(f"{name} something")
            if not (r.rc == 127 and r.text.count("\n") == 1 and r.out.startswith(sh.DIM)
                    and f"{name} isn't available in Blender Local — " in r.text):
                bad.append((name, r))
        check("every left-out command prints one dim line saying it isn't available, and why",
              not bad, bad[:3])
        r = run("pip install numpy")
        check("pip's reason is being offline", "works offline" in r.text, r)


# ---------------------------------------------------------------------------

def main():
    try:
        os.fstat(0)
    except OSError:
        fd = os.open(os.devnull, os.O_RDONLY)
        if fd != 0:
            os.dup2(fd, 0)
            os.close(fd)
    faulthandler.dump_traceback_later(900, exit=True, file=sys.__stderr__)
    for test in TESTS:
        try:
            test()
        except Exception as e:
            check(f"{test.__name__} ran to the end", False,
                  f"{type(e).__name__}: {e}\n{traceback.format_exc()}")
    faulthandler.cancel_dump_traceback_later()
    print("\nALL PASS" if failures == 0 else f"\n{failures} FAILED")
    sys.exit(0 if failures == 0 else 1)


if __name__ == "__main__":
    main()
