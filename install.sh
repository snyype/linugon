#!/usr/bin/env bash
#
#  Linugon installer — puts the `linugon` command on your PATH.
#
#    curl -fsSL https://raw.githubusercontent.com/snyype/linugon/master/install.sh | bash
#
#  Env overrides:  LINUGON_BRANCH=<branch>   LINUGON_DEST=/path/to/linugon
#
set -euo pipefail

REPO="snyype/linugon"
BRANCH="${LINUGON_BRANCH:-master}"
URL="https://raw.githubusercontent.com/$REPO/$BRANCH/linugon.sh"
# /usr/local/bin is on PATH by default on Debian/Ubuntu, and it's where the
# auto-vhost systemd service expects to find the command.
DEST="${LINUGON_DEST:-/usr/local/bin/linugon}"

if [ -t 1 ]; then
    G=$'\033[0;32m'; C=$'\033[0;36m'; R=$'\033[0;31m'; Y=$'\033[0;33m'; B=$'\033[1m'; N=$'\033[0m'
else
    G=""; C=""; R=""; Y=""; B=""; N=""
fi
say()  { printf '  %s›%s %s\n' "$C" "$N" "$*"; }
ok()   { printf '  %s✔%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '  %s✘%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

printf '\n  %sLinugon installer%s\n\n' "$B" "$N"

[ "$(uname -s)" = "Linux" ] || die "Linugon runs on Linux (Debian/Ubuntu)."
command -v apt-get >/dev/null 2>&1 || die "Linugon supports apt-based distros (Debian/Ubuntu) only."

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else
    command -v sudo >/dev/null 2>&1 || die "sudo is required."
    SUDO="sudo"
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

say "Downloading linugon.sh ($BRANCH)…"
if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$URL" -o "$tmp" || die "Download failed: $URL"
elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp" "$URL" || die "Download failed: $URL"
else
    die "curl or wget is required."
fi

head -n 1 "$tmp" | grep -q '^#!.*bash' || die "Downloaded file is not a bash script."
bash -n "$tmp" || die "Downloaded script has syntax errors; aborting."

say "Installing to $DEST (may ask for your sudo password)…"
$SUDO install -d "$(dirname "$DEST")"
$SUDO install -m 755 "$tmp" "$DEST"
ok "Installed $("$DEST" --version 2>/dev/null | sed 's/^/Linugon v/') → $DEST"

# Make sure the install dir is on PATH (it is by default on Debian/Ubuntu).
dir="$(dirname "$DEST")"
case ":$PATH:" in
    *":$dir:"*) ;;
    *)
        line="export PATH=\"$dir:\$PATH\""
        for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
            [ -f "$rc" ] || continue
            grep -qsF "$line" "$rc" || printf '\n# Added by Linugon installer\n%s\n' "$line" >>"$rc"
        done
        warn "$dir was not on your PATH — added it to your shell profile."
        warn "Open a new terminal (or run: $line)"
        ;;
esac

printf '\n  %sNext:%s run %slinugon%s to open the installer menu\n' "$B" "$N" "$B" "$N"
printf '         or %slinugon install all%s for the full stack.\n\n' "$B" "$N"
