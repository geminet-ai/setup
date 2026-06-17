#!/usr/bin/env bash
# Geminet team-wide Claude Code cc-logs Stop Hook.
#
# At the end of a Claude Code session whose cwd is inside an allowlisted Geminet
# working directory, this reads the session transcript (JSONL), extracts the last
# assistant summary plus the list of files touched, appends one timestamped section
# to cc-logs/<DisplayName>/YYYY-MM-DD.md in geminet-docs, syncs it (concurrency-safe),
# and posts a one-line summary to #cc-logs.
#
# This generalizes Kim's original personal hook for the whole team. It is the same
# script for everyone: identity, paths, and Slack are all derived at runtime.
#
# 3-layer scoping (any one of these suppresses capture):
#   1. Per-session env override: CC_LOG_DISABLE=1 skips entirely.
#   2. Path allowlist: only $HOME-relative Geminet dirs are captured. Personal and
#      other-company paths (~/Betty, ~/imolu-pm, Voltela/MeasPipeline) are never seen.
#   3. Per-project CLAUDE.md flag: a line containing "CC_LOG: false" disables for that
#      project.
#
# Fixes vs the original:
#   - Original json.load()'d the whole transcript; Claude Code transcripts are JSONL
#     (one JSON object per line) so it always failed and wrote "no summary extracted"
#     noise. This parses line-by-line from the end.
#   - Original backgrounded a raw "git push" and discarded the result, so a rejected
#     non-fast-forward push failed silently and the clone drifted. This uses
#     gd_safe_sync (lock, rebase, retry, loud-on-failure).
#   - Empty/noise sessions are now skipped entirely (no summary AND no files, or pure
#     short chat with zero tool calls) instead of writing a placeholder line.
#
# Deployed location: ~/.geminet/cc-stop-hook.sh  (installer copies it there).
# Wired as a "Stop" hook in ~/.claude/settings.json by install-cc-hook.sh.

set -uo pipefail

# Layer 1 · per-session override.
[[ "${CC_LOG_DISABLE:-}" == "1" ]] && exit 0

# Load Slack credentials if present (webhook env vars). Missing file is fine.
[[ -f "$HOME/.secrets/slack.env" ]] && source "$HOME/.secrets/slack.env"

# Shared helpers: gx_user, slack_post, gd_append_and_sync. Deployed alongside this hook.
COMMON="$HOME/.geminet/geminet_common.sh"
if [[ -f "$COMMON" ]]; then
    # shellcheck source=/dev/null
    source "$COMMON"
else
    # The lib is mandatory for safe sync. Without it, do nothing rather than risk a
    # racy raw push. Exit 0 so the session is never blocked.
    exit 0
fi

