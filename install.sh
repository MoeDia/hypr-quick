#!/usr/bin/env bash
set -euo pipefail

### ===== FIXED OPTIONS (per your choices) =====
ZSH_FRAMEWORK="zinit"                 # zinit chosen as the best balance of speed & flexibility
ENABLE_NETWORKMANAGER="true"          # keep NetworkManager enabled
SET_DEFAULTS_FOR_SANE_USE="true"      # enable ufw with sane defaults, etc.
PRIMARY_USER="${PRIMARY_USER:-${SUDO_USER:-$USER}}"

### ===== SANITY CHECKS =====
if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0"; exit 1
fi
if ! command -v pacman >/dev/null 2>&1; then
  echo "This script is for Arch Linux."; exit 1
fi
home_dir="$(eval echo ~"$PRIMARY_USER")"
if [[ ! -d "$home_dir" ]]; then
  echo "Could not resolve home for user $PRIMARY_USER"; exit 1
fi
echo "==> Installing for user: $PRIMARY_USER (home: $home_dir)"

### ===== SYNC & BASE TOOLS =====
pacman -Syu --noconfirm
pacman -S --needed --noconfirm base-devel git

### ===== AUR HELPER: yay =====
if ! command -v yay >/dev/null 2>&1; then
  echo "==> Installing yay (AUR helper)"
  sudo -u "$PRIMARY_USER" bash -lc '
    set -e
    cd ~
    rm -rf yay || true
    git clone https://aur.archlinux.org/yay.git
    cd yay
    makepkg -si --noconfirm
  '
else
  echo "==> yay already installed"
fi

### ===== PACKAGE SETS =====
# Core Wayland/Hyprland + greeter
CORE_PKGS=(
  hyprland waybar wofi mako wlogout grim slurp swappy fastfetch wallust
  nwg-look wl-clipboard xdg-desktop-portal xdg-desktop-portal-hyprland
  hyprpaper hyprlock hypridle
  polkit-gnome
  greetd tuigreet
)

# PipeWire audio
AUDIO_PKGS=( pipewire wireplumber pipewire-alsa pipewire-pulse pipewire-jack pavucontrol )

# Shell / CLI
SHELL_PKGS=( kitty zsh zsh-autosuggestions zsh-syntax-highlighting fzf bat fd ripgrep tldr thefuck )

# Apps (Wayland-friendly)
APPS_PKGS=( firefox zathura abiword gnumeric mpv galculator thunar ddcutil )

# Thunar helpers
THUNAR_EXTRAS=( gvfs udisks2 tumbler ffmpegthumbnailer thunar-archive-plugin file-roller )

# Printing & scanning (you said yes)
PRINT_PKGS=( cups cups-pdf system-config-printer avahi nss-mdns sane simple-scan )

# Intel CPU + AMD GPU
GPU_CPU_PKGS=( mesa vulkan-radeon libva-mesa-driver libvdpau mesa-utils intel-ucode )

# Networking
NET_PKGS=( networkmanager )

# Misc utilities
UTIL_PKGS=( xdg-user-dirs xdg-utils ufw ntfs-3g )

# Qt Wayland + config tools
QT_PKGS=( qt5-wayland qt6-wayland qt5ct qt6ct )

REPO_PKGS=(
  "${CORE_PKGS[@]}" "${AUDIO_PKGS[@]}" "${SHELL_PKGS[@]}"
  "${APPS_PKGS[@]}" "${THUNAR_EXTRAS[@]}" "${PRINT_PKGS[@]}"
  "${GPU_CPU_PKGS[@]}" "${QT_PKGS[@]}" "${UTIL_PKGS[@]}"
)

if [[ "$ENABLE_NETWORKMANAGER" == "true" ]]; then
  REPO_PKGS+=( "${NET_PKGS[@]}" )
fi

echo "==> Installing repo packages (pacman)"
pacman -S --needed --noconfirm "${REPO_PKGS[@]}"

### AUR/mixed
AUR_PKGS=( sublime-text-4 ncspot )
echo "==> Installing AUR packages (yay)"
sudo -u "$PRIMARY_USER" yay -S --needed --noconfirm "${AUR_PKGS[@]}"

### ===== ENABLE SERVICES =====
systemctl enable greetd.service
if [[ "$ENABLE_NETWORKMANAGER" == "true" ]]; then
  systemctl enable NetworkManager.service
fi
systemctl enable cups.service
systemctl enable avahi-daemon.service
systemctl enable ufw.service

### ===== GREETD CONFIG (tuigreet -> Hyprland) =====
install -Dm644 /dev/stdin /etc/greetd/config.toml <<'EOF'
[terminal]
vt = 1

[default_session]
command = "tuigreet --greetd --remember --time --cmd 'Hyprland'"
user = "greeter"
EOF

### ===== mDNS for printers (Avahi) =====
if grep -q '^hosts:' /etc/nsswitch.conf; then
  sed -i 's/^hosts:.*/hosts: files mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] dns myhostname/' /etc/nsswitch.conf
fi

### ===== FIREWALL DEFAULTS =====
if [[ "$SET_DEFAULTS_FOR_SANE_USE" == "true" ]]; then
  ufw default deny incoming || true
  ufw default allow outgoing || true
  ufw --force enable || true
fi

### ===== USER DIRS =====
sudo -u "$PRIMARY_USER" xdg-user-dirs-update || true

### ===== DDCUTIL SUPPORT =====
install -Dm644 /dev/stdin /etc/modules-load.d/i2c-dev.conf <<'EOF'
i2c-dev
EOF
modprobe i2c-dev || true
install -Dm644 /dev/stdin /etc/udev/rules.d/45-ddcutil-i2c.rules <<'EOF'
KERNEL=="i2c-[0-9]*", GROUP="video", MODE="0660"
EOF
usermod -aG video "$PRIMARY_USER" || true

