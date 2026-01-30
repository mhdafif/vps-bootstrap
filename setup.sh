#!/usr/bin/env bash
set -euo pipefail

log() { echo -e "\n==> $1"; }
warn() { echo -e "\n[WARN] $1"; }

# ========= LOAD CONFIG (optional) =========
if [[ -f "./env.conf" ]]; then
  # shellcheck disable=SC1091
  source ./env.conf
fi

# ========= DEFAULTS =========
USERNAME="${USERNAME:-aafif}"
TIMEZONE="${TIMEZONE:-Asia/Jakarta}"

ALLOW_HTTP="${ALLOW_HTTP:-true}"
ALLOW_HTTPS="${ALLOW_HTTPS:-true}"

ALLOW_SSH_PUBLIC="${ALLOW_SSH_PUBLIC:-false}"
SSH_PORT="${SSH_PORT:-22}"

INSTALL_TAILSCALE="${INSTALL_TAILSCALE:-true}"
INSTALL_FAIL2BAN="${INSTALL_FAIL2BAN:-true}"
INSTALL_TMUX="${INSTALL_TMUX:-false}"

INSTALL_OPENCODE_CLI="${INSTALL_OPENCODE_CLI:-true}"

TMUX_SESSION="${TMUX_SESSION:-main}"
PROJECT_DIR="${PROJECT_DIR:-/home/${USERNAME}/apps}"

WEB_CMD="${WEB_CMD:-cd web && pnpm dev}"
API_CMD="${API_CMD:-cd api && pnpm dev}"
COMPOSE_CMD="${COMPOSE_CMD:-docker compose up -d}"
LOGS_CMD="${LOGS_CMD:-docker compose logs -f --tail=200}"

# Security toggles (recommended)
HARDEN_SSH="${HARDEN_SSH:-true}"  # set true if you want to auto-disable SSH password login later

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
BASE_PACKAGES="openssh-server ufw curl git htop net-tools ca-certificates gnupg lsb-release"
if [[ "${INSTALL_TMUX}" == "true" ]]; then
  BASE_PACKAGES="${BASE_PACKAGES} tmux"
fi
apt install -y ${BASE_PACKAGES}

if [[ "${INSTALL_FAIL2BAN}" == "true" ]]; then
  log "Installing fail2ban..."
  apt install -y fail2ban
fi

# ========= CREATE USER + SUDO =========
USER_CREATED=false
if id "${USERNAME}" &>/dev/null; then
  log "User ${USERNAME} already exists"
else
  log "Creating user ${USERNAME}..."
  adduser --disabled-password --gecos "" "${USERNAME}"
  USER_CREATED=true
fi

# Ensure sudo group membership
usermod -aG sudo "${USERNAME}"

# ========= SET PASSWORD ONLY WHEN NEEDED =========
# We only prompt for password if:
# - user was just created, OR
# - the account password is still locked/empty in /etc/shadow
#
# This prevents asking for a new password on every rerun.
SHADOW_STATUS="$(passwd -S "${USERNAME}" 2>/dev/null | awk "{print \$2}")" || SHADOW_STATUS=""
# Common statuses:
#  P = password set
#  L = locked
#  NP = no password
NEED_PASSWORD=false
if [[ "${USER_CREATED}" == "true" ]]; then
  NEED_PASSWORD=true
elif [[ "${SHADOW_STATUS}" == "L" || "${SHADOW_STATUS}" == "NP" ]]; then
  NEED_PASSWORD=true
fi

if [[ "${NEED_PASSWORD}" == "true" ]]; then
  log "Setting a password for ${USERNAME} (required for sudo)."
  log "You will be prompted to type a new password now."
  passwd "${USERNAME}"
else
  log "Password already set for ${USERNAME} (skipping)."
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

# ========= USER PHASE: NVM + NODE + PNPM (robust) =========
log "Installing NVM + Node LTS + pnpm for user ${USERNAME} (robust mode)..."

su - "${USERNAME}" -c '
  set -eo pipefail

  # Install NVM if missing
  if [[ ! -d "$HOME/.nvm" ]]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  fi

  # Load NVM
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

  # Install/use Node LTS
  nvm install --lts
  nvm use --lts

  # Enable pnpm via Corepack
  corepack enable
  corepack prepare pnpm@latest --activate

  # Fix pnpm global bin dir deterministically
  export PNPM_HOME="$HOME/.local/share/pnpm"
  mkdir -p "$PNPM_HOME"
  pnpm config set global-bin-dir "$PNPM_HOME"
  export PATH="$PNPM_HOME:$PATH"

  # Persist PNPM_HOME in bashrc
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

  node -v
  pnpm -v
'

# ========= OPENCODE CLI =========
if [[ "${INSTALL_OPENCODE_CLI}" == "true" ]]; then
  log "Installing OpenCode CLI..."
  su - "${USERNAME}" -c '
    set -eo pipefail
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    nvm use --lts >/dev/null

    export PNPM_HOME="$HOME/.local/share/pnpm"
    export PATH="$PNPM_HOME:$PATH"

    pnpm add -g opencode-cli
    command -v opencode >/dev/null || true
    opencode --version || true
  '
fi

# ========= TMUX AUTO-SESSION + 4 PANE LAYOUT =========
if [[ "${INSTALL_TMUX}" == "true" ]]; then
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

    # Pane 3: shell (bottom-right) for opencode
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
fi

# ========= OPTIONAL SSH HARDENING =========
if [[ "${HARDEN_SSH}" == "true" ]]; then
  log "Hardening SSH (disabling password login & root login)..."
  SSHD="/etc/ssh/sshd_config"
  cp "${SSHD}" "${SSHD}.bak.$(date +%s)"

  # ensure directives exist (append if missing)
  grep -q "^PasswordAuthentication" "${SSHD}" && sed -i "s/^PasswordAuthentication.*/PasswordAuthentication no/" "${SSHD}" || echo "PasswordAuthentication no" >> "${SSHD}"
  grep -q "^PubkeyAuthentication" "${SSHD}" && sed -i "s/^PubkeyAuthentication.*/PubkeyAuthentication yes/" "${SSHD}" || echo "PubkeyAuthentication yes" >> "${SSHD}"
  grep -q "^PermitRootLogin" "${SSHD}" && sed -i "s/^PermitRootLogin.*/PermitRootLogin no/" "${SSHD}" || echo "PermitRootLogin no" >> "${SSHD}"

  systemctl restart ssh
  warn "SSH hardened: PasswordAuthentication no, PubkeyAuthentication yes, PermitRootLogin no"
fi

log "Bootstrap completed ✅"

echo
echo "Next steps:"

if [[ "${ALLOW_SSH_PUBLIC}" == "true" ]]; then
  echo "1) SSH into your user:"
  echo "   ssh ${USERNAME}@<VPS_IP>"
fi

if [[ "${INSTALL_TAILSCALE}" == "true" ]]; then
  echo "2) (Optional) Tailscale auth (on VPS):"
  echo "   sudo tailscale up --ssh"
fi

if [[ "${INSTALL_TMUX}" == "true" ]]; then
  echo "3) Create project dir if needed:"
  echo "   mkdir -p ${PROJECT_DIR}"
fi

if [[ "${INSTALL_OPENCODE_CLI}" == "true" ]]; then
  echo "4) OpenCode usage:"
  echo "   opencode --help"
fi
echo
