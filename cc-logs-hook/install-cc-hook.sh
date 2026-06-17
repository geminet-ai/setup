#!/usr/bin/env bash
# Idempotent installer for the Geminet team-wide cc-logs Stop Hook.
#
# What it does:
#   1. Ensures ~/.geminet/ exists.
#   2. Copies cc-stop-hook.sh and the shared lib (geminet_common.sh, and
#      geminet_common.py if present) into ~/.geminet/ and makes the hook executable.
#   3. Merges a single "Stop" hook entry into ~/.claude/settings.json using python's
#      json module: it preserves every other key, and does not add a duplicate if the
#      same command is already wired.
#
# Safe to run repeatedly. Works on macOS and Linux (the Ubuntu VM hire) since it only
# needs bash, python3, and cp.
#
# Deployment target: claude-hook (+ referenced by the setup-repo bootstrap).
# This script does NOT load a LaunchAgent, push to any repo, or touch any live tree
# other than the user's own ~/.geminet and ~/.claude.

set -euo pipefail

# Resolve the directory this installer lives in, to find its sibling files.
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GEMINET_DIR="$HOME/.geminet"
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
HOOK_DEST="$GEMINET_DIR/cc-stop-hook.sh"

mkdir -p "$GEMINET_DIR" "$CLAUDE_DIR"

# --- 1 + 2. Copy the hook and the shared lib into ~/.geminet/ ----------------------

if [[ ! -f "$SRC_DIR/cc-stop-hook.sh" ]]; then
    echo "install-cc-hook: cannot find cc-stop-hook.sh next to this installer ($SRC_DIR)" >&2
    exit 1
fi
cp "$SRC_DIR/cc-stop-hook.sh" "$HOOK_DEST"
chmod +x "$HOOK_DEST"

# The shared lib may sit beside the installer (in the staging subdir) or one level up
# in lib/. Try both. The shell lib is mandatory; the python lib is optional here.
copy_lib() {
    local name="$1"
    local required="$2"
    local dest="$GEMINET_DIR/$name"
    local found=""
    for cand in "$SRC_DIR/$name" "$SRC_DIR/../lib/$name" "$SRC_DIR/lib/$name"; do
        if [[ -f "$cand" ]]; then found="$cand"; break; fi
    done
    if [[ -n "$found" ]]; then
        cp "$found" "$dest"
        echo "  copied $name -> $dest"
    elif [[ "$required" == "1" ]]; then
        echo "install-cc-hook: required lib $name not found (looked beside installer and in ../lib)" >&2
        exit 1
    fi
}
copy_lib "geminet_common.sh" 1
copy_lib "geminet_common.py" 0

echo "  copied cc-stop-hook.sh -> $HOOK_DEST"

# --- 3. Merge the Stop hook into ~/.claude/settings.json (idempotent) --------------

HOOK_DEST="$HOOK_DEST" SETTINGS="$SETTINGS" python3 << 'PY'
import json, os, sys

settings_path = os.environ["SETTINGS"]
hook_cmd = os.environ["HOOK_DEST"]

# Load existing settings, preserving everything. Tolerate missing / empty / invalid.
data = {}
if os.path.isfile(settings_path):
    try:
        with open(settings_path) as f:
            raw = f.read().strip()
        data = json.loads(raw) if raw else {}
    except Exception as e:
        print(f"  WARNING: {settings_path} is not valid JSON ({e}); refusing to overwrite.", file=sys.stderr)
        print("  Fix or remove the file, then re-run. No changes made.", file=sys.stderr)
        sys.exit(1)

if not isinstance(data, dict):
    print("  WARNING: settings.json top level is not an object; refusing to touch it.", file=sys.stderr)
    sys.exit(1)

hooks = data.setdefault("hooks", {})
if not isinstance(hooks, dict):
    print("  WARNING: settings.json 'hooks' is not an object; refusing to touch it.", file=sys.stderr)
    sys.exit(1)

stop = hooks.setdefault("Stop", [])
if not isinstance(stop, list):
    print("  WARNING: settings.json hooks.Stop is not a list; refusing to touch it.", file=sys.stderr)
    sys.exit(1)

# Claude Code Stop-hook shape:
#   { "matcher": "", "hooks": [ { "type": "command", "command": "<cmd>" } ] }
# Idempotency: skip if any existing command equals ours OR references the hook script.
def already_present():
    target = os.path.basename(hook_cmd)
    for group in stop:
        if not isinstance(group, dict):
            continue
        for h in group.get("hooks", []) or []:
            if not isinstance(h, dict):
                continue
            cmd = h.get("command", "")
            if cmd == hook_cmd or target in cmd:
                return True
    return False

if already_present():
    print("  Stop hook already wired in settings.json; left unchanged.")
else:
    stop.append({
        "matcher": "",
        "hooks": [{"type": "command", "command": hook_cmd}],
    })
    tmp = settings_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, settings_path)
    print(f"  added Stop hook -> {settings_path}")
PY

echo
echo "cc-logs Stop Hook installed."
echo "Opt out per-session:  export CC_LOG_DISABLE=1"
echo "Opt out per-project:  add a line 'CC_LOG: false' to that project's CLAUDE.md"
echo "Audit your logs:      \$HOME/geminet-docs/cc-logs/<YourName>/"
