# VPS Bootstrap Script

Automated VPS setup script for Ubuntu/Debian servers with Docker, Node.js, pnpm, OpenCode CLI, and tmux auto-configuration.

## Features

- ✅ System updates & timezone configuration
- ✅ User creation with sudo access
- ✅ Docker installation
- ✅ UFW firewall configuration
- ✅ Fail2ban (optional)
- ✅ Tailscale VPN (optional)
- ✅ NVM + Node.js LTS + pnpm
- ✅ **OpenCode CLI** for AI-powered coding assistance
- ✅ Tmux auto-session with 4-pane layout
- ✅ SSH hardening (optional)

## Quick Start

### 1. Clone or download this repository to your VPS

```bash
git clone <your-repo-url> vps-bootstrap
cd vps-bootstrap
```

### 2. (Optional) Configure settings

Copy `env.example` to `env.conf` and customize:

```bash
cp env.example env.conf
nano env.conf
```

### 3. Make the script executable and run as root

```bash
sudo chmod +x setup.sh
sudo -i
cd /path/to/vps-bootstrap
./setup.sh
```

## Configuration

All configuration is done via environment variables. You can either:

- Create an `env.conf` file (recommended, gitignored)
- Set environment variables before running the script
- Use the defaults

### Key Configuration Options

#### User & System

```bash
USERNAME=aafif                    # User to create
TIMEZONE=Asia/Jakarta             # Server timezone
```

#### Firewall

```bash
ALLOW_HTTP=true                   # Allow port 80
ALLOW_HTTPS=true                  # Allow port 443
ALLOW_SSH_PUBLIC=false            # Allow public SSH (use false with Tailscale)
SSH_PORT=22                       # SSH port
```

#### Tmux Configuration

```bash
TMUX_SESSION=main                 # Session name
PROJECT_DIR=/home/aafif/apps      # Project directory

# Commands for each pane
WEB_CMD="pnpm dev:web"
API_CMD="pnpm dev:api"
COMPOSE_CMD="docker compose up -d"
LOGS_CMD="docker compose logs -f --tail=200"
```

#### Tools

```bash
INSTALL_OPENCODE_CLI=true         # Install OpenCode CLI
INSTALL_TAILSCALE=true            # Install Tailscale VPN
INSTALL_FAIL2BAN=true             # Install fail2ban
INSTALL_TMUX=true                 # Install tmux and configure auto-session
```

#### Security

```bash
HARDEN_SSH=true                   # Disable password auth & root login (default: true)
```

**Note**: All optional tools (`INSTALL_TAILSCALE`, `INSTALL_FAIL2BAN`, `INSTALL_TMUX`, `INSTALL_OPENCODE_CLI`) default to `true`.

## Tmux Layout

When `INSTALL_TMUX=true` (default), the script creates a 4-pane tmux layout that auto-starts on SSH login:

```
┌─────────────┬─────────────┐
│   Pane 0    │   Pane 1    │
│   Web Dev   │   API Dev   │
├─────────────┼─────────────┤
│   Pane 2    │   Pane 3    │
│Docker Logs  │  OpenCode   │
└─────────────┴─────────────┘
```

- **Pane 0**: Web development (runs `WEB_CMD`)
- **Pane 1**: API development (runs `API_CMD`)
- **Pane 2**: Docker compose + logs (runs `COMPOSE_CMD` then `LOGS_CMD`)
- **Pane 3**: Shell for OpenCode CLI and general commands

## Post-Installation

**Note**: The post-installation steps shown by the script are conditional based on your configuration (e.g., Tailscale instructions only show if `INSTALL_TAILSCALE=true`).

### 1. SSH into your user account

```bash
ssh aafif@<VPS_IP>
```

### 2. (Optional) Connect Tailscale

```bash
sudo tailscale up --ssh
```

### 3. Create project directory

```bash
mkdir -p ~/apps
cd ~/apps
```

### 4. Use OpenCode CLI

```bash
opencode --help
opencode
```

## OpenCode CLI

OpenCode CLI is installed globally via pnpm and is available in your PATH. Use it for:

- AI-powered code generation
- Code assistance and suggestions
- Interactive coding sessions

```bash
# Check installation
opencode --version

# Start OpenCode
opencode
```

## Security Recommendations

1. **Use Tailscale**: Set `ALLOW_SSH_PUBLIC=false` and access your VPS via Tailscale
2. **SSH Hardening**: The script defaults to `HARDEN_SSH=true`, which configures:
   - `PasswordAuthentication no` (only SSH keys allowed)
   - `PubkeyAuthentication yes` (explicit public key support)
   - `PermitRootLogin no` (root cannot login via SSH)
3. **Keep system updated**: Regularly run `apt update && apt upgrade`
4. **Monitor fail2ban**: Check logs with `sudo fail2ban-client status sshd`

## Troubleshooting

### Tmux session doesn't auto-start

- Ensure `INSTALL_TMUX=true` in your config
- Check that you're connecting via SSH (not console)
- Verify the snippet in `~/.bashrc`

### OpenCode command not found

- Reload your shell: `source ~/.bashrc`
- Check pnpm global bin: `echo $PNPM_HOME`

### Permission issues

- Ensure you're in the docker group: `groups`
- Logout and login again after initial setup

## License

MIT
