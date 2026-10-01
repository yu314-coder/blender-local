"""Shell commands for Blender Local's Python console.

The Scripting tab's console is Python. A line whose first word is one of the
commands below is handed to this module instead, and runs the way the Unix
tool of that name would — in pure Python, because an iOS app can neither fork
nor exec, and has no /bin to exec from.

How the app calls it
--------------------
    run_b64(line_b64, columns, rows) -> int

`line_b64` is base64 of the UTF-8 command line. The call runs on a background
thread of the app's interpreter and returns the command's exit status; it
never raises. COLUMNS and LINES are set from `columns` and `rows` first, and
the first call moves to the app's working folder (see `init`).

stdout and stderr go to the terminal as they are written, ANSI colour and
cursor escapes included. Keys typed while a command runs arrive on fd 0, a
pipe: closing its write end is end of input (⌃D, or the command being
stopped), and a 0x03 byte is Ctrl-C. Full-screen commands (top, htop, ncdu)
switch the terminal to raw keys with RAW_MARKER and back with COOKED_MARKER,
and put the terminal back however they end.

Nothing here touches the network, starts a process or installs code. The
system numbers top and ps show come from public Mach and sysctl calls, which
iOS and macOS answer alike; any that fail show as "–".
"""

import base64 as _base64
import io
import os
import shlex
import shutil
import stat as _stat
import struct
import sys
import time
import traceback
from pathlib import Path
from typing import Callable, Dict, List, Optional


# ---------------------------------------------------------------------------
# ANSI helpers — the app's terminal supports SGR colour codes.

def _c(n: int) -> str:
    return f"\x1b[{n}m"


RESET = _c(0)
BOLD = _c(1)
DIM = _c(2)
RED = _c(31)
GRN = _c(32)
YLW = _c(33)
BLU = _c(34)
MAG = _c(35)
CYN = _c(36)
WHT = _c(37)
GRAY = _c(90)

_DASH = "–"   # what a probe that could not answer shows


# ---------------------------------------------------------------------------
# Aliases and the commands Blender Local leaves out

ALIASES: Dict[str, str] = {
    "ll": "ls -lah",
    "la": "ls -a",
    "cls": "clear",
    "py": "python",
}

# Commands the same shell has elsewhere that are left out here, and why, in a
# few words. Most need the network or a code download, which the App Store
# rules and the app's offline promise both rule out; the rest need engines
# that are not bundled.
UNAVAILABLE: Dict[str, str] = {}
for _names, _why in (
    (("pip", "pip3", "pip-install", "pip-uninstall", "pip-list", "pip-show",
      "pip-freeze", "pip-check"),
     "it works offline, so nothing is installed from the internet"),
    (("git",), "it works offline, so nothing is cloned"),
    (("curl", "wget", "ping"), "it works offline"),
    (("ai",), "there's no AI assistant"),
    (("js", "node"), "there's no JavaScript engine"),
    (("cc", "gcc", "clang", "c++", "g++", "clang++", "gfortran", "f77", "f90",
      "f95"), "there's no compiler"),
    (("swift",), "there's no Swift interpreter"),
    (("pdflatex", "latex", "tex", "pdftex", "xelatex", "latex-diagnose"),
     "there's no TeX engine"),
    (("md", "markdown"), "there's no Markdown preview"),
    (("nb", "ipynb", "notebook"), "there's no notebook viewer"),
    (("manim",), "manim isn't bundled"),
    (("repl",), "the console is already Python"),
    (("debug", "debug-gui"), "there's no debugger"),
    (("cpu-z", "cpuz", "gpu-z", "gpuz"), "there are no benchmarks; top shows the hardware"),
    (("crash-log", "crashlog"), "no crash log is kept"),
    (("test-libs", "test_libs"), "there are no library self-tests"),
    (("7z",), "use zip, tar or gzip"),
    (("unar",), "use extract"),
    (("binwalk", "simg2img"), "firmware tools aren't bundled"),
):
    for _name in _names:
        UNAVAILABLE[_name] = _why
del _names, _why, _name


def _unavailable(name: str) -> int:
    print(f"{DIM}{name} isn't available in Blender Local — {UNAVAILABLE[name]}.{RESET}")
    return 127


# ---------------------------------------------------------------------------
# The terminal: size, raw mode, and what a full-screen command changed

# Written to switch the app's terminal to raw keys and back. Always paired in
# try/finally, so a crash restores cooked mode.
RAW_MARKER = "\x1b]blenderlocal;raw\x1b\\"
COOKED_MARKER = "\x1b]blenderlocal;cooked\x1b\\"
_TUI_RAW_MODE = RAW_MARKER
_TUI_COOKED_MODE = COOKED_MARKER

# What a full-screen command has changed about the terminal. The app's Stop
# raises KeyboardInterrupt between any two Python lines — including the lines
# of a command's own cleanup — so run_b64 checks this afterwards and undoes
# whatever is still set.
_screen = {"raw": False, "cursor_hidden": False, "alt": False}


def _write(s: str) -> None:
    sys.stdout.write(s)
    sys.stdout.flush()


def tui_enter_raw() -> None:
    _screen["raw"] = True
    _write(_TUI_RAW_MODE)


def tui_exit_raw() -> None:
    _write(_TUI_COOKED_MODE)
    _screen["raw"] = False


def _hide_cursor() -> None:
    _screen["cursor_hidden"] = True
    _write("\x1b[?25l")


def _show_cursor() -> None:
    _write("\x1b[?25h")
    _screen["cursor_hidden"] = False


def _alt_screen_on() -> None:
    _screen["alt"] = True
    _screen["cursor_hidden"] = True
    _write("\x1b[?1049h\x1b[?25l")


def _alt_screen_off() -> None:
    _write("\x1b[?25h\x1b[?1049l")
    _screen["alt"] = False
    _screen["cursor_hidden"] = False


def _restore_screen() -> None:
    """Undo whatever a full-screen command left set. Never raises."""
    try:
        if _screen["raw"]:
            tui_exit_raw()
        if _screen["cursor_hidden"] or _screen["alt"]:
            _write("\x1b[?25h" + ("\x1b[?1049l" if _screen["alt"] else ""))
    except BaseException:
        pass
    _screen["raw"] = _screen["cursor_hidden"] = _screen["alt"] = False


def _term_size() -> tuple:
    """(columns, rows) from COLUMNS and LINES, which run_b64 sets."""
    def _env(name: str, default: int) -> int:
        try:
            v = int(os.environ.get(name, ""))
        except ValueError:
            return default
        return v if v > 0 else default
    return _env("COLUMNS", 80), _env("LINES", 24)


def _set_size(columns, rows) -> None:
    try:
        cols = int(columns)
    except (TypeError, ValueError):
        cols = 80
    try:
        lines = int(rows)
    except (TypeError, ValueError):
        lines = 24
    os.environ["COLUMNS"] = str(max(1, cols))
    os.environ["LINES"] = str(max(1, lines))


def _fit(s: str, width: int) -> str:
    """Pad or cut `s` to exactly `width` characters."""
    return s[:width] if len(s) >= width else s + " " * (width - len(s))


# ---------------------------------------------------------------------------
# Standard input — the keys typed into the console, on fd 0
#
# Every wait is cut into short slices. The app stops a command by raising
# KeyboardInterrupt between Python lines, so a command blocked for a whole
# second in select() would keep Stop waiting for that second.

# Bytes read ahead of need and handed back, e.g. the key after a lone ESC.
_pushback = bytearray()


def _fd0_ready(timeout: float) -> bool:
    """Whether a read of fd 0 would return now: data, or end of input."""
    if _pushback:
        return True
    import select
    try:
        ready, _, _ = select.select([0], [], [], max(0.0, timeout))
        return bool(ready)
    except (OSError, ValueError):
        # No usable fd 0 at all: say it is ready, and the read reports the
        # end of input.
        return True


def _fd0_read(n: int) -> Optional[bytes]:
    """Up to `n` bytes from fd 0; b"" at end of input, None if nothing yet."""
    if _pushback:
        data = bytes(_pushback[:n])
        del _pushback[:n]
        return data
    try:
        return os.read(0, n)
    except (BlockingIOError, InterruptedError):
        return None
    except OSError:
        return b""


def _unread(data: bytes) -> None:
    _pushback[:0] = data


def _stdin_chunks():
    """Yield what arrives on fd 0 until the end of input.

    0x03 is Ctrl-C and raises KeyboardInterrupt; a 0x04 in the stream ends
    input the way ⌃D does at a terminal."""
    while True:
        if not _fd0_ready(0.1):
            continue
        data = _fd0_read(65536)
        if data is None:
            time.sleep(0.01)
            continue
        if not data:
            return
        if b"\x03" in data:
            raise KeyboardInterrupt
        eot = data.find(b"\x04")
        if eot >= 0:
            if eot:
                yield data[:eot]
            return
        yield data


def _stdin_bytes() -> bytes:
    return b"".join(_stdin_chunks())


def _stdin_text() -> str:
    return _stdin_bytes().decode("utf-8", errors="replace")


def _copy_stdin_to_stdout() -> None:
    import codecs
    decoder = codecs.getincrementaldecoder("utf-8")("replace")
    for chunk in _stdin_chunks():
        sys.stdout.write(decoder.decode(chunk))
        sys.stdout.flush()
    tail = decoder.decode(b"", final=True)
    if tail:
        sys.stdout.write(tail)


def _pause(seconds: float, stop_at_eof: bool) -> bool:
    """Wait `seconds` while watching fd 0 for Ctrl-C.

    0x03 raises KeyboardInterrupt and other keys are dropped. Returns False
    when input ended and `stop_at_eof` asks for that to end the wait early,
    True otherwise."""
    deadline = time.monotonic() + max(0.0, seconds)
    input_open = True
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return True
        step = min(remaining, 0.1)
        if not input_open:
            time.sleep(step)
            continue
        if not _fd0_ready(step):
            continue
        data = _fd0_read(4096)
        if data is None:
            time.sleep(min(step, 0.01))
            continue
        if b"\x03" in data:
            raise KeyboardInterrupt
        if not data or b"\x04" in data:
            if stop_at_eof:
                return False
            input_open = False


def _read_line_fd0() -> Optional[str]:
    """One line typed into the console, without its line ending; None when
    input ends or Ctrl-C is pressed."""
    buf = bytearray()
    while True:
        if not _fd0_ready(0.25):
            continue
        b = _fd0_read(1)
        if b is None:
            time.sleep(0.01)
            continue
        if not b or b in (b"\x03", b"\x04"):
            return None
        if b in (b"\n", b"\r"):
            if b == b"\r" and _fd0_ready(0.01):
                nx = _fd0_read(1)
                if nx and nx != b"\n":
                    _unread(nx)
            return buf.decode("utf-8", errors="replace")
        buf += b


class _Fd0Reader(io.TextIOBase):
    """sys.stdin while `python file.py` runs: the keys typed into the
    console, read from fd 0 without reading ahead, so nothing is left over for
    the next command. ⌃C raises KeyboardInterrupt; the end of input reads as
    "", as it does at a terminal."""

    def __init__(self) -> None:
        super().__init__()
        import codecs
        self._decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self._buf = ""
        self._eof = False

    @property
    def encoding(self):
        return "utf-8"

    @property
    def errors(self):
        return "replace"

    def readable(self) -> bool:
        return True

    def isatty(self) -> bool:
        return False

    def fileno(self) -> int:
        return 0

    def _more(self) -> bool:
        """Wait for the next piece of input; False once input has ended."""
        while not self._eof:
            if not _fd0_ready(0.1):
                continue
            data = _fd0_read(4096)
            if data is None:
                time.sleep(0.01)
                continue
            if b"\x03" in data:
                raise KeyboardInterrupt
            end = data.find(b"\x04")
            if not data or end >= 0:
                data = data[:end] if end >= 0 else b""
                self._eof = True
                self._buf += self._decoder.decode(data, final=True)
                return bool(data)
            self._buf += self._decoder.decode(data)
            return True
        return False

    def readline(self, size=-1) -> str:
        size = -1 if size is None else size
        while "\n" not in self._buf and (size < 0 or len(self._buf) < size):
            if not self._more():
                break
        cut = self._buf.index("\n") + 1 if "\n" in self._buf else len(self._buf)
        if size >= 0:
            cut = min(cut, size)
        line, self._buf = self._buf[:cut], self._buf[cut:]
        return line

    def read(self, size=-1) -> str:
        size = -1 if size is None else size
        while (size < 0 or len(self._buf) < size) and self._more():
            pass
        if size < 0:
            out, self._buf = self._buf, ""
        else:
            out, self._buf = self._buf[:size], self._buf[size:]
        return out


# ── Keys, in raw mode ─────────────────────────────────────────────

_ESC_FOLLOW = 0.05   # a lone ESC is the Escape key if nothing follows this fast


def _read_escape() -> str:
    """The rest of a key that began with ESC, read to its final byte — so
    ESC [ 5 ~ is 'pageup', not 'esc[5' followed by a stray '~'."""
    if not _fd0_ready(_ESC_FOLLOW):
        return "esc"
    nx = _fd0_read(1)
    if not nx:
        return "esc"
    if nx == b"[":
        seq = b""
        # Parameter and intermediate bytes (0x20-0x3F), then one final byte
        # (0x40-0x7E). Bounded so a malformed stream can't hold the key.
        while len(seq) < 32:
            if not _fd0_ready(_ESC_FOLLOW):
                break
            ch = _fd0_read(1)
            if not ch:
                break
            seq += ch
            if 0x40 <= ch[0] <= 0x7E:
                break
        text = seq.decode("ascii", errors="ignore")
        if not seq or not (0x40 <= seq[-1] <= 0x7E):
            return "esc[" + text
        final = chr(seq[-1])
        arrows = {"A": "up", "B": "down", "C": "right", "D": "left",
                  "H": "home", "F": "end"}
        if final in arrows:          # also ESC [ 1 ; 5 A and friends
            return arrows[final]
        if final == "~":
            code = text[:-1].split(";")[0]
            named = {"1": "home", "7": "home", "4": "end", "8": "end",
                     "2": "insert", "3": "delete", "5": "pageup", "6": "pagedown"}
            if code in named:
                return named[code]
        return "esc[" + text
    if nx == b"O":
        if not _fd0_ready(_ESC_FOLLOW):
            return "esc"
        tail = _fd0_read(1) or b""
        return {b"A": "up", b"B": "down", b"C": "right", b"D": "left",
                b"H": "home", b"F": "end"}.get(tail, "esc")
    _unread(nx)
    return "esc"


def _tui_read_key(timeout: float = 0.25) -> Optional[str]:
    """Read one keypress in raw mode and name it: 'up' 'down' 'left'
    'right' 'home' 'end' 'pageup' 'pagedown' 'delete' 'enter' 'esc'
    'backspace' 'tab' 'ctrl-c' 'ctrl-d' …, or the character for a printable
    key. "" at the end of input; None if `timeout` passes first."""
    if not _fd0_ready(timeout):
        return None
    b = _fd0_read(1)
    if b is None:
        return None
    if not b:
        return ""
    c = b[0]
    if c == 0x1B:
        return _read_escape()
    if c == 0x0D or c == 0x0A:
        return "enter"
    if c == 0x7F or c == 0x08:
        return "backspace"
    if c == 0x09:
        return "tab"
    if c == 0x03:
        return "ctrl-c"
    if c == 0x04:
        return "ctrl-d"
    if c < 0x20:
        return f"ctrl-{chr(c + 0x40).lower()}"
    # UTF-8: read continuation bytes if the lead indicates multi-byte
    if c >= 0xC0:
        extra = 1 if c < 0xE0 else (2 if c < 0xF0 else 3)
        rest = b""
        for _ in range(extra):
            if not _fd0_ready(_ESC_FOLLOW):
                break
            nx = _fd0_read(1)
            if not nx:
                break
            rest += nx
        return (bytes([c]) + rest).decode("utf-8", errors="replace")
    return chr(c)


def _tui_wait_key() -> str:
    """Block for a key ("" at the end of input), in slices Stop can reach."""
    while True:
        key = _tui_read_key(0.25)
        if key is not None:
            return key


# ---------------------------------------------------------------------------
# Formatting

def _color(path: Path) -> str:
    """Pick an ls color based on the file type/extension."""
    try:
        st = path.lstat()
    except OSError:
        return GRAY
    if _stat.S_ISDIR(st.st_mode):
        return BLU + BOLD
    if _stat.S_ISLNK(st.st_mode):
        return CYN
    if path.suffix in {".py", ".pyi"}:
        return YLW
    if path.suffix in {".md", ".txt", ".rst"}:
        return WHT
    if path.suffix in {".png", ".jpg", ".jpeg", ".gif", ".svg", ".mp4"}:
        return MAG
    if path.suffix in {".json", ".yaml", ".yml", ".toml"}:
        return CYN
    if st.st_mode & 0o111:  # executable
        return GRN + BOLD
    return ""


def _fmt_size(n: int) -> str:
    for unit in ("B", "K", "M", "G", "T"):
        if n < 1024:
            return f"{n:>5.0f}{unit}" if unit == "B" else f"{n:>5.1f}{unit}"
        n /= 1024
    return f"{n:.1f}P"


def _human_bytes(n: float) -> str:
    """Compact human size — the `du`/`df`/`top` formatter."""
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(n) < 1024.0:
            return f"{n:.1f}{unit}"
        n /= 1024.0
    return f"{n:.1f}PiB"


def _bytes_or_dash(n: Optional[float]) -> str:
    return _DASH if n is None else _human_bytes(n)


def _bar(frac: float, width: int, fill_ch: str = "|", empty_ch: str = " ") -> str:
    frac = max(0.0, min(1.0, frac))
    filled = int(round(width * frac))
    return fill_ch * filled + empty_ch * (width - filled)


def _bar_colored(frac: float, width: int) -> str:
    """ANSI-colored bar — green under 60%, yellow 60-80%, red over 80%."""
    frac = max(0.0, min(1.0, frac))
    color = GRN if frac < 0.6 else (YLW if frac < 0.8 else RED)
    filled = int(round(width * frac))
    return f"{color}{'|' * filled}{RESET}{DIM}{'·' * (width - filled)}{RESET}"


# ---------------------------------------------------------------------------
# System probes for top and ps
#
# Public Mach and sysctl calls through ctypes, which iOS and macOS answer the
# same way. libSystem is opened by path: ctypes.util.find_library would start
# a process to look for it. Every probe returns None when it can't answer.

_libsys = None
_libsys_tried = False
_host_port: Optional[int] = None
_page_size_cache: Optional[int] = None
_ctypes_types: Dict[str, type] = {}


