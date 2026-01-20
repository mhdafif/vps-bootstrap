#!/usr/bin/env bash
set -euo pipefail

log() { echo -e "\n==> $1"; }
warn() { echo -e "\n[WARN] $1"; }

# ========= LOAD CONFIG =========
if [[ ! -f "./env.conf" ]]; then
  echo "❌ Missing env.conf. Create it first:"
  echo "   cp env.example env.conf && nano env.conf"
  exit 1
fi
# shellcheck disable=SC1091
source ./env.conf

# ========= CHECK ROOT =========
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "❌ Run as root for first-time bootstrap."
  echo "   sudo -i   # then rerun ./setup.sh"
  exit 1
fi

log "Starting VPS bootstrap..."

# ========= UPDATE & UPGRADE =========
log "Updating system packages..."
apt update -y
DEBIAN_FRONTEND=noninteractive apt upgrade -y

# ========= TIMEZONE =========
log "Setting timezone to ${TIMEZONE}..."
timedatectl set-timezone "${TIMEZONE}"

# ========= BASE PACKAGES =========
log "Installing base packages..."
apt install -y \
  openssh-server \
  ufw \
  curl git \
  htop net-tools \
  ca-certificates gnupg lsb-release \
  tmux

# Optional fail2ban
if [[ "${INSTALL_FAIL2BAN:-true}" == "true" ]]; then
  apt install -y fail2ban
fi

# ========= CREATE USER =========
if id "${USERNAME}" &>/dev/null; then
  log "User ${USERNAME} already exists"
else
  log "Creating user ${USERNAME}..."
  adduser --disabled-password --gecos "" "${USERNAME}"
  usermod -aG sudo "${USERNAME}"
fi

# ========= DOCKER =========
if command -v docker &>/dev/null; then
  log "Docker already installed"
else
  log "Installing Docker..."
  curl -fsSL https://get.docker.com | sh
fi
usermod -aG docker "${USERNAME}" || true

# ========= UFW FIREWALL =========
log "Configuring UFW..."
ufw --force reset

if [[ "${ALLOW_SSH_PUBLIC}" == "true" ]]; then
  log "Allowing SSH on port ${SSH_PORT} (public)..."
  ufw allow "${SSH_PORT}/tcp"
else
  warn "Public SSH disabled in UFW. Make sure you have alternative access (console/Tailscale) first."
fi

if [[ "${ALLOW_HTTP}" == "true" ]]; then ufw allow 80/tcp; fi
if [[ "${ALLOW_HTTPS}" == "true" ]]; then ufw allow 443/tcp; fi

ufw --force enable
ufw status verbose || true

# ========= FAIL2BAN =========
if [[ "${INSTALL_FAIL2BAN:-true}" == "true" ]]; then
  log "Enabling Fail2Ban..."
  systemctl enable --now fail2ban
fi

# ========= TAILSCALE =========
if [[ "${INSTALL_TAILSCALE:-true}" == "true" ]]; then
  if command -v tailscale &>/dev/null; then
    log "Tailscale already installed"
  else
    log "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  systemctl enable --now tailscaled || true
fi

# ========= NVM + NODE LTS + PNPM (COREPACK) =========
log "Installing NVM + Node LTS + pnpm (via Corepack) for user ${USERNAME}..."

# 1) Install NVM if missing
su - "${USERNAME}" -c 'if [[ ! -d "$HOME/.nvm" ]]; then
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
fi'

# 2) Install Node LTS + enable pnpm
su - "${USERNAME}" -c '
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1090
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

  nvm install --lts
  nvm use --lts

  # Enable corepack + activate pnpm
  corepack enable
  corepack prepare pnpm@latest --activate

  pnpm -v
'

# 3) Ensure PNPM_HOME is in PATH (so global pnpm binaries work)
BASHRC_PATH="/home/${USERNAME}/.bashrc"
if ! grep -q "PNPM_HOME" "${BASHRC_PATH}"; then
  log "Adding PNPM_HOME to ${BASHRC_PATH}..."
  cat >> "${BASHRC_PATH}" <<'EOF'

# --- pnpm ---
export PNPM_HOME="$HOME/.local/share/pnpm"
case ":$PATH:" in
  *":$PNPM_HOME:"*) ;;
  *) export PATH="$PNPM_HOME:$PATH" ;;
esac
EOF
  chown "${USERNAME}:${USERNAME}" "${BASHRC_PATH}"
fi

# ========= GROK CLI (install via pnpm) =========
if [[ "${INSTALL_GROK_CLI}" == "true" ]]; then
  log "Installing Grok CLI using pnpm..."
  su - "${USERNAME}" -c '
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    nvm use --lts >/dev/null

    corepack enable >/dev/null 2>&1 || true
    corepack prepare pnpm@latest --activate >/dev/null 2>&1 || true

    pnpm add -g @vibe-kit/grok-cli
  '

  # Add Grok env vars
  if ! grep -q "GROK CLI (Z.AI / GLM)" "${BASHRC_PATH}"; then
    log "Adding Grok env vars to ${BASHRC_PATH}..."
    cat >> "${BASHRC_PATH}" <<EOF

