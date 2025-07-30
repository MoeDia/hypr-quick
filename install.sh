#!/usr/bin/env bash
set -euo pipefail

### ===== CONFIGURATION =====
ZSH_FRAMEWORK="zinit"                # choices: zinit | oh-my-zsh
ENABLE_NETWORKMANAGER="true"         # true to enable NM.service
SET_DEFAULTS_FOR_SANE_USE="true"     # enable and configure ufw
PRIMARY_USER="${PRIMARY_USER:-${SUDO_USER:-$USER}}"

### ===== SANITY CHECKS =====
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must be run as root"; exit 1
fi
if ! command -v pacman &>/dev/null; then
  echo "ERROR: this script only works on Arch Linux"; exit 1
fi
HOME_DIR="$(getent passwd "$PRIMARY_USER" | cut -d: -f6)"
if [[ ! -d "$HOME_DIR" ]]; then
  echo "ERROR: user '$PRIMARY_USER' not found"; exit 1
fi
echo "Installing for user: $PRIMARY_USER (home: $HOME_DIR)"

### ===== UPDATE & BASE TOOLS =====
pacman -Syu --noconfirm
pacman -S --noconfirm --needed base-devel git runuser

### ===== AUR HELPER (yay) =====
if ! command -v yay &>/dev/null; then
  echo "Installing yay (AUR helper)..."
  runuser -u "$PRIMARY_USER" -- bash -lc '
    cd ~
    rm -rf yay
    git clone https://aur.archlinux.org/yay.git
    cd yay
    makepkg -si --noconfirm
  '
else
  echo "yay already present"
fi

### ===== PACKAGE GROUPS =====
CORE_PKGS=(
  hyprland waybar wofi mako swaylock wlogout
  grim slurp swappy fastfetch
  polkit-gnome greetd tuigreet
)

AUDIO_PKGS=( pipewire wireplumber pipewire-alsa pipewire-pulse pavucontrol )
SHELL_PKGS=( kitty zsh zsh-autosuggestions zsh-syntax-highlighting fzf bat fd ripgrep tldr thefuck )
APP_PKGS=( firefox zathura abiword gnumeric mpv galculator thunar ddcutil )
THUNAR_EXTRAS=( gvfs udisks2 tumbler ffmpegthumbnailer thunar-archive-plugin file-roller )
PRINT_PKGS=( cups cups-pdf system-config-printer avahi nss-mdns sane simple-scan )
GPU_CPU_PKGS=( mesa vulkan-radeon libva-mesa-driver libvdpau mesa-utils intel-ucode )
NET_PKGS=( networkmanager )
UTIL_PKGS=( xdg-user-dirs xdg-utils ufw ntfs-3g )
QT_PKGS=( qt5-wayland qt6-wayland qt5ct qt6ct )

# Combine all *repo* packages
REPO_PKGS=(
  "${CORE_PKGS[@]}" "${AUDIO_PKGS[@]}" "${SHELL_PKGS[@]}"
  "${APP_PKGS[@]}" "${THUNAR_EXTRAS[@]}" "${PRINT_PKGS[@]}"
  "${GPU_CPU_PKGS[@]}" "${QT_PKGS[@]}" "${UTIL_PKGS[@]}"
)
if [[ "$ENABLE_NETWORKMANAGER" == "true" ]]; then
  REPO_PKGS+=( "${NET_PKGS[@]}" )
fi

echo "==> Installing official repo packages"
pacman -S --noconfirm --needed "${REPO_PKGS[@]}"

### ===== AUR-ONLY PACKAGES =====
AUR_PKGS=(
  # Hyprland extras & themers
  xdg-desktop-portal-hyprland hyprpaper hypridle hyprlock wallust nwg-look
  # your editor + any remaining
  sublime-text-4 ncspot
)
echo "==> Installing AUR packages"
runuser -u "$PRIMARY_USER" -- yay -S --noconfirm --needed "${AUR_PKGS[@]}"

### ===== ENABLE SERVICES =====
systemctl enable greetd.service
systemctl enable cups.service avahi-daemon.service
[[ "$ENABLE_NETWORKMANAGER" == "true" ]] && systemctl enable NetworkManager.service
[[ "$SET_DEFAULTS_FOR_SANE_USE" == "true" ]] && systemctl enable ufw.service

### ===== GREETD (tuigreet) =====
install -Dm644 /dev/stdin /etc/greetd/config.toml <<'EOF'
[terminal]
vt = 1

[default_session]
command = "tuigreet --greetd --remember --time --cmd 'Hyprland'"
user = "greeter"
EOF

### ===== mDNS for printers =====
sed -i 's|^hosts:.*|hosts: files mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] dns myhostname|' /etc/nsswitch.conf