def _libsystem():
    global _libsys, _libsys_tried
    if _libsys_tried:
        return _libsys
    _libsys_tried = True
    try:
        import ctypes
        from ctypes import POINTER, c_char_p, c_int, c_size_t, c_uint, c_void_p
        lib = None
        for name in ("/usr/lib/libSystem.B.dylib", "/usr/lib/libSystem.dylib", None):
            try:
                candidate = ctypes.CDLL(name)
                candidate.sysctlbyname
            except (OSError, AttributeError):
                continue
            lib = candidate
            break
        if lib is None:
            return None
        signatures = {
            "sysctlbyname": (c_int, [c_char_p, c_void_p, POINTER(c_size_t), c_void_p, c_size_t]),
            "sysctl": (c_int, [POINTER(c_int), c_uint, c_void_p, POINTER(c_size_t), c_void_p, c_size_t]),
            "mach_host_self": (c_uint, []),
            "host_page_size": (c_int, [c_uint, POINTER(c_size_t)]),
            "host_processor_info": (c_int, [c_uint, c_int, POINTER(c_uint),
                                            POINTER(POINTER(c_uint)), POINTER(c_uint)]),
            "host_statistics64": (c_int, [c_uint, c_int, c_void_p, POINTER(c_uint)]),
            "task_info": (c_int, [c_uint, c_int, c_void_p, POINTER(c_uint)]),
            "task_threads": (c_int, [c_uint, POINTER(POINTER(c_uint)), POINTER(c_uint)]),
            "vm_deallocate": (c_int, [c_uint, c_size_t, c_size_t]),
            "mach_port_deallocate": (c_int, [c_uint, c_uint]),
        }
        for fname, (restype, argtypes) in signatures.items():
            try:
                fn = getattr(lib, fname)
            except AttributeError:
                continue
            fn.restype = restype
            fn.argtypes = argtypes
        _libsys = lib
    except Exception:
        _libsys = None
    return _libsys


def _mach_host() -> Optional[int]:
    """This host's port. Taken once: every mach_host_self() call adds a
    reference to the port, so asking per frame would pile them up."""
    global _host_port
    lib = _libsystem()
    if lib is None:
        return None
    if _host_port is None:
        try:
            _host_port = int(lib.mach_host_self())
        except Exception:
            return None
    return _host_port or None


def _mach_task() -> Optional[int]:
    lib = _libsystem()
    if lib is None:
        return None
    import ctypes
    try:
        return int(ctypes.c_uint.in_dll(lib, "mach_task_self_").value)
    except (ValueError, AttributeError):
        pass
    try:
        fn = lib.mach_task_self
        fn.restype = ctypes.c_uint
        fn.argtypes = []
        return int(fn())
    except Exception:
        return None


def _sysctl_raw(name: str) -> Optional[bytes]:
    lib = _libsystem()
    if lib is None:
        return None
    try:
        import ctypes
        key = name.encode()
        size = ctypes.c_size_t(0)
        if lib.sysctlbyname(key, None, ctypes.byref(size), None, 0) != 0 or not size.value:
            return None
        buf = ctypes.create_string_buffer(size.value)
        if lib.sysctlbyname(key, buf, ctypes.byref(size), None, 0) != 0:
            return None
        return buf.raw[:size.value]
    except Exception:
        return None


def _sysctl_int(name: str) -> Optional[int]:
    raw = _sysctl_raw(name)
    if raw is None:
        return None
    if len(raw) == 8:
        return struct.unpack("=Q", raw)[0]
    if len(raw) == 4:
        return struct.unpack("=I", raw)[0]
    return None


def _sysctl_str(name: str) -> Optional[str]:
    raw = _sysctl_raw(name)
    if not raw:
        return None
    text = raw.split(b"\0", 1)[0].decode("utf-8", errors="replace").strip()
    return text or None


def _page_size() -> Optional[int]:
    """The kernel's page size, which the VM counters are counted in."""
    global _page_size_cache
    if _page_size_cache:
        return _page_size_cache
    lib, host = _libsystem(), _mach_host()
    if lib is not None and host is not None:
        try:
            import ctypes
            size = ctypes.c_size_t(0)
            if lib.host_page_size(host, ctypes.byref(size)) == 0 and size.value > 0:
                _page_size_cache = int(size.value)
                return _page_size_cache
        except Exception:
            pass
    value = _sysctl_int("hw.pagesize")
    if not value:
        try:
            value = os.sysconf("SC_PAGE_SIZE")
        except (OSError, ValueError, AttributeError):
            value = None
    _page_size_cache = value if value and value > 0 else None
    return _page_size_cache


_PROCESSOR_CPU_LOAD_INFO = 2
_HOST_VM_INFO64 = 4
_TASK_VM_INFO = 22
_TASK_VM_INFO_REV1_COUNT = 38   # the struct through phys_footprint


def _cpu_ticks() -> Optional[List[tuple]]:
    """Per-core (user, system, idle, nice) tick counters since boot."""
    lib, host, task = _libsystem(), _mach_host(), _mach_task()
    if lib is None or host is None or task is None:
        return None
    try:
        import ctypes
        count = ctypes.c_uint(0)
        info = ctypes.POINTER(ctypes.c_uint)()
        info_count = ctypes.c_uint(0)
        kr = lib.host_processor_info(host, _PROCESSOR_CPU_LOAD_INFO, ctypes.byref(count),
                                     ctypes.byref(info), ctypes.byref(info_count))
        if kr != 0 or not info:
            return None
        try:
            ticks = [tuple(int(info[i * 4 + j]) for j in range(4))
                     for i in range(int(count.value))]
        finally:
            lib.vm_deallocate(task, ctypes.cast(info, ctypes.c_void_p).value,
                              int(info_count.value) * ctypes.sizeof(ctypes.c_uint))
        return ticks or None
    except Exception:
        return None


def _cpu_usage(prev: Optional[List[tuple]], cur: Optional[List[tuple]]):
    """(total %, [per-core %], {usr, sys, idl, ni} %) between two samples."""
    if not prev or not cur or len(prev) != len(cur):
        return None
    per_core: List[float] = []
    sums = [0, 0, 0, 0]
    for a, b in zip(prev, cur):
        d = [(y - x) & 0xFFFFFFFF for x, y in zip(a, b)]   # the counters wrap at 2^32
        t = sum(d)
        per_core.append(100.0 * (d[0] + d[1] + d[3]) / t if t else 0.0)
        for k in range(4):
            sums[k] += d[k]
    total_ticks = sum(sums)
    if not total_ticks:
        return 0.0, per_core, {"usr": 0.0, "sys": 0.0, "idl": 100.0, "ni": 0.0}
    total = 100.0 * (sums[0] + sums[1] + sums[3]) / total_ticks
    breakdown = {"usr": 100.0 * sums[0] / total_ticks, "sys": 100.0 * sums[1] / total_ticks,
                 "idl": 100.0 * sums[2] / total_ticks, "ni": 100.0 * sums[3] / total_ticks}
    return total, per_core, breakdown


def _vm_statistics64_type():
    t = _ctypes_types.get("vm_statistics64")
    if t is None:
        import ctypes
        u32, u64 = ctypes.c_uint32, ctypes.c_uint64

        class vm_statistics64(ctypes.Structure):
            # <mach/vm_statistics.h>
            _fields_ = [
                ("free_count", u32), ("active_count", u32),
                ("inactive_count", u32), ("wire_count", u32),
                ("zero_fill_count", u64), ("reactivations", u64),
                ("pageins", u64), ("pageouts", u64), ("faults", u64),
                ("cow_faults", u64), ("lookups", u64), ("hits", u64),
                ("purges", u64),
                ("purgeable_count", u32), ("speculative_count", u32),
                ("decompressions", u64), ("compressions", u64),
                ("swapins", u64), ("swapouts", u64),
                ("compressor_page_count", u32), ("throttled_count", u32),
                ("external_page_count", u32), ("internal_page_count", u32),
                ("total_uncompressed_pages_in_compressor", u64),
            ]
        t = _ctypes_types["vm_statistics64"] = vm_statistics64
    return t


def _task_vm_info_type():
    t = _ctypes_types.get("task_vm_info")
    if t is None:
        import ctypes
        u64 = ctypes.c_uint64

        class task_vm_info(ctypes.Structure):
            # <mach/task_info.h>, through rev2
            _fields_ = [("virtual_size", u64), ("region_count", ctypes.c_int32),
                        ("page_size", ctypes.c_int32), ("resident_size", u64),
                        ("resident_size_peak", u64)] + [
                (name, u64) for name in (
                    "device", "device_peak", "internal", "internal_peak",
                    "external", "external_peak", "reusable", "reusable_peak",
                    "purgeable_volatile_pmap", "purgeable_volatile_resident",
                    "purgeable_volatile_virtual", "compressed", "compressed_peak",
                    "compressed_lifetime", "phys_footprint", "min_address",
                    "max_address")]
        t = _ctypes_types["task_vm_info"] = task_vm_info
    return t


