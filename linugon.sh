#!/usr/bin/env bash
#
#  Linugon — a Laragon-style local dev environment for Debian/Ubuntu.
#
#  Interactive:   ./linugon.sh
#  CLI:           linugon install [all|apache php mysql phpmyadmin composer node redis]
#                 linugon vhost add <domain> [document-root]
#                 linugon vhost remove <domain>
#                 linugon vhost list
#                 linugon sync            # create/remove vhosts to match www/ folders
#                 linugon php <version>   # switch CLI + Apache PHP version
#                 linugon status
#
set -o pipefail
shopt -s nullglob

VERSION="2.0.2"
CONF_FILE="/etc/linugon.conf"
SITES_DIR="/etc/apache2/sites-available"
SELF_BIN="/usr/local/bin/linugon"
SELF_URL="https://raw.githubusercontent.com/snyype/linugon/master/linugon.sh"
HOSTS_FILE="/etc/hosts"

# ─── Colors ──────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
    CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; BOLD=""; DIM=""; NC=""
fi

info()  { printf '  %s›%s %s\n' "$CYAN" "$NC" "$*"; }
ok()    { printf '  %s✔%s %s\n' "$GREEN" "$NC" "$*"; }
warn()  { printf '  %s!%s %s\n' "$YELLOW" "$NC" "$*"; }
err()   { printf '  %s✘%s %s\n' "$RED" "$NC" "$*" >&2; }
die()   { err "$*"; exit 1; }

# ─── Config ──────────────────────────────────────────────────────────────────
# /etc/linugon.conf is shared between the interactive script (run as the user)
# and the background sync service (run as root), so both agree on paths.
load_config() {
    LINUGON_USER="$(id -un)"
    LINUGON_HOME="$HOME/linugon-linux"
    TLD="test"
    AUTO_VHOST=1
    # shellcheck disable=SC1090
    [ -r "$CONF_FILE" ] && . "$CONF_FILE"
    WWW_DIR="$LINUGON_HOME/www"
    LOGS_DIR="$LINUGON_HOME/logs"
    BIN_DIR="$LINUGON_HOME/bin"
    LOG_FILE="$LOGS_DIR/linugon.log"
}

save_config() {
    printf '%s\n' \
        "# Linugon configuration — generated $(date '+%F %T')" \
        "LINUGON_USER=\"$LINUGON_USER\"" \
        "LINUGON_HOME=\"$LINUGON_HOME\"" \
        "TLD=\"$TLD\"" \
        "AUTO_VHOST=$AUTO_VHOST" | $SUDO tee "$CONF_FILE" >/dev/null
}

