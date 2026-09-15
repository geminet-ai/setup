#!/usr/bin/env bash
# Geminet new hire setup script
# Run once on a new Apple Silicon Mac (M1+, macOS 13+)
# Prerequisites: VoiceInk installed, 1Password items saved (see onboarding guide)

set -euo pipefail

BOLD=$(tput bold 2>/dev/null || echo "")
RESET=$(tput sgr0 2>/dev/null || echo "")
GREEN=$(tput setaf 2 2>/dev/null || echo "")
RED=$(tput setaf 1 2>/dev/null || echo "")
BLUE=$(tput setaf 4 2>/dev/null || echo "")

step() { echo "${BOLD}${BLUE}==> $1${RESET}"; }
ok()   { echo "${GREEN}    ok: $1${RESET}"; }
fail() { echo "${RED}    ERROR: $1${RESET}"; exit 1; }
warn() { echo "${RED}    WARNING: $1${RESET}"; }

echo ""
echo "${BOLD}Geminet setup${RESET}"
echo "--------------------------------------------"
echo ""

# -- 0. Hardware check --
ARCH=$(uname -m)
if [[ "$ARCH" != "arm64" ]]; then
  fail "Apple Silicon required (M1 or later). This machine reports: $ARCH"
fi
ok "Apple Silicon confirmed"

# -- 1. FileVault --
step "FileVault"
FVSTATUS=$(fdesetup status 2>/dev/null || echo "unknown")
if [[ "$FVSTATUS" == *"FileVault is On"* ]]; then
  ok "FileVault is on"
else
  warn "FileVault is off. Enable it: System Settings > Privacy & Security > FileVault"
  warn "Call Recorder requires FileVault. Enable it and reboot before continuing."
  read -rp "    Press Enter to continue anyway (setup will complete but Call Recorder will fail)..."
fi

# -- 2. Xcode Command Line Tools --
step "Xcode Command Line Tools"
if xcode-select -p &>/dev/null; then
  ok "Xcode CLT already installed"
else
  echo "    Installing Xcode Command Line Tools..."
  xcode-select --install
  echo "    A system dialog appeared. Complete the install, then re-run this script."
  exit 0
fi

# -- 3. Homebrew --
step "Homebrew"
if command -v brew &>/dev/null; then
  ok "Homebrew already installed"
else
  echo "    Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Add brew to PATH for Apple Silicon
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi
brew install pandoc --quiet 2>/dev/null && ok "pandoc installed" || ok "pandoc already present"

# -- 4. GitHub SSH key --
step "GitHub SSH key"
SSH_KEY=~/.ssh/id_ed25519
if [[ -f "$SSH_KEY" ]]; then
  ok "SSH key already exists at $SSH_KEY"
else
  ssh-keygen -t ed25519 -C "$(whoami)@geminet" -f "$SSH_KEY" -N ""
  echo ""
  echo "    ${BOLD}Add this public key to your GitHub account:${RESET}"
  echo "    github.com > Settings > SSH and GPG keys > New SSH key"
  echo ""
  cat "${SSH_KEY}.pub"
  echo ""
  read -rp "    Press Enter once you have added the key to GitHub..."
fi

# -- 5. geminet-docs --
step "geminet-docs"
if [[ -d ~/geminet-docs ]]; then
  ok "Already cloned"
else
  git clone git@github.com:geminet-ai/docs.git ~/geminet-docs
  ok "Cloned to ~/geminet-docs"
fi

# -- 6. Node.js + Claude Code --
step "Node.js + Claude Code"
if ! command -v node &>/dev/null; then
  brew install node --quiet
fi
if command -v claude &>/dev/null; then
  ok "Claude Code already installed"
else
  npm install -g @anthropic-ai/claude-code
  ok "Claude Code installed"
fi

# -- 7. agent-skills --
step "agent-skills (Addy Osmani)"
if [[ -d ~/.claude/skills/agent-skills ]]; then
  ok "Already installed"
else
  mkdir -p ~/.claude/skills
  git clone https://github.com/addyosmani/agent-skills.git ~/.claude/skills/agent-skills
  ok "Installed to ~/.claude/skills/agent-skills"
fi

# -- 7b. audit skill (Geminet) --
# The /audit procedure lives in geminet-docs so `git pull` updates it. Symlink rather than copy,
# so there is exactly one source of truth on disk and it cannot drift.
step "audit skill"
if [[ -L ~/.claude/skills/audit ]]; then
  ok "Already linked"
elif [[ -e ~/.claude/skills/audit ]]; then
  warn "~/.claude/skills/audit exists and is not a symlink; leaving it alone"
elif [[ -d ~/geminet-docs/skills/audit ]]; then
  mkdir -p ~/.claude/skills
  ln -s ~/geminet-docs/skills/audit ~/.claude/skills/audit
  ok "Linked to ~/geminet-docs/skills/audit"
else
  warn "~/geminet-docs/skills/audit not found; pull geminet-docs, then re-run this script"
fi

# -- 7c. OpenRouter API key (audit skill's non-Claude engines) --
# Lets your laptop run audit's full engine set (GLM, Grok, Gemini, Kimi), not just the free
# Claude auditor. NOT required: without it, audit still runs with the Claude auditor alone and
# reports the missing engines under Coverage, so a missing key warns and continues, never aborts.
step "OpenRouter API key"
ENV_FILE=~/.env
touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
if grep -q '^OPENROUTER_API_KEY=' "$ENV_FILE" 2>/dev/null; then
  ok "already set in ~/.env"
