#!/usr/bin/env bash
# geminet_common.sh · shared helpers for the Geminet operating-model automations.
#
# Source it from a script:
#     source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/geminet_common.sh"
#
# Provides:
#   gx_user                 echoes the team member's display name  (e.g. "Kim", "Haris")
#   gx_user_slug            echoes the lowercased first-name slug   (e.g. "kim")
#   gx_log <file> <msg>     timestamped append to a log file (best effort)
#   slack_post <url> <text> post a plain-text message to a Slack incoming webhook
#   gd_safe_sync <repo> <msg> <path...>
#                           concurrency-safe add / commit / pull --rebase / push (whole files)
#   gd_append_and_sync <repo> <relpath> <content> <msg>
#                           append <content> to <relpath> and sync, append done under the lock
#                           after a rebase (for cc-logs and other append-style writers)
#
# Why gd_safe_sync exists
# -----------------------
# AI_COMPANY_OS.md Open item #6: at four-person team scale, naive
# `git add && git commit && git push origin <branch>` from background hooks/crons
# will race. The original Kim-only hook pushed in the background and discarded the
# push result, so a rejected (non-fast-forward) push failed silently and the local
# clone drifted ahead of origin. gd_safe_sync fixes this:
#   - an atomic mkdir mutex serialises writers on one machine (macOS has no flock);
#   - it stages only the caller's explicit paths (callers must pass per-user paths
#     so two people never stage the same file);
#   - it rebases on top of origin and retries the push with backoff;
#   - on exhaustion it is LOUD: non-zero return, a .git/geminet-sync-failed.log line,
#     a .sync-failed marker file, and a Slack alert. Never silent.

# Guard against double-sourcing.
[[ -n "${_GEMINET_COMMON_SH:-}" ]] && return 0
_GEMINET_COMMON_SH=1

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------

# gx_user · the team member's display name, used for cc-logs/<user>/ etc.
# Resolution order (first hit wins):
#   1. $GEMINET_USER          explicit override
#   2. $MEET_RECORDER_NAME    already exported by some sessions
#   3. ~/.geminet/call-recorder/config  (MEET_RECORDER_NAME="...") · set at Call Recorder install
#   4. macOS full name, first word (id -F)
#   5. $USER / whoami
gx_user() {
    if [[ -n "${GEMINET_USER:-}" ]]; then echo "$GEMINET_USER"; return; fi
    if [[ -n "${MEET_RECORDER_NAME:-}" ]]; then echo "$MEET_RECORDER_NAME"; return; fi
    local cfg="$HOME/.geminet/call-recorder/config"
    if [[ -f "$cfg" ]]; then
        local n
        n=$(grep -E '^MEET_RECORDER_NAME=' "$cfg" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
        [[ -n "$n" ]] && { echo "$n"; return; }
    fi
    local full
    full=$(id -F 2>/dev/null | awk '{print $1}')
    [[ -n "$full" ]] && { echo "$full"; return; }
    echo "${USER:-$(whoami)}"
}

# gx_user_slug · lowercased first-name slug (matches the clockify-sync convention).
gx_user_slug() {
    gx_user | tr '[:upper:]' '[:lower:]' | awk '{print $1}'
}

# ---------------------------------------------------------------------------
# Logging + Slack
# ---------------------------------------------------------------------------

gx_log() {
    local file="$1"; shift
    mkdir -p "$(dirname "$file")" 2>/dev/null || true
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "$file" 2>/dev/null || true
}

# slack_post <webhook_url> <text>
# No-op (returns 0) when the URL is empty, so missing creds never break a hook.
slack_post() {
    local url="$1" text="$2"
    [[ -z "$url" ]] && return 0
    local payload
    payload=$(python3 -c 'import json,sys; print(json.dumps({"text": sys.argv[1]}))' "$text" 2>/dev/null) \
        || payload="{\"text\":\"geminet automation\"}"
    curl -s -m 10 -X POST "$url" -H 'Content-type: application/json' -d "$payload" >/dev/null 2>&1 || true
}

# _gx_resolve_channel <#name> -> channel id or "#name" (env override SLACK_CHANNEL_<NAME>).
# NOTE: "general" maps to id C0B0KUVKEMB, which is the channel named "#generals" (the live
# workspace default, is_general=true); the original "#general" (C0B1HQQU7MW) is archived.
_gx_resolve_channel() {
    local n="${1#\#}" envk ov
    envk="SLACK_CHANNEL_$(printf '%s' "$n" | tr '[:lower:]-' '[:upper:]_')"
    ov="${!envk:-}"
    if [[ -n "$ov" ]]; then printf '%s' "$ov"; return; fi
    case "$n" in
        general) printf '%s' "C0B0KUVKEMB" ;;
        *)       printf '#%s' "$n" ;;
    esac
}

