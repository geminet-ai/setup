#!/usr/bin/env python3
"""geminet_common.py · shared helpers for the Geminet operating-model automations.

Mirrors lib/geminet_common.sh for the Python crons (ADR drafter, coverage check,
Clockify auto-draft). Stdlib only, so it runs in a bare LaunchAgent on Betty.

Key piece: safe_sync() applies AI_COMPANY_OS Open item #6 (concurrent writes at team
scale). It locks, stages only the caller's paths, rebases on origin, retries the push
with backoff, and on exhaustion is LOUD (marker file + Slack alert), never silent.
"""
from __future__ import annotations

import json
import os
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------

def derive_user() -> str:
    """Team member display name. Order: $GEMINET_USER, $MEET_RECORDER_NAME,
    ~/.geminet/call-recorder/config, macOS full name, $USER."""
    for env in ("GEMINET_USER", "MEET_RECORDER_NAME"):
        v = os.environ.get(env)
        if v:
            return v
    cfg = Path.home() / ".geminet" / "call-recorder" / "config"
    if cfg.is_file():
        for line in cfg.read_text(errors="ignore").splitlines():
            if line.startswith("MEET_RECORDER_NAME="):
                v = line.split("=", 1)[1].strip().strip('"').strip("'")
                if v:
                    return v
    try:
        full = subprocess.run(["id", "-F"], capture_output=True, text=True).stdout.strip()
        if full:
            return full.split()[0]
    except Exception:
        pass
    return os.environ.get("USER", "unknown")


def user_slug() -> str:
    return derive_user().lower().split()[0]


# ---------------------------------------------------------------------------
# Slack
# ---------------------------------------------------------------------------