def _vm_statistics():
    lib, host = _libsystem(), _mach_host()
    if lib is None or host is None:
        return None
    try:
        import ctypes
        st = _vm_statistics64_type()()
        count = ctypes.c_uint(ctypes.sizeof(st) // 4)
        if lib.host_statistics64(host, _HOST_VM_INFO64, ctypes.byref(st), ctypes.byref(count)) != 0:
            return None
        return st
    except Exception:
        return None


def _memory(vm) -> Optional[tuple]:
    """(used, total, percent) the way psutil reports Darwin memory:
    available = inactive + free, used = active + wired."""
    total = _sysctl_int("hw.memsize")
    page = _page_size()
    if not total or vm is None or not page:
        return None
    available = (vm.inactive_count + vm.free_count) * page
    used = (vm.active_count + vm.wire_count) * page
    percent = max(0.0, min(100.0, (total - available) * 100.0 / total))
    return used, total, percent


def _swap() -> Optional[tuple]:
    """(used, total, percent) of swap from vm.swapusage."""
    raw = _sysctl_raw("vm.swapusage")
    if not raw or len(raw) < 24:
        return None
    total, _avail, used = struct.unpack_from("=QQQ", raw, 0)
    return used, total, (used * 100.0 / total if total else 0.0)


def _compressed(vm) -> Optional[tuple]:
    """(bytes the compressor holds, what they stand in for uncompressed)."""
    page = _page_size()
    if vm is None or not page:
        return None
    return (int(vm.compressor_page_count) * page,
            int(vm.total_uncompressed_pages_in_compressor) * page)


def _task_memory() -> Optional[tuple]:
    """(resident size, physical footprint) of this process; the footprint
    is None on a kernel too old to report it."""
    lib, task = _libsystem(), _mach_task()
    if lib is None or task is None:
        return None
    try:
        import ctypes
        info = _task_vm_info_type()()
        count = ctypes.c_uint(ctypes.sizeof(info) // 4)
        if lib.task_info(task, _TASK_VM_INFO, ctypes.byref(info), ctypes.byref(count)) != 0:
            return None
        footprint = int(info.phys_footprint) if count.value >= _TASK_VM_INFO_REV1_COUNT else None
        return int(info.resident_size), footprint
    except Exception:
        return None


def _thread_count() -> Optional[int]:
    lib, task = _libsystem(), _mach_task()
    if lib is None or task is None:
        return None
    try:
        import ctypes
        threads = ctypes.POINTER(ctypes.c_uint)()
        count = ctypes.c_uint(0)
        if lib.task_threads(task, ctypes.byref(threads), ctypes.byref(count)) != 0:
            return None
        n = int(count.value)
        try:
            # Each entry is a send right to a thread; give them back, then
            # the array that held them.
            for i in range(n):
                lib.mach_port_deallocate(task, threads[i])
        finally:
            if threads:
                lib.vm_deallocate(task, ctypes.cast(threads, ctypes.c_void_p).value,
                                  n * ctypes.sizeof(ctypes.c_uint))
        return n
    except Exception:
        return None


def _boot_time() -> Optional[float]:
    raw = _sysctl_raw("kern.boottime")
    if not raw or len(raw) < 12:
        return None
    sec, usec = struct.unpack_from("=qi", raw, 0)
    return sec + usec / 1e6 if sec > 0 else None


def _kinfo_proc() -> Optional[bytes]:
    """This process's struct kinfo_proc, from sysctl KERN_PROC_PID."""
    lib = _libsystem()
    if lib is None:
        return None
    try:
        import ctypes
        mib = (ctypes.c_int * 4)(1, 14, 1, os.getpid())   # CTL_KERN, KERN_PROC, KERN_PROC_PID
        size = ctypes.c_size_t(0)
        if lib.sysctl(mib, 4, None, ctypes.byref(size), None, 0) != 0 or size.value < 16:
            return None
        buf = ctypes.create_string_buffer(size.value)
        if lib.sysctl(mib, 4, buf, ctypes.byref(size), None, 0) != 0 or size.value < 16:
            return None
        return buf.raw[:size.value]
    except Exception:
        return None


def _process_start() -> Optional[float]:
    info = _kinfo_proc()
    if not info:
        return None
    sec, usec = struct.unpack_from("=qi", info, 0)   # kp_proc.p_starttime
    return sec + usec / 1e6 if sec > 0 else None


def _proc_cpu_seconds() -> Optional[float]:
    try:
        import resource
        usage = resource.getrusage(resource.RUSAGE_SELF)
        return usage.ru_utime + usage.ru_stime
    except Exception:
        return None


def _loadavg() -> Optional[tuple]:
    try:
        return os.getloadavg()
    except (OSError, AttributeError):
        return None


def _open_fd_count() -> Optional[int]:
    try:
        return max(0, len(os.listdir("/dev/fd")) - 1)   # less the listing's own
    except OSError:
        return None


def _disk_usage(path: str) -> Optional[tuple]:
    """(used, total, percent) for the volume holding `path`; percent of the
    space a user can have, as df and psutil count it."""
    try:
        usage = shutil.disk_usage(path)
    except (OSError, ValueError):
        return None
    denominator = usage.used + usage.free
    return usage.used, usage.total, (usage.used * 100.0 / denominator if denominator else 0.0)


def _process_command() -> str:
    try:
        argv = [a for a in getattr(sys, "orig_argv", []) if a]
        if argv:
            return " ".join(argv)
    except Exception:
        pass
    return sys.executable or "?"


# Apple model identifier → human-readable product + chip. iOS's
# `platform.machine()` returns the identifier (e.g. "iPad15,4") — we
# map it so users see "iPad Air 11-inch (M2)" instead of a raw code.
_APPLE_DEVICE_TABLE = {
    # iPad Air
    "iPad13,1":  ("iPad Air 10.9-inch (4th gen)",    "Apple A14 Bionic"),
    "iPad13,2":  ("iPad Air 10.9-inch (4th gen)",    "Apple A14 Bionic"),
    "iPad13,16": ("iPad Air 10.9-inch (5th gen)",    "Apple M1"),
    "iPad13,17": ("iPad Air 10.9-inch (5th gen)",    "Apple M1"),
    "iPad14,8":  ("iPad Air 11-inch (M2)",           "Apple M2"),
    "iPad14,9":  ("iPad Air 11-inch (M2)",           "Apple M2"),
    "iPad14,10": ("iPad Air 13-inch (M2)",           "Apple M2"),
    "iPad14,11": ("iPad Air 13-inch (M2)",           "Apple M2"),
    "iPad15,3":  ("iPad Air 11-inch (M3)",           "Apple M3"),
    "iPad15,4":  ("iPad Air 11-inch (M3)",           "Apple M3"),
    "iPad15,5":  ("iPad Air 13-inch (M3)",           "Apple M3"),
    "iPad15,6":  ("iPad Air 13-inch (M3)",           "Apple M3"),
    # iPad Pro
    "iPad8,1":   ("iPad Pro 11-inch (1st gen)",      "Apple A12X Bionic"),
    "iPad8,2":   ("iPad Pro 11-inch (1st gen)",      "Apple A12X Bionic"),
    "iPad8,3":   ("iPad Pro 11-inch (1st gen)",      "Apple A12X Bionic"),
    "iPad8,4":   ("iPad Pro 11-inch (1st gen)",      "Apple A12X Bionic"),
    "iPad8,5":   ("iPad Pro 12.9-inch (3rd gen)",    "Apple A12X Bionic"),
    "iPad8,6":   ("iPad Pro 12.9-inch (3rd gen)",    "Apple A12X Bionic"),
    "iPad8,7":   ("iPad Pro 12.9-inch (3rd gen)",    "Apple A12X Bionic"),
    "iPad8,8":   ("iPad Pro 12.9-inch (3rd gen)",    "Apple A12X Bionic"),
    "iPad8,9":   ("iPad Pro 11-inch (2nd gen)",      "Apple A12Z Bionic"),
    "iPad8,10":  ("iPad Pro 11-inch (2nd gen)",      "Apple A12Z Bionic"),
    "iPad8,11":  ("iPad Pro 12.9-inch (4th gen)",    "Apple A12Z Bionic"),
    "iPad8,12":  ("iPad Pro 12.9-inch (4th gen)",    "Apple A12Z Bionic"),
    "iPad13,4":  ("iPad Pro 11-inch (M1)",           "Apple M1"),
    "iPad13,5":  ("iPad Pro 11-inch (M1)",           "Apple M1"),
    "iPad13,6":  ("iPad Pro 11-inch (M1)",           "Apple M1"),
    "iPad13,7":  ("iPad Pro 11-inch (M1)",           "Apple M1"),
    "iPad13,8":  ("iPad Pro 12.9-inch (M1)",         "Apple M1"),
    "iPad13,9":  ("iPad Pro 12.9-inch (M1)",         "Apple M1"),
    "iPad13,10": ("iPad Pro 12.9-inch (M1)",         "Apple M1"),
    "iPad13,11": ("iPad Pro 12.9-inch (M1)",         "Apple M1"),
    "iPad14,3":  ("iPad Pro 11-inch (M2)",           "Apple M2"),
    "iPad14,4":  ("iPad Pro 11-inch (M2)",           "Apple M2"),
    "iPad14,5":  ("iPad Pro 12.9-inch (M2)",         "Apple M2"),
    "iPad14,6":  ("iPad Pro 12.9-inch (M2)",         "Apple M2"),
    "iPad16,3":  ("iPad Pro 11-inch (M4)",           "Apple M4"),
    "iPad16,4":  ("iPad Pro 11-inch (M4)",           "Apple M4"),
    "iPad16,5":  ("iPad Pro 13-inch (M4)",           "Apple M4"),
    "iPad16,6":  ("iPad Pro 13-inch (M4)",           "Apple M4"),
    # iPhone (recent)
    "iPhone14,7": ("iPhone 14",                      "Apple A15 Bionic"),
    "iPhone14,8": ("iPhone 14 Plus",                 "Apple A15 Bionic"),
    "iPhone15,2": ("iPhone 14 Pro",                  "Apple A16 Bionic"),
    "iPhone15,3": ("iPhone 14 Pro Max",              "Apple A16 Bionic"),
    "iPhone15,4": ("iPhone 15",                      "Apple A16 Bionic"),
    "iPhone15,5": ("iPhone 15 Plus",                 "Apple A16 Bionic"),
    "iPhone16,1": ("iPhone 15 Pro",                  "Apple A17 Pro"),
    "iPhone16,2": ("iPhone 15 Pro Max",              "Apple A17 Pro"),
    "iPhone17,1": ("iPhone 16 Pro",                  "Apple A18 Pro"),
    "iPhone17,2": ("iPhone 16 Pro Max",              "Apple A18 Pro"),
    "iPhone17,3": ("iPhone 16",                      "Apple A18"),
    "iPhone17,4": ("iPhone 16 Plus",                 "Apple A18"),
    # Simulator
    "arm64":     ("iOS Simulator",                   "Host Apple Silicon"),
    "x86_64":    ("iOS Simulator",                   "Host Intel"),
}


def _apple_device_info() -> tuple:
    """(product name, chip name) for this device. Falls back to the raw
    identifier, and to the kernel's CPU brand string, when the table doesn't
    know the model."""
    import platform
    ident = ""
    try:
        ident = platform.machine() or ""
    except Exception:
        pass
    if sys.platform == "darwin":
        # A Mac — the table's "arm64" entry means the iOS Simulator.
        return (_sysctl_str("hw.model") or ident or "unknown device",
                _sysctl_str("machdep.cpu.brand_string") or "unknown chip")
    entry = _APPLE_DEVICE_TABLE.get(ident)
    if entry:
        return entry
    chip = _sysctl_str("machdep.cpu.brand_string")
    if ident.startswith("iPad"):
        return (f"iPad (model {ident})", chip or "Apple silicon (unrecognized)")
    if ident.startswith("iPhone"):
        return (f"iPhone (model {ident})", chip or "Apple silicon (unrecognized)")
    return (ident or "unknown device", chip or "unknown chip")


# ---------------------------------------------------------------------------
# Shell state and dispatch

BUILTINS: Dict[str, Callable] = {}

# Builtins whose --help is their own rather than their docstring.
_FORWARD_HELP = {"python", "python3"}

# Tokens that ANY builtin should treat as a request for help. Includes
# common typos / abbreviations users reach for on a phone keyboard where
# exact flag spelling is easy to fat-finger: --h (shortened --help),
# -help (the Java-ish single-dash form), -H, and a bare `help`.
_HELP_TOKENS = {"--help", "-h", "--h", "-H", "-help", "help", "-?", "/?"}

_START_TIME = time.time()


def builtin(name: str):
    def deco(fn):
        BUILTINS[name] = fn
        return fn
    return deco


def _is_help_tok(s: str) -> bool:
    return s in _HELP_TOKENS


def _status(rc) -> int:
    if rc is None:
        return 0
    if isinstance(rc, bool):
        return int(rc)
    return rc if isinstance(rc, int) else 1


def _find_unbalanced_quote(line: str) -> Optional[int]:
    """Walk `line` tracking quote state. Return the 0-based column
    of the unbalanced quote, or None if all quotes are matched."""
    in_single = False
    in_double = False
    opener_col: Optional[int] = None
    i = 0
    n = len(line)
    while i < n:
        c = line[i]
        if c == "\\" and i + 1 < n:
            i += 2
            continue          # backslash-escaped — skip pair
        if in_single:
            if c == "'":
                in_single = False
                opener_col = None
        elif in_double:
            if c == '"':
                in_double = False
                opener_col = None
        else:
            if c == "'":
                in_single = True
                opener_col = i
            elif c == '"':
                in_double = True
                opener_col = i
        i += 1
    return opener_col


def _similar_commands(name: str) -> List[str]:
    """Close spellings among the commands — `gerp` for `grep`."""
    if not name or len(name) < 2:
        return []
    import difflib
    return difflib.get_close_matches(name, sorted(COMMANDS), n=3, cutoff=0.7)


def _resolve_command(args: List[str]):
    """(name, function, argv) for a command line given as tokens, with an
    alias expanded; None when it isn't a command."""
    if not args:
        return None
    if args[0] in ALIASES:
        args = shlex.split(ALIASES[args[0]]) + list(args[1:])
    fn = BUILTINS.get(args[0])
    return (args[0], fn, list(args[1:])) if fn else None


class _Shell:
    """What the commands share: the aliases, when the console started, the
    home directory, and a way to run a nested command line."""

    def __init__(self) -> None:
        self.aliases = ALIASES
        self.start_time = _START_TIME
        # How many command lines are running inside one another: ncdu's
        # mini-shell runs them nested. Only the outermost puts the terminal
        # back when a command fails, or a nested failure would pull ncdu off
        # its own screen while it is still running.
        self.depth = 0

    @property
    def home(self) -> str:
        return str(Path.home())

    def run_line(self, line: str) -> int:
        """Run one command line and return its exit status."""
        if not line.strip() or line.strip().startswith("#"):
            return 0

        # Alias expansion (single level, first word only)
        first, _, rest = line.lstrip().partition(" ")
        if first in self.aliases:
            line = self.aliases[first] + (" " + rest if rest else "")

        # shlex raises ValueError on unbalanced quotes. Show the line with a
        # caret under the quote that has no partner, the way SyntaxError does.
        try:
            tokens = shlex.split(line, comments=False, posix=True)
        except ValueError as e:
            head = line.lstrip().split(maxsplit=1)[0]
            col = _find_unbalanced_quote(line)
            shown = line.rstrip("\n")
            if len(shown) > 200:
                shown = shown[:200] + "…"
            print(f"  {DIM}{shown}{RESET}")
            if col is not None:
                print(f"  {RED}{' ' * col}^{RESET}")
            print(f"{RED}{head}:{RESET} unbalanced quote ({e})")
            return 2
        if not tokens:
            return 0

        name = tokens[0]
        fn = BUILTINS.get(name)
        if fn is None:
            if name in UNAVAILABLE:
                return _unavailable(name)
            print(f"{RED}{name}:{RESET} command not found")
            similar = _similar_commands(name)
            if similar:
                print(f"  {DIM}did you mean: {', '.join(similar)}?{RESET}")
            return 127

        # Universal help-flag handling. Accepts --help / -h / --h / -H /
        # -help / help / -? / /? — anything in _HELP_TOKENS.
        if len(tokens) == 2 and _is_help_tok(tokens[1]) and name not in _FORWARD_HELP:
            _print_builtin_help(name)
            return 0

        outermost = self.depth <= 0
        self.depth += 1
        try:
            return _status(fn(self, tokens[1:]))
        except SystemExit as se:
            code = se.code
            if isinstance(code, int) and code != 0:
                print(f"{YLW}{name} exited with code {code}{RESET}")
                return code
            if isinstance(code, str) and code:
                print(f"{YLW}{name} exited:{RESET} {code}")
                return 1
            return 0
        except KeyboardInterrupt:
            # Put the terminal back first, so ^C lands on the main screen.
            if outermost:
                _restore_screen()
            print(f"\n{YLW}^C{RESET}")
            return 130
        except Exception as e:
            if outermost:
                _restore_screen()
            print(f"{RED}{type(e).__name__}:{RESET} {e}")
            traceback.print_exc()
            return 1
        finally:
            self.depth = max(0, self.depth - 1)


def _print_builtin_help(name: str) -> None:
    """Pretty-print a builtin's docstring. Called by run_line when the
    user types `<cmd> --help` / `<cmd> -h`."""
    fn = BUILTINS.get(name)
    if fn is None:
        print(f"{RED}help:{RESET} no such command: {name}")
        return
    doc = (fn.__doc__ or "").strip()
    print(f"{BOLD}{GRN}{name}{RESET}")
    if doc:
        for line in doc.splitlines():
            print(f"  {line}")
    else:
        print(f"  {DIM}(no documentation){RESET}")
        print(f"  {DIM}Try `help` to see the full command overview.{RESET}")


# ---------------------------------------------------------------------------
# Builtin commands

@builtin("help")
def _help(sh: _Shell, argv: List[str]):
    """help [command]  — list all commands, or print detailed docs for one."""

    # `help <name>` — detailed docs for a single builtin.
    if argv:
        name = argv[0]
        fn = BUILTINS.get(name)
        if fn is None:
            # Accept aliases too (they're expanded in run_line before
            # BUILTINS lookup, but explicit `help cls` should still work).
            alias_target = sh.aliases.get(name, "").split(" ", 1)[0]
            fn = BUILTINS.get(alias_target) if alias_target else None
            if fn is None:
                if name in UNAVAILABLE:
                    return _unavailable(name)
                print(f"{RED}help:{RESET} no such command: {name}")
                print(f"{DIM}  try `help` with no args for the full list{RESET}")
                return 1
            print(f"{DIM}({name} is an alias for {alias_target}){RESET}\n")
        doc = (fn.__doc__ or "").strip()
        if not doc:
            doc = f"{name}  — no documentation available."
        print(f"{BOLD}{GRN}{name}{RESET}")
        for line in doc.splitlines():
            print(f"  {line}")
        return 0

    # ── Full overview ─────────────────────────────────────────────

    # Group builtins by category for a nicer overview.
    categories = [
        ("Filesystem",
         ["ls", "ll", "la", "cat", "head", "tail", "less", "more", "pwd", "cd",
          "mkdir", "rmdir", "rm", "touch", "cp", "mv", "mktemp", "find", "tree",
          "grep", "stat", "file", "wc", "diff", "xxd", "hexdump", "basename",
          "dirname", "realpath", "which"]),
        ("Text",
         ["echo", "tee", "sort", "uniq", "tr", "cut", "nl", "tac", "rev", "seq",
          "yes", "bc", "cal", "base64", "sha256sum", "sha1sum", "md5sum"]),
        ("Archives",
         ["zip", "unzip", "tar", "gzip", "gunzip", "extract"]),
        ("Disk usage",
         ["du", "df", "ncdu"]),
        ("System monitor",
         ["top", "htop", "ps", "kill", "watch", "uptime", "uname", "whoami",
          "hostname", "id", "nproc"]),
        ("Terminal",
         ["clear", "cls", "date", "sleep", "time", "env", "export", "history",
          "man", "help"]),
        ("Python",
         ["python", "python3", "py"]),
        ("Session",
         ["exit", "quit"]),
    ]

    print(f"{BOLD}Blender Local shell{RESET} — "
          f"{DIM}type `help <command>` for details on a specific command{RESET}\n")

    col_w = 16
    per_row = 4
    for cat_name, cmds in categories:
        avail = [c for c in cmds if c in BUILTINS]
        if not avail:
            continue
        print(f"{BOLD}{CYN}{cat_name}{RESET}")
        # Print commands in rows of 4, aligned.
        for i in range(0, len(avail), per_row):
            chunk = avail[i:i + per_row]
            print("  " + "".join(f"{GRN}{c:<{col_w}}{RESET}" for c in chunk))
        print()

    # Mention builtins we haven't categorized above so `help` stays honest
    # as commands get added.
    known = {c for _, cs in categories for c in cs}
    rest = [c for c in sorted(BUILTINS) if c not in known]
    if rest:
        print(f"{BOLD}{CYN}Other{RESET}")
        for i in range(0, len(rest), per_row):
            chunk = rest[i:i + per_row]
            print("  " + "".join(f"{GRN}{c:<{col_w}}{RESET}" for c in chunk))
        print()

    print(f"{BOLD}Python{RESET}")
    print("  Anything that isn't a command runs as Python in this console. Examples:\n")
    print(f"    {CYN}2 + 2{RESET}                  → evaluate Python expression")
    print(f"    {CYN}bpy.data.objects[:]{RESET}    → look at the scene")
    print(f"    {CYN}for i in range(3): print(i){RESET} → Python statement")
    print()
    print(f"{BOLD}Aliases{RESET}")
    if sh.aliases:
        for a, t in sorted(sh.aliases.items()):
            print(f"  {CYN}{a:<8}{RESET} → {t}")
    print()
    print(f"{DIM}Line editing: ↑/↓ history, ←/→ cursor, Ctrl-A/E home/end,{RESET}")
    print(f"{DIM}              Ctrl-U/K/W delete, Ctrl-C cancel, Ctrl-L clear.{RESET}")
    return 0


@builtin("man")
def _man(sh: _Shell, argv: List[str]):
    """man <command>  — abbreviated help for a single command."""
    if not argv:
        print("usage: man <command>")
        return 1
    name = argv[0]
    fn = BUILTINS.get(name)
    if fn is None:
        print(f"{RED}man:{RESET} no entry for {name}")
        return 1
    doc = (fn.__doc__ or "").strip() or "(no documentation)"
    print(f"{BOLD}{name}{RESET}")
    for line in doc.splitlines():
        print(f"  {line}")
    return 0


@builtin("pwd")
def _pwd(sh: _Shell, argv: List[str]):
    """pwd  — print the current working directory (absolute path)."""
    try:
        print(os.getcwd())
    except OSError as e:
        print(f"{RED}pwd:{RESET} {e.strerror or e}")
        return 1
    return 0


@builtin("cd")
def _cd(sh: _Shell, argv: List[str]):
    """cd [path]  — change the current working directory.

    Special targets:
        cd         → go to $HOME (~)
        cd ~       → same
        cd -       → go to the previous directory ($OLDPWD)
        cd /tmp    → redirected to the app's writable tmp dir

    iOS sandbox: you can only cd into paths under $HOME, the app's own
    container. Attempting to leave it prints a friendly one-liner
    instead of the kernel's raw EPERM."""
    import tempfile

    if not argv or argv[0] == "~":
        target = sh.home
    elif argv[0] == "-":
        target = os.environ.get("OLDPWD", sh.home)
    else:
        target = os.path.expanduser(os.path.expandvars(argv[0]))
        # iOS: /tmp → per-app writable tmp dir.
        if target in ("/tmp", "/private/tmp", "/private/var/tmp"):
            target = tempfile.gettempdir()
    shown = argv[0] if argv else target

    # Resolve to an absolute, normalized path so downstream checks and
    # error messages show a real path (not "..").
    try:
        current = os.getcwd()
    except OSError:
        current = sh.home
    abs_target = os.path.normpath(
        target if os.path.isabs(target) else os.path.join(current, target))

    # The sandbox is $HOME. Refuse anything outside it with a friendly
    # one-liner instead of firing a raw EPERM from the kernel.
    try:
        root = os.path.realpath(sh.home)
    except OSError:
        root = sh.home
    real = os.path.realpath(abs_target)
    in_sandbox = real == root or real.startswith(root.rstrip(os.sep) + os.sep)
    if not in_sandbox:
        try:
            exists = os.path.exists(abs_target)
        except OSError:
            exists = False
        if not exists:
            print(f"{RED}cd:{RESET} no such directory: {shown}")
        else:
            print(f"{RED}cd:{RESET} can't leave the app sandbox")
            print(f"{DIM}    (try `cd ~` or `cd ~/Documents`){RESET}")
        return 1

    prev = current
    try:
        os.chdir(abs_target)
        # Verify we can actually READ the new cwd. On iOS you can
        # sometimes chdir into a directory (the kernel permits the
        # syscall) but then getcwd() fails because the resolver can't
        # walk the parent chain. If that happens, chdir back.
        try:
            os.getcwd()
        except OSError:
            try:
                os.chdir(prev)
            except OSError:
                try:
                    os.chdir(sh.home)
                except OSError:
                    pass
            print(f"{RED}cd:{RESET} can't read that directory (iOS sandbox)")
            return 1
        os.environ["OLDPWD"] = prev
        os.environ["PWD"] = os.getcwd()
    except FileNotFoundError:
        print(f"{RED}cd:{RESET} no such directory: {shown}")
        return 1
    except NotADirectoryError:
        print(f"{RED}cd:{RESET} not a directory: {shown}")
        return 1
    except PermissionError:
        print(f"{RED}cd:{RESET} permission denied: {shown}")
        return 1
    except OSError as e:
        print(f"{RED}cd:{RESET} {e.strerror or e}: {shown}")
        return 1
    return 0


def _list_entries(path: Path, show_hidden: bool) -> Optional[List[Path]]:
    try:
        entries = list(path.iterdir())
    except OSError as e:
        print(f"{RED}ls:{RESET} {e.strerror}: {path}")
        return None
    if not show_hidden:
        entries = [e for e in entries if not e.name.startswith(".")]
    entries.sort(key=lambda p: (not p.is_dir(), p.name.lower()))
    return entries


@builtin("ls")
def _ls(sh: _Shell, argv: List[str]):
    """ls [-l] [-a] [-h] [path…]  — list directory contents.

    Flags:
        -l    long form: permissions, size, mtime, name
        -a    include hidden (dotfile) entries
        -h    human-readable sizes (only meaningful with -l)

    Aliases:  ll = ls -lah    la = ls -a

    Directory names are shown in blue with a trailing /, regular files
    in the default color, executables are highlighted green."""
    long = "l" in "".join(a for a in argv if a.startswith("-") and not a.startswith("--"))
    show_hidden = "a" in "".join(a for a in argv if a.startswith("-"))
    human = "h" in "".join(a for a in argv if a.startswith("-"))
    paths = [a for a in argv if not a.startswith("-")] or ["."]
    rc = 0
    for idx, p in enumerate(paths):
        base = Path(os.path.expanduser(p))
        if not base.exists():
            print(f"{RED}ls:{RESET} no such path: {p}")
            rc = 1
            continue
        if base.is_file():
            _print_one(base, long=long, human=human)
            continue
        if len(paths) > 1:
            if idx:
                print()
            print(f"{BOLD}{base}:{RESET}")
        entries = _list_entries(base, show_hidden)
        if entries is None:
            rc = 1
            continue
        for entry in entries:
            _print_one(entry, long=long, human=human)
    return rc


def _dir_content_size(path: str, _cap: int = 100_000) -> int:
    """Recursive total of a directory's file sizes (apparent size, like `du`).
    Plain `ls -l` prints a directory's *own* entry size (~64–400 B), which is
    misleading — a Documents/ folder full of files still reads a few hundred
    bytes. We sum the tree instead. Bounded by `_cap` entries so listing a huge
    tree can't hang the terminal; past the cap we return the partial sum."""
    total = 0
    seen = 0
    stack = [path]
    while stack:
        d = stack.pop()
        try:
            with os.scandir(d) as it:
                for e in it:
                    seen += 1
                    if seen > _cap:
                        return total
                    try:
                        if e.is_dir(follow_symlinks=False):
                            stack.append(e.path)
                        else:
                            total += e.stat(follow_symlinks=False).st_size
                    except OSError:
                        continue
        except OSError:
            continue
    return total


def _print_one(p: Path, *, long: bool, human: bool) -> None:
    color = _color(p)
    name = p.name + ("/" if p.is_dir() else "")
    if not long:
        print(f"{color}{name}{RESET}")
        return
    try:
        st = p.lstat()
    except OSError:
        print(f"{color}{name}{RESET}")
        return
    perms = _stat.filemode(st.st_mode)
    # Directories show their recursive content size (not the tiny, misleading
    # directory-entry size); files/symlinks show their own size.
    size_ = _dir_content_size(str(p)) if (p.is_dir() and not p.is_symlink()) else st.st_size
    size = _fmt_size(size_) if human else f"{size_:>8d}"
    mtime = time.strftime("%b %d %H:%M", time.localtime(st.st_mtime))
    print(f"{GRAY}{perms}{RESET}  {size}  {GRAY}{mtime}{RESET}  {color}{name}{RESET}")


@builtin("cat")
def _cat(sh: _Shell, argv: List[str]):
    """cat [file…]  — print files to the terminal.

    Concatenates one or more UTF-8 text files and prints them. With no
    file, or `-`, it copies what you type until the end of input (⌃D),
    the way cat reads a terminal."""
    rc = 0
    for arg in argv or ["-"]:
        if arg == "-":
            _copy_stdin_to_stdout()
            continue
        path = Path(os.path.expanduser(arg))
        try:
            data = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as e:
            print(f"{RED}cat:{RESET} {e}")
            rc = 1
            continue
        sys.stdout.write(data)
        if not data.endswith("\n"):
            sys.stdout.write("\n")
    return rc


def _parse_count(argv: List[str], cmd: str):
    """(n, files) from head/tail arguments; None after printing an error."""
    n = 10
    args: List[str] = []
    it = iter(argv)
    for a in it:
        if a == "-n":
            try:
                n = int(next(it))
            except (StopIteration, ValueError):
                print(f"{RED}{cmd}:{RESET} -n needs an integer")
                return None
        elif a.startswith("-") and a[1:].isdigit():
            n = int(a[1:])
        else:
            args.append(a)
    if not args:
        print(f"{RED}{cmd}:{RESET} usage: {cmd} [-n N] <file>")
        return None
    return n, args


@builtin("head")
def _head(sh: _Shell, argv: List[str]):
    """head [-n N] <file…>  — print the first N lines (default 10)."""
    parsed = _parse_count(argv, "head")
    if parsed is None:
        return 1
    n, args = parsed
    rc = 0
    for p in args:
        try:
            with open(os.path.expanduser(p), encoding="utf-8", errors="replace") as f:
                for i, line in enumerate(f):
                    if i >= n:
                        break
                    sys.stdout.write(line)
        except OSError as e:
            print(f"{RED}head:{RESET} {e}")
            rc = 1
    return rc


@builtin("tail")
def _tail(sh: _Shell, argv: List[str]):
    """tail [-n N] <file…>  — print the last N lines (default 10)."""
    from collections import deque
    parsed = _parse_count(argv, "tail")
    if parsed is None:
        return 1
    n, args = parsed
    rc = 0
    for p in args:
        try:
            with open(os.path.expanduser(p), encoding="utf-8", errors="replace") as f:
                # Keeps N lines rather than the whole file.
                lines = deque(f, maxlen=n) if n > 0 else ()
                sys.stdout.write("".join(lines))
        except OSError as e:
            print(f"{RED}tail:{RESET} {e}")
            rc = 1
    return rc


@builtin("mkdir")
def _mkdir(sh: _Shell, argv: List[str]):
    """mkdir [-p] <dir…>  — create directories.

    Flags:
        -p    create intermediate directories as needed (no error if
              the leaf already exists)."""
    recursive = "-p" in argv
    rc = 0
    for a in (a for a in argv if not a.startswith("-")):
        try:
            Path(os.path.expanduser(a)).mkdir(parents=recursive, exist_ok=recursive)
        except OSError as e:
            print(f"{RED}mkdir:{RESET} {e}")
            rc = 1
    return rc


def _is_protected(path: Path) -> bool:
    """The filesystem root and the app's home, which rm won't delete."""
    try:
        real = os.path.realpath(path)
        return real == os.sep or real == os.path.realpath(os.path.expanduser("~"))
    except (OSError, ValueError):
        return False


@builtin("rm")
def _rm(sh: _Shell, argv: List[str]):
    """rm [-r] [-f] <path…>  — remove files (or directories with -r).

    Flags:
        -r / -R   recurse into directories
        -f        don't error on missing files
        -rf       combined (also -fr, -Rf)

    Caution: this is a permanent delete — the iOS sandbox has no
    Trash / Recycle Bin. The app's home directory itself is refused."""
    flags = "".join(a[1:] for a in argv if a.startswith("-") and not a.startswith("--"))
    recursive = "r" in flags or "R" in flags or "--recursive" in argv
    force = "f" in flags or "--force" in argv
    args = [a for a in argv if not a.startswith("-")]
    if not args:
        print(f"{RED}rm:{RESET} usage: rm [-rf] <path> …")
        return 1
    rc = 0
    for a in args:
        path = Path(os.path.expanduser(a))
        if _is_protected(path):
            print(f"{RED}rm:{RESET} refusing to remove {a}")
            rc = 1
            continue
        try:
            if path.is_dir() and not path.is_symlink():
                if not recursive:
                    print(f"{RED}rm:{RESET} {a} is a directory (use -r)")
                    rc = 1
                    continue
                shutil.rmtree(path)
            else:
                path.unlink()
        except FileNotFoundError:
            if not force:
                print(f"{RED}rm:{RESET} no such file: {a}")
                rc = 1
        except OSError as e:
            print(f"{RED}rm:{RESET} {e}")
            rc = 1
    return rc


@builtin("rmdir")
def _rmdir(sh: _Shell, argv: List[str]):
    """rmdir <dir…>  — remove empty directories.

    Fails if the directory is non-empty; use `rm -r` for that."""
    rc = 0
    for a in argv:
        try:
            os.rmdir(os.path.expanduser(a))
        except OSError as e:
            print(f"{RED}rmdir:{RESET} {e}")
            rc = 1
    return rc


@builtin("touch")
def _touch(sh: _Shell, argv: List[str]):
    """touch <file…>  — create empty files, or update mtime if they exist."""
    rc = 0
    for a in argv:
        try:
            Path(os.path.expanduser(a)).touch(exist_ok=True)
        except OSError as e:
            print(f"{RED}touch:{RESET} {e}")
            rc = 1
    return rc


@builtin("cp")
def _cp(sh: _Shell, argv: List[str]):
    """cp [-r] <src…> <dst>  — copy files or directories.

    Flags:
        -r / -R   copy directories recursively

    Copying into an existing directory puts the copy inside it, as with
    Unix cp. Preserves mtime and mode where the iOS sandbox permits."""
    flags = "".join(a[1:] for a in argv if a.startswith("-") and not a.startswith("--"))
    recursive = "r" in flags or "R" in flags or "a" in flags
    args = [a for a in argv if not a.startswith("-")]
    if len(args) < 2:
        print(f"{RED}cp:{RESET} usage: cp [-r] <src> <dst>")
        return 1
    *srcs, dst = (os.path.expanduser(a) for a in args)
    rc = 0
    for src in srcs:
        try:
            if os.path.isdir(src):
                if not recursive:
                    print(f"{RED}cp:{RESET} {src} is a directory (use -r)")
                    rc = 1
                    continue
                target = dst
                if os.path.isdir(dst):
                    target = os.path.join(dst, os.path.basename(os.path.normpath(src)))
                shutil.copytree(src, target)
            else:
                shutil.copy2(src, dst)
        except OSError as e:
            print(f"{RED}cp:{RESET} {e}")
            rc = 1
    return rc


@builtin("mv")
def _mv(sh: _Shell, argv: List[str]):
    """mv <src…> <dst>  — move or rename a file/directory.

    If `dst` is an existing directory, `src` is moved into it (same
    as Unix mv). Otherwise `src` is renamed to `dst`."""
    args = [a for a in argv if not a.startswith("-")]
    if len(args) < 2:
        print(f"{RED}mv:{RESET} usage: mv <src> <dst>")
        return 1
    *srcs, dst = (os.path.expanduser(a) for a in args)
    rc = 0
    for src in srcs:
        try:
            shutil.move(src, dst)
        except OSError as e:
            print(f"{RED}mv:{RESET} {e}")
            rc = 1
    return rc


@builtin("mktemp")
def _mktemp(sh: _Shell, argv: List[str]):
    """mktemp [-d]  — create a unique temp file (or `-d` directory).

    Prints its path. Paths live under the app's TMPDIR, which iOS
    empties when it needs the space."""
    import tempfile
    want_dir = bool(argv) and argv[0] == "-d"
    try:
        if want_dir:
            print(tempfile.mkdtemp(prefix="blenderlocal_"))
        else:
            fd, p = tempfile.mkstemp(prefix="blenderlocal_")
            os.close(fd)
            print(p)
    except OSError as e:
        print(f"{RED}mktemp:{RESET} {e}")
        return 1
    return 0


@builtin("tee")
def _tee(sh: _Shell, argv: List[str]):
    """tee [-a] FILE…  — copy what you type to the terminal AND to each FILE
    (overwrite, or append with -a). Ends at the end of input (⌃D)."""
    append = False
    args = list(argv)
    if args and args[0] == "-a":
        append = True
        args.pop(0)
    if not args:
        print(f"{RED}tee:{RESET} usage: tee [-a] FILE…")
        return 1
    data = _stdin_text()
    sys.stdout.write(data)
    mode = "a" if append else "w"
    rc = 0
    for path in args:
        try:
            with open(os.path.expanduser(path), mode, encoding="utf-8") as f:
                f.write(data)
        except OSError as e:
            print(f"\n{RED}tee:{RESET} {path}: {e}", file=sys.stderr)
            rc = 1
    return rc


@builtin("echo")
def _echo(sh: _Shell, argv: List[str]):
    """echo <args…>  — print arguments to stdout, space-separated."""
    print(" ".join(argv))
    return 0


@builtin("env")
def _env(sh: _Shell, argv: List[str]):
    """env  — print all environment variables, one per line (sorted)."""
    for k in sorted(os.environ):
        print(f"{CYN}{k}{RESET}={os.environ[k]}")
    return 0


@builtin("export")
def _export(sh: _Shell, argv: List[str]):
    """export NAME=VALUE [NAME=VALUE …]  — set environment variables.

    Only affects this session (and any Python code subsequently run
    in this interpreter). Doesn't persist across app restarts."""
    rc = 0
    for a in argv:
        if "=" not in a:
            print(f"{RED}export:{RESET} expected NAME=VALUE, got {a!r}")
            rc = 1
            continue
        k, _, v = a.partition("=")
        os.environ[k] = v
    return rc


@builtin("which")
def _which(sh: _Shell, argv: List[str]):
    """which <name…>  — locate a command or module.

    Reports whether each name is a shell builtin, an alias, or a
    loaded Python module (with the module's __file__ path)."""
    rc = 0
    for name in argv:
        if name in BUILTINS:
            print(f"{name}: shell builtin")
        elif name in sh.aliases:
            print(f"{name}: aliased to {sh.aliases[name]!r}")
        elif (mod := sys.modules.get(name)) is not None:
            src = getattr(mod, "__file__", None) or "built-in"
            print(f"{name}: Python module at {src}")
        else:
            print(f"{RED}which:{RESET} {name} not found")
            rc = 1
    return rc


@builtin("date")
def _date(sh: _Shell, argv: List[str]):
    """date  — print the current date and time in local timezone."""
    print(time.strftime("%a %b %d %H:%M:%S %Z %Y"))
    return 0


@builtin("uptime")
def _uptime(sh: _Shell, argv: List[str]):
    """uptime  — how long the console's shell has been running."""
    d = int(time.time() - sh.start_time)
    h, d = divmod(d, 3600)
    m, s = divmod(d, 60)
    print(f"shell up {h}h {m}m {s}s")
    return 0


@builtin("uname")
def _uname(sh: _Shell, argv: List[str]):
    """uname [-a]  — print system identification.

    Without flags prints the kernel name. With -a prints all
    fields (kernel, hostname, release, version, machine).
    """
    import platform
    show_all = bool(argv) and "a" in argv[0]
    sysname = platform.system()
    if not show_all:
        print(sysname)
        return 0
    node = platform.node() or "ios"
    rel = platform.release()
    ver = platform.version()
    mach = platform.machine()
    print(f"{sysname} {node} {rel} {ver} {mach}")
    return 0


@builtin("whoami")
def _whoami(sh: _Shell, argv: List[str]):
    """whoami  — print the current user (or 'mobile' on iOS)."""
    try:
        import getpass
        print(getpass.getuser())
    except Exception:
        # The iOS sandbox sometimes doesn't expose pwd.getpwuid — fall back
        # to whatever USER env says, then the iOS convention 'mobile'.
        print(os.environ.get("USER") or os.environ.get("LOGNAME") or "mobile")
    return 0


@builtin("hostname")
def _hostname(sh: _Shell, argv: List[str]):
    """hostname  — print this device's network name."""
    try:
        name = os.uname().nodename
    except (OSError, AttributeError):
        name = ""
    print(name or "localhost")
    return 0


@builtin("id")
def _id(sh: _Shell, argv: List[str]):
    """id  — print the (sandbox) user identity."""
    try:
        import getpass
        import pwd
        u = getpass.getuser()
        try:
            entry = pwd.getpwnam(u)
            print(f"uid={entry.pw_uid}({u}) gid={entry.pw_gid}")
        except KeyError:
            print(f"uid=?({u}) gid=?")
    except Exception:
        print(f"uid=?({os.environ.get('USER', 'mobile')}) gid=?")
    return 0


@builtin("nproc")
def _nproc(sh: _Shell, argv: List[str]):
    """nproc  — print the number of logical CPU cores available."""
    try:
        n = os.cpu_count() or 1
    except Exception:
        n = 1
    print(n)
    return 0


@builtin("basename")
def _basename(sh: _Shell, argv: List[str]):
    """basename PATH [SUFFIX]  — strip the directory + optional suffix."""
    if not argv:
        print(f"{RED}basename:{RESET} usage: basename PATH [SUFFIX]")
        return 1
    name = os.path.basename(argv[0])
    if len(argv) >= 2 and name.endswith(argv[1]) and name != argv[1]:
        name = name[: -len(argv[1])]
    print(name)
    return 0


@builtin("dirname")
def _dirname(sh: _Shell, argv: List[str]):
    """dirname PATH  — strip the last component, leaving the directory."""
    if not argv:
        print(f"{RED}dirname:{RESET} usage: dirname PATH")
        return 1
    print(os.path.dirname(argv[0]) or ".")
    return 0


@builtin("realpath")
def _realpath(sh: _Shell, argv: List[str]):
    """realpath PATH  — print the canonical absolute path."""
    if not argv:
        print(f"{RED}realpath:{RESET} usage: realpath PATH")
        return 1
    print(os.path.realpath(os.path.expanduser(argv[0])))
    return 0


@builtin("clear")
def _clear(sh: _Shell, argv: List[str]):
    """clear | cls  — wipe the terminal screen AND scrollback buffer.

    Sends ESC[3J ESC[2J ESC[H — same behaviour as macOS Terminal.app
    and iTerm2, which both clear scrollback on this sequence."""
    sys.stdout.write("\x1b[3J\x1b[2J\x1b[H")
    sys.stdout.flush()
    return 0


@builtin("history")
def _history(sh: _Shell, argv: List[str]):
    """history  — reminder that arrow keys walk the command history.

    The history lives in the console's line editor, which keeps it
    across launches. Use ↑/↓ at the prompt to recall previous commands."""
    print("History: press ↑ or ↓ in the terminal to recall previous commands.")
    return 0


@builtin("exit")
@builtin("quit")
def _exit(sh: _Shell, argv: List[str]):
    """exit | quit  — leaves everything as it is: the console stays open.

    The console belongs to Blender Local, not to a shell of its own, so
    there is nothing to close. Switch tabs to leave it."""
    print(f"{DIM}exit ends a shell, not the app; the console stays open.{RESET}")
    return 0


# ── Searching and inspecting files ───────────────────────────────

@builtin("grep")
def _grep(sh: _Shell, argv: List[str]):
    """grep [-i] <pattern> <file…>  — search for a regex in files.

    Flags:
        -i    case-insensitive match

    Output format: file:line_no: matching_line
    Exit status: 0 if a line matched, 1 if none did, 2 on an error."""
    if len(argv) < 2:
        print(f"{RED}grep:{RESET} usage: grep [-i] <pattern> <file> …")
        return 2
    import re
    flags = 0
    pat_args = list(argv)
    if pat_args and pat_args[0].startswith("-"):
        opt = pat_args.pop(0)
        if "i" in opt:
            flags |= re.IGNORECASE
    if len(pat_args) < 2:
        print(f"{RED}grep:{RESET} missing files")
        return 2
    try:
        pattern = re.compile(pat_args[0], flags)
    except re.error as e:
        print(f"{RED}grep:{RESET} bad pattern: {e}")
        return 2
    matched = False
    failed = False
    for path in pat_args[1:]:
        try:
            with open(os.path.expanduser(path), encoding="utf-8", errors="replace") as f:
                for i, line in enumerate(f, 1):
                    if pattern.search(line):
                        matched = True
                        if not line.endswith("\n"):
                            line += "\n"
                        sys.stdout.write(f"{BLU}{path}{RESET}:{GRN}{i}{RESET}: {line}")
        except OSError as e:
            print(f"{RED}grep:{RESET} {e}")
            failed = True
    return 2 if failed else (0 if matched else 1)


@builtin("find")
def _find(sh: _Shell, argv: List[str]):
    """find [path] [-name] <pattern>  — recursively list matching files.

    Examples:
        find .                       # everything under cwd
        find . '*.py'                # every .py file
        find src -name '*.h'         # every .h file under src/"""
    import fnmatch
    if not argv:
        root, pattern = ".", "*"
    elif len(argv) == 1:
        root, pattern = argv[0], "*"
    else:
        root = argv[0]
        if argv[1] == "-name" and len(argv) >= 3:
            pattern = argv[2]
        else:
            pattern = argv[1]
    root_path = os.path.expanduser(root)
    if not os.path.exists(root_path):
        print(f"{RED}find:{RESET} {root}: No such file or directory")
        return 1
    try:
        for base, dirs, files in os.walk(root_path):
            for name in dirs + files:
                if fnmatch.fnmatch(name, pattern):
                    print(os.path.join(base, name))
    except OSError as e:
        print(f"{RED}find:{RESET} {e}")
        return 1
    return 0


@builtin("tree")
def _tree(sh: _Shell, argv: List[str]):
    """tree [path]  — display a directory as an ASCII tree.

    Hidden entries (dotfiles) are skipped. Directories come first,
    files second, both alphabetically sorted."""
    root = Path(os.path.expanduser(argv[0])) if argv else Path(".")
    if not root.exists():
        print(f"{RED}tree:{RESET} no such path: {argv[0] if argv else root}")
        return 1

    def _walk(p: Path, prefix: str) -> None:
        try:
            entries = sorted(p.iterdir(), key=lambda x: (not x.is_dir(), x.name.lower()))
        except OSError:
            return
        entries = [e for e in entries if not e.name.startswith(".")]
        for i, entry in enumerate(entries):
            last = i == len(entries) - 1
            connector = "└── " if last else "├── "
            print(f"{prefix}{GRAY}{connector}{RESET}{_color(entry)}{entry.name}{RESET}")
            if entry.is_dir() and not entry.is_symlink():
                ext = "    " if last else "│   "
                _walk(entry, prefix + ext)

    print(f"{_color(root)}{root}{RESET}")
    _walk(root, "")
    return 0


@builtin("wc")
def _wc(sh: _Shell, argv: List[str]):
    """wc [file…]  — count lines, words, and characters.

    Output columns: lines, words, chars, filename. With no file (or `-`)
    it counts what you type until the end of input."""
    rc = 0
    for p in argv or ["-"]:
        try:
            text = _stdin_text() if p == "-" else Path(os.path.expanduser(p)).read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as e:
            print(f"{RED}wc:{RESET} {e}")
            rc = 1
            continue
        lines = text.count("\n")
        words = len(text.split())
        chars = len(text)
        print(f"  {lines:7d}  {words:7d}  {chars:7d}  {p}")
    return rc


@builtin("stat")
def _stat_cmd(sh: _Shell, argv: List[str]):
    """stat <path>  — size / mtime / permissions of a single file."""
    if not argv:
        print("usage: stat <path>")
        return 1
    rc = 0
    # NB: don't name anything `_stat` here — that's the stat MODULE.
    for p in argv:
        path = os.path.abspath(os.path.expanduser(p))
        try:
            s = os.lstat(path)
        except OSError as e:
            print(f"{RED}stat:{RESET} {e.strerror}: {p}")
            rc = 1
            continue
        mode = _stat.filemode(s.st_mode)
        mtime = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(s.st_mtime))
        kind = "dir" if _stat.S_ISDIR(s.st_mode) else "file" if _stat.S_ISREG(s.st_mode) else "other"
        print(f"{BOLD}{path}{RESET}")
        print(f"  type   : {kind}")
        print(f"  size   : {_human_bytes(s.st_size)} ({s.st_size} bytes)")
        print(f"  perms  : {mode}")
        print(f"  mtime  : {mtime}")
    return rc


@builtin("file")
def _file(sh: _Shell, argv: List[str]):
    """file PATH…  — best-effort guess of file type from contents.

    Sniffs the first 512 bytes for common magic numbers (PNG, JPEG, PDF,
    ZIP, gzip, .blend, Mach-O, …) and falls back to a UTF-8/ASCII probe."""
    if not argv:
        print(f"{RED}file:{RESET} usage: file PATH…")
        return 1
    magic_hits = [
        (b"\x89PNG\r\n\x1a\n", "PNG image"),
        (b"\xff\xd8\xff", "JPEG image"),
        (b"GIF87a", "GIF image (87a)"),
        (b"GIF89a", "GIF image (89a)"),
        (b"%PDF-", "PDF document"),
        (b"PK\x03\x04", "Zip archive (or zip-based: docx, jar, …)"),
        (b"\x1f\x8b", "gzip compressed data"),
        (b"BZh", "bzip2 compressed data"),
        (b"\xfd7zXZ\x00", "xz compressed data"),
        (b"\x28\xb5\x2f\xfd", "Zstandard compressed data"),
        (b"BLENDER", "Blender file"),
        (b"\x7fELF", "ELF binary"),
        (b"\xca\xfe\xba\xbe", "Mach-O fat binary"),
        (b"\xcf\xfa\xed\xfe", "Mach-O 64-bit binary"),
        (b"\xfe\xed\xfa\xce", "Mach-O 32-bit binary"),
        (b"\xfe\xed\xfa\xcf", "Mach-O 64-bit binary"),
        (b"#!", "POSIX shell script"),
    ]
    rc = 0
    for path in argv:
        p = os.path.expanduser(path)
        if not os.path.exists(p):
            print(f"{path}: cannot open: No such file")
            rc = 1
            continue
        if os.path.isdir(p):
            print(f"{path}: directory")
            continue
        try:
            with open(p, "rb") as f:
                head = f.read(512)
        except OSError as e:
            print(f"{path}: cannot read: {e}")
            rc = 1
            continue
        if not head:
            print(f"{path}: empty")
            continue
        kind = next((label for sig, label in magic_hits if head.startswith(sig)), None)
        if kind is None:
            try:
                head.decode("utf-8")
                kind = "ASCII / UTF-8 text"
            except UnicodeDecodeError:
                kind = "data"
        print(f"{path}: {kind}")
    return rc


@builtin("xxd")
@builtin("hexdump")
def _xxd(sh: _Shell, argv: List[str]):
    """xxd | hexdump FILE  — print a hex+ASCII dump of FILE.

    Output mirrors `xxd` (16 bytes per line: offset / hex / printable)."""
    if not argv:
        print(f"{RED}xxd:{RESET} usage: xxd FILE")
        return 1
    p = os.path.expanduser(argv[0])
    try:
        with open(p, "rb") as f:
            off = 0
            while True:
                block = f.read(64 * 1024)
                if not block:
                    break
                for i in range(0, len(block), 16):
                    chunk = block[i:i + 16]
                    hexs = " ".join(f"{b:02x}" for b in chunk)
                    printable = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
                    # Pad hex column to fixed width (16 bytes × "XX " - last space = 47)
                    print(f"{off:08x}  {hexs:<47}  |{printable}|")
                    off += len(chunk)
    except OSError as e:
        print(f"{RED}xxd:{RESET} {e}")
        return 1
    return 0


@builtin("diff")
def _diff(sh: _Shell, argv: List[str]):
    """diff FILE1 FILE2  — line-by-line unified diff (3 lines of context).

    Exit status: 0 if the files are the same, 1 if they differ, 2 on an error."""
    if len(argv) < 2:
        print(f"{RED}diff:{RESET} usage: diff FILE1 FILE2")
        return 2
    import difflib
    paths = [os.path.expanduser(p) for p in argv[:2]]
    try:
        with open(paths[0], encoding="utf-8", errors="replace") as f:
            a = f.read().splitlines(keepends=True)
        with open(paths[1], encoding="utf-8", errors="replace") as f:
            b = f.read().splitlines(keepends=True)
    except OSError as e:
        print(f"{RED}diff:{RESET} {e}")
        return 2
    had = False
    for line in difflib.unified_diff(a, b, fromfile=argv[0], tofile=argv[1], n=3):
        had = True
        if not line.endswith("\n"):
            line += "\n"
        if line.startswith("+") and not line.startswith("+++"):
            sys.stdout.write(f"{GRN}{line}{RESET}")
        elif line.startswith("-") and not line.startswith("---"):
            sys.stdout.write(f"{RED}{line}{RESET}")
        elif line.startswith("@@"):
            sys.stdout.write(f"{CYN}{line}{RESET}")
        else:
            sys.stdout.write(line)
    if not had:
        print(f"{DIM}(files identical){RESET}")
        return 0
    return 1


@builtin("less")
@builtin("more")
def _less(sh: _Shell, argv: List[str]):
    """less | more [file…]  — show file(s) one screen at a time.

    The in-app terminal already provides scrollback (drag up), so this
    just `cat`s the file with a divider — there's no real pager UI.
    Use the script editor for proper pagination."""
    if not argv:
        print(f"{RED}less:{RESET} usage: less FILE…")
        return 1
    rc = 0
    for i, path in enumerate(argv):
        if i:
            print(f"\n{DIM}{'═' * 60}{RESET}\n")
        try:
            with open(os.path.expanduser(path), encoding="utf-8", errors="replace") as f:
                sys.stdout.write(f.read())
        except OSError as e:
            print(f"{RED}less:{RESET} {path}: {e}")
            rc = 1
    return rc


# ── Text utilities ────────────────────────────────────────────────

def _read_files(paths: List[str], cmd: str) -> Optional[str]:
    """Concatenate every file in `paths`. Print error + return None on the
    first I/O failure so the caller can bail."""
    out = []
    for p in paths:
        try:
            with open(os.path.expanduser(p), encoding="utf-8", errors="replace") as f:
                out.append(f.read())
        except OSError as e:
            print(f"{RED}{cmd}:{RESET} {e}")
            return None
    return "".join(out)


@builtin("sort")
def _sort(sh: _Shell, argv: List[str]):
    """sort [-r] [-n] [-u] [file…]  — sort lines.

    Flags:
        -r   reverse order
        -n   numeric (lines compare as numbers, not strings)
        -u   drop duplicates after sorting

    With no file, sorts what you type until the end of input."""
    rev = num = uniq = False
    args = list(argv)
    while args and args[0].startswith("-") and args[0] != "-":
        for ch in args.pop(0)[1:]:
            if ch == "r":
                rev = True
            elif ch == "n":
                num = True
            elif ch == "u":
                uniq = True
            else:
                print(f"{RED}sort:{RESET} unknown flag -{ch}")
                return 1
    if not args:
        lines = _stdin_text().splitlines()
    else:
        src = _read_files(args, "sort")
        if src is None:
            return 1
        lines = src.splitlines()
    if num:
        def _key(s):
            try:
                return (0, float(s.strip()))
            except ValueError:
                return (1, s)
        lines.sort(key=_key, reverse=rev)
    else:
        lines.sort(reverse=rev)
    if uniq:
        seen = set()
        out = []
        for ln in lines:
            if ln not in seen:
                out.append(ln)
                seen.add(ln)
        lines = out
    sys.stdout.write("\n".join(lines))
    if lines:
        sys.stdout.write("\n")
    return 0


@builtin("uniq")
def _uniq(sh: _Shell, argv: List[str]):
    """uniq [-c] [file]  — collapse adjacent duplicate lines.

    With -c, prefix each output line with its run length (like the
    real uniq). Doesn't sort first — run `sort` on the file first if needed.
    """
    show_count = False
    args = list(argv)
    if args and args[0] == "-c":
        show_count = True
        args.pop(0)
    if not args:
        text = _stdin_text()
    else:
        text = _read_files(args[:1], "uniq")
        if text is None:
            return 1
    prev, count = None, 0
    out_lines: List[str] = []
    for ln in text.splitlines():
        if ln == prev:
            count += 1
        else:
            if prev is not None:
                out_lines.append(f"{count:>4} {prev}" if show_count else prev)
            prev, count = ln, 1
    if prev is not None:
        out_lines.append(f"{count:>4} {prev}" if show_count else prev)
    sys.stdout.write("\n".join(out_lines))
    if out_lines:
        sys.stdout.write("\n")
    return 0


@builtin("tr")
def _tr(sh: _Shell, argv: List[str]):
    """tr [-d] SET1 [SET2]  — translate or delete characters from what you
    type (until the end of input).

    Examples:
        tr a-z A-Z         # uppercase
        tr -d 0-9          # strip digits
    """
    delete = False
    args = list(argv)
    if args and args[0] == "-d":
        delete = True
        args.pop(0)
    if not args:
        print(f"{RED}tr:{RESET} usage: tr [-d] SET1 [SET2]")
        return 1

    def _expand(spec: str) -> str:
        # Handle `a-z` style ranges.
        out = []
        i = 0
        while i < len(spec):
            if i + 2 < len(spec) and spec[i + 1] == "-":
                lo, hi = ord(spec[i]), ord(spec[i + 2])
                if lo <= hi:
                    out.extend(chr(c) for c in range(lo, hi + 1))
                    i += 3
                    continue
            out.append(spec[i])
            i += 1
        return "".join(out)

    set1 = _expand(args[0])
    if not delete and len(args) < 2:
        print(f"{RED}tr:{RESET} non-delete mode needs SET2")
        return 1
    text = _stdin_text()
    if delete:
        sys.stdout.write(text.translate(str.maketrans("", "", set1)))
        return 0
    set2 = _expand(args[1])
    if len(set2) < len(set1):
        # Real tr pads with the last char of SET2 — match that.
        set2 = set2 + (set2[-1] * (len(set1) - len(set2))) if set2 else ""
    if not set2:
        sys.stdout.write(text)
        return 0
    sys.stdout.write(text.translate(str.maketrans(set1, set2[:len(set1)])))
    return 0


@builtin("cut")
def _cut(sh: _Shell, argv: List[str]):
    """cut -d DELIM -f FIELDS [file…]  — extract columns.

    Examples:
        cut -d, -f 1,3 data.csv          # first + third comma-separated cols
        cut -d: -f 1 users.txt           # first colon-separated field
        cut -c 1-10 file.txt             # first 10 chars of each line
    """
    delim = "\t"
    fields_spec = None
    chars_spec = None
    args = list(argv)
    while args and args[0].startswith("-"):
        flag = args.pop(0)
        if flag.startswith("-d"):
            delim = flag[2:] if len(flag) > 2 else (args.pop(0) if args else "\t")
        elif flag.startswith("-f"):
            fields_spec = flag[2:] if len(flag) > 2 else (args.pop(0) if args else "")
        elif flag.startswith("-c"):
            chars_spec = flag[2:] if len(flag) > 2 else (args.pop(0) if args else "")
        else:
            print(f"{RED}cut:{RESET} unknown flag {flag!r}")
            return 1
    if fields_spec is None and chars_spec is None:
        print(f"{RED}cut:{RESET} need -f FIELDS or -c CHARS")
        return 1

    def _parse_ranges(spec: str) -> List[tuple]:
        out: List[tuple] = []
        for part in spec.split(","):
            part = part.strip()
            if "-" in part:
                a, b = part.split("-", 1)
                lo = int(a) if a else 1
                hi = int(b) if b else 10**9
                out.append((lo, hi))
            else:
                n = int(part)
                out.append((n, n))
        return out

    try:
        ranges = _parse_ranges(fields_spec if fields_spec is not None else chars_spec)
    except ValueError:
        print(f"{RED}cut:{RESET} bad range spec")
        return 1
    src = _stdin_text() if not args else _read_files(args, "cut")
    if src is None:
        return 1
    for line in src.splitlines():
        if fields_spec is not None:
            parts = line.split(delim)
            picked = []
            for lo, hi in ranges:
                picked.extend(parts[lo - 1: hi])
            print(delim.join(picked))
        else:
            print("".join(line[lo - 1: hi] for lo, hi in ranges))
    return 0


@builtin("nl")
def _nl(sh: _Shell, argv: List[str]):
    """nl [file…]  — number each non-empty line."""
    src = _stdin_text() if not argv else _read_files(argv, "nl")
    if src is None:
        return 1
    n = 0
    for line in src.splitlines():
        if line.strip():
            n += 1
            print(f"{n:>6}\t{line}")
        else:
            print()
    return 0


@builtin("tac")
def _tac(sh: _Shell, argv: List[str]):
    """tac [file…]  — print lines in reverse order (last → first)."""
    src = _stdin_text() if not argv else _read_files(argv, "tac")
    if src is None:
        return 1
    for line in reversed(src.splitlines()):
        print(line)
    return 0


@builtin("rev")
def _rev(sh: _Shell, argv: List[str]):
    """rev [file…]  — reverse each line's character order."""
    src = _stdin_text() if not argv else _read_files(argv, "rev")
    if src is None:
        return 1
    for line in src.splitlines():
        print(line[::-1])
    return 0


@builtin("seq")
def _seq(sh: _Shell, argv: List[str]):
    """seq [START [STEP]] END  — print numbers from START to END (inclusive).

    Examples:
        seq 5            # 1..5
        seq 2 10         # 2..10
        seq 0 2 10       # 0,2,4,6,8,10
    """
    if not argv:
        print(f"{RED}seq:{RESET} usage: seq [START [STEP]] END")
        return 1
    try:
        nums = [float(a) for a in argv]
    except ValueError:
        print(f"{RED}seq:{RESET} arguments must be numeric")
        return 1
    if len(nums) == 1:
        start, step, end = 1.0, 1.0, nums[0]
    elif len(nums) == 2:
        start, step, end = nums[0], 1.0, nums[1]
    elif len(nums) == 3:
        start, step, end = nums
    else:
        print(f"{RED}seq:{RESET} too many args")
        return 1
    if step == 0:
        print(f"{RED}seq:{RESET} step cannot be 0")
        return 1
    integer = all(float(a).is_integer() for a in argv)
    x = start
    while (x <= end) if step > 0 else (x >= end):
        print(int(x) if integer else f"{x:g}")
        x += step
    return 0


@builtin("yes")
def _yes(sh: _Shell, argv: List[str]):
    """yes [STRING]  — print STRING (or 'y') 100 times.

    Capped at 100 lines: with no pipes to feed, an endless `yes` would
    only fill the terminal."""
    msg = " ".join(argv) if argv else "y"
    for _ in range(100):
        print(msg)
    return 0


def _bc_eval(expr: str):
    """Evaluate + - * / % ** // and parentheses over numbers, refusing
    powers so large they would hold the console for minutes."""
    import ast
    import operator
    binary = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul,
              ast.Div: operator.truediv, ast.FloorDiv: operator.floordiv,
              ast.Mod: operator.mod, ast.Pow: operator.pow}
    unary = {ast.UAdd: operator.pos, ast.USub: operator.neg}

    def ev(node):
        if isinstance(node, ast.Expression):
            return ev(node.body)
        if isinstance(node, ast.Constant) and type(node.value) in (int, float):
            return node.value
        if isinstance(node, ast.UnaryOp) and type(node.op) in unary:
            return unary[type(node.op)](ev(node.operand))
        if isinstance(node, ast.BinOp) and type(node.op) in binary:
            left, right = ev(node.left), ev(node.right)
            if isinstance(node.op, ast.Pow):
                magnitude = abs(left) if isinstance(left, (int, float)) else 0
                if abs(right) > 100_000 or (
                        isinstance(left, int) and isinstance(right, int) and magnitude > 1
                        and magnitude.bit_length() * abs(right) > 1_000_000):
                    raise ValueError("result too large")
            return binary[type(node.op)](left, right)
        raise ValueError("unsupported expression")

    return ev(ast.parse(expr.strip(), mode="eval"))


