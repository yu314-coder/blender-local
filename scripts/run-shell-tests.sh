#!/bin/bash
# The console's shell commands are Python over files, the clock and a handful
# of Mach and sysctl calls that macOS answers the same way iOS does, so they run
# on the Mac: each test gets a throwaway home directory, a pipe on fd 0, and a
# call to run_b64 made the way the app makes it.
set -euo pipefail
cd "$(dirname "$0")/.."

# The newest python3 on this Mac. The app embeds 3.14, so an older interpreter
# would test a different language.
best=""
best_key=0
best_version=""
for candidate in /opt/homebrew/bin/python3* /usr/local/bin/python3*; do
  case "$candidate" in *-config) continue ;; esac
  [ -x "$candidate" ] || continue
  version=$("$candidate" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null) || continue
  IFS=. read -r major minor patch <<<"$version"
  key=$((major * 1000000 + minor * 1000 + patch))
  if [ "$key" -gt "$best_key" ]; then
    best="$candidate"
    best_key=$key
    best_version=$version
  fi
done

if [ -z "$best" ]; then
  echo "No python3 found in /opt/homebrew/bin or /usr/local/bin" >&2
  exit 1
fi
echo "Using $best (Python $best_version)"

# The Swift side decides which lines are commands before it sends them, from its
# own list. A command added to one list and not the other is a line that goes to
# the wrong interpreter, so the two are compared before anything else.
#
# -B: the module sits in Resources/python/site, which is copied into the app;
# a .pyc compiled by the Mac's Python has no business going with it.
"$best" -B - <<'EOF'
import re, sys
sys.path.insert(0, "Resources/python/site")
import _blenderkit_shell as shell
swift = open("Sources/BlenderLocalBridge/ConsoleShell.swift", encoding="utf-8").read()
def names(name):
    body = re.search(r"static let %s: Set<String> = \[(.*?)\]" % name, swift, re.S).group(1)
    return set(re.findall(r'"([^"]+)"', body))
commands, unavailable = names("commands"), names("unavailable")
problems = []
if commands != set(shell.COMMANDS):
    problems.append("the command lists differ: Swift only %s, Python only %s"
                    % (sorted(commands - set(shell.COMMANDS)), sorted(set(shell.COMMANDS) - commands)))
if not unavailable <= set(shell.UNAVAILABLE):
    problems.append("Swift routes names Python does not know: %s"
                    % sorted(unavailable - set(shell.UNAVAILABLE)))
for problem in problems:
    print("  FAIL  " + problem)
if problems:
    sys.exit(1)
print("  PASS  ConsoleShell.swift and _blenderkit_shell.py agree on the commands")
EOF

exec "$best" -B tests/shell/main.py