if [ "$EUID" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# ─── Helpers ─────────────────────────────────────────────────────────────────
has()              { command -v "$1" >/dev/null 2>&1; }
pkg_installed()    { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }
pkg_available()    { apt-cache show "$1" >/dev/null 2>&1; }
apache_installed() { [ -x /usr/sbin/apache2 ] && [ -d /etc/apache2 ]; }
is_ubuntu()        { grep -qi '^ID=ubuntu' /etc/os-release 2>/dev/null; }

apt_install() { $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@"; }
apt_update()  { $SUDO apt-get update -q; }

ensure_dirs() {
    if [ "$EUID" -eq 0 ]; then
        install -d -o "$LINUGON_USER" "$LINUGON_HOME" "$WWW_DIR" "$LOGS_DIR" "$BIN_DIR"
    else
        mkdir -p "$WWW_DIR" "$LOGS_DIR" "$BIN_DIR"
    fi
}

slugify() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//'
}

valid_domain() {
    [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]
}

# Laravel/Symfony → public/, Drupal/Craft → web/, otherwise the folder itself.
detect_docroot() {
    local dir="$1"
    if   [ -f "$dir/public/index.php" ] || [ -f "$dir/public/index.html" ]; then echo "$dir/public"
    elif [ -f "$dir/web/index.php" ]; then echo "$dir/web"
    else echo "$dir"
    fi
}

sudo_keepalive() {
    [ -z "$SUDO" ] && return 0
    [ -n "${KEEPALIVE_PID:-}" ] && kill -0 "$KEEPALIVE_PID" 2>/dev/null && return 0
    sudo -v || die "sudo access is required."
    ( while kill -0 "$$" 2>/dev/null; do sudo -n true; sleep 50; done ) 2>/dev/null &
    KEEPALIVE_PID=$!
    trap '[ -n "${KEEPALIVE_PID:-}" ] && kill "$KEEPALIVE_PID" 2>/dev/null' EXIT
}

# Run a command with a spinner; full output goes to the log file.
run_step() {
    local msg="$1"; shift
    local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0 start=$SECONDS rc
    printf '\n=== %s — %s\n' "$(date '+%F %T')" "$msg" >>"$LOG_FILE"
    ( "$@" ) >>"$LOG_FILE" 2>&1 &
    local pid=$!
    if [ -t 1 ]; then
        while kill -0 "$pid" 2>/dev/null; do
            printf '\r  %s%s%s %s %s(%ss)%s ' "$CYAN" "${frames:i++%10:1}" "$NC" "$msg" "$DIM" $((SECONDS - start)) "$NC"
            sleep 0.1
        done
    fi
    wait "$pid"; rc=$?
    if [ $rc -eq 0 ]; then
        printf '\r\033[K  %s✔%s %s %s(%ss)%s\n' "$GREEN" "$NC" "$msg" "$DIM" $((SECONDS - start)) "$NC"
    else
        printf '\r\033[K  %s✘%s %s %s(failed — last lines of %s)%s\n' "$RED" "$NC" "$msg" "$DIM" "$LOG_FILE" "$NC"
        tail -n 12 "$LOG_FILE" | sed 's/^/      /'
    fi
    return $rc
}

pause() { [ -t 0 ] && { echo; read -rp "  ${DIM}Press Enter to continue…${NC}" _; }; }

banner() {
    [ -t 1 ] && clear
    printf '%s' "$CYAN"
    cat <<'EOF'

   ██╗     ██╗███╗   ██╗██╗   ██╗ ██████╗  ██████╗ ███╗   ██╗
   ██║     ██║████╗  ██║██║   ██║██╔════╝ ██╔═══██╗████╗  ██║
   ██║     ██║██╔██╗ ██║██║   ██║██║  ███╗██║   ██║██╔██╗ ██║
   ██║     ██║██║╚██╗██║██║   ██║██║   ██║██║   ██║██║╚██╗██║
   ███████╗██║██║ ╚████║╚██████╔╝╚██████╔╝╚██████╔╝██║ ╚████║
   ╚══════╝╚═╝╚═╝  ╚═══╝ ╚═════╝  ╚═════╝  ╚═════╝ ╚═╝  ╚═══╝
EOF
    printf '%s   Laragon-style dev environment for Linux  ·  v%s%s\n\n' "$DIM" "$VERSION" "$NC"
}

# ─── UI layer: whiptail when available, plain prompts otherwise ──────────────
HAS_TUI=0
if has whiptail && [ -t 0 ] && [ -t 1 ]; then HAS_TUI=1; fi
BACKTITLE="Linugon v$VERSION  ·  Laragon-style dev environment for Linux"
export NEWT_COLORS='
root=white,black
border=cyan,black
window=white,black
shadow=black,black
title=brightcyan,black
button=black,cyan
actbutton=black,brightcyan
compactbutton=white,black
checkbox=white,black
actcheckbox=black,cyan
entry=white,black
label=white,black
listbox=white,black
actlistbox=black,cyan
sellistbox=brightcyan,black
actsellistbox=black,cyan
textbox=white,black
acttextbox=black,cyan
helpline=black,cyan
roottext=cyan,black
'

# ui_menu "Title" "Text" tag desc [tag desc ...]  → prints chosen tag
ui_menu() {
    local title="$1" text="$2"; shift 2
    if ((HAS_TUI)); then
        whiptail --title " $title " --backtitle "$BACKTITLE" --menu "\n$text" 22 78 12 "$@" 3>&1 1>&2 2>&3
        return
    fi
    local tags=() n=0 ans
    printf '\n  %s%s%s\n  %s\n\n' "$BOLD" "$title" "$NC" "$text" >&2
    while (($#)); do tags+=("$1"); n=$((n + 1)); printf '   %s%2d)%s %s\n' "$CYAN" "$n" "$NC" "$2" >&2; shift 2; done
    while true; do
        read -rp "  › " ans || return 1
        [ -z "$ans" ] && return 1
        [[ "$ans" =~ ^[0-9]+$ ]] && ((ans >= 1 && ans <= n)) && break
        printf '  %sChoose 1-%s (Enter to go back)%s\n' "$YELLOW" "$n" "$NC" >&2
    done
    echo "${tags[ans - 1]}"
}

# ui_checklist "Title" "Text" tag desc ON|OFF ...  → prints chosen tags, one per line
ui_checklist() {
    local title="$1" text="$2"; shift 2
    if ((HAS_TUI)); then
        whiptail --title " $title " --backtitle "$BACKTITLE" --separate-output \
            --checklist "\n$text\n\n(Space = toggle, Enter = confirm)" 22 78 10 "$@" 3>&1 1>&2 2>&3
        return
    fi
    local tags=() defaults=() n=0 ans
    printf '\n  %s%s%s\n  %s\n\n' "$BOLD" "$title" "$NC" "$text" >&2
    while (($#)); do
        tags+=("$1"); n=$((n + 1))
        [ "$3" = ON ] && defaults+=("$n")
        printf '   %s%2d)%s [%s] %s\n' "$CYAN" "$n" "$NC" "$([ "$3" = ON ] && echo x || echo ' ')" "$2" >&2
        shift 3
    done
    read -rp "  Numbers separated by spaces [${defaults[*]}]: " ans
    [ -z "$ans" ] && ans="${defaults[*]}"
    local i
    for i in $ans; do [[ "$i" =~ ^[0-9]+$ ]] && ((i >= 1 && i <= n)) && echo "${tags[i - 1]}"; done
}

ui_input() {
    local title="$1" text="$2" def="${3:-}" ans
    if ((HAS_TUI)); then
        whiptail --title " $title " --backtitle "$BACKTITLE" --inputbox "\n$text" 12 78 "$def" 3>&1 1>&2 2>&3
        return
    fi
    read -rp "  $(printf '%b' "$text") [${def}]: " ans
    echo "${ans:-$def}"
}

ui_password() {
    local title="$1" text="$2" ans
    if ((HAS_TUI)); then
        whiptail --title " $title " --backtitle "$BACKTITLE" --passwordbox "\n$text" 12 78 3>&1 1>&2 2>&3
        return
    fi
    read -rsp "  $text: " ans; echo >&2
    echo "$ans"
}

ui_yesno() {
    local title="$1" text="$2" ans
    if ((HAS_TUI)); then
        whiptail --title " $title " --backtitle "$BACKTITLE" --yesno "\n$text" 14 78
        return
    fi
    printf '\n%b\n' "$text" | sed 's/^/  /' >&2
    read -rp "  Continue? [Y/n]: " ans
    [[ ! "$ans" =~ ^[Nn] ]]
}

ui_msg() {
    local title="$1" text="$2"
    if ((HAS_TUI)); then
        whiptail --title " $title " --backtitle "$BACKTITLE" --scrolltext --msgbox "\n$text" 24 82
        return
    fi
    printf '\n  %s%s%s\n\n%b\n' "$BOLD" "$title" "$NC" "$text"
    pause
}

# ─── Apache ──────────────────────────────────────────────────────────────────
install_apache() {
    apt_install apache2 || return 1
    $SUDO systemctl enable --now apache2
}

# Runs Apache as the Linugon user (group www-data) so projects in $HOME are
# readable and frameworks can write to storage/cache dirs without chmod 777.
configure_apache() {
    $SUDO sed -i \
        -e "s/^export APACHE_RUN_USER=.*/export APACHE_RUN_USER=$LINUGON_USER/" \
        -e "s/^export APACHE_RUN_GROUP=.*/export APACHE_RUN_GROUP=www-data/" \
        /etc/apache2/envvars
    $SUDO usermod -aG www-data "$LINUGON_USER"
    $SUDO tee /etc/apache2/conf-available/linugon.conf >/dev/null <<'EOF'
# Managed by Linugon
ServerName localhost
DirectoryIndex index.php index.html index.htm
EOF
    $SUDO a2enconf -q linugon
    $SUDO a2enmod -q rewrite headers
    [ -d /var/lib/phpmyadmin/tmp ] && $SUDO chown -R "$LINUGON_USER:www-data" /var/lib/phpmyadmin/tmp
    $SUDO systemctl restart apache2
}

apache_reload() {
    local out
    if ! out=$($SUDO apache2ctl configtest 2>&1); then
        err "Apache config test failed — not reloading:"
        printf '%s\n' "$out" | sed 's/^/      /' >&2
        return 1
    fi
    systemctl is-active --quiet apache2 && $SUDO systemctl reload apache2
    return 0
}

# Laragon-style dashboard at http://localhost listing every Linugon site.
install_dashboard() {
    $SUDO tee /var/www/html/index.php >/dev/null <<'PHP'
<?php
// Managed by Linugon — regenerated on install.
if (isset($_GET['phpinfo'])) { phpinfo(); exit; }
$sites = [];
foreach (glob('/etc/apache2/sites-enabled/linugon-*.conf') ?: [] as $f) {
    $c = @file_get_contents($f);
    if ($c === false) continue;
    preg_match('/^\s*ServerName\s+(\S+)/m', $c, $n);
    preg_match('/^\s*DocumentRoot\s+"?([^"\n]+)"?/m', $c, $r);
    preg_match('/linugon:type=(\w+)/', $c, $t);
    $sites[] = ['name' => $n[1] ?? '?', 'root' => $r[1] ?? '', 'type' => $t[1] ?? 'auto'];
}
usort($sites, function ($a, $b) { return strcmp($a['name'], $b['name']); });
$h = function ($s) { return htmlspecialchars($s, ENT_QUOTES); };
$pma = is_dir('/usr/share/phpmyadmin');
?><!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Linugon</title>
<style>
:root{--bg:#0f1419;--card:#171d24;--line:#26303b;--text:#e6edf3;--muted:#8b98a5;--accent:#2dd4bf}
@media (prefers-color-scheme:light){:root{--bg:#f6f8fa;--card:#fff;--line:#d8dee4;--text:#1f2328;--muted:#656d76;--accent:#0d9488}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px/1.5 system-ui,-apple-system,Segoe UI,sans-serif}
main{max-width:880px;margin:0 auto;padding:48px 16px}
h1{margin:0;font-size:28px;letter-spacing:-.02em}h1 span{color:var(--accent)}
.sub{color:var(--muted);margin:4px 0 28px}
.chips{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:28px}
.chip{border:1px solid var(--line);background:var(--card);border-radius:999px;padding:6px 14px;color:var(--text);text-decoration:none;font-size:13px}
.chip:hover{border-color:var(--accent)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(250px,1fr));gap:12px}
.site{display:block;background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px;text-decoration:none;color:inherit;transition:border-color .15s}
.site:hover{border-color:var(--accent)}
.site b{display:block;color:var(--accent);font-size:16px}
.site small{display:block;color:var(--muted);font-family:ui-monospace,monospace;font-size:12px;margin-top:6px;word-break:break-all}
.tag{float:right;font-size:11px;color:var(--muted);border:1px solid var(--line);border-radius:4px;padding:0 6px}
.empty{color:var(--muted);border:1px dashed var(--line);border-radius:10px;padding:24px;text-align:center}
code{font-family:ui-monospace,monospace}
</style></head><body><main>
<h1><span>Linugon</span> is running</h1>
<p class="sub">PHP <?= PHP_VERSION ?> · <?= $h($_SERVER['SERVER_SOFTWARE'] ?? 'Apache') ?></p>
<div class="chips">
<?php if ($pma): ?><a class="chip" href="/phpmyadmin">phpMyAdmin</a><?php endif ?>
<a class="chip" href="?phpinfo=1">phpinfo()</a>
</div>
<?php if (!$sites): ?>
<p class="empty">No sites yet. Create a folder in your <code>www/</code> directory and it will appear here.</p>
<?php else: ?><div class="grid">
<?php foreach ($sites as $s): ?>
<a class="site" href="http://<?= $h($s['name']) ?>/"><span class="tag"><?= $h($s['type']) ?></span><b><?= $h($s['name']) ?></b><small><?= $h($s['root']) ?></small></a>
<?php endforeach ?></div><?php endif ?>
</main></body></html>
PHP
}

# ─── PHP ─────────────────────────────────────────────────────────────────────
PHP_CANDIDATES=(5.6 7.0 7.1 7.2 7.3 7.4 8.0 8.1 8.2 8.3 8.4 8.5)
PHP_EXTS=(cli common mysql curl mbstring xml zip gd intl bcmath sqlite3 readline)

php_default_version() { apt-cache depends php 2>/dev/null | grep -oE 'php[0-9]+\.[0-9]+' | head -1 | sed 's/^php//'; }
php_available_versions() { local v; for v in "${PHP_CANDIDATES[@]}"; do pkg_available "php$v-cli" && echo "$v"; done; }
php_installed_versions() {
    local b
    for b in /usr/bin/php[0-9]*; do
        b="${b##*/}"; [[ "$b" =~ ^php[0-9]+\.[0-9]+$ ]] && echo "${b#php}"
    done | sort -V
}
php_active_version() { has php && php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null; }

add_php_ppa() {
    apt_install software-properties-common ca-certificates || return 1
    $SUDO add-apt-repository -y ppa:ondrej/php && apt_update
}

install_php_version() {
    local v="$1" pkgs=() e
    for e in "${PHP_EXTS[@]}"; do pkg_available "php$v-$e" && pkgs+=("php$v-$e"); done
    apache_installed && pkgs+=("libapache2-mod-php$v")
    apt_install "${pkgs[@]}" || return 1
    mkdir -p "$BIN_DIR/php$v" && ln -sf "/usr/bin/php$v" "$BIN_DIR/php$v/php"
}

# Apache installed after PHP has no mod_php yet — add it for the active version.
ensure_mod_php() {
    local v; v="$(php_active_version)"
    [ -n "$v" ] && apache_installed || return 0
    [ -f "/etc/apache2/mods-available/php$v.load" ] || apt_install "libapache2-mod-php$v" || return 1
    php_activate "$v"
}

# Point the `php` CLI and Apache's mod_php at one version.
php_activate() {
    local v="$1" m
    [ -x "/usr/bin/php$v" ] || { err "PHP $v is not installed."; return 1; }
    $SUDO update-alternatives --set php "/usr/bin/php$v" >/dev/null
    if apache_installed && [ -f "/etc/apache2/mods-available/php$v.load" ]; then
        for m in /etc/apache2/mods-enabled/php*.load; do
            m="${m##*/}"; $SUDO a2dismod -q "${m%.load}" >/dev/null
        done
        $SUDO a2dismod -q mpm_event mpm_worker >/dev/null 2>&1
        $SUDO a2enmod -q mpm_prefork "php$v" >/dev/null || return 1
        $SUDO systemctl restart apache2
    fi
}

# ─── MySQL / MariaDB ─────────────────────────────────────────────────────────
db_package() { if pkg_available mysql-server; then echo mysql-server; else echo mariadb-server; fi; }
db_service() { if systemctl list-unit-files mariadb.service 2>/dev/null | grep -q mariadb; then echo mariadb; else echo mysql; fi; }

install_mysql() {
    apt_install "$(db_package)" || return 1
    $SUDO systemctl enable --now "$(db_service)"
}

create_db_user() {
    local u="$1" p="$2"
    p="${p//\\/\\\\}"; p="${p//\'/\\\'}"
    $SUDO mysql <<SQL
CREATE USER IF NOT EXISTS '$u'@'localhost' IDENTIFIED BY '$p';
ALTER USER '$u'@'localhost' IDENTIFIED BY '$p';
GRANT ALL PRIVILEGES ON *.* TO '$u'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
}

# ─── phpMyAdmin & extras ─────────────────────────────────────────────────────
install_phpmyadmin() {
    local pass
    pass="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
    $SUDO debconf-set-selections <<EOF
phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2
phpmyadmin phpmyadmin/dbconfig-install boolean true
phpmyadmin phpmyadmin/mysql/app-pass password $pass
phpmyadmin phpmyadmin/app-password-confirm password $pass
EOF
    apt_install phpmyadmin || return 1
    if [ ! -e /etc/apache2/conf-enabled/phpmyadmin.conf ] && [ -f /etc/phpmyadmin/apache.conf ]; then
        $SUDO ln -sf /etc/phpmyadmin/apache.conf /etc/apache2/conf-available/phpmyadmin.conf
        $SUDO a2enconf -q phpmyadmin
    fi
    # Old Linugon versions symlinked it into the docroot; the Alias replaces that.
    [ -L /var/www/html/phpmyadmin ] && $SUDO rm -f /var/www/html/phpmyadmin
    $SUDO systemctl reload apache2
}

install_composer() { apt_install composer; }
install_node()     { apt_install nodejs npm; }
install_redis()    { apt_install redis-server && $SUDO systemctl enable --now redis-server; }

# ─── Virtual hosts ───────────────────────────────────────────────────────────
conf_path()   { echo "$SITES_DIR/linugon-$1.conf"; }
conf_get()    { sed -n "s/^# linugon:$1=//p" "$2" | head -1; }
conf_domain() { awk '$1 == "ServerName" { print $2; exit }' "$1"; }
linugon_confs() { local f; for f in "$SITES_DIR"/linugon-*.conf; do [ -f "$f" ] && echo "$f"; done; }

render_vhost() {
    local domain="$1" root="$2" type="$3" source="$4"
    cat <<EOF
# Managed by Linugon — use 'linugon vhost' to change this site.
# linugon:type=$type
# linugon:source=$source
<VirtualHost *:80>
    ServerName $domain
    DocumentRoot "$root"
    ErrorLog "$LOGS_DIR/$domain-error.log"
    CustomLog "$LOGS_DIR/$domain-access.log" combined
    <Directory "$root">
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF
}

# Returns 0 if the vhost was created or changed, 1 if it was already up to date.
write_vhost() {
    local domain="$1" conf tmp rc=1
    conf="$(conf_path "$domain")"
    tmp="$(mktemp)"
    render_vhost "$@" >"$tmp"
    if ! [ -f "$conf" ] || ! cmp -s "$tmp" "$conf"; then
        $SUDO install -m 644 "$tmp" "$conf"; rc=0
    fi
    rm -f "$tmp"
    if [ ! -e "/etc/apache2/sites-enabled/linugon-$domain.conf" ]; then
        $SUDO a2ensite -q "linugon-$domain" >/dev/null; rc=0
    fi
    return $rc
}

delete_vhost() {
    local domain="$1"
    $SUDO a2dissite -q "linugon-$domain" >/dev/null 2>&1
    $SUDO rm -f "$(conf_path "$domain")"
}

# Rewrites the Linugon block in /etc/hosts. Returns 0 if the file changed.
update_hosts() {
    local tmp f d
    tmp="$(mktemp)"
    sed '/^# >>> linugon/,/^# <<< linugon/d' "$HOSTS_FILE" >"$tmp"
    {
        echo "# >>> linugon (managed automatically — do not edit inside this block)"
        for f in /etc/apache2/sites-enabled/linugon-*.conf; do
            d="$(conf_domain "$f")"; [ -n "$d" ] && printf '127.0.0.1\t%s\n::1\t\t%s\n' "$d" "$d"
        done
        echo "# <<< linugon"
    } >>"$tmp"
    if cmp -s "$tmp" "$HOSTS_FILE"; then rm -f "$tmp"; return 1; fi
    $SUDO tee "$HOSTS_FILE" <"$tmp" >/dev/null
    rm -f "$tmp"
}

# v1 wrote <name>.conf vhosts and bare /etc/hosts lines; replace them with
# managed ones so there are no duplicate ServerNames.
migrate_legacy() {
    local f d rc=1
    for f in "$SITES_DIR"/*.conf; do
        case "${f##*/}" in linugon-*) continue ;; esac
        grep -q "linugon:type" "$f" && continue
        grep -q "^[[:space:]]*DocumentRoot $WWW_DIR/" "$f" || continue
        d="$(conf_domain "$f")"
        $SUDO a2dissite -q "$(basename "$f" .conf)" >/dev/null 2>&1
        $SUDO rm -f "$f"
        [ -n "$d" ] && $SUDO sed -i "/^127\.0\.0\.1 ${d//./\\.}\$/d" "$HOSTS_FILE"
        rc=0
    done
    return $rc
}

# Make the vhosts match the folders in www/: <folder>.<tld> for every folder,
# remove auto vhosts whose folder is gone. Custom vhosts are never touched.
# Folders starting with "." or "_" are ignored.
cmd_sync() {
    local quiet=0; [ "${1:-}" = "--quiet" ] && quiet=1
    apache_installed || { err "Apache is not installed."; return 1; }
    [ -d "$WWW_DIR" ] || ensure_dirs
    [ -d "$LOGS_DIR" ] || ensure_dirs

    local changed=0 dir name slug domain conf root s covered f
    local -a custom_sources=()
    local -A wanted=()
    migrate_legacy && { changed=1; ((quiet)) || info "Migrated vhosts from Linugon v1."; }
    while IFS= read -r f; do
        [ "$(conf_get type "$f")" = custom ] && custom_sources+=("$(conf_get source "$f")")
    done < <(linugon_confs)

    for dir in "$WWW_DIR"/*/; do
        dir="${dir%/}"; name="${dir##*/}"
        case "$name" in .*|_*) continue ;; esac
        covered=0
        for s in "${custom_sources[@]}"; do
            [[ "$s" == "$dir" || "$s" == "$dir/"* ]] && covered=1
        done
        ((covered)) && continue
        slug="$(slugify "$name")"; [ -z "$slug" ] && continue
        domain="$slug.$TLD"
        conf="$(conf_path "$domain")"
        [ -f "$conf" ] && [ "$(conf_get type "$conf")" = custom ] && continue
        wanted["$domain"]=1
        root="$(detect_docroot "$dir")"
        if write_vhost "$domain" "$root" auto "$dir"; then
            changed=1; ((quiet)) || ok "http://$domain  →  $root"
        fi
    done

    while IFS= read -r f; do
        [ "$(conf_get type "$f")" = auto ] || continue
        domain="$(conf_domain "$f")"
        [ -n "${wanted[$domain]:-}" ] && continue
        delete_vhost "$domain"; changed=1
        ((quiet)) || warn "removed $domain (folder gone, or now served by a custom vhost)"
    done < <(linugon_confs)

    update_hosts
    if ((changed)); then apache_reload || return 1; fi
    ((quiet)) || { ((changed)) && ok "Virtual hosts in sync." || ok "Virtual hosts already up to date."; }
    return 0
}

vhost_add() {
    local domain root
    domain="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
    root="${2:-}"
    [ -z "$domain" ] && { err "A domain is required."; return 1; }
    [[ "$domain" == *.* ]] || domain="$domain.$TLD"
    valid_domain "$domain" || { err "'$domain' is not a valid hostname."; return 1; }
    apache_installed || { err "Apache is not installed."; return 1; }
    [ -z "$root" ] && root="$WWW_DIR/${domain%%.*}"
    root="$(realpath -m "$root")"
    [[ "$root" == *'"'* ]] && { err "Document root may not contain quotes."; return 1; }

    if [ ! -d "$root" ]; then
        mkdir -p "$root" 2>/dev/null || $SUDO install -d -o "$LINUGON_USER" "$root" || return 1
        cat >"$root/index.php" <<EOF
<!doctype html><html><head><meta charset="utf-8"><title>$domain</title>
<style>body{font:16px system-ui;display:grid;place-items:center;height:100vh;margin:0;background:#0f1419;color:#e6edf3}b{color:#2dd4bf}</style></head>
<body><div><h1>Hello from <b>$domain</b></h1><p>Edit <code>$root/index.php</code> — PHP <?= PHP_VERSION ?></p></div></body></html>
EOF
    fi
    ensure_dirs
    write_vhost "$domain" "$root" custom "$root"
    update_hosts
    apache_reload || return 1
    ok "Created ${BOLD}http://$domain${NC}  →  $root"
}

vhost_remove() {
    local domain="$1" conf
    conf="$(conf_path "$domain")"
    [ -f "$conf" ] || { err "No Linugon vhost named '$domain'."; return 1; }
    delete_vhost "$domain"
    update_hosts
    apache_reload
    ok "Removed $domain (project files were not touched)."
}

vhost_list() {
    local f n=0
    printf '  %s%-32s %-7s %s%s\n' "$BOLD" "DOMAIN" "TYPE" "DOCUMENT ROOT" "$NC"
    while IFS= read -r f; do
        n=$((n + 1))
        printf '  %-32s %-7s %s\n' "$(conf_domain "$f")" "$(conf_get type "$f")" \
            "$(sed -n 's/^\s*DocumentRoot "\(.*\)"/\1/p' "$f" | head -1)"
    done < <(linugon_confs)
    ((n)) || printf '  %s(no virtual hosts yet)%s\n' "$DIM" "$NC"
}

# ─── Auto-vhost watcher (systemd) ────────────────────────────────────────────
install_self() {
    local src; src="$(readlink -f "$0")"
    [ "$src" = "$SELF_BIN" ] && return 0
    $SUDO install -m 755 "$src" "$SELF_BIN"
}

self_update() {
    local tmp new url
    tmp="$(mktemp)"
    # Bypass caches when fetching the moving master branch URL.
    url="${SELF_URL}?v=${VERSION}-$(date +%s)"
    if has curl; then curl -fsSL "$url" -o "$tmp"; else wget -qO "$tmp" "$url"; fi \
        || { rm -f "$tmp"; err "Download failed: $SELF_URL"; return 1; }
    if ! head -n 1 "$tmp" | grep -q '^#!.*bash' || ! bash -n "$tmp"; then
        rm -f "$tmp"; err "Downloaded file is not a valid Linugon script."; return 1
    fi
    new="$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$tmp" | head -1)"
    if [ -z "$new" ]; then
        rm -f "$tmp"; err "Could not read the downloaded Linugon version."; return 1
    fi
    if [ "$new" = "$VERSION" ]; then
        rm -f "$tmp"; ok "Linugon is already up to date: v$VERSION ($SELF_BIN)"; return 0
    fi
    $SUDO install -m 755 "$tmp" "$SELF_BIN"; rm -f "$tmp"
    ok "Linugon updated: v$VERSION → v${new:-?} ($SELF_BIN)"
}

watch_enabled() { systemctl is-enabled --quiet linugon-sync.path 2>/dev/null; }

enable_watch() {
    install_self || return 1
    $SUDO tee /etc/systemd/system/linugon-sync.service >/dev/null <<EOF
[Unit]
Description=Linugon: sync Apache virtual hosts with $WWW_DIR
After=apache2.service
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart=$SELF_BIN sync --quiet
EOF
    # Path unit reacts instantly to folders being added/removed; the timer
    # catches later changes such as a public/ dir appearing after composer.
    $SUDO tee /etc/systemd/system/linugon-sync.path >/dev/null <<EOF
[Unit]
Description=Linugon: watch $WWW_DIR for new projects

[Path]
PathModified=$WWW_DIR
Unit=linugon-sync.service

[Install]
WantedBy=multi-user.target
EOF
    $SUDO tee /etc/systemd/system/linugon-sync.timer >/dev/null <<'EOF'
[Unit]
Description=Linugon: periodic virtual host sync

[Timer]
OnBootSec=30s
OnUnitActiveSec=1min
Unit=linugon-sync.service

[Install]
WantedBy=timers.target
EOF
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable --now linugon-sync.path linugon-sync.timer
}

disable_watch() {
    $SUDO systemctl disable --now linugon-sync.path linugon-sync.timer 2>/dev/null
    return 0
}

# ─── Install orchestration ───────────────────────────────────────────────────
ALL_COMPONENTS=(apache php mysql phpmyadmin composer node redis)
PHP_SELECTED=()
DB_USER=""; DB_PASS=""

component_label() {
    case "$1" in
        apache)     echo "Apache 2 web server" ;;
        php)        echo "PHP (choose one or more versions)" ;;
        mysql)      echo "MySQL / MariaDB database" ;;
        phpmyadmin) echo "phpMyAdmin  (http://localhost/phpmyadmin)" ;;
        composer)   echo "Composer — PHP package manager" ;;
        node)       echo "Node.js + npm" ;;
        redis)      echo "Redis server" ;;
    esac
}

