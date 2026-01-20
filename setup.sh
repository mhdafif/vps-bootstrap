#!/usr/bin/env bash
set -euo pipefail

log() { echo -e "\n==> $1"; }
warn() { echo -e "\n[WARN] $1"; }

# ========= LOAD CONFIG =========
# You may keep env.conf optional. If missing, defaults are used.
if [[ -f "./env.conf" ]]; then
  # shellcheck disable=SC1091
  source ./env.conf
fi

# ========= DEFAULTS =========
USERNAME="${USERNAME:-aafif}"
TIMEZONE="${TIMEZONE:-Asia/Jakarta}"

ALLOW_HTTP="${ALLOW_HTTP:-true}"
ALLOW_HTTPS="${ALLOW_HTTPS:-true}"
ALLOW_SSH_PUBLIC="${ALLOW_SSH_PUBLIC:-true}"
SSH_PORT="${SSH_PORT:-22}"

INSTALL_TAILSCALE="${INSTALL_TAILSCALE:-true}"
INSTALL_FAIL2BAN="${INSTALL_FAIL2BAN:-true}"

INSTALL_GROK_CLI="${INSTALL_GROK_CLI:-true}"
GROK_BASE_URL="${GROK_BASE_URL:-https://api.z.ai/api/coding/paas/v4}"
GROK_MODEL="${GROK_MODEL:-glm-4.7}"
GROK_API_KEY="${GROK_API_KEY:-}"

INSTALL_KIRO_CLI="${INSTALL_KIRO_CLI:-true}"

TMUX_SESSION="${TMUX_SESSION:-main}"
PROJECT_DIR="${PROJECT_DIR:-/home/${USERNAME}/apps}"

WEB_CMD="${WEB_CMD:-cd web && pnpm dev}"
API_CMD="${API_CMD:-cd api && pnpm dev}"
COMPOSE_CMD="${COMPOSE_CMD:-docker compose up -d}"
LOGS_CMD="${LOGS_CMD:-docker compose logs -f --tail=200}"

# ========= ROOT CHECK =========
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "❌ Run as root:"
  echo "   sudo -i"
  echo "   ./setup.sh"
  exit 1
fi

log "Starting VPS bootstrap (target user: ${USERNAME})"

# ========= UPDATE & UPGRADE =========
log "Updating system packages..."
apt update -y
DEBIAN_FRONTEND=noninteractive apt upgrade -y

# ========= TIMEZONE =========
log "Setting timezone: ${TIMEZONE}"
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

if [[ "${INSTALL_FAIL2BAN}" == "true" ]]; then
  log "Installing fail2ban..."
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
  log "Allowing SSH public on port ${SSH_PORT}/tcp"
  ufw allow "${SSH_PORT}/tcp"
else
  warn "Public SSH is disabled by config. Ensure console/Tailscale access exists."
fi

if [[ "${ALLOW_HTTP}" == "true" ]]; then ufw allow 80/tcp; fi
if [[ "${ALLOW_HTTPS}" == "true" ]]; then ufw allow 443/tcp; fi

ufw --force enable
ufw status verbose || true

# ========= FAIL2BAN ENABLE =========
if [[ "${INSTALL_FAIL2BAN}" == "true" ]]; then
  log "Enabling fail2ban..."
  systemctl enable --now fail2ban
fi

# ========= TAILSCALE =========
if [[ "${INSTALL_TAILSCALE}" == "true" ]]; then
  if command -v tailscale &>/dev/null; then
    log "Tailscale already installed"
  else
    log "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  systemctl enable --now tailscaled || true
fi

# ========= USER PHASE: NVM + NODE + PNPM + GROK =========
log "Installing NVM + Node LTS + pnpm for user ${USERNAME} (robust mode)..."

su - "${USERNAME}" -c '
  set -euo pipefail

  # 1) Install NVM if missing
  if [[ ! -d "$HOME/.nvm" ]]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  fi

  # 2) Load NVM
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

  # 3) Install and use Node LTS
  nvm install --lts
  nvm use --lts

  # 4) Enable pnpm via Corepack (comes with Node >=16.10+; on LTS it should exist)
  corepack enable
  corepack prepare pnpm@latest --activate

  # 5) Make pnpm global bin dir deterministic (fixes ERR_PNPM_NO_GLOBAL_BIN_DIR)
  export PNPM_HOME="$HOME/.local/share/pnpm"
  mkdir -p "$PNPM_HOME"
  pnpm config set global-bin-dir "$PNPM_HOME"
  export PATH="$PNPM_HOME:$PATH"

  # 6) Ensure PNPM_HOME is persisted in shell config
  BASHRC="$HOME/.bashrc"
  if ! grep -q "export PNPM_HOME=" "$BASHRC"; then
    cat >> "$BASHRC" <<'"'"'EOF'"'"'

# --- pnpm ---
export PNPM_HOME="$HOME/.local/share/pnpm"
case ":$PATH:" in
  *":$PNPM_HOME:"*) ;;
  *) export PATH="$PNPM_HOME:$PATH" ;;
esac
EOF
  fi

  # Verify basic tools
  node -v
  pnpm -v
'