@builtin("bc")
def _bc(sh: _Shell, argv: List[str]):
    """bc EXPR…  — evaluate an arithmetic expression.

    Supports + - * / % ** and parentheses. Use Python at the prompt for
    anything richer (math.sqrt, etc.).
    """
    if not argv:
        print(f"{RED}bc:{RESET} usage: bc EXPR")
        return 1
    expr = " ".join(argv)
    # Restrict to a safe subset — no function calls, no name lookup.
    if not all(ch in "0123456789.+-*/%() " for ch in expr):
        print(f"{RED}bc:{RESET} only digits and + - * / % ( ) allowed")
        return 1
    try:
        result = _bc_eval(expr)
        print(result)
    except (ValueError, ArithmeticError, SyntaxError, RecursionError, MemoryError) as e:
        print(f"{RED}bc:{RESET} {e}")
        return 1
    return 0


@builtin("cal")
def _cal(sh: _Shell, argv: List[str]):
    """cal [MONTH] [YEAR]  — print a month calendar (defaults to current)."""
    import calendar
    now = time.localtime()
    if len(argv) == 0:
        month, year = now.tm_mon, now.tm_year
    elif len(argv) == 1:
        try:
            year = int(argv[0])
            month = now.tm_mon
        except ValueError:
            print(f"{RED}cal:{RESET} bad year")
            return 1
    else:
        try:
            month, year = int(argv[0]), int(argv[1])
        except ValueError:
            print(f"{RED}cal:{RESET} bad month/year")
            return 1
    if not 1 <= month <= 12:
        print(f"{RED}cal:{RESET} month must be 1-12")
        return 1
    try:
        print(calendar.month(year, month).rstrip())
    except (ValueError, OverflowError) as e:
        print(f"{RED}cal:{RESET} {e}")
        return 1
    return 0