component_installed() {
    case "$1" in
        apache)     apache_installed ;;
        php)        [ -n "$(php_installed_versions)" ] ;;
        mysql)      pkg_installed mysql-server || pkg_installed mariadb-server ;;
        phpmyadmin) pkg_installed phpmyadmin ;;
        composer)   has composer ;;
        node)       has node ;;
        redis)      pkg_installed redis-server ;;
    esac
}

# Interactive questions are all asked up front so the install runs unattended.
prepare_php() {
    local interactive="$1" def avail=() items=() v state
    if ((interactive)) && is_ubuntu && ! grep -rqs ondrej /etc/apt/sources.list.d/; then
        if ui_yesno "PHP versions" "Ubuntu only ships one PHP version.\n\nAdd the ondrej/php PPA to choose from PHP 5.6 – 8.x?"; then
            run_step "Adding ondrej/php PPA" add_php_ppa || warn "Could not add the PPA, using distro PHP."
        fi
    fi
    def="$(php_default_version)"
    mapfile -t avail < <(php_available_versions)
    [ ${#avail[@]} -eq 0 ] && { err "No PHP packages found in apt sources."; return 1; }
    [ -z "$def" ] && def="${avail[-1]}"
    if ! ((interactive)); then PHP_SELECTED=("$def"); return 0; fi
    for v in "${avail[@]}"; do
        state=OFF; [ "$v" = "$def" ] && state=ON
        [ -x "/usr/bin/php$v" ] && items+=("$v" "PHP $v  (installed)" ON) || items+=("$v" "PHP $v" "$state")
    done
    mapfile -t PHP_SELECTED < <(ui_checklist "PHP versions" "Select PHP versions to install. The highest one becomes active." "${items[@]}")
    [ ${#PHP_SELECTED[@]} -gt 0 ]
}

prepare_mysql() {
    local u p p2
    ui_yesno "Database user" "MySQL's root account only works via 'sudo mysql' (socket auth),\nso it can't log in to phpMyAdmin or Laravel.\n\nCreate a password-based admin user now?" || return 0
    u="$(ui_input "Database user" "Username:" "$LINUGON_USER")" || return 0
    [[ "$u" =~ ^[A-Za-z0-9_]+$ ]] || { warn "Invalid username, skipping user creation."; return 0; }
    while true; do
        p="$(ui_password "Database user" "Password for '$u':")" || return 0
        p2="$(ui_password "Database user" "Repeat password:")" || return 0
        [ -n "$p" ] && [ "$p" = "$p2" ] && break
        ui_msg "Database user" "Passwords were empty or did not match. Try again."
    done
    DB_USER="$u"; DB_PASS="$p"
}

run_install() {
    local interactive="$1"; shift
    local want=() c started=$SECONDS failed=()
    declare -A sel=()
    for c in "$@"; do sel[$c]=1; done

    # Dependencies: phpMyAdmin needs a web server, PHP and a database.
    if [ -n "${sel[phpmyadmin]:-}" ]; then
        for c in apache php mysql; do component_installed "$c" || sel[$c]=1; done
    fi
    for c in "${ALL_COMPONENTS[@]}"; do [ -n "${sel[$c]:-}" ] && want+=("$c"); done
    [ ${#want[@]} -eq 0 ] && { warn "Nothing selected."; return 0; }

    [ -t 1 ] && banner
    printf '  %sInstalling:%s %s\n' "$BOLD" "$NC" "${want[*]}"
    printf '  %sFull log: %s%s\n\n' "$DIM" "$LOG_FILE" "$NC"
    sudo_keepalive
    ensure_dirs
    [ -f "$CONF_FILE" ] || save_config

    run_step "Refreshing package index" apt_update || return 1

    if [ -n "${sel[php]:-}" ]; then prepare_php "$interactive" || { warn "No PHP version selected."; unset 'sel[php]'; }; fi
    if [ -n "${sel[mysql]:-}" ] && ((interactive)); then prepare_mysql; fi
    echo

    for c in "${want[@]}"; do
        case "$c" in
            apache)
                run_step "Installing Apache" install_apache || { failed+=(apache); continue; }
                run_step "Configuring Apache (runs as $LINUGON_USER)" configure_apache || failed+=(apache-config) ;;
            php)
                [ -n "${sel[php]:-}" ] || continue
                local v
                for v in "${PHP_SELECTED[@]}"; do
                    run_step "Installing PHP $v + extensions" install_php_version "$v" || failed+=("php$v")
                done ;;
            mysql)
                run_step "Installing $(db_package)" install_mysql || { failed+=(mysql); continue; }
                if [ -n "$DB_USER" ]; then
                    run_step "Creating database user '$DB_USER'" create_db_user "$DB_USER" "$DB_PASS" || failed+=(db-user)
                fi ;;
            phpmyadmin) run_step "Installing phpMyAdmin" install_phpmyadmin || failed+=(phpmyadmin) ;;
            composer)   run_step "Installing Composer" install_composer || failed+=(composer) ;;
            node)       run_step "Installing Node.js + npm" install_node || failed+=(node) ;;
            redis)      run_step "Installing Redis" install_redis || failed+=(redis) ;;
        esac
    done

    # Activate last: phpMyAdmin/Composer may pull in the distro's default PHP.
    if [ -n "${sel[php]:-}" ]; then
        local top; top="$(printf '%s\n' "${PHP_SELECTED[@]}" | sort -V | tail -1)"
        run_step "Activating PHP $top" php_activate "$top" || failed+=(php-activate)
    elif apache_installed && [ -n "$(php_installed_versions)" ]; then
        run_step "Enabling PHP for Apache" ensure_mod_php || failed+=(mod-php)
    fi

    if apache_installed; then
        run_step "Installing localhost dashboard" install_dashboard
        run_step "Installing 'linugon' command" install_self
        if ((AUTO_VHOST)) && ! watch_enabled; then
            run_step "Enabling automatic virtual hosts" enable_watch
        fi
        run_step "Syncing virtual hosts with www/" cmd_sync --quiet
    fi

    echo
    if [ ${#failed[@]} -eq 0 ]; then
        ok "${BOLD}Done in $((SECONDS - started))s.${NC}"
    else
        err "Finished with errors in: ${failed[*]}  (see $LOG_FILE)"
    fi
    if apache_installed; then
        echo
        info "Dashboard:   ${BOLD}http://localhost${NC}"
        pkg_installed phpmyadmin && info "phpMyAdmin:  ${BOLD}http://localhost/phpmyadmin${NC}"
        info "Projects:    ${BOLD}$WWW_DIR/<name>${NC}  →  http://<name>.$TLD"
    fi
    [ ${#failed[@]} -eq 0 ]
}

update_system() {
    sudo_keepalive
    ensure_dirs
    run_step "Refreshing package index" apt_update &&
    run_step "Upgrading installed packages" $SUDO env DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y -q
}

# ─── Status ──────────────────────────────────────────────────────────────────
svc() {
    local s; s="$(systemctl is-active "$1" 2>/dev/null)"
    case "$s" in active) echo "● running" ;; "") echo "-" ;; *) echo "○ $s" ;; esac
}