# Read the hook payload (JSON object) from stdin.
INPUT=$(cat)
CWD=$(printf '%s' "$INPUT" | python3 -c "import sys,json
try: d=json.load(sys.stdin); print(d.get('cwd',''))
except Exception: print('')" 2>/dev/null || echo "")
TRANSCRIPT=$(printf '%s' "$INPUT" | python3 -c "import sys,json
try: d=json.load(sys.stdin); print(d.get('transcript_path',''))
except Exception: print('')" 2>/dev/null || echo "")

# If the harness gave us no cwd, fall back to the real cwd.
[[ -z "$CWD" ]] && CWD="$PWD"

# Layer 2 · path allowlist, $HOME-relative so it works on macOS and the Ubuntu VM.
# Allowed Geminet work:
#   - geminet-docs:        team knowledge work
#   - Coding/geminet-code: Geminet engineering monorepo (Mac layout)
#   - geminet-code:        the hire's VM clone at $HOME/geminet-code
#   - .geminet:            Betty automation scripts (dev/testing)
# Never allowed (personal or other-company): ~/Betty, ~/imolu-pm,
# Coding/MeasPipeline*, MainVC2 and other Voltela paths are simply absent here.
ALLOWED=(
    "$HOME/geminet-docs"
    "$HOME/Coding/geminet-code"
    "$HOME/geminet-code"
    "$HOME/.geminet"
)
allowed=false
for p in "${ALLOWED[@]}"; do
    [[ "$CWD" == "$p" || "$CWD" == "$p/"* ]] && { allowed=true; break; }
done
$allowed || exit 0

# Symlink-escape guard: the resolved path must ALSO sit inside an allowed tree, so a symlink
# under an allowed dir that points at ~/imolu-pm (or anywhere else) cannot smuggle private
# work into the team cc-log. Both the raw and the resolved path must pass.
REAL_CWD="$(cd "$CWD" 2>/dev/null && pwd -P || echo "$CWD")"
real_allowed=false
for p in "${ALLOWED[@]}"; do
    rp="$(cd "$p" 2>/dev/null && pwd -P || echo "$p")"
    [[ "$REAL_CWD" == "$rp" || "$REAL_CWD" == "$rp/"* ]] && { real_allowed=true; break; }
done
$real_allowed || exit 0

# Layer 3 · per-project CLAUDE.md opt-out.
[[ -f "$CWD/CLAUDE.md" ]] && grep -q "CC_LOG: false" "$CWD/CLAUDE.md" && exit 0

# Extract summary + files touched from the JSONL transcript in one python pass.
# Output protocol (so bash can split cleanly):
#   line 1: SUMMARY<TAB><text>     (may be empty)
#   line 2: FILES<TAB><comma-separated basenames>  (may be empty)
#   line 3: TOOLS<TAB><integer>    (count of tool_use blocks seen)
#   line 4: IMOLU<TAB><0|1>        (1 if any tool input referenced the private IMOLU repo)
SUMMARY=""
FILES=""
TOOLS=0
IMOLU=0
if [[ -f "$TRANSCRIPT" ]]; then
    PARSED=$(python3 - "$TRANSCRIPT" << 'PY'
import json, os, sys

path = sys.argv[1]
last_assistant_text = ""
files = []          # ordered, deduped
seen = set()
tool_calls = 0
imolu_flag = False  # set if any tool input references the private IMOLU repo

def add_file(fp):
    if not fp or not isinstance(fp, str):
        return
    base = os.path.basename(fp.rstrip("/")) or fp
    if base not in seen:
        seen.add(base)
        files.append(base)

EDIT_TOOLS = {"Write", "Edit", "MultiEdit", "NotebookEdit"}

try:
    with open(path, errors="ignore") as f:
        lines = f.readlines()
except Exception:
    lines = []

# Forward pass: count tool calls and collect touched files (need every line for files).
for line in lines:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    msg = obj.get("message", obj)
    if not isinstance(msg, dict):
        continue
    content = msg.get("content")
    if not isinstance(content, list):
        continue
    for block in content:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "tool_use":
            tool_calls += 1
            name = block.get("name", "")
            inp = block.get("input", {}) or {}
            if name in EDIT_TOOLS:
                add_file(inp.get("file_path") or inp.get("path") or inp.get("notebook_path"))
            # Privacy: flag any tool input string that references the private IMOLU repo.
            for v in inp.values():
                if isinstance(v, str) and "imolu-pm" in v:
                    imolu_flag = True

# Backward pass: last assistant text block (skip tool_result-only / empty messages).
for line in reversed(lines):
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    role = obj.get("type") or obj.get("role")
    msg = obj.get("message", obj)
    if isinstance(msg, dict):
        role = msg.get("role", role)
        content = msg.get("content", "")
    else:
        content = ""
    if role != "assistant":
        continue
    text = ""
    if isinstance(content, list):
        parts = [b.get("text", "") for b in content
                 if isinstance(b, dict) and b.get("type") == "text"]
        text = "\n".join(p for p in parts if p).strip()
    elif isinstance(content, str):
        text = content.strip()
    if len(text) > 20:
        first_para = text.split("\n\n")[0].replace("\n", " ").strip()
        last_assistant_text = first_para[:400]
        break

print("SUMMARY\t" + last_assistant_text.replace("\t", " "))
print("FILES\t" + ", ".join(files))
print("TOOLS\t" + str(tool_calls))
print("IMOLU\t" + ("1" if imolu_flag else "0"))
PY
    )
    SUMMARY=$(printf '%s\n' "$PARSED" | sed -n 's/^SUMMARY\t//p' | head -1)
    FILES=$(printf '%s\n'   "$PARSED" | sed -n 's/^FILES\t//p'   | head -1)
    TOOLS=$(printf '%s\n'   "$PARSED" | sed -n 's/^TOOLS\t//p'   | head -1)
    IMOLU=$(printf '%s\n'   "$PARSED" | sed -n 's/^IMOLU\t//p'   | head -1)
    [[ "$TOOLS" =~ ^[0-9]+$ ]] || TOOLS=0
fi

# Skip noisy/empty sessions.
#   - Nothing to say AND nothing touched -> skip (no placeholder noise).
#   - Pure short chat: zero tool calls and a thin summary -> skip.
if [[ -z "$SUMMARY" && -z "$FILES" ]]; then
    exit 0
fi
if [[ "$TOOLS" -eq 0 && -z "$FILES" && ${#SUMMARY} -lt 200 ]]; then
    exit 0
fi

# Content firewall (defense in depth on top of the cwd allowlist). The allowlist gates the
# directory; this gates the CONTENT we are about to publish to the team-visible cc-log. A
# session legitimately rooted in geminet-docs can still read ~/imolu-pm and restate a private
# figure in its summary. If the session touched the IMOLU repo, or the text we would write
# contains IMOLU / financial / payroll markers, skip the capture entirely. Over-suppression
# is the safe failure mode: the worst case is a session that is simply not auto-logged.
if [[ "$IMOLU" == "1" ]]; then
    exit 0
fi
if printf '%s\n%s' "$SUMMARY" "$FILES" | grep -qiE \
   'imolu-pm|NKBF|NABF|Zuwendung|Stundennachweis|Verwendungsnachweis|lohnabrechnung|bruttogehalt|payroll|salary|(€|EUR)[[:space:]]*[0-9]|[0-9][.,][0-9]{3}[[:space:]]*(€|EUR)'; then
    exit 0
fi

# Target repo. If the clone is missing we cannot log; exit cleanly.
DOCS="$HOME/geminet-docs"
[[ -d "$DOCS/.git" ]] || exit 0

USER_NAME="$(gx_user)"
[[ -z "$USER_NAME" ]] && USER_NAME="unknown"
DATE=$(date '+%Y-%m-%d')
TIME=$(date '+%H:%M')
PROJECT=$(basename "$CWD")
REL="cc-logs/$USER_NAME/$DATE.md"

# Build one timestamped section. New day-files simply start with the first section, matching
# the existing on-disk format (## HH:MM · <project>). Middle-dot, no em-dash (brand rule).
CONTENT="## $TIME · $PROJECT"$'\n\n'
[[ -n "$SUMMARY" ]] && CONTENT+="$SUMMARY"$'\n\n'
[[ -n "$FILES" ]]   && CONTENT+="**Files:** $FILES"$'\n\n'
CONTENT+=$'---\n\n'

# Append + sync atomically under one lock (append happens after a rebase, so concurrent
# sessions on the same machine cannot interleave or strand a section). Loud on failure.
COMMIT_MSG="cc-log $USER_NAME $DATE $TIME ($PROJECT)"
gd_append_and_sync "$DOCS" "$REL" "$CONTENT" "$COMMIT_MSG" || true

# Best-effort Slack one-liner to #cc-logs (webhook if configured, else the bot token).
SHORT="$SUMMARY"
[[ -z "$SHORT" && -n "$FILES" ]] && SHORT="touched: $FILES"
if [[ ${#SHORT} -gt 120 ]]; then SHORT="${SHORT:0:120}…"; fi
slack_notify "#cc-logs" "*$USER_NAME* \`$PROJECT\` · $SHORT"

exit 0