else
  warn "OPENROUTER_API_KEY not set yet."
  warn "If Kim sent you a 1Password link for it, open the link, copy the key, and paste it below."
  warn "If you don't have one yet, ask Kim -- not everyone needs this on day one."
  if [[ -t 0 ]]; then
    read -rsp "    Paste the key now, then press Enter (or press Enter to skip and add it later): " OR_KEY
    echo ""
    if [[ -n "$OR_KEY" ]]; then
      echo "OPENROUTER_API_KEY=$OR_KEY" >> "$ENV_FILE"
      ok "saved to ~/.env"
    else
      warn "skipped. audit still runs (Claude auditor only) until you add the key."
    fi
  else
    warn "audit still runs (Claude auditor only) until you add the key."
  fi
fi

# -- 8. Call Recorder --
step "Call Recorder"
# The submit key lets your laptop publish transcripts to Betty. It is NOT required to install
# or use the recorder: without it, recording and local transcription work and transcripts
# queue locally until the key is in place. So a missing key warns and continues (never aborts).
KEY=~/.geminet/call-recorder/id_geminet_recorder
mkdir -p ~/.geminet/call-recorder
if [[ -f "$KEY" ]]; then
  chmod 600 "$KEY"
  ok "submit key present"
else
  warn "Call Recorder submit key not found yet."
  warn "Open the 1Password link Kim sent ('Call Recorder Key'), copy the key, and save it to:"
  warn "  $KEY"
  if [[ -t 0 ]]; then
    echo "    Paste the key now, then press Ctrl-D (or just press Ctrl-D to skip and add it later):"
    cat > "$KEY" || true
    if [[ -s "$KEY" ]]; then
      chmod 600 "$KEY"; ok "submit key saved"
    else
      rm -f "$KEY"; warn "skipped. Recording still works; transcripts queue locally until you add the key."
    fi
  else
    warn "Recording still works; transcripts queue locally until you add the key."
  fi
fi

CR_APP=/Applications/CallRecorder.app
if [[ -d "$CR_APP" ]]; then
  ok "Call Recorder already installed"
else
  TMP=$(mktemp -d)
  git clone git@github.com:geminet-ai/call-recorder.git "$TMP/call-recorder"
  cd "$TMP/call-recorder" && bash install.sh
  cd - > /dev/null
  ok "Call Recorder installed"
fi

# -- 9. cc-logs Stop Hook --
# Auto-commits a session summary to geminet-docs/cc-logs/<you>/ at the end of each
# Claude Code session in a Geminet dir. Runs after Call Recorder so it reuses the name
# you set there. Opt-out-able; never captures personal or IMOLU/financial content.
step "cc-logs Stop Hook"
# Resolve cc-logs-hook/. When run from a local checkout it sits next to this script; when
# run via `bash <(curl ...)` there is no checkout, so clone the repo (SSH is set up by now,
# same pattern as Call Recorder above).
CC_HOOK_DIR=""
SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
if [[ -n "$SETUP_DIR" && -f "$SETUP_DIR/cc-logs-hook/install-cc-hook.sh" ]]; then
  CC_HOOK_DIR="$SETUP_DIR/cc-logs-hook"
else
  TMP_SETUP=$(mktemp -d)
  if git clone --depth 1 -q git@github.com:geminet-ai/setup.git "$TMP_SETUP/setup" 2>/dev/null; then
    CC_HOOK_DIR="$TMP_SETUP/setup/cc-logs-hook"
  fi
fi
if [[ -n "$CC_HOOK_DIR" && -f "$CC_HOOK_DIR/install-cc-hook.sh" ]]; then
  if bash "$CC_HOOK_DIR/install-cc-hook.sh"; then
    ok "cc-logs Stop Hook installed"
  else
    warn "cc-logs hook install reported a problem; run it later: bash $CC_HOOK_DIR/install-cc-hook.sh"
  fi
else
  warn "Could not obtain cc-logs-hook/ (clone failed?); install it later from geminet-ai/setup."
fi

# -- 10. Verify geminet-docs builds --
step "Verifying geminet-docs build"
if python3 ~/geminet-docs/docs/_designs/build-docs.py 2>/dev/null; then
  ok "geminet-docs builds cleanly"
else
  warn "geminet-docs build had errors. Run manually to diagnose:"
  warn "  cd ~/geminet-docs && python3 docs/_designs/build-docs.py"
fi

# -- Done --
echo ""
echo "${BOLD}${GREEN}Setup complete.${RESET}"
echo ""
echo "${BOLD}Two steps left (require browser auth, cannot be scripted):${RESET}"
echo ""
echo "  1. ${BOLD}claude auth${RESET}"
echo "     Authenticates Claude Code with your Geminet Max Team seat."
echo "     Run it, then sign in with the Claude account from your invitation email."
echo ""
echo "  2. ${BOLD}tailscale up${RESET}"
echo "     Joins the Geminet tailnet. Required for Betty access and Call Recorder."
echo "     Run it, then complete sign-in in the browser that opens."
echo ""
echo "Then open VoiceInk and confirm it is running (you should see it in the menu bar)."
echo ""
echo "${BOLD}cc-logs:${RESET} Claude Code sessions in Geminet dirs auto-log a short summary to"
echo "geminet-docs. Opt out this shell with 'export CC_LOG_DISABLE=1', or a project with a"
echo "'CC_LOG: false' line in its CLAUDE.md. Personal and IMOLU/financial content is never captured."
echo ""