status_text() {
    local apache_v php_v db_v mods n
    apache_v="$(/usr/sbin/apache2 -v 2>/dev/null | sed -n 's/.*Apache\/\([0-9.]*\).*/\1/p')"
    php_v="$(php_active_version)"
    db_v="$(mysql --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-MariaDB)?' | head -1)"
    mods="$(for m in /etc/apache2/mods-enabled/php*.load; do m="${m##*/}"; printf '%s ' "${m%.load}"; done)"
    n="$(linugon_confs | wc -l)"
    printf '%-14s %-22s %s\n' "COMPONENT" "VERSION" "STATE"
    printf '%-14s %-22s %s\n' "Apache"      "${apache_v:-not installed}" "$(apache_installed && svc apache2)"
    printf '%-14s %-22s %s\n' "PHP (CLI)"   "${php_v:-not installed}" "installed: $(php_installed_versions | tr '\n' ' ')"
    printf '%-14s %-22s %s\n' "PHP (Apache)" "${mods:-none}" ""
    printf '%-14s %-22s %s\n' "Database"    "${db_v:-not installed}" "$( [ -n "$db_v" ] && svc "$(db_service)")"
    printf '%-14s %-22s\n'    "phpMyAdmin"  "$(pkg_installed phpmyadmin && echo installed || echo -)"
    printf '%-14s %-22s\n'    "Composer"    "$(has composer && composer --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo -)"
    printf '%-14s %-22s\n'    "Node.js"     "$(has node && node -v || echo -)"
    printf '%-14s %-22s %s\n' "Redis"       "$(pkg_installed redis-server && echo installed || echo -)" "$(pkg_installed redis-server && svc redis-server)"
    echo
    printf 'Projects dir   %s\n' "$WWW_DIR"
    printf 'Domain suffix  .%s\n' "$TLD"
    printf 'Virtual hosts  %s\n' "$n"
    printf 'Auto vhosts    %s\n' "$(watch_enabled && echo "on (watching www/)" || echo off)"
}

# ─── Interactive menus ───────────────────────────────────────────────────────
menu_components() {
    local items=() c sel
    for c in "${ALL_COMPONENTS[@]}"; do
        if component_installed "$c"; then
            items+=("$c" "$(component_label "$c")  ✔ installed" OFF)
        else
            items+=("$c" "$(component_label "$c")" OFF)
        fi
    done
    mapfile -t sel < <(ui_checklist "Install components" "Pick exactly what you want — select a single item for a solo install." "${items[@]}") || return
    [ ${#sel[@]} -eq 0 ] && return
    run_install 1 "${sel[@]}"
    pause
}

menu_vhost_add() {
    local domain root def
    domain="$(ui_input "New virtual host" "Domain (a bare name gets .$TLD, or type a full domain like api.shop.local):" "")" || return
    [ -z "$domain" ] && return
    domain="$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')"
    [[ "$domain" == *.* ]] || domain="$domain.$TLD"
    def="$WWW_DIR/${domain%%.*}"
    [ -d "$def" ] && def="$(detect_docroot "$def")"
    root="$(ui_input "New virtual host" "Document root for $domain (any folder; created if missing):" "$def")" || return
    clear
    sudo_keepalive
    vhost_add "$domain" "$root"
    pause
}

menu_vhost_remove() {
    local items=() f domain
    while IFS= read -r f; do
        items+=("$(conf_domain "$f")" "$(conf_get type "$f")  ·  $(sed -n 's/^\s*DocumentRoot "\(.*\)"/\1/p' "$f" | head -1)")
    done < <(linugon_confs)
    [ ${#items[@]} -eq 0 ] && { ui_msg "Remove virtual host" "There are no Linugon virtual hosts."; return; }
    items+=(0 "← Back")
    domain="$(ui_menu "Remove virtual host" "Choose a site to remove (files stay on disk):" "${items[@]}")" || return
    [ "$domain" = 0 ] && return
    if [ "$(conf_get type "$(conf_path "$domain")")" = auto ]; then
        ui_yesno "Remove $domain" "$domain was created automatically from a folder in www/.\nIt will come back on the next sync unless you rename the\nfolder to start with '_' (e.g. _${domain%%.*}).\n\nRemove anyway?" || return
    fi
    clear; sudo_keepalive
    vhost_remove "$domain"
    pause
}

menu_tld() {
    local t
    t="$(ui_input "Domain suffix" "Suffix for automatic vhosts (current: .$TLD).\nAvoid .dev/.app (forced HTTPS) and .local (mDNS)." "$TLD")" || return
    t="${t#.}"; t="$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')"
    [[ "$t" =~ ^[a-z][a-z0-9-]*$ ]] || { ui_msg "Domain suffix" "'$t' is not a valid suffix."; return; }
    [ "$t" = "$TLD" ] && return
    TLD="$t"
    clear; sudo_keepalive
    save_config
    cmd_sync
    pause
}

menu_vhosts() {
    local choice watch
    while true; do
        watch_enabled && watch="ON — new folders in www/ get a site instantly" || watch="OFF"
        choice="$(ui_menu "Virtual hosts" "Auto vhosts: $watch\nEvery folder in $WWW_DIR becomes http://<folder>.$TLD" \
            1 "List virtual hosts" \
            2 "Sync now  (scan www/ and create/remove sites)" \
            3 "Add a custom virtual host  (any domain, any folder)" \
            4 "Remove a virtual host" \
            5 "Turn automatic vhosts $(watch_enabled && echo OFF || echo ON)" \
            6 "Change domain suffix  (.$TLD)" \
            0 "← Back")" || return
        case "$choice" in
            1) clear; vhost_list; pause ;;
            2) clear; sudo_keepalive; cmd_sync; pause ;;
            3) menu_vhost_add ;;
            4) menu_vhost_remove ;;
            5)
                clear; sudo_keepalive
                if watch_enabled; then
                    disable_watch && AUTO_VHOST=0 && save_config && ok "Automatic vhosts turned off."
                else
                    apache_installed || { err "Install Apache first."; pause; continue; }
                    AUTO_VHOST=1; save_config
                    run_step "Enabling automatic virtual hosts" enable_watch && cmd_sync
                fi
                pause ;;
            6) menu_tld ;;
            0) return ;;
        esac
    done
}