# ========= GROK CLI (via pnpm) =========
if [[ "${INSTALL_GROK_CLI}" == "true" ]]; then
  log "Installing Grok CLI (pnpm global)..."
  su - "${USERNAME}" -c '
    set -euo pipefail
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    nvm use --lts >/dev/null

    export PNPM_HOME="$HOME/.local/share/pnpm"
    export PATH="$PNPM_HOME:$PATH"

    pnpm add -g @vibe-kit/grok-cli
    command -v grok >/dev/null
    grok --help | head -n 5 || true
  '

  # Add Grok env vars to bashrc (API key only if provided)
  BASHRC_PATH="/home/${USERNAME}/.bashrc"
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
      warn "GROK_API_KEY is empty. Fill it in env.conf then rerun ./setup.sh, or export manually before using grok."
    fi
    chown "${USERNAME}:${USERNAME}" "${BASHRC_PATH}"
  else
    log "Grok env snippet already exists in ${BASHRC_PATH}"
  fi
fi

# ========= KIRO CLI =========
if [[ "${INSTALL_KIRO_CLI}" == "true" ]]; then
  log "Installing Kiro CLI..."
  su - "${USERNAME}" -c '
    set -euo pipefail
    curl -fsSL https://cli.kiro.dev/install | bash
    command -v kiro-cli >/dev/null || true
    kiro-cli --version || true
  '
  warn "Kiro auth is usually interactive. After login:"
  warn "  kiro-cli login"
fi

# ========= TMUX AUTO-SESSION + 4 PANE LAYOUT =========
log "Configuring tmux auto-session + 4-pane layout for ${USERNAME}..."

BASHRC_PATH="/home/${USERNAME}/.bashrc"

TMUX_SNIPPET=$(cat <<'EOF'

# --- Auto tmux session on SSH (with 4-pane layout) ---
__tmux_bootstrap_session() {
  local SESSION="__TMUX_SESSION__"
  local ROOT_DIR="__PROJECT_DIR__"
  local WEB="__WEB_CMD__"
  local API="__API_CMD__"
  local COMPOSE="__COMPOSE_CMD__"
  local LOGS="__LOGS_CMD__"

  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux new-session -d -s "$SESSION" -c "$ROOT_DIR"

    # Pane 0: web
    tmux send-keys -t "$SESSION":0.0 "cd \"$ROOT_DIR\" && $WEB" C-m

    # Pane 1: api (right)
    tmux split-window -h -t "$SESSION":0 -c "$ROOT_DIR"
    tmux send-keys -t "$SESSION":0.1 "cd \"$ROOT_DIR\" && $API" C-m

    # Pane 2: compose + logs (bottom-left)
    tmux select-pane -t "$SESSION":0.0
    tmux split-window -v -t "$SESSION":0 -c "$ROOT_DIR"
    tmux send-keys -t "$SESSION":0.2 "cd \"$ROOT_DIR\" && $COMPOSE && $LOGS" C-m

    # Pane 3: shell (bottom-right) for grok/kiro
    tmux select-pane -t "$SESSION":0.1
    tmux split-window -v -t "$SESSION":0 -c "$ROOT_DIR"
    tmux send-keys -t "$SESSION":0.3 "cd \"$ROOT_DIR\"" C-m

    tmux select-layout -t "$SESSION":0 tiled >/dev/null 2>&1 || true
  fi
}

if [[ -z "$TMUX" && -n "$SSH_CONNECTION" && $- == *i* ]]; then
  __tmux_bootstrap_session
  tmux attach -t "__TMUX_SESSION__"
fi
EOF
)

TMUX_SNIPPET="${TMUX_SNIPPET/__TMUX_SESSION__/${TMUX_SESSION}}"
TMUX_SNIPPET="${TMUX_SNIPPET/__PROJECT_DIR__/${PROJECT_DIR}}"
TMUX_SNIPPET="${TMUX_SNIPPET/__WEB_CMD__/${WEB_CMD}}"
TMUX_SNIPPET="${TMUX_SNIPPET/__API_CMD__/${API_CMD}}"
TMUX_SNIPPET="${TMUX_SNIPPET/__COMPOSE_CMD__/${COMPOSE_CMD}}"
TMUX_SNIPPET="${TMUX_SNIPPET/__LOGS_CMD__/${LOGS_CMD}}"

if grep -q "Auto tmux session on SSH (with 4-pane layout)" "${BASHRC_PATH}"; then
  log "tmux snippet already present in ${BASHRC_PATH}"
else
  printf "\n%s\n" "${TMUX_SNIPPET}" >> "${BASHRC_PATH}"
  chown "${USERNAME}:${USERNAME}" "${BASHRC_PATH}"
  log "tmux auto-session + layout snippet added"
fi

log "Bootstrap completed ✅"

echo
echo "Next steps:"
echo "1) SSH into your user:"
echo "   ssh ${USERNAME}@<VPS_IP>"
echo "2) (Optional) Tailscale auth (on VPS):"
echo "   sudo tailscale up"
echo "3) Create project dir if needed:"
echo "   mkdir -p ${PROJECT_DIR}"
echo "4) Grok usage (if API key configured):"
echo "   grok --model \"${GROK_MODEL}\""
echo "5) Kiro login:"
echo "   kiro-cli login"
echo