# slack_notify <#channel> <text> [webhook]
# Post by channel name using whatever the host has: an explicit webhook, else
# SLACK_WEBHOOK_<CHANNEL>, else SLACK_BOT_TOKEN + chat.postMessage (Betty's mechanism).
slack_notify() {
    local channel="$1" text="$2" webhook="${3:-}" n="${1#\#}" envk token chan payload
    if [[ -z "$webhook" ]]; then
        envk="SLACK_WEBHOOK_$(printf '%s' "$n" | tr '[:lower:]-' '[:upper:]_')"
        webhook="${!envk:-}"
    fi
    if [[ -n "$webhook" ]]; then slack_post "$webhook" "$text"; return 0; fi
    token="${SLACK_BOT_TOKEN:-}"
    [[ -z "$token" ]] && return 0
    chan="$(_gx_resolve_channel "$channel")"
    payload=$(python3 -c 'import json,sys; print(json.dumps({"channel": sys.argv[1], "text": sys.argv[2]}))' "$chan" "$text" 2>/dev/null) || return 0
    curl -s -m 10 -X POST "https://slack.com/api/chat.postMessage" \
        -H "Authorization: Bearer $token" -H 'Content-type: application/json; charset=utf-8' \
        -d "$payload" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Concurrency-safe git sync
# ---------------------------------------------------------------------------

# _gx_mtime <path> · epoch mtime, portable across macOS (BSD stat) and Linux (GNU stat).
_gx_mtime() {
    stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

# _gx_lock <lockdir> [timeout_seconds] · atomic mkdir mutex with stale-lock steal.
_gx_lock() {
    local lockdir="$1" timeout="${2:-180}" waited=0 age
    while ! mkdir "$lockdir" 2>/dev/null; do
        if [[ -d "$lockdir" ]]; then
            age=$(( $(date +%s) - $(_gx_mtime "$lockdir") ))
            if (( age > timeout )); then rm -rf "$lockdir" 2>/dev/null || true; continue; fi
        fi
        sleep 1; waited=$((waited + 1))
        (( waited > timeout )) && return 1
    done
    return 0
}

# _gx_loud_fail <repo> <branch> <msg> · record a sync failure everywhere a human looks.
# Never silent, and never Slack-only: a hire laptop may have no webhook configured, so we
# also write a repo-local log, a user-visible ~/.geminet/sync-failed.log, a .sync-failed
# marker in the repo, and a line on stderr. Slack is the team-channel path on top of that.
_gx_loud_fail() {
    local repo="$1" branch="$2" msg="$3"
    gx_log "$repo/.git/geminet-sync-failed.log" "push FAILED on $branch: $msg"
    gx_log "$HOME/.geminet/sync-failed.log"      "push FAILED to $(basename "$repo") on $branch: $msg"
    : > "$repo/.sync-failed" 2>/dev/null || true
    echo "geminet sync: push to $repo FAILED after retries ($msg). Local clone is ahead of origin; run: git -C $repo pull --rebase && git -C $repo push" >&2
    slack_notify "#ops" ":rotating_light: Geminet sync to $(basename "$repo") failed on $(hostname -s) (push rejected after retries). Local clone is ahead of origin; needs a manual pull/push. Commit message: $msg"
}

# _gx_rebase_push <repo> <branch> <msg> · rebase onto origin and push, with retry.
# Caller must hold the lock and have already committed. Returns 0 on success, 5 on failure.
# Conflict guard: if the tree ever has unmerged paths (rebase or autostash-pop conflict) we
# abort an in-progress rebase and fail loud, so conflict markers are never committed.
_gx_rebase_push() {
    local repo="$1" branch="$2" msg="$3" tries=0 max=5 rc
    local lockdir="$repo/.git/geminet-sync.lock"
    while (( tries < max )); do
        touch "$lockdir" 2>/dev/null || true   # keep our lock fresh so a slow sync is not stolen
        git -C "$repo" pull --rebase --autostash -q origin "$branch" 2>/dev/null; rc=$?
        if [[ -n "$(git -C "$repo" ls-files -u 2>/dev/null)" ]]; then
            git -C "$repo" rebase --abort 2>/dev/null || true   # non-destructive; no checkout of user work
            _gx_loud_fail "$repo" "$branch" "merge conflict during sync; resolve manually: $msg"
            return 5
        fi
        if (( rc == 0 )); then
            git -C "$repo" push -q origin "$branch" 2>/dev/null && return 0
        else
            git -C "$repo" rebase --abort 2>/dev/null || true
        fi
        tries=$((tries + 1))
        sleep $(( tries * 3 ))
    done
    _gx_loud_fail "$repo" "$branch" "$msg"
    return 5
}

# gd_safe_sync <repo> <commit_msg> <path...>  · for callers that WROTE whole files.
# Returns: 0 committed+pushed or nothing to commit · 2 not a git repo · 3 lock timeout
#          · 4 commit failed · 5 push failed after retries (LOUD).
gd_safe_sync() {
    local repo="$1" msg="$2"; shift 2
    local paths=("$@")
    [[ -d "$repo/.git" ]] || { echo "gd_safe_sync: not a git repo: $repo" >&2; return 2; }
    local branch lockdir="$repo/.git/geminet-sync.lock"
    branch=$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null || echo master)
    _gx_lock "$lockdir" 180 || { echo "gd_safe_sync: lock timeout on $repo" >&2; return 3; }

    git -C "$repo" add -- "${paths[@]}" 2>/dev/null || true
    # Consider ONLY our paths, so we never sweep a user's other staged changes.
    if git -C "$repo" diff --cached --quiet -- "${paths[@]}" 2>/dev/null; then
        rm -rf "$lockdir" 2>/dev/null || true
        return 0   # nothing staged in our paths
    fi
    # Commit ONLY our paths (pathspec-scoped); unrelated staged work is left untouched.
    if ! git -C "$repo" commit -q -m "$msg" -- "${paths[@]}" 2>/dev/null; then
        rm -rf "$lockdir" 2>/dev/null || true
        return 4
    fi
    local rc
    _gx_rebase_push "$repo" "$branch" "$msg"; rc=$?
    rm -rf "$lockdir" 2>/dev/null || true
    return "$rc"
}

# gd_append_and_sync <repo> <relpath> <content> <commit_msg>  · for APPEND-style callers
# (e.g. the cc-logs hook). The append happens WHILE the lock is held and AFTER rebasing onto
# origin, so two appenders on the same machine cannot interleave and a rebase can never
# strand or garble a section. Commits only <relpath>. Same return codes as gd_safe_sync.
gd_append_and_sync() {
    local repo="$1" rel="$2" content="$3" msg="$4"
    [[ -d "$repo/.git" ]] || { echo "gd_append_and_sync: not a git repo: $repo" >&2; return 2; }
    local branch lockdir="$repo/.git/geminet-sync.lock"
    branch=$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null || echo master)
    _gx_lock "$lockdir" 180 || { echo "gd_append_and_sync: lock timeout on $repo" >&2; return 3; }

    # Rebase onto origin first, under the lock, so we append to the latest version.
    git -C "$repo" pull --rebase --autostash -q origin "$branch" 2>/dev/null \
        || git -C "$repo" rebase --abort 2>/dev/null || true
    if [[ -n "$(git -C "$repo" ls-files -u 2>/dev/null)" ]]; then
        git -C "$repo" rebase --abort 2>/dev/null || true
        _gx_loud_fail "$repo" "$branch" "merge conflict before append; resolve manually: $msg"
        rm -rf "$lockdir" 2>/dev/null || true
        return 5
    fi

    mkdir -p "$(dirname "$repo/$rel")" 2>/dev/null || true
    printf '%s' "$content" >> "$repo/$rel" || { rm -rf "$lockdir" 2>/dev/null || true; return 4; }

    git -C "$repo" add -- "$rel" 2>/dev/null || true
    if git -C "$repo" diff --cached --quiet -- "$rel" 2>/dev/null; then
        rm -rf "$lockdir" 2>/dev/null || true
        return 0
    fi
    if ! git -C "$repo" commit -q -m "$msg" -- "$rel" 2>/dev/null; then
        rm -rf "$lockdir" 2>/dev/null || true
        return 4
    fi
    local rc
    _gx_rebase_push "$repo" "$branch" "$msg"; rc=$?
    rm -rf "$lockdir" 2>/dev/null || true
    return "$rc"
}