@builtin("base64")
def _base64_cmd(sh: _Shell, argv: List[str]):
    """base64 [-d] [file]  — encode (default) or decode (-d) base64.

    Reads from a file if given, else from the trailing positional
    argument as a literal string. With `-d`, decodes; output is
    written to stdout (lossy decode for non-UTF-8 bytes).
    """
    decode = False
    args = list(argv)
    if args and args[0] == "-d":
        decode = True
        args.pop(0)
    if not args:
        print(f"{RED}base64:{RESET} usage: base64 [-d] <file|string>")
        return 1
    arg = args[0]
    p = os.path.expanduser(arg)
    if os.path.isfile(p):
        try:
            with open(p, "rb") as f:
                data = f.read()
        except OSError as e:
            print(f"{RED}base64:{RESET} {e}")
            return 1
    else:
        data = arg.encode("utf-8")
    if decode:
        try:
            out = _base64.b64decode(data, validate=False)
        except Exception as e:
            print(f"{RED}base64:{RESET} {e}")
            return 1
        sys.stdout.write(out.decode("utf-8", errors="replace"))
        if not out.endswith(b"\n"):
            sys.stdout.write("\n")
    else:
        # Match GNU coreutils: 76-char lines.
        encoded = _base64.b64encode(data).decode("ascii")
        for i in range(0, len(encoded), 76):
            print(encoded[i:i + 76])
    return 0