menu_php() {
    local items=() v active
    active="$(php_active_version)"
    for v in $(php_installed_versions); do
        items+=("$v" "PHP $v$([ "$v" = "$active" ] && echo '   ← active')")
    done
    [ ${#items[@]} -eq 0 ] && { ui_msg "Switch PHP" "No PHP versions installed yet. Use 'Install components' first."; return; }
    items+=(0 "← Back")
    v="$(ui_menu "Switch PHP" "Sets the version for the php CLI and Apache:" "${items[@]}")" || return
    [ "$v" = 0 ] && return
    clear; sudo_keepalive; ensure_dirs
    run_step "Switching to PHP $v" php_activate "$v"
    pause
}

menu_services() {
    local choice action db
    db="$(db_service)"
    choice="$(ui_menu "Services" "Apache: $(svc apache2)   ·   Database: $(svc "$db")" \
        1 "Start all" 2 "Stop all" 3 "Restart all" 0 "← Back")" || return
    case "$choice" in 1) action=start ;; 2) action=stop ;; 3) action=restart ;; *) return ;; esac
    clear; sudo_keepalive
    local s
    for s in apache2 "$db" redis-server; do
        systemctl list-unit-files "$s.service" 2>/dev/null | grep -q "$s" || continue
        $SUDO systemctl "$action" "$s" && ok "$action $s" || err "$action $s failed"
    done
    pause
}