### ===== ZSH SETUP (zinit) =====
chsh -s /bin/zsh "$PRIMARY_USER" || true
mkdir -p "$home_dir/.config" "$home_dir/.config/zsh"
sudo -u "$PRIMARY_USER" bash -lc '
  mkdir -p ~/.local/share/zinit
  [[ -d ~/.local/share/zinit/bin ]] || git clone https://github.com/zdharma-continuum/zinit.git ~/.local/share/zinit/bin
'
install -Dm644 /dev/stdin "$home_dir/.zshrc" <<'EOF'
# ----- ZSH with zinit -----
export ZDOTDIR="$HOME/.config/zsh"
export PATH="$HOME/.local/bin:$PATH"

# Wayland/Qt
export QT_QPA_PLATFORM="wayland;xcb"
export QT_QPA_PLATFORMTHEME="qt5ct"
export MOZ_ENABLE_WAYLAND=1

# Load zinit
export ZINIT_HOME="$HOME/.local/share/zinit"
source "$ZINIT_HOME/bin/zinit.zsh"

# Plugins
zinit light zsh-users/zsh-autosuggestions
zinit light zsh-users/zsh-syntax-highlighting

# FZF keybindings (if available)
[[ -f /usr/share/fzf/key-bindings.zsh ]] && source /usr/share/fzf/key-bindings.zsh

# Prompt (fallback if pure not present)
autoload -Uz promptinit; promptinit; PROMPT='%F{cyan}%n@%m%f %F{yellow}%~%f %# '

# Aliases
alias cat='bat --paging=never'
alias ls='ls --color=auto'
alias grep='rg'
eval "$(thefuck --alias)" 2>/dev/null
EOF
chown -R "$PRIMARY_USER":"$PRIMARY_USER" "$home_dir/.config" "$home_dir/.zshrc" || true

### ===== HYPRLAND BASE CONFIGS =====
install -d -m 755 "$home_dir/.config/hypr" "$home_dir/.config/waybar" "$home_dir/.config/wofi" "$home_dir/.config/mako"

# Hyprland
install -Dm644 /dev/stdin "$home_dir/.config/hypr/hyprland.conf" <<'EOF'
# --- Minimal Hyprland config ---
monitor=,preferred,auto,1

input {
  kb_layout = us
  follow_mouse = 1
}

env = XDG_CURRENT_DESKTOP,Hyprland
env = XDG_SESSION_TYPE,wayland
env = QT_QPA_PLATFORM,wayland;xcb
env = MOZ_ENABLE_WAYLAND,1

exec-once = /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
exec-once = waybar
exec-once = mako
exec-once = hyprpaper
exec-once = hypridle

bind = SUPER,SPACE,exec,wofi --show drun
bind = SUPER,L,exec,hyprlock
bind = ,Print,exec,grim -g "$(slurp)" - | swappy -f -
bind = SUPER,ESC,exec,wlogout
EOF

# hyprpaper
install -Dm644 /dev/stdin "$home_dir/.config/hypr/hyprpaper.conf" <<'EOF'
# hyprpaper config — set your wallpaper(s):
# preload = /usr/share/backgrounds/archlinux/archbtw.jpg
# wallpaper = ,/usr/share/backgrounds/archlinux/archbtw.jpg
EOF

# hypridle -> hyprlock
install -Dm644 /dev/stdin "$home_dir/.config/hypr/hypridle.conf" <<'EOF'
general {
  lock_cmd = hyprlock
  before_sleep_cmd = hyprlock
  after_sleep_cmd = hyprpaper
}
listener {
  timeout = 600
  on-timeout = hyprlock
}
EOF

# Waybar (minimal)
install -Dm644 /dev/stdin "$home_dir/.config/waybar/config.jsonc" <<'EOF'
{
  "layer": "top",
  "position": "top",
  "modules-left": ["workspaces"],
  "modules-center": ["clock"],
  "modules-right": ["cpu", "memory", "network", "pulseaudio"],
  "clock": { "format": "{:%Y-%m-%d  %H:%M}" }
}
EOF
install -Dm644 /dev/stdin "$home_dir/.config/waybar/style.css" <<'EOF'
* { font-size: 12pt; }
#clock, #cpu, #memory, #network, #pulseaudio { padding: 0 10px; }
EOF

# Wofi
install -Dm644 /dev/stdin "$home_dir/.config/wofi/style.css" <<'EOF'
window { border-radius: 12px; }
EOF

# Mako
install -Dm644 /dev/stdin "$home_dir/.config/mako/config" <<'EOF'
font=monospace 12
background-color=#1e1e2e
text-color=#eeeeee
border-color=#6c7086
default-timeout=5000
EOF

chown -R "$PRIMARY_USER":"$PRIMARY_USER" "$home_dir/.config"

### ===== DONE =====
cat <<'EOM'

All set!

Next steps:
1) (Optional) set a wallpaper in ~/.config/hypr/hyprpaper.conf (uncomment and set a real path).
2) Start services now (or reboot):
   sudo systemctl start greetd cups avahi-daemon ufw
   sudo systemctl start NetworkManager
3) Log in via tuigreet; Hyprland will launch automatically.
4) Use nwg-look (GTK) and qt5ct/qt6ct later to theme apps.

Tip: If you later want Oh My Zsh instead, re-run this script with:
  ZSH_FRAMEWORK=oh-my-zsh sudo ./hyprland-install.sh

EOM