def _hash_file_or_stdin(algo: str, argv: List[str]) -> int:
    import hashlib
    if not argv:
        h = hashlib.new(algo)
        h.update(_stdin_bytes())
        print(f"{h.hexdigest()}  -")
        return 0
    rc = 0
    for path in argv:
        p = os.path.expanduser(path)
        try:
            h = hashlib.new(algo)
            with open(p, "rb") as f:
                for chunk in iter(lambda: f.read(1024 * 1024), b""):
                    h.update(chunk)
            print(f"{h.hexdigest()}  {path}")
        except OSError as e:
            print(f"{RED}{algo}sum:{RESET} {e}")
            rc = 1
    return rc


@builtin("sha256sum")
def _sha256sum(sh: _Shell, argv: List[str]):
    """sha256sum <file…>  — print SHA-256 hash of each file."""
    return _hash_file_or_stdin("sha256", argv)


@builtin("sha1sum")
def _sha1sum(sh: _Shell, argv: List[str]):
    """sha1sum <file…>  — print SHA-1 hash of each file."""
    return _hash_file_or_stdin("sha1", argv)


@builtin("md5sum")
def _md5sum(sh: _Shell, argv: List[str]):
    """md5sum <file…>  — print MD5 hash of each file."""
    return _hash_file_or_stdin("md5", argv)


@builtin("sleep")
def _sleep(sh: _Shell, argv: List[str]):
    """sleep N  — wait N seconds (supports decimals: `sleep 0.5`)."""
    if not argv:
        print(f"{RED}sleep:{RESET} usage: sleep N")
        return 1
    try:
        secs = float(argv[0])
    except ValueError:
        print(f"{RED}sleep:{RESET} not a number: {argv[0]!r}")
        return 1
    if secs != secs or secs < 0:
        print(f"{RED}sleep:{RESET} N must be ≥ 0")
        return 1
    _pause(min(secs, 3600), stop_at_eof=False)   # cap at 1h so a typo doesn't wedge the console
    return 0


@builtin("time")
def _time_cmd(sh: _Shell, argv: List[str]):
    """time <command…>  — measure how long another command takes.

    Only real (wall clock) time is shown: every command runs inside the
    app's own process, so there are no separate user/sys times.
    """
    if not argv:
        print(f"{RED}time:{RESET} usage: time <command…>")
        return 1
    resolved = _resolve_command(argv)
    if resolved is None:
        print(f"{RED}time:{RESET} not a builtin: {argv[0]}")
        return 1
    _name, fn, rest = resolved
    t0 = time.perf_counter()
    try:
        rc = fn(sh, rest)
    finally:
        elapsed = time.perf_counter() - t0
        print(f"\n{DIM}real  {elapsed:.3f}s{RESET}")
    return _status(rc)


# ── Disk usage ────────────────────────────────────────────────────

def _dir_size(path: str) -> int:
    """Total bytes under `path` (files + subdir files). Silent on
    permission errors — iOS has many."""
    total = 0
    stack = [path]
    while stack:
        d = stack.pop()
        try:
            with os.scandir(d) as it:
                for entry in it:
                    try:
                        if entry.is_symlink():
                            continue
                        if entry.is_file(follow_symlinks=False):
                            total += entry.stat(follow_symlinks=False).st_size
                        elif entry.is_dir(follow_symlinks=False):
                            stack.append(entry.path)
                    except OSError:
                        continue
        except OSError:
            continue
    return total


@builtin("du")
def _du(sh: _Shell, argv: List[str]):
    """du [-s] [-h] [path]  — disk usage of directories.
    -s  summary (just the grand total, not per-subdir)
    -h  human-readable sizes (default on)
    """
    summary_only = "-s" in argv
    targets = [a for a in argv if not a.startswith("-")] or ["."]
    rc = 0
    for tgt in targets:
        p = os.path.abspath(os.path.expanduser(tgt))
        if not os.path.exists(p):
            print(f"{RED}du:{RESET} no such path: {tgt}")
            rc = 1
            continue
        if os.path.isfile(p):
            try:
                print(f"{_human_bytes(os.path.getsize(p)):>8}  {tgt}")
            except OSError as e:
                print(f"{RED}du:{RESET} {e.strerror}: {tgt}")
                rc = 1
            continue

        total = 0
        if not summary_only:
            try:
                with os.scandir(p) as it:
                    for entry in sorted(it, key=lambda e: e.name):
                        if entry.name.startswith("."):
                            continue
                        try:
                            if entry.is_dir(follow_symlinks=False):
                                sz = _dir_size(entry.path)
                            elif entry.is_file(follow_symlinks=False):
                                sz = entry.stat(follow_symlinks=False).st_size
                            else:
                                continue
                            total += sz
                            print(f"{_human_bytes(sz):>8}  {entry.name}")
                        except OSError:
                            continue
            except OSError as e:
                print(f"{RED}du:{RESET} {e.strerror}: {tgt}")
                rc = 1
                continue
        else:
            total = _dir_size(p)
        print(f"{BOLD}{_human_bytes(total):>8}{RESET}  {tgt}")
    return rc


@builtin("df")
def _df(sh: _Shell, argv: List[str]):
    """df — free space on the app sandbox filesystem."""
    paths = [a for a in argv if not a.startswith("-")] or [sh.home]
    rc = 0
    for p in paths:
        try:
            usage = shutil.disk_usage(os.path.expanduser(p))
        except OSError as e:
            print(f"{RED}df:{RESET} {e.strerror}: {p}")
            rc = 1
            continue
        print(f"{BOLD}Filesystem      Size   Used   Free  Use%  Mounted on{RESET}")
        used_pct = (usage.used * 100 / usage.total) if usage.total else 0
        print(f"iOS sandbox  {_human_bytes(usage.total):>6} "
              f"{_human_bytes(usage.used):>6} "
              f"{_human_bytes(usage.free):>6} "
              f"{used_pct:>4.0f}%  {p}")
    return rc


def _ncdu_scan(path: str, show_hidden: bool, sort_mode: str) -> List[tuple]:
    """Scan a directory → list of (size, name, is_dir, mtime).
    Sort modes: 'size' (desc), 'name' (asc), 'mtime' (desc)."""
    entries: List[tuple] = []
    try:
        with os.scandir(path) as it:
            for entry in it:
                if not show_hidden and entry.name.startswith("."):
                    continue
                try:
                    st = entry.stat(follow_symlinks=False)
                    if entry.is_dir(follow_symlinks=False):
                        entries.append((_dir_size(entry.path), entry.name, True, st.st_mtime))
                    elif entry.is_file(follow_symlinks=False):
                        entries.append((st.st_size, entry.name, False, st.st_mtime))
                except OSError:
                    continue
    except OSError:
        pass
    if sort_mode == "name":
        entries.sort(key=lambda e: e[1].lower())
    elif sort_mode == "mtime":
        entries.sort(key=lambda e: e[3], reverse=True)
    else:
        entries.sort(reverse=True)
    return entries


def _ncdu_human_mib(n: int) -> str:
    """Format bytes using the KiB/MiB/GiB convention real ncdu uses."""
    if n < 1024:
        return f"{n:>5.0f}   B"
    x = float(n) / 1024
    for unit in ("KiB", "MiB", "GiB", "TiB", "PiB"):
        if x < 1024:
            return f"{x:>5.1f} {unit}"
        x /= 1024
    return f"{x:>5.1f} PiB"


def _ncdu_draw(path: str, entries: List[tuple], selected: int, page_start: int,
               rows: int, width: int, height: int) -> None:
    """One frame, in real ncdu 2.x's layout, sized to the terminal:

        ┌─ inverse video ─────────────────────────────────────────────┐
        │ ncdu 1.x ~ Use the arrow keys to navigate, press ? for help │
        └─────────────────────────────────────────────────────────────┘
        --- /path/here -------------------------------------------
          SIZE UNIT [##########] name-or-/dirname
          …
        ┌─ inverse video ─────────────────────────────────────────────┐
        │ *Total disk usage:  X MiB  Apparent size: Y MiB  Items: N  │
        └─────────────────────────────────────────────────────────────┘
    """
    out = ["\x1b[2J\x1b[H"]

    # ── Top status bar (inverse video) ──
    title = "ncdu 1.1 ~ Use the arrow keys to navigate, press ? for help"
    out.append(f"\x1b[7m{_fit(' ' + title, width)}\x1b[0m\r\n")

    # ── Path separator ──
    dash_path = f"--- {path} "
    if len(dash_path) < width:
        dash_path = dash_path + "-" * (width - len(dash_path))
    else:
        # Path too long — truncate keeping the tail visible
        head = "--- ..."
        tail_len = max(0, width - len(head) - 1)
        dash_path = head + (path[-tail_len:] if tail_len else "") + " "
    out.append(f"{dash_path[:width]}\r\n")

    # ── Entries ──
    shown = 0
    more_line = 0
    if not entries:
        out.append(" (empty directory)\r\n")
        shown = 1
    else:
        max_sz = max((e[0] for e in entries), default=0) or 1
        bar_w = 20
        end = min(page_start + rows, len(entries))
        for idx in range(page_start, end):
            sz, name, is_dir, _mt = entries[idx]
            bar_len = int(bar_w * sz / max_sz) if max_sz else 0
            bar = "#" * bar_len + " " * (bar_w - bar_len)
            # Real ncdu prefix convention: "/name" for directories,
            # bare "name" for files, leading two spaces for alignment.
            label = ("/" + name) if is_dir else ("  " + name)
            # Padded to full width so the inverse-video stripe runs edge to edge.
            line = _fit(f" {_ncdu_human_mib(sz)} [{bar}] {label}", width)
            if idx == selected:
                out.append(f"\x1b[7m{line}\x1b[0m\r\n")
            else:
                out.append(f"{line}\r\n")
        shown = end - page_start
        if end < len(entries):
            out.append(_fit(f" ... {len(entries) - end} more below ...", width).rstrip() + "\r\n")
            more_line = 1

    # ── Pad vertical space so the footer sits on the terminal's last row ──
    rendered_rows = 2 + shown + more_line
    out.append("\r\n" * max(0, (height - 2) - rendered_rows))

    # ── Bottom status bar (inverse video) ──
    total = sum(e[0] for e in entries) if entries else 0
    # "Apparent size" ≈ total for our purposes (we don't use st_blocks).
    footer = (f"*Total disk usage: {_ncdu_human_mib(total).strip()}   "
              f"Apparent size: {_ncdu_human_mib(total).strip()}   "
              f"Items: {len(entries)}")
    out.append(f"\x1b[7m{_fit(footer, width)}\x1b[0m\r\n")
    _write("".join(out))


_NCDU_KEYS = """\
  ↑↓ or j/k        move cursor            ←/h   parent directory
  →/enter/l        open dir / info        d     delete (confirm)
  PgUp/PgDn        move a page            Home/End  first / last
  i                info (stat)            r     recalculate
  s                cycle sort order       .     toggle hidden
  b                shell at cwd           ?     this help
  q                quit"""


@builtin("ncdu")
def _ncdu(sh: _Shell, argv: List[str]):
    """ncdu [path]  — ncurses-style interactive disk-usage browser with
    raw-mode arrow-key navigation (matches real ncdu behavior).

    Keys:
      ↑↓ or j/k        move cursor            ←/h   parent directory
      →/enter/l        open dir / info        d     delete (confirm)
      PgUp/PgDn        move a page            Home/End  first / last
      i                info (stat)            r     recalculate
      s                cycle sort order       .     toggle hidden
      b                shell at cwd           ?     key help
      q                quit
    """
    start = os.path.realpath(os.path.expanduser(argv[0])) if argv else os.getcwd()
    if not os.path.isdir(start):
        print(f"{RED}ncdu:{RESET} not a directory: {start}")
        return 1

    show_hidden = True      # show hidden dotfiles by default so disk totals are
                            # transparent (press `.` to hide)
    try:
        sandbox_root = os.path.realpath(sh.home)
    except OSError:
        sandbox_root = start

    path = start
    sort_modes = ("size", "name", "mtime")
    sort_idx = 0
    selected = 0
    page_start = 0

    def scan():
        return _ncdu_scan(path, show_hidden, sort_modes[sort_idx])

    def wait_key() -> str:
        # Any key returns; the end of input quits.
        return _tui_wait_key()

    entries = scan()

    # Switch to the alternate screen buffer so ncdu's frames don't
    # flood scrollback, exactly like real ncdu / vim / less do. On
    # exit we restore, so the terminal's content comes back unchanged.
    _alt_screen_on()
    # Enter raw mode so arrow keys reach us as escape sequences.
    # try/finally so a crash always restores cooked mode AND the main
    # screen buffer.
    tui_enter_raw()
    try:
        while True:
            width, height = _term_size()
            width = max(20, width)
            rows = max(1, height - 6)
            parent = os.path.dirname(path)
            parent_ok = (parent != path) and (
                parent == sandbox_root or parent.startswith(sandbox_root + os.sep))
            if not entries:
                selected = 0
            else:
                selected = max(0, min(selected, len(entries) - 1))
            if selected < page_start:
                page_start = selected
            if selected >= page_start + rows:
                page_start = selected - rows + 1
            page_start = max(0, min(page_start, max(0, len(entries) - 1)))

            _ncdu_draw(path, entries, selected, page_start, rows, width, height)

            key = wait_key()

            if key in ("", "q", "ctrl-c", "ctrl-d"):
                break
            elif key in ("down", "j"):
                selected += 1
            elif key in ("up", "k"):
                selected -= 1
            elif key == "pagedown":
                selected += rows
            elif key == "pageup":
                selected -= rows
            elif key == "home":
                selected = 0
            elif key == "end":
                selected = max(0, len(entries) - 1)
            elif key in ("left", "h", "backspace"):
                # 'h' as a key here = parent dir, matches real ncdu.
                if parent_ok:
                    path = parent
                    entries = scan()
                    selected, page_start = 0, 0
            elif key in ("right", "enter", "l", "i"):
                if not entries:
                    continue
                _sz, name, is_dir, _mt = entries[selected]
                if is_dir and key != "i":
                    path = os.path.join(path, name)
                    entries = scan()
                    selected, page_start = 0, 0
                else:
                    _write("\x1b[2J\x1b[H")
                    _stat_cmd(sh, [os.path.join(path, name)])
                    _write(f"\n{DIM}(press any key to return){RESET} ")
                    if wait_key() == "":
                        break
            elif key == "?":
                _write("\x1b[2J\x1b[H")
                print(f"{BOLD}ncdu keys{RESET}\n")
                print(_NCDU_KEYS)
                _write(f"\n\n{DIM}(press any key to return){RESET} ")
                if wait_key() == "":
                    break
            elif key == "r":
                entries = scan()
            elif key == "s":
                sort_idx = (sort_idx + 1) % len(sort_modes)
                entries = scan()
            elif key == ".":
                show_hidden = not show_hidden
                entries = scan()
                selected, page_start = 0, 0
            elif key == "d":
                if not entries:
                    continue
                _, name, is_dir, _mt = entries[selected]
                target = os.path.join(path, name)
                _write(f"\r\n{RED}Delete {'dir ' if is_dir else 'file '}{name}? (y/N): {RESET}")
                answer = wait_key()
                if answer == "":
                    break
                if answer == "y":
                    try:
                        if is_dir:
                            shutil.rmtree(target)
                        else:
                            os.unlink(target)
                        entries = scan()
                        if selected >= len(entries):
                            selected = max(0, len(entries) - 1)
                    except OSError as e:
                        _write(f"\r\n{RED}delete failed: {e}{RESET}\r\n{DIM}(press any key){RESET} ")
                        if wait_key() == "":
                            break
            elif key == "b":
                try:
                    saved = os.getcwd()
                except OSError:
                    saved = sh.home
                try:
                    os.chdir(path)
                except OSError:
                    pass
                tui_exit_raw()
                _write("\x1b[2J\x1b[H")
                print(f"{DIM}(mini-shell at {path}; type `exit` to return to ncdu){RESET}")
                while True:
                    _write(f"{BOLD}ncdu:shell>{RESET} ")
                    line = _read_line_fd0()
                    if line is None or line.strip().lower() in ("exit", "quit"):
                        break
                    sh.run_line(line)
                tui_enter_raw()
                try:
                    os.chdir(saved)
                except OSError:
                    pass
                entries = scan()
    finally:
        tui_exit_raw()
        # Show cursor + leave alt screen (scrollback unchanged).
        _alt_screen_off()
        print(f"{DIM}(ncdu exited — last path: {path}){RESET}")
    return 0