### ===== FIREWALL =====
if [[ "$SET_DEFAULTS_FOR_SANE_USE" == "true" ]]; then
  ufw default deny incoming
  ufw default allow outgoing
  ufw --force enable
fi

### ===== USER DIRECTORIES =====
runuser -u "$PRIMARY_USER" -- xdg-user-dirs-update || true

### ===== DDCUTIL (external brightness) =====
install -Dm644 /dev/stdin /etc/modules-load.d/i2c-dev.conf <<'EOF'
i2c-dev
EOF
modprobe i2c-dev || true
install -Dm644 /dev/stdin /etc/udev/rules.d/45-ddcutil-i2c.rules <<'EOF'
KERNEL=="i2c-[0-9]*", GROUP="video", MODE="0660"
EOF
usermod -aG video "$PRIMARY_USER" || true

### ===== ZSH + ZINIT SETUP =====
chsh -s /usr/bin/zsh "$PRIMARY_USER" || true
mkdir -p "$HOME_DIR/.config/zsh" "$HOME_DIR/.local/share/zinit"

runuser -u "$PRIMARY_USER" -- bash -lc '
  if [[ ! -d ~/.local/share/zinit/bin ]]; then
    git clone https://github.com/zdharma-continuum/zinit.git ~/.local/share/zinit/bin
  fi
'

install -Dm644 /dev/stdin "$HOME_DIR/.zshrc" <<'EOF'
# ZSH + ZINIT
export ZDOTDIR="$HOME/.config/zsh"
export ZINIT_HOME="$HOME/.local/share/zinit"
source "$ZINIT_HOME/bin/zinit.zsh"

# Plugins
zinit light zsh-users/zsh-autosuggestions
zinit light zsh-users/zsh-syntax-highlighting

# Aliases
alias cat='bat --paging=never'
alias ls='exa --icons --group-directories-first'
eval "$(thefuck --alias)"

# FZF
[[ -f /usr/share/fzf/key-bindings.zsh ]] && source /usr/share/fzf/key-bindings.zsh
EOF

chown -R "$PRIMARY_USER":"$PRIMARY_USER" \
  "$HOME_DIR/.config" "$HOME_DIR/.local/share/zinit" "$HOME_DIR/.zshrc"

### ===== HYPRLAND CONFIGS =====
CFG_ROOT="$HOME_DIR/.config"
install -d -m755 "$CFG_ROOT/hypr" "$CFG_ROOT/waybar" "$CFG_ROOT/wofi" "$CFG_ROOT/mako"

# hyprland.conf
install -Dm644 /dev/stdin "$CFG_ROOT/hypr/hyprland.conf" <<'EOF'
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

# hyprpaper.conf
install -Dm644 /dev/stdin "$CFG_ROOT/hypr/hyprpaper.conf" <<'EOF'
# preload = /usr/share/backgrounds/archlinux/archbtw.jpg
# wallpaper = ,/usr/share/backgrounds/archlinux/archbtw.jpg
EOF

# hypridle.conf
install -Dm644 /dev/stdin "$CFG_ROOT/hypr/hypridle.conf" <<'EOF'
general {
  lock_cmd = hyprlock
  before_sleep_cmd = hyprlock
}
listener {
  timeout = 600
  on-timeout = hyprlock
}
EOF

# waybar
install -Dm644 /dev/stdin "$CFG_ROOT/waybar/config.json" <<'EOF'
{
  "layer": "top", "position": "top",
  "modules-left": ["workspaces"],
  "modules-center": ["clock"],
  "modules-right": ["cpu","memory","network","pulseaudio"],
  "clock": {"format":"{:%Y-%m-%d %H:%M}"}
}
EOF
install -Dm644 /dev/stdin "$CFG_ROOT/waybar/style.css" <<'EOF'
* { font-size: 12pt; }
#clock,#cpu,#memory,#network,#pulseaudio { padding: 0 8px; }
EOF

# wofi
install -Dm644 /dev/stdin "$CFG_ROOT/wofi/style.css" <<'EOF'
window { border-radius: 12px; }
EOF

# mako
install -Dm644 /dev/stdin "$CFG_ROOT/mako/config" <<'EOF'
font=monospace 12
background-color=#1e1e2e
text-color=#eeeeee
border-color=#6c7086
default-timeout=5000
EOF

chown -R "$PRIMARY_USER":"$PRIMARY_USER" "$HOME_DIR/.config"

### ===== FINISHED =====
cat <<'EOM'

✅ All done!
Next:
 1) Uncomment/set your wallpaper in ~/.config/hypr/hyprpaper.conf
 2) Reboot or manually start services:
     systemctl start greetd cups avahi-daemon ufw
     systemctl start NetworkManager
 3) Log in on tty1 via tuigreet → Hyprland launches.
 4) Theme GTK/Qt with nwg-look, qt5ct/qt6ct.

EOM