main_menu() {
    local choice
    while true; do
        ((HAS_TUI)) || banner
        choice="$(ui_menu "Linugon" " _      _ _  _ _   _  ____  _   _
| |    | | \| | | | |/ ___|| | | |
| |    | | .\` | | | | |  _ | | | |
| |___ | | |\ | |_| | |_| || |_| |
|_____||_|_| \_|\__, |\____| \___/
                 |___/

What would you like to do?" \
            1 "Quick install — everything (Apache, PHP, MySQL, phpMyAdmin, Composer)" \
            2 "Install components — pick one or several" \
            3 "Virtual hosts — auto & custom" \
            4 "Switch PHP version" \
            5 "Services — start / stop / restart" \
            6 "Status" \
            7 "Update system packages" \
            0 "Exit")" || { clear; exit 0; }
        case "$choice" in
            1) ui_yesno "Quick install" "Install Apache, PHP, MySQL, phpMyAdmin and Composer,\nand turn on automatic virtual hosts for $WWW_DIR?" \
                   && { run_install 1 apache php mysql phpmyadmin composer; pause; } ;;
            2) menu_components ;;
            3) menu_vhosts ;;
            4) menu_php ;;
            5) menu_services ;;
            6) ui_msg "Status" "$(status_text)" ;;
            7) clear; update_system; pause ;;
            0) clear; exit 0 ;;
        esac
    done
}

usage() {
    cat <<EOF
Linugon v$VERSION — Laragon-style dev environment for Debian/Ubuntu

Usage: linugon [command]

  (no command)                    Interactive menu
  install all                     Install Apache, PHP, MySQL, phpMyAdmin, Composer
  install <component...>          Install only what you name:
                                  ${ALL_COMPONENTS[*]}
  vhost add <domain> [root]       Custom vhost (bare name gets .$TLD)
  vhost remove <domain>           Remove a vhost (files are kept)
  vhost list                      List vhosts
  sync [--quiet]                  Create/remove vhosts to match folders in www/
  watch on|off                    Toggle automatic vhosts
  php <version>                   Switch PHP version (CLI + Apache)
  status                          Show installed components and services
  self-update                     Download the latest Linugon to $SELF_BIN
EOF
}

# ─── Entry point ─────────────────────────────────────────────────────────────
main() {
    case "${1:-}" in -v|--version) echo "$VERSION"; return 0 ;; esac
    has apt-get || die "Linugon supports Debian/Ubuntu (apt) systems only."
    if [ "$EUID" -eq 0 ] && [ "${1:-}" != "sync" ] && [ ! -f "$CONF_FILE" ]; then
        die "Run Linugon as your normal user (it will ask for sudo when needed)."
    fi
    load_config
    [ "$EUID" -ne 0 ] && ensure_dirs
    [ -w "$LOGS_DIR" ] || LOG_FILE="/dev/null"

    case "${1:-}" in
        "") main_menu ;;
        install)
            shift
            [ $# -eq 0 ] || [ "$1" = all ] && set -- apache php mysql phpmyadmin composer
            local c
            for c in "$@"; do [[ " ${ALL_COMPONENTS[*]} " == *" $c "* ]] || die "Unknown component '$c'."; done
            run_install 0 "$@" ;;
        vhost)
            case "${2:-}" in
                add)    sudo_keepalive; vhost_add "${3:-}" "${4:-}" ;;
                remove) sudo_keepalive; vhost_remove "${3:-}" ;;
                list|"") vhost_list ;;
                *) usage; exit 1 ;;
            esac ;;
        sync)   shift; [ "$EUID" -ne 0 ] && sudo_keepalive; cmd_sync "$@" ;;
        watch)
            sudo_keepalive
            case "${2:-}" in
                on)  AUTO_VHOST=1; save_config; enable_watch && cmd_sync && ok "Automatic vhosts on." ;;
                off) AUTO_VHOST=0; save_config; disable_watch && ok "Automatic vhosts off." ;;
                *) usage; exit 1 ;;
            esac ;;
        php)    [ -n "${2:-}" ] || { php_installed_versions; exit 0; }; sudo_keepalive; php_activate "$2" && ok "Now using PHP $2" ;;
        status) status_text ;;
        self-update|update) sudo_keepalive; self_update ;;
        -h|--help|help) usage ;;
        -v|--version) echo "$VERSION" ;;
        *) usage; exit 1 ;;
    esac
}

main "$@"