# ── System monitor ────────────────────────────────────────────────

@builtin("top")
@builtin("htop")
def _top(sh: _Shell, argv: List[str]):
    """top | htop  — live CPU / memory monitor with auto-refresh.

    Shows overall CPU, per-core bars, load average, RAM and compressed
    memory, uptime, the CPU time split, disk space in the app's home,
    and this process's memory footprint, resident size, thread count
    and CPU use. iOS doesn't expose GPU utilisation to apps, so the GPU
    line only names the device.

    Keys (raw-mode input while running):
        q / Ctrl-C  quit
        space / r   refresh now (skip the wait)
        +           increase refresh interval
        -           decrease refresh interval

    Flags:
        -d SEC      starting refresh interval (default 1, minimum 0.2)
    """
    # Parse args: -d <sec> sets initial delay.
    delay = 1.0
    if "-d" in argv:
        try:
            i = argv.index("-d")
            delay = max(0.2, float(argv[i + 1]))
        except (ValueError, IndexError):
            pass

    # Cache device/chip info — these don't change during the session.
    product_name, chip_name = _apple_device_info()
    gpu_name = (chip_name.split(" ", 1)[-1] if " " in chip_name else chip_name) + " integrated"
    cores_fallback = os.cpu_count() or 1
    home = sh.home

    # Streaming frames, not the alternate screen: each refresh prints a
    # full frame under a divider, so earlier frames stay in scrollback.
    # The cursor stays hidden so the redraw doesn't flicker the caret.
    _hide_cursor()
    tui_enter_raw()
    try:
        # A frame's CPU figures are the ticks between two samples, so take
        # one now and let a moment pass before drawing the first frame.
        prev_ticks = _cpu_ticks()
        prev_cpu_seconds = _proc_cpu_seconds()
        prev_t = time.monotonic()
        time.sleep(0.2)

        first = True
        while True:
            cols, _rows = _term_size()
            width = max(20, min(72, cols))

            # ── Collect stats (keep it fast — this runs each frame) ──
            cur_ticks = _cpu_ticks()
            now = time.monotonic()
            usage = _cpu_usage(prev_ticks, cur_ticks)
            cpu_seconds = _proc_cpu_seconds()
            proc_cpu = None
            if cpu_seconds is not None and prev_cpu_seconds is not None and now > prev_t:
                proc_cpu = 100.0 * (cpu_seconds - prev_cpu_seconds) / (now - prev_t)
            prev_ticks, prev_cpu_seconds, prev_t = cur_ticks, cpu_seconds, now
            core_count = len(cur_ticks) if cur_ticks else cores_fallback

            vm = _vm_statistics()
            mem = _memory(vm)
            swap = _swap()
            comp = _compressed(vm)
            load = _loadavg()
            task_mem = _task_memory()
            threads = _thread_count()

            # ── Draw — one write per frame ──
            out: List[str] = []
            if not first:
                out.append(f"\r\n{DIM}{'─' * width}{RESET}\r\n\r\n")

            # Top status bar
            stamp = time.strftime("%H:%M:%S")
            title = f" top — live system monitor   ({stamp},  refresh {delay:.1f}s)"
            out.append(f"\x1b[7m{_fit(title, width)}\x1b[0m\r\n\r\n")

            # Overall CPU
            if usage is not None:
                cpu_total, cpu_each, breakdown = usage
                out.append(f"  {BOLD}CPU total{RESET}  "
                           f"[{_bar_colored(cpu_total / 100, 32)}]  "
                           f"{cpu_total:>5.1f}%\r\n")
            else:
                cpu_each, breakdown = [], None
                out.append(f"  {BOLD}CPU total{RESET}  "
                           f"[{_bar_colored(0.0, 32)}]  {_DASH:>6}\r\n")

            # Per-core bars
            if cpu_each:
                out.append(f"  {DIM}cores ({core_count}){RESET}\r\n")
                for i, p in enumerate(cpu_each):
                    out.append(f"    {DIM}#{i:<2}{RESET}     "
                               f"[{_bar_colored(p / 100, 32)}]  "
                               f"{p:>5.1f}%\r\n")

            # Load average
            if load is not None:
                load1, load5, load15 = load
                out.append(f"  {BOLD}load avg {RESET}  "
                           f"{load1:>4.2f}  {load5:>4.2f}  {load15:>4.2f}   "
                           f"{DIM}(1m / 5m / 15m, {core_count} cores){RESET}\r\n")
            else:
                out.append(f"  {BOLD}load avg {RESET}  {_DASH}\r\n")

            out.append("\r\n")

            # Memory (RAM)
            if mem is not None:
                mem_used, mem_total, mem_pct = mem
                out.append(f"  {BOLD}RAM      {RESET}  "
                           f"[{_bar_colored(mem_pct / 100, 32)}]  "
                           f"{mem_pct:>5.1f}%   "
                           f"{_human_bytes(mem_used)} / {_human_bytes(mem_total)}\r\n")
            else:
                out.append(f"  {BOLD}RAM      {RESET}  "
                           f"[{_bar_colored(0.0, 32)}]  {_DASH:>6}   {_DASH}\r\n")
            # Compressed / swap. A real swap total when the system swaps to
            # disk; otherwise the XNU compressor pool — iOS's "swap".
            if swap is not None and swap[1] > 0:
                swap_used, swap_total, swap_pct = swap
                out.append(f"  {BOLD}Swap/cmp {RESET}  "
                           f"[{_bar_colored(swap_pct / 100, 32)}]  "
                           f"{swap_pct:>5.1f}%   "
                           f"{_human_bytes(swap_used)} / {_human_bytes(swap_total)}   "
                           f"{DIM}(iOS compressed memory){RESET}\r\n")
            elif comp is not None and comp[0] > 0:
                held, uncompressed = comp
                saved = max(0, uncompressed - held)
                out.append(f"  {BOLD}Compressed{RESET} "
                           f"{_human_bytes(held)} held   "
                           f"({_human_bytes(uncompressed)} uncompressed, "
                           f"{_human_bytes(saved)} saved)   "
                           f"{DIM}(iOS XNU memory compressor){RESET}\r\n")
            elif swap is None and comp is None:
                out.append(f"  {BOLD}Compressed{RESET} {_DASH}\r\n")

            out.append("\r\n")

            # Uptime, from the boot time.
            boot = _boot_time()
            if boot is not None:
                up = max(0.0, time.time() - boot)
                d = int(up // 86400)
                h = int((up % 86400) // 3600)
                m = int((up % 3600) // 60)
                up_str = f"{d}d {h}h {m}m" if d > 0 else (f"{h}h {m}m" if h > 0 else f"{m}m")
            else:
                up_str = _DASH
            out.append(f"  {BOLD}Uptime   {RESET}  {CYN}{up_str}{RESET}\r\n")

            # CPU time breakdown — what the CPU is actually DOING.
            if breakdown is not None:
                # Every component, zeros included: a monitor whose fields
                # disappear when they reach zero moves the ones beside them,
                # and under a full load `idl` was the one that vanished.
                parts = [f"{lbl}={v:.1f}%" for lbl, v in breakdown.items()]
                out.append(f"  {BOLD}CPU time {RESET}  {DIM}{'  '.join(parts) or _DASH}{RESET}\r\n")
            else:
                out.append(f"  {BOLD}CPU time {RESET}  {DIM}{_DASH}{RESET}\r\n")

            # Disk space in the app's home — what the user cares about.
            disk = _disk_usage(home)
            if disk is not None:
                du_used, du_total, du_pct = disk
                out.append(f"  {BOLD}Disk     {RESET}  "
                           f"[{_bar_colored(du_pct / 100, 32)}]  "
                           f"{du_pct:>5.1f}%   "
                           f"{_human_bytes(du_used)} / {_human_bytes(du_total)}   "
                           f"{DIM}(app home){RESET}\r\n")
            else:
                out.append(f"  {BOLD}Disk     {RESET}  "
                           f"[{_bar_colored(0.0, 32)}]  {_DASH:>6}   {_DASH}\r\n")

            fds = _open_fd_count()
            out.append(f"  {BOLD}FDs      {RESET}  "
                       f"{f'{fds} open' if fds is not None else _DASH}\r\n")

            out.append("\r\n")

            # Device info — chip + product (cached, doesn't change).
            out.append(f"  {BOLD}Device   {RESET}  {CYN}{product_name}{RESET}\r\n")
            out.append(f"  {BOLD}Chip     {RESET}  {CYN}{chip_name}{RESET}\r\n")
            out.append(f"  {BOLD}GPU      {RESET}  {CYN}{gpu_name}{RESET}\r\n")
            out.append(f"  {DIM}(utilisation not exposed on iOS){RESET}\r\n")

            out.append("\r\n")

            # This process — pid, footprint, resident size, threads, CPU.
            rss = task_mem[0] if task_mem else None
            footprint = task_mem[1] if task_mem else None
            proc_cpu_str = f"{proc_cpu:.1f}%" if proc_cpu is not None else _DASH
            out.append(f"  {BOLD}Process  {RESET}  "
                       f"pid={os.getpid()}   "
                       f"footprint={_bytes_or_dash(footprint)}   "
                       f"rss={_bytes_or_dash(rss)}   "
                       f"threads={threads if threads is not None else _DASH}   "
                       f"cpu={proc_cpu_str}\r\n")

            # Footer hint (reverse video)
            out.append("\r\n")
            footer = " q quit   space refresh   +/- adjust interval"
            out.append(f"\x1b[7m{_fit(footer, width)}\x1b[0m\r\n")
            _write("".join(out))

            # ── Wait for a keypress or the refresh interval ──
            deadline = time.monotonic() + delay
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                key = _tui_read_key(min(remaining, 0.25))
                if key is None:
                    continue
                if key in ("", "q", "ctrl-c", "ctrl-d"):
                    return 0
                if key in (" ", "r"):
                    break
                if key in ("+", "="):
                    delay = min(10.0, delay + 0.5)
                    break
                if key in ("-", "_"):
                    delay = max(0.2, delay - 0.5)
                    break

            first = False
    finally:
        tui_exit_raw()
        # Show the cursor again. Every frame went to the normal scrollback,
        # so the history is still there to scroll back through.
        _show_cursor()


@builtin("ps")
def _ps(sh: _Shell, argv: List[str]):
    """ps  — list this app's process.

    iOS doesn't let an app see other processes, so the list is Blender
    Local itself: pid, state, CPU use averaged since launch, resident
    memory, thread count and command."""
    print(f"{BOLD}{'PID':>6}  {'STATE':<10} {'CPU%':>6}  {'RSS':>8}  {'THR':>4}  CMD{RESET}")
    cpu = None
    started = _process_start()
    cpu_seconds = _proc_cpu_seconds()
    if started is not None and cpu_seconds is not None:
        age = time.time() - started
        if age > 0:
            cpu = 100.0 * cpu_seconds / age
    task_mem = _task_memory()
    threads = _thread_count()
    cpu_str = f"{cpu:>5.1f}%" if cpu is not None else f"{_DASH:>6}"
    rss_str = _human_bytes(task_mem[0]) if task_mem else _DASH
    thr_str = str(threads) if threads is not None else _DASH
    print(f"{os.getpid():>6}  {'running':<10} {cpu_str}  {rss_str:>8}  {thr_str:>4}  "
          f"{_process_command()[:64]}")
    return 0


@builtin("kill")
def _kill(sh: _Shell, argv: List[str]):
    """kill [-SIGNAL] PID  — send a signal to a process.

    iOS only lets an app signal processes it owns. The one process here
    is Blender Local itself, and kill refuses that pid (and 0 or below,
    which would include it): signalling it would close the app."""
    import signal as _sig
    sig = _sig.SIGTERM
    args = list(argv)
    if args and args[0].startswith("-"):
        s = args.pop(0).lstrip("-")
        if s.isdigit():
            sig = int(s)
        else:
            named = "SIG" + s if not s.startswith("SIG") else s
            try:
                sig = getattr(_sig, named)
            except AttributeError:
                print(f"{RED}kill:{RESET} unknown signal {s!r}")
                return 1
    if not args:
        print(f"{RED}kill:{RESET} usage: kill [-SIGNAL] PID")
        return 1
    me = os.getpid()
    rc = 0
    for spid in args:
        try:
            pid = int(spid)
        except ValueError as e:
            print(f"{RED}kill:{RESET} {spid}: {e}")
            rc = 1
            continue
        if pid == me or pid <= 0:
            print(f"{RED}kill:{RESET} {spid}: refusing — that is Blender Local itself, "
                  f"and the signal would close the app")
            rc = 1
            continue
        try:
            os.kill(pid, sig)
        except (OSError, ValueError, OverflowError) as e:
            print(f"{RED}kill:{RESET} {spid}: {e}")
            rc = 1
    return rc


@builtin("watch")
def _watch(sh: _Shell, argv: List[str]):
    """watch [-n SEC] [-c COUNT] CMD  — re-run CMD every SEC seconds (default 2).

    Runs COUNT times (default and cap: 60) so a typo doesn't wedge the
    console; Ctrl-C stops it sooner.
    """
    interval = 2.0
    count = 60
    args = list(argv)
    while args and args[0].startswith("-"):
        flag = args.pop(0)
        if flag == "-n" and args:
            try:
                interval = max(0.1, float(args.pop(0)))
            except ValueError:
                print(f"{RED}watch:{RESET} bad interval")
                return 1
        elif flag in ("-c", "--count") and args:
            try:
                count = max(1, min(60, int(args.pop(0))))
            except ValueError:
                print(f"{RED}watch:{RESET} bad count")
                return 1
        else:
            print(f"{RED}watch:{RESET} unknown flag {flag!r}")
            return 1
    if not args:
        print(f"{RED}watch:{RESET} usage: watch [-n SEC] [-c COUNT] CMD")
        return 1
    resolved = _resolve_command(args)
    if resolved is None:
        print(f"{RED}watch:{RESET} not a builtin: {args[0]}")
        return 1
    _name, fn, rest = resolved
    rc = 0
    for i in range(count):
        sys.stdout.write("\x1b[H\x1b[2J")  # cursor home + clear
        print(f"{DIM}every {interval}s — {' '.join(args)}{RESET}\n")
        rc = _status(fn(sh, list(rest)))
        # The end of input (Stop, or ⌃D) ends the loop too.
        if i + 1 < count and not _pause(interval, stop_at_eof=True):
            break
    return rc


# ── Archives — formats the standard library reads ─────────────────

@builtin("zip")
def _zip(sh: _Shell, argv: List[str]):
    """zip <archive.zip> <path…>  — create a zip archive.

    Each path is added recursively (directories are walked). Entries
    are deflated.
    """
    if len(argv) < 2:
        print(f"{RED}zip:{RESET} usage: zip <archive.zip> <path…>")
        return 1
    import zipfile
    out = os.path.expanduser(argv[0])
    inputs = [os.path.expanduser(p) for p in argv[1:]]
    try:
        import zlib  # noqa: F401 — deflate needs it
        comp = zipfile.ZIP_DEFLATED
    except ImportError:
        comp = zipfile.ZIP_STORED
    added = 0
    rc = 0
    try:
        with zipfile.ZipFile(out, "w", compression=comp) as zf:
            for src in inputs:
                if not os.path.exists(src):
                    print(f"{YLW}zip:{RESET} skip (not found) {src}")
                    rc = 1
                    continue
                if os.path.isfile(src):
                    arcname = os.path.basename(src)
                    zf.write(src, arcname)
                    added += 1
                    print(f"  + {arcname}  {DIM}{_human_bytes(os.path.getsize(src))}{RESET}")
                else:
                    base = os.path.dirname(os.path.abspath(src)) + os.sep
                    for root, _, files in os.walk(src):
                        for f in files:
                            full = os.path.join(root, f)
                            if os.path.abspath(full) == os.path.abspath(out):
                                continue   # never zip the archive into itself
                            arc = os.path.relpath(os.path.abspath(full), base)
                            zf.write(full, arc)
                            added += 1
                            print(f"  + {arc}  {DIM}{_human_bytes(os.path.getsize(full))}{RESET}")
    except OSError as e:
        print(f"{RED}zip:{RESET} {e}")
        return 1
    print(f"{GRN}wrote{RESET} {out}  ({added} entries, "
          f"{_human_bytes(os.path.getsize(out))})")
    return rc


@builtin("unzip")
def _unzip(sh: _Shell, argv: List[str]):
    """unzip [-l] [-d DIR] <archive.zip>  — extract or list a zip.

    Flags:
        -l         list contents instead of extracting
        -d DIR     extract into DIR (default: current directory)
    """
    if not argv:
        print(f"{RED}unzip:{RESET} usage: unzip [-l] [-d DIR] <archive.zip>")
        return 1
    import zipfile
    list_only, dest = False, "."
    args = list(argv)
    while args and args[0].startswith("-"):
        flag = args.pop(0)
        if flag == "-l":
            list_only = True
        elif flag == "-d" and args:
            dest = args.pop(0)
        else:
            print(f"{RED}unzip:{RESET} unknown flag {flag!r}")
            return 1
    # `unzip a.zip -d out`, flags after the archive
    if len(args) >= 3 and args[1] == "-d":
        dest = args[2]
        args = args[:1]
    if not args:
        print(f"{RED}unzip:{RESET} no archive given")
        return 1
    src = os.path.expanduser(args[0])
    try:
        with zipfile.ZipFile(src) as zf:
            if list_only:
                print(f"{BOLD}Length{RESET}      {BOLD}Date{RESET}              {BOLD}Name{RESET}")
                total = 0
                for info in zf.infolist():
                    dt = "%04d-%02d-%02d %02d:%02d" % info.date_time[:5]
                    print(f"{info.file_size:>9}  {dt}  {info.filename}")
                    total += info.file_size
                print(f"{DIM}{'-' * 9}{RESET}")
                print(f"{total:>9}  {DIM}({len(zf.infolist())} files){RESET}")
                return 0
            os.makedirs(os.path.expanduser(dest), exist_ok=True)
            count = 0
            for info in zf.infolist():
                zf.extract(info, os.path.expanduser(dest))
                count += 1
                print(f"  ↳ {info.filename}")
            print(f"{GRN}extracted{RESET} {count} entries into {dest}")
    except (OSError, zipfile.BadZipFile) as e:
        print(f"{RED}unzip:{RESET} {e}")
        return 1
    return 0


def _extract_tar(tf, dest: str) -> None:
    try:
        tf.extractall(dest, filter="data")     # refuses absolute and ../ paths
    except TypeError:
        tf.extractall(dest)


@builtin("tar")
def _tar(sh: _Shell, argv: List[str]):
    """tar -c|-x|-t [-z|-j|-J] [-f FILE] [-C DIR] [path…]

    Subset of tar(1) covering the common cases:
        tar -czf out.tar.gz dir1 dir2     # create gzipped
        tar -xzf in.tar.gz                # extract gzipped
        tar -tf  in.tar                   # list contents
        tar -xf  in.tar -C target/        # extract to a directory

    `-j` selects bzip2 and `-J` xz; default is uncompressed. `-C DIR`
    changes the extraction destination.
    """
    if not argv:
        print(f"{RED}tar:{RESET} usage: tar -c|-x|-t [-z|-j|-J] [-f FILE] [paths…]")
        return 1
    import tarfile
    mode_op = None       # 'c', 'x', or 't'
    compress = ""        # '', 'gz', 'bz2' or 'xz'
    archive = None
    chdir = None
    paths: List[str] = []

    args = list(argv)
    # Allow combined flags: tar -czf foo.tgz src/   (parses c, z, f)
    if args and args[0].startswith("-") and len(args[0]) > 2 and not args[0].startswith("--"):
        combined = args.pop(0)[1:]
        for ch in combined:
            if ch in "cxt":
                mode_op = ch
            elif ch == "z":
                compress = "gz"
            elif ch == "j":
                compress = "bz2"
            elif ch == "J":
                compress = "xz"
            elif ch == "f":
                if args:
                    archive = args.pop(0)
                else:
                    print(f"{RED}tar:{RESET} -f needs a filename")
                    return 1
            elif ch == "v":
                pass
            else:
                print(f"{RED}tar:{RESET} unknown flag char {ch!r}")
                return 1
    while args and args[0].startswith("-"):
        flag = args.pop(0)
        if flag in ("-c", "-x", "-t"):
            mode_op = flag[1]
        elif flag == "-z":
            compress = "gz"
        elif flag == "-j":
            compress = "bz2"
        elif flag == "-J":
            compress = "xz"
        elif flag == "-f" and args:
            archive = args.pop(0)
        elif flag == "-C" and args:
            chdir = args.pop(0)
        elif flag == "-v":
            pass
        else:
            print(f"{RED}tar:{RESET} unknown flag {flag!r}")
            return 1
    # -C given after the paths
    while "-C" in args:
        i = args.index("-C")
        if i + 1 >= len(args):
            print(f"{RED}tar:{RESET} -C needs a directory")
            return 1
        chdir = args[i + 1]
        del args[i:i + 2]
    paths.extend(args)

    if mode_op is None:
        print(f"{RED}tar:{RESET} need one of -c, -x, -t")
        return 1
    if archive is None:
        print(f"{RED}tar:{RESET} no archive (-f) given")
        return 1
    archive = os.path.expanduser(archive)
    suffix = {"": "", "gz": ":gz", "bz2": ":bz2", "xz": ":xz"}[compress]

    rc = 0
    try:
        if mode_op == "c":
            if not paths:
                print(f"{RED}tar:{RESET} no input files for create")
                return 1
            with tarfile.open(archive, f"w{suffix}") as tf:
                for p in paths:
                    p = os.path.expanduser(p)
                    if not os.path.exists(p):
                        print(f"{YLW}tar:{RESET} skip (not found) {p}")
                        rc = 1
                        continue
                    tf.add(p, arcname=os.path.basename(p.rstrip(os.sep)))
                    print(f"  + {p}")
            print(f"{GRN}wrote{RESET} {archive}  ({_human_bytes(os.path.getsize(archive))})")
        elif mode_op == "x":
            with tarfile.open(archive, f"r{suffix}") as tf:
                dest = os.path.expanduser(chdir) if chdir else "."
                _extract_tar(tf, dest)
                print(f"{GRN}extracted{RESET} into {dest}")
        elif mode_op == "t":
            with tarfile.open(archive, f"r{suffix}") as tf:
                for m in tf.getmembers():
                    print(f"  {m.name}  {DIM}{_human_bytes(m.size)}{RESET}")
    except (OSError, tarfile.TarError) as e:
        print(f"{RED}tar:{RESET} {e}")
        return 1
    return rc


@builtin("gzip")
def _gzip_cmd(sh: _Shell, argv: List[str]):
    """gzip <file>  — compress a file in place; output is <file>.gz."""
    if not argv:
        print(f"{RED}gzip:{RESET} usage: gzip <file>")
        return 1
    import gzip
    src = os.path.expanduser(argv[0])
    if not os.path.isfile(src):
        print(f"{RED}gzip:{RESET} no such file: {src}")
        return 1
    dst = src + ".gz"
    try:
        with open(src, "rb") as fi, gzip.open(dst, "wb", compresslevel=6) as fo:
            shutil.copyfileobj(fi, fo, 1024 * 1024)
        os.remove(src)
        print(f"{GRN}gzipped{RESET} {src} → {dst}  "
              f"({_human_bytes(os.path.getsize(dst))})")
    except OSError as e:
        print(f"{RED}gzip:{RESET} {e}")
        return 1
    return 0


@builtin("gunzip")
def _gunzip_cmd(sh: _Shell, argv: List[str]):
    """gunzip <file.gz>  — decompress a .gz file; restores the original."""
    if not argv:
        print(f"{RED}gunzip:{RESET} usage: gunzip <file.gz>")
        return 1
    import gzip
    src = os.path.expanduser(argv[0])
    if not src.endswith(".gz") or not os.path.isfile(src):
        print(f"{RED}gunzip:{RESET} expected an existing *.gz file")
        return 1
    dst = src[:-3]
    try:
        with gzip.open(src, "rb") as fi, open(dst, "wb") as fo:
            shutil.copyfileobj(fi, fo, 1024 * 1024)
        os.remove(src)
        print(f"{GRN}gunzipped{RESET} {src} → {dst}  "
              f"({_human_bytes(os.path.getsize(dst))})")
    except (OSError, EOFError, gzip.BadGzipFile) as e:
        try:
            os.remove(dst)   # don't leave half a file behind
        except OSError:
            pass
        print(f"{RED}gunzip:{RESET} {e}")
        return 1
    return 0


@builtin("extract")
def _extract(sh: _Shell, argv: List[str]):
    """extract <archive> [-oDIR]  — auto-detect & unpack a supported archive.

    One command for every format Blender Local can read: .zip
    (.whl/.jar/.egg) .tar .tar.gz/.tgz .tar.bz2 .tar.xz .gz .bz2 .xz.
    Detection is by magic bytes (with an extension fallback), so the right
    tool is chosen even when the extension is wrong or missing.

    RAR, 7z and disk images are rejected: the standard library has no
    decoder for them.
        extract foo.tar.gz            unpack into the current directory
        extract foo.zip -oOUT         unpack into OUT/
    """
    if not argv or _is_help_tok(argv[0]):
        print("extract <archive> [-oDIR]  — .zip .tar(.gz/.bz2/.xz) .gz .bz2 .xz")
        return 0 if argv else 1
    dest = "."
    rest: List[str] = []
    for a in argv:
        if a.startswith("-o") and len(a) > 2:
            dest = a[2:]
        elif a in ("-o", "-y", "-r"):          # accepted-and-ignored
            pass
        else:
            rest.append(a)
    if not rest:
        print(f"{RED}extract:{RESET} no archive given")
        return 1
    path = os.path.expanduser(rest[0])
    if not os.path.exists(path):
        print(f"{RED}extract:{RESET} not found: {rest[0]}")
        return 1
    dest = os.path.expanduser(dest)
    low = path.lower()
    try:
        with open(path, "rb") as fh:
            magic = fh.read(8)
    except OSError as e:
        print(f"{RED}extract:{RESET} {e}")
        return 1

    try:
        # RAR — proprietary compression, no decoder available offline.
        if magic[:4] == b"Rar!" or low.endswith(".rar"):
            print(f"{RED}extract:{RESET} RAR isn't supported — its compression is "
                  "proprietary and unavailable offline. Re-pack as .zip or .tar.gz.")
            return 1

        # 7z / ISO / UDF — no standard-library reader.
        if magic[:6] == b"7z\xbc\xaf\x27\x1c" or low.endswith((".7z", ".iso", ".udf")):
            print(f"{RED}extract:{RESET} 7z and disk images aren't supported in "
                  "Blender Local. Re-pack as .zip or .tar.gz.")
            return 1

        os.makedirs(dest, exist_ok=True)

        # ZIP family (zip, wheel, jar, egg)
        if magic[:2] == b"PK" or low.endswith((".zip", ".whl", ".jar", ".egg")):
            import zipfile
            with zipfile.ZipFile(path) as zf:
                zf.extractall(dest)
                n = len(zf.namelist())
            print(f"{GRN}extracted{RESET} {n} entries into {dest}")
            return 0

        # TAR + compressed tar (tarfile auto-detects gz/bz2/xz itself).
        import tarfile
        if tarfile.is_tarfile(path) or low.endswith(
                (".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tbz", ".tar.xz", ".txz")):
            with tarfile.open(path, "r:*") as tf:
                _extract_tar(tf, dest)
                n = len(tf.getnames())
            print(f"{GRN}extracted{RESET} {n} entries into {dest}")
            return 0

        # Single-stream compressors → one decompressed output file.
        import bz2 as _bz2
        import gzip as _gz
        import lzma as _xz
        pick = None
        if magic[:2] == b"\x1f\x8b" or low.endswith(".gz"):
            pick, suf, opn = "gzip", ".gz", _gz.open
        elif magic[:3] == b"BZh" or low.endswith(".bz2"):
            pick, suf, opn = "bzip2", ".bz2", _bz2.open
        elif magic[:6] == b"\xfd7zXZ\x00" or low.endswith(".xz"):
            pick, suf, opn = "xz", ".xz", _xz.open
        if pick:
            stem = os.path.basename(rest[0])
            stem = stem[:-len(suf)] if stem.lower().endswith(suf) else stem
            out = os.path.join(dest, stem or "out.bin")
            with opn(path, "rb") as src, open(out, "wb") as dst:
                shutil.copyfileobj(src, dst)
            print(f"{GRN}extracted{RESET} {out}")
            return 0

        print(f"{RED}extract:{RESET} unrecognized archive format: {rest[0]}")
        return 1
    except Exception as e:
        print(f"{RED}extract:{RESET} {e}")
        return 1


# ── Python ────────────────────────────────────────────────────────

# Flags accepted and ignored because they don't apply to an in-process
# interpreter, though scripts and tooling still pass them.
_PY_IGNORED_FLAGS = {"-u", "-B", "-E", "-I", "-S", "-s", "-q",
                     "-O", "-OO", "-b", "-bb"}


@builtin("python")
@builtin("python3")
def _python(sh: _Shell, argv: List[str]):
    """Run a .py file, a -c snippet, or query the interpreter.

    Flags supported:
      -V, --version        → "Python X.Y.Z"
      -VV                  → full sys.version (build info, compiler, date)
      -c "<code>"          → execute the code string
      -m <module> [args…]  → run module as __main__
      -h, --help           → this help
      <file.py> [args…]    → run script
    Bare `python` with no args shows the version banner. (No interactive
    REPL — this console IS the Python REPL; type Python at the prompt.)"""
    # Version flags — accept before any other processing.
    if argv and argv[0] in ("-V", "--version"):
        print(f"Python {sys.version.split()[0]}")
        return 0
    if argv and argv[0] == "-VV":
        print(sys.version)
        return 0

    # Bare `python` — show banner. The console itself is Python.
    if not argv:
        print(f"Python {sys.version.split()[0]} (in-process, "
              f"{sys.implementation.name})")
        print(f"{DIM}  This console is already Python — type Python at the "
              f"prompt and it runs.{RESET}")
        print(f"{DIM}  `python <file.py>`, `python -c \"<code>\"`, "
              f"or `python --help` for more.{RESET}")
        return 0

    if _is_help_tok(argv[0]):
        print("usage: python [flag] <file.py> [arg …]")
        print("           | python -c \"<code>\" [arg …]")
        print("           | python -m <module> [arg …]")
        print()
        print("flags:")
        print("  -V, --version        print version and exit")
        print("  -VV                  verbose version (build info + compiler)")
        print("  -c <cmd>             run a single command")
        print("  -m <mod>             run a module as __main__")
        print("  -h, --help           this help")
        print()
        print(f"{DIM}Note: this is the in-process interpreter — the console")
        print(f"itself is Python. No -i, -O, -S etc. (they don't apply).{RESET}")
        return 0

    if argv[0] == "-c":
        if len(argv) < 2:
            print(f"{RED}python -c:{RESET} expected argument")
            return 2
        # Real Python: `python -c "code" arg1 arg2` exposes args as
        # sys.argv[0]="-c", sys.argv[1:]=["arg1", "arg2"].
        return _run_python("code", argv[1], ["-c", *argv[2:]])

    if argv[0] == "-m":
        if len(argv) < 2:
            print(f"{RED}python -m:{RESET} expected module name")
            return 2
        return _run_python("module", argv[1], [argv[1], *argv[2:]])

    if argv[0] in _PY_IGNORED_FLAGS:
        return _python(sh, argv[1:])
    if argv[0] == "-i":
        print(f"{RED}python -i:{RESET} interactive mode unavailable — "
              f"the console already is the REPL.")
        return 2
    if argv[0].startswith("-"):
        print(f"{RED}python:{RESET} unsupported flag {argv[0]!r}. "
              f"See `python --help`.")
        return 2

    script = os.path.expanduser(argv[0])
    if not os.path.isfile(script):
        print(f"{RED}python:{RESET} no such file: {script}")
        return 2
    return _run_python("path", script, [script, *argv[1:]])


def _run_python(kind: str, target: str, new_argv: List[str]) -> int:
    """Run a script file, module or code string as __main__ with sys.argv
    set, then put sys.argv, sys.stdin and sys.path back."""
    import builtins
    import gc
    import runpy

    old_argv = sys.argv[:]
    old_stdin = sys.stdin
    added_path = None
    sys.argv = list(new_argv)
    sys.stdin = _Fd0Reader()
    if kind == "path":
        folder = os.path.dirname(os.path.abspath(target))
        if folder not in sys.path:
            # At the end, not the front: a script saved as bpy.py must not
            # shadow the real bpy for itself or anything it imports.
            sys.path.append(folder)
            added_path = folder
    rc = 0
    try:
        if kind == "path":
            runpy.run_path(target, run_name="__main__")
        elif kind == "module":
            runpy.run_module(target, run_name="__main__", alter_sys=True)
        else:
            code = compile(target, "<string>", "exec")
            exec(code, {"__name__": "__main__", "__builtins__": builtins})
    except SystemExit as e:
        # Show the exit code only if non-zero — keep output clean on success
        if e.code is not None and not isinstance(e.code, int):
            print(e.code, file=sys.stderr)
        rc = e.code if isinstance(e.code, int) else (1 if e.code else 0)
        if rc:
            print(f"{DIM}[exit {rc}]{RESET}")
    except KeyboardInterrupt:
        raise
    except BaseException as exc:
        print(f"{RED}[shell] {type(exc).__name__}: {exc}{RESET}", file=sys.stderr, flush=True)
        _print_script_traceback(exc, target if kind == "path" else None)
        rc = 1
    finally:
        sys.stdin = old_stdin
        sys.argv = old_argv
        if added_path is not None:
            try:
                sys.path.remove(added_path)
            except ValueError:
                pass
        # One long-lived interpreter: release what the run left in cycles.
        gc.collect()
    return rc


def _print_script_traceback(exc: BaseException, script: Optional[str]) -> None:
    """The traceback from the script's first frame on, without the frames
    of this module and runpy that started it."""
    try:
        te = traceback.TracebackException.from_exception(exc)
        frames = list(te.stack)
        start = None
        if script:
            want = os.path.realpath(script)
            for i, frame in enumerate(frames):
                try:
                    if os.path.realpath(frame.filename) == want:
                        start = i
                        break
                except (OSError, ValueError):
                    continue
        if start is None:
            here = os.path.realpath(__file__)
            start = 0
            for frame in frames:
                name = frame.filename or ""
                if name.endswith("runpy.py") or "runpy" in name or os.path.realpath(name) == here:
                    start += 1
                else:
                    break
        te.stack = traceback.StackSummary.from_list(frames[start:])
        sys.stderr.write("".join(te.format()))
    except Exception:
        traceback.print_exception(exc)


# ---------------------------------------------------------------------------
# Entry points

_initialized = False

# Where the Scripting tab keeps scripts: ScriptDocument.directory is
# Documents/Scripts, so commands start beside them.
_WORK_FOLDER = os.path.join("Documents", "Scripts")


def init() -> None:
    """Move to the app's working folder — ~/Documents/Scripts, created if
    missing, or ~/Documents if that can't be made. Only the first call does
    anything, and it never raises."""
    global _initialized
    if _initialized:
        return
    _initialized = True
    try:
        home = os.path.expanduser("~")
        for folder in (os.path.join(home, _WORK_FOLDER), os.path.join(home, "Documents")):
            try:
                os.makedirs(folder, exist_ok=True)
                os.chdir(folder)
                os.environ["PWD"] = os.getcwd()
                return
            except OSError:
                continue
    except Exception:
        pass


def _report_interrupt() -> int:
    _restore_screen()
    try:
        print(f"\n{YLW}^C{RESET}")
    except BaseException:
        pass
    return 130


def _run_guarded(line_b64, columns, rows) -> int:
    try:
        _set_size(columns, rows)
        init()
        _pushback.clear()   # a new run reads a new pipe
        try:
            line = _base64.b64decode(line_b64, validate=True).decode("utf-8", errors="replace")
        except (ValueError, TypeError) as e:
            print(f"{RED}shell:{RESET} can't read the command line ({e})")
            return 2
        return _status(_SHELL.run_line(line))
    except KeyboardInterrupt:
        return _report_interrupt()
    except SystemExit as e:
        code = e.code
        return code if isinstance(code, int) else (1 if code else 0)
    except BaseException as e:
        _restore_screen()
        try:
            print(f"{RED}{type(e).__name__}:{RESET} {e}")
            traceback.print_exc()
        except BaseException:
            pass
        return 1
    finally:
        _restore_screen()
        try:
            sys.stdout.flush()
        except BaseException:
            pass


def run_b64(line_b64: str, columns: int, rows: int) -> int:
    """Run one console command and return its exit status.

    `line_b64` is base64 of the UTF-8 command line; `columns` and `rows`
    are the terminal's size, exported as COLUMNS and LINES. Never raises:
    errors are printed and give a non-zero status, and an interrupt prints
    ^C and gives 130."""
    try:
        return _run_guarded(line_b64, columns, rows)
    except BaseException:
        # Only a second Stop landing inside the handlers above gets here.
        try:
            _restore_screen()
        except BaseException:
            pass
        return 130


COMMANDS = frozenset(BUILTINS) | frozenset(ALIASES)

_SHELL = _Shell()