# --- GROK CLI (Z.AI / GLM) ---
export GROK_BASE_URL="${GROK_BASE_URL}"
export GROK_MODEL_DEFAULT="${GROK_MODEL}"
EOF
    if [[ -n "${GROK_API_KEY}" ]]; then
      echo "export GROK_API_KEY=\"${GROK_API_KEY}\"" >> "${BASHRC_PATH}"
    else
      warn "GROK_API_KEY is empty. Fill it in env.conf then rerun setup.sh, or export manually before using grok."
    fi
    chown "${USERNAME}:${USERNAME}" "${BASHRC_PATH}"
  else
    log "Grok env snippet already exists in ${BASHRC_PATH}"
  fi

  # Best-effort verify
  su - "${USERNAME}" -c 'command -v grok >/dev/null && grok --help | head -n 5 || true'
fi

# ========= KIRO CLI =========
if [[ "${INSTALL_KIRO_CLI}" == "true" ]]; then
  log "Installing Kiro CLI..."
  su - "${USERNAME}" -c 'curl -fsSL https://cli.kiro.dev/install | bash'
  su - "${USERNAME}" -c 'command -v kiro-cli >/dev/null && kiro-cli --version || true'

  warn "Kiro auth is usually interactive. After login:"
  warn "  kiro-cli login"
fi

# ========= TMUX AUTO-SESSION + 4 PANE LAYOUT =========
log "Setting up tmux auto-session + 4-pane layout..."

# We inject a function that creates a 4-pane layout only when session doesn't exist.
# Panes:
#  - pane 0: WEB_CMD
#  - pane 1: API_CMD
#  - pane 2: COMPOSE_CMD then LOGS_CMD (runs logs)
#  - pane 3: free shell (good for grok/kiro)
TMUX_SNIPPET=$(cat <<'EOF'

# --- Auto tmux session on SSH (with 4-pane layout) ---
__tmux_bootstrap_session() {
  local SESSION="__TMUX_SESSION__"
  local ROOT_DIR="__PROJECT_DIR__"
  local WEB="__WEB_CMD__"
  local API="__API_CMD__"
  local COMPOSE="__COMPOSE_CMD__"
  local LOGS="__LOGS_CMD__"

  # Create session in detached mode if missing
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux new-session -d -s "$SESSION" -c "$ROOT_DIR"

    # Pane 0 (web)
    tmux send-keys -t "$SESSION":0.0 "cd \"$ROOT_DIR\" && $WEB" C-m

    # Split right (pane 1: api)
    tmux split-window -h -t "$SESSION":0 -c "$ROOT_DIR"
    tmux send-keys -t "$SESSION":0.1 "cd \"$ROOT_DIR\" && $API" C-m

    # Split bottom-left (pane 2: compose/logs)
    tmux select-pane -t "$SESSION":0.0
    tmux split-window -v -t "$SESSION":0 -c "$ROOT_DIR"
    tmux send-keys -t "$SESSION":0.2 "cd \"$ROOT_DIR\" && $COMPOSE && $LOGS" C-m

    # Split bottom-right (pane 3: shell, good for grok/kiro)
    tmux select-pane -t "$SESSION":0.1
    tmux split-window -v -t "$SESSION":0 -c "$ROOT_DIR"
    tmux send-keys -t "$SESSION":0.3 "cd \"$ROOT_DIR\"" C-m

    # Make layout tidy
    tmux select-layout -t "$SESSION":0 tiled >/dev/null 2>&1 || true
  fi
}

# Auto attach/create a tmux session when connecting via SSH.
if [[ -z "$TMUX" && -n "$SSH_CONNECTION" && $- == *i* ]]; then
  __tmux_bootstrap_session
  tmux attach -t "__TMUX_SESSION__"
fi
EOF
)

# Replace placeholders with actual values from env.conf
TMUX_SNIPPET="${TMUX_SNIPPET/__TMUX_SESSION__/${TMUX_SESSION}}"
TMUX_SNIPPET="${TMUX_SNIPPET/__PROJECT_DIR__/${PROJECT_DIR}}"
TMUX_SNIPPET="${TMUX_SNIPPET/__WEB_CMD__/${WEB_CMD}}"
TMUX_SNIPPET="${TMUX_SNIPPET/__API_CMD__/${API_CMD}}"
TMUX_SNIPPET="${TMUX_SNIPPET/__COMPOSE_CMD__/${COMPOSE_CMD}}"
TMUX_SNIPPET="${TMUX_SNIPPET/__LOGS_CMD__/${LOGS_CMD}}"

if grep -q "Auto tmux session on SSH (with 4-pane layout)" "${BASHRC_PATH}"; then
  log "tmux auto-session snippet already exists in ${BASHRC_PATH}"
else
  printf "\n%s\n" "${TMUX_SNIPPET}" >> "${BASHRC_PATH}"
  chown "${USERNAME}:${USERNAME}" "${BASHRC_PATH}"
  log "Added tmux auto-session + 4-pane layout snippet to ${BASHRC_PATH}"
fi

log "Bootstrap completed ✅"

echo
echo "Next steps:"
echo "1) Login: ssh ${USERNAME}@<VPS_IP>  (or via Tailscale IP)"
echo "2) Create project dir if not exists:"
echo "   mkdir -p ${PROJECT_DIR} && cd ${PROJECT_DIR}"
echo "3) If using Tailscale:"
echo "   sudo tailscale up"
echo "4) For Grok CLI, ensure GROK_API_KEY is set (env.conf or export) then:"
echo "   grok --model \"${GROK_MODEL}\""
echo "5) For Kiro CLI:"
echo "   kiro-cli login"
echo
