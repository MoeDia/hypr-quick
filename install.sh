#!/usr/bin/env bash
set -euo pipefail

# ====== Settings ======
USER="MoeDia"                 # change if needed
HOSTNAME_DEFAULT="$(hostname)"
TIMEZONE_DEFAULT="$(timedatectl show -p Timezone --value || echo 'UTC')"
LOCALE_DEFAULT="${LANG:-en_US.UTF-8}"
KEYMAP_DEFAULT="us"

# ====== Sanity checks ======
id "$USER" >/dev/null 2>&1 || { echo "User $USER does not exist. Edit USER=..."; exit 1; }
command -v pacman >/dev/null || { echo "Not Arch/No pacman?"; exit 1; }

echo ">>> Using user=$USER, hostname=$HOSTNAME_DEFAULT, tz=$TIMEZONE_DEFAULT, locale=$LOCALE_DEFAULT"

# ====== Packages ======
BASE_APPS="kitty zsh zsh-autosuggestions zsh-syntax-highlighting fzf bat fd ripgrep tldr thefuck"

WAYLAND_STACK="hyprland waybar wofi swww mako swaylock wlogout \
grim slurp swappy fastfetch wallust nwg-look wl-clipboard \
xdg-desktop-portal xdg-desktop-portal-hyprland xdg-user-dirs"

AUDIO_STACK="pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber"  # PipeWire + WP replaces PulseAudio. :contentReference[oaicite:0]{index=0}

GPU_STACK="mesa mesa-utils vulkan-radeon lib32-vulkan-radeon \
libva-mesa-driver lib32-libva-mesa-driver"  # RADV/VAAPI for AMD. :contentReference[oaicite:1]{index=1}

EVERYDAY_APPS="firefox zathura zathura-pdf-poppler mpv thunar galculator abiword gnumeric ncspot"

FONTS_THEME="noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-jetbrains-mono ttf-font-awesome papirus-icon-theme"

LOGIN="greetd greetd-tuigreet"  # Greeter; config in /etc/greetd/config.toml . :contentReference[oaicite:2]{index=2}

BRIGHTNESS="ddcutil ddcui"      # DDC/CI brightness for external monitors. :contentReference[oaicite:3]{index=3}

PKGS="$BASE_APPS $WAYLAND_STACK $AUDIO_STACK $GPU_STACK $EVERYDAY_APPS $FONTS_THEME $LOGIN $BRIGHTNESS"

echo ">>> Installing packages..."
pacman -Syu --needed --noconfirm $PKGS

# ====== Ensure only the Hyprland portal backend is present ======
if pacman -Q xdg-desktop-portal-wlr >/dev/null 2>&1; then
  echo ">>> Detected xdg-desktop-portal-wlr; removing to avoid conflicts with Hyprland portal"
  pacman -Rns --noconfirm xdg-desktop-portal-wlr || true
fi
# Hyprland docs & Arch recommend running a single suitable backend for the compositor. :contentReference[oaicite:4]{index=4}

# ====== Shell: make zsh default for the user ======
if [ "$(getent passwd "$USER" | cut -d: -f7)" != "/bin/zsh" ]; then
  chsh -s /bin/zsh "$USER"
fi

# ====== User groups (video/audio/input/i2c) ======
usermod -aG video,audio,input,i2c "$USER"

# ====== Load i2c-dev for DDC/CI (external monitor brightness) ======
mkdir -p /etc/modules-load.d
echo i2c-dev > /etc/modules-load.d/i2c-dev.conf
# (ddcutil controls brightness via DDC/CI when supported by the monitor/path.) :contentReference[oaicite:5]{index=5}

# ====== Enable core services ======
systemctl enable NetworkManager || true
systemctl enable fstrim.timer   || true   # weekly TRIM recommended. :contentReference[oaicite:6]{index=6}
systemctl enable greetd         || true

# ====== greetd -> Hyprland ======
install -Dm644 /dev/stdin /etc/greetd/config.toml <<'CFG'
[terminal]
vt = 1

[default_session]
# tuigreet is a TUI greeter that can exec a command after login
command = "tuigreet --time --cmd Hyprland"
user = "greeter"
CFG
# greetd reads /etc/greetd/config.toml by default. :contentReference[oaicite:7]{index=7}

# ====== Hyprland minimal config for the user ======
sudo -u "$USER" mkdir -p "/home/$USER/.config/hypr"
install -Dm644 /dev/stdin "/home/$USER/.config/hypr/hyprland.conf" <<'HYP'
exec-once = dbus-update-activation-environment --systemd --all
exec-once = xdg-user-dirs-update
exec-once = mako
exec-once = waybar
exec-once = swww init

# External monitor brightness via DDC/CI (adjust VCP 0x10 step to taste)
bind = ,XF86MonBrightnessUp,   exec, ddcutil setvcp 10 +10
bind = ,XF86MonBrightnessDown, exec, ddcutil setvcp 10 -10
HYP
chown -R "$USER:$USER" "/home/$USER/.config"

# ====== Zsh: basic plugin setup via zshrc (no heavy managers to keep it simple) ======
if [ ! -f "/home/$USER/.zshrc" ]; then
  cat >"/home/$USER/.zshrc" <<'ZRC'
export EDITOR=vi
bindkey -v
# Plugins installed from repos:
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
ZRC
  chown "$USER:$USER" "/home/$USER/.zshrc"
fi

echo ">>> Done. Reboot to land on the greetd -> Hyprland login."
echo ">>> After reboot:"
echo "    - Verify PipeWire:  systemctl --user status pipewire wireplumber  (active per-user)."
echo "    - Verify GPU:       glxinfo -B   | grep -E 'OpenGL|Mesa'"
echo "    - Verify portal:    login to Hyprland, then:  journalctl --user -u xdg-desktop-portal -b"
echo "    - DDC/CI detect:    sudo ddcutil detect   (DP direct is best)."