def slack_post(webhook: str | None, text: str) -> bool:
    """Post plain text to a Slack incoming webhook. No-op if webhook is falsy."""
    if not webhook:
        return False
    data = json.dumps({"text": text}).encode()
    req = urllib.request.Request(
        webhook, data=data, headers={"Content-Type": "application/json"}, method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status == 200
    except (urllib.error.URLError, OSError):
        return False


# Known channel IDs (env-overridable via SLACK_CHANNEL_<NAME>). NOTE: the live workspace-default
# channel is named "#generals" (id C0B0KUVKEMB, is_general=true) because the original "#general"
# (C0B1HQQU7MW) is archived. So we map the logical name "general" to the working #generals id.
# Other names fall back to a "#name", which chat.postMessage accepts for public channels the
# bot is a member of (e.g. #decisions; #ops once it is created and betty is invited).
_KNOWN_CHANNELS = {"general": "C0B0KUVKEMB"}


def _resolve_channel(name: str) -> str:
    n = name.lstrip("#")
    return (os.environ.get("SLACK_CHANNEL_" + n.upper().replace("-", "_"))
            or _KNOWN_CHANNELS.get(n) or ("#" + n))


def _slack_bot_post(token: str, channel: str, text: str) -> bool:
    """Post via chat.postMessage with a bot token (the mechanism Betty already uses)."""
    data = json.dumps({"channel": _resolve_channel(channel), "text": text}).encode()
    req = urllib.request.Request(
        "https://slack.com/api/chat.postMessage", data=data,
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return bool(json.loads(resp.read() or b"{}").get("ok"))
    except (urllib.error.URLError, OSError, ValueError):
        return False


def slack_notify(channel: str, text: str, webhook: str | None = None) -> bool:
    """Post to a Slack channel by NAME (e.g. '#general'), using whatever the host has:
       1. an explicit incoming webhook arg, else
       2. a per-channel webhook env SLACK_WEBHOOK_<CHANNEL>, else
       3. SLACK_BOT_TOKEN + chat.postMessage (Betty's existing mechanism).
    Returns False (clean no-op) when nothing is configured."""
    if webhook:
        return slack_post(webhook, text)
    env_key = "SLACK_WEBHOOK_" + channel.lstrip("#").upper().replace("-", "_")
    wh = os.environ.get(env_key)
    if wh:
        return slack_post(wh, text)
    token = os.environ.get("SLACK_BOT_TOKEN")
    if token:
        return _slack_bot_post(token, channel, text)
    return False


# ---------------------------------------------------------------------------
# Concurrency-safe git sync
# ---------------------------------------------------------------------------

def _git(repo: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True, text=True,
    )


def _acquire_lock(lockdir: Path, timeout: int = 180) -> bool:
    waited = 0
    while True:
        try:
            lockdir.mkdir()
            return True
        except FileExistsError:
            try:
                age = time.time() - lockdir.stat().st_mtime
                if age > timeout:
                    subprocess.run(["rm", "-rf", str(lockdir)], check=False)
                    continue
            except OSError:
                pass
            if waited > timeout:
                return False
            time.sleep(1)
            waited += 1


def current_branch(repo: Path) -> str:
    r = _git(repo, "symbolic-ref", "--short", "HEAD")
    return r.stdout.strip() or "master"


def _loud_fail(repo: Path, branch: str, msg: str, ops_webhook: str | None) -> None:
    """Record a sync failure everywhere a human looks (never Slack-only)."""
    ts = time.strftime("%Y-%m-%dT%H:%M:%S")
    try:
        (repo / ".sync-failed").write_text("")
        with open(repo / ".git" / "geminet-sync-failed.log", "a") as f:
            f.write(f"{ts} push FAILED on {branch}: {msg}\n")
    except OSError:
        pass
    try:
        glog = Path.home() / ".geminet" / "sync-failed.log"
        glog.parent.mkdir(parents=True, exist_ok=True)
        with open(glog, "a") as f:
            f.write(f"{ts} push FAILED to {repo.name} on {branch}: {msg}\n")
    except OSError:
        pass
    print(f"geminet sync: push to {repo} FAILED after retries ({msg}); "
          f"local clone ahead of origin, run: git -C {repo} pull --rebase && git -C {repo} push",
          file=__import__("sys").stderr)
    slack_notify(
        "#ops",
        f":rotating_light: Geminet sync to {repo.name} failed (push rejected after retries). "
        f"Local clone ahead of origin; needs manual pull/push. Commit: {msg}",
        webhook=ops_webhook,
    )


def _tree_conflicted(repo: Path) -> bool:
    """True if the working tree has unmerged (conflicted) paths."""
    return bool(_git(repo, "ls-files", "-u").stdout.strip())


def safe_sync(repo: Path, msg: str, *paths: str, ops_webhook: str | None = None) -> int:
    """Concurrency-safe add/commit/pull --rebase/push for the given paths.

    Returns 0 (committed+pushed or nothing to do), or a non-zero code on failure.
    On push exhaustion or a rebase conflict: LOUD via _loud_fail (repo marker + repo log +
    user-visible ~/.geminet/sync-failed.log + stderr + Slack). Never commits conflict markers.
    """
    repo = Path(repo)
    if not (repo / ".git").exists():
        return 2
    branch = current_branch(repo)
    lockdir = repo / ".git" / "geminet-sync.lock"
    if not _acquire_lock(lockdir):
        return 3
    try:
        _git(repo, "add", "--", *paths)
        # Consider ONLY our paths, so we never sweep other staged changes.
        if _git(repo, "diff", "--cached", "--quiet", "--", *paths).returncode == 0:
            return 0  # nothing staged in our paths
        # Commit ONLY our paths (pathspec-scoped); unrelated staged work is left untouched.
        if _git(repo, "commit", "-q", "-m", msg, "--", *paths).returncode != 0:
            return 4
        for attempt in range(1, 6):
            try:
                os.utime(lockdir, None)  # keep our lock fresh so a slow sync is not stolen
            except OSError:
                pass
            pull = _git(repo, "pull", "--rebase", "--autostash", "-q", "origin", branch)
            if _tree_conflicted(repo):
                _git(repo, "rebase", "--abort")  # non-destructive; never checkout user work
                _loud_fail(repo, branch, f"merge conflict during sync; resolve manually: {msg}", ops_webhook)
                return 5
            if pull.returncode == 0:
                if _git(repo, "push", "-q", "origin", branch).returncode == 0:
                    return 0
            else:
                _git(repo, "rebase", "--abort")
            time.sleep(attempt * 3)
        _loud_fail(repo, branch, msg, ops_webhook)
        return 5
    finally:
        subprocess.run(["rm", "-rf", str(lockdir)], check=False)
