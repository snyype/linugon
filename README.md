# Linugon — Laragon for Linux

A Laragon-style local dev environment for Debian/Ubuntu. One script installs
Apache, PHP (multiple versions), MySQL/MariaDB, phpMyAdmin, Composer, Node.js and
Redis, and gives every project folder its own `http://<name>.test` site
automatically.

**Website:** https://snyype.github.io/linugon/

> Inspired by [Laragon](https://github.com/leokhoa/laragon), the open-source
> portable dev environment for Windows by Leo Khoa. Linugon brings its
> "folder = site" workflow to Linux. It is an independent project, not
> affiliated with or endorsed by Laragon.

## Features

- **Nice interactive UI**: dialog menus and checklists (whiptail). Falls back to plain numbered prompts when whiptail isn't installed.
- **Quick install or solo install**: install everything in one go, or tick only the components you want. Picking phpMyAdmin pulls in Apache, PHP and MySQL if they aren't installed yet.
- **Automatic virtual hosts**: create a folder in `www/` and `http://<folder>.test` works within seconds (a systemd watcher handles it, Laragon-style). Delete the folder and the site goes away.
  - Laravel/Symfony `public/` and Drupal/Craft `web/` doc roots are detected automatically.
  - Folders starting with `_` or `.` are ignored.
- **Custom virtual hosts**: any domain (`api.shop.local`, `myapp.test`) pointing at any folder. Auto-sync never touches custom hosts.
- **Managed `/etc/hosts`**: all entries live in one `# >>> linugon` block, with no duplicates and cleanup when sites are removed.
- **Multiple PHP versions**: on Ubuntu, optionally adds the `ondrej/php` PPA so you can choose PHP 5.6–8.x, then switch the CLI and Apache with one command.
- **Dashboard** at `http://localhost` lists every site, with links to phpMyAdmin and `phpinfo()`.
- **Status & services**: see versions and service state at a glance, and start, stop or restart everything.
- Install steps show a spinner with elapsed time. The full output goes to `~/linugon-linux/logs/linugon.log`.

## Requirements

- Debian or Ubuntu (apt-based), with systemd
- A normal user with `sudo`. Don't run the script as root.

## Install

One line. This downloads Linugon to `/usr/local/bin/linugon`, so it's on your PATH:

```bash
curl -fsSL 'https://raw.githubusercontent.com/snyype/linugon/master/install.sh?v=2.0.3' | bash
```

No curl? `wget -qO- 'https://raw.githubusercontent.com/snyype/linugon/master/install.sh?v=2.0.3' | bash`

Then run:

```bash
linugon
```

Choose **Quick install** for the full stack, or **Install components** to pick
individual pieces. Update any time with `linugon self-update`.

<details>
<summary>Manual install (git clone)</summary>

```bash
git clone https://github.com/snyype/linugon.git
cd linugon
./linugon.sh        # also installs itself as `linugon` after the first install
```
</details>

## Command line

```bash
linugon                               # interactive menu
linugon install all                   # Apache, PHP, MySQL, phpMyAdmin, Composer
linugon install redis node            # solo install, just what you name
linugon vhost add myapp               # http://myapp.test → ~/linugon-linux/www/myapp
linugon vhost add api.shop.local ~/code/shop/public   # any domain, any folder
linugon vhost remove api.shop.local   # project files are kept
linugon vhost list
linugon sync                          # match vhosts to folders in www/ now
linugon watch on|off                  # automatic vhosts on/off
linugon php 8.3                       # switch PHP (CLI + Apache)
linugon status
linugon self-update                   # fetch the latest version
```

## Folder structure

```
~/linugon-linux/
├── www/    # one folder per project → http://<folder>.test
├── logs/   # per-site Apache logs + linugon.log (install output)
└── bin/    # php<version>/php shortcuts
```

## How it works

- Settings are stored in `/etc/linugon.conf` (user, paths, domain suffix). Change the suffix from **Virtual hosts → Change domain suffix**. Avoid `.dev`/`.app` (browsers force HTTPS) and `.local` (mDNS).
- Vhosts are written to `/etc/apache2/sites-available/linugon-<domain>.conf`.
- `linugon-sync.path` reacts the moment a folder is added to or removed from `www/`. `linugon-sync.timer` re-checks every minute, so a `public/` folder created later (for example by `composer create-project`) gets picked up. A sync only reloads Apache when something changed.
- Apache runs as your user (group `www-data`), so projects in your home folder work and frameworks can write to `storage/` and cache folders without `chmod 777`.
- MySQL's `root` account uses socket auth (`sudo mysql`). The installer offers to create a password-based admin user for phpMyAdmin and your apps.

## Upgrading from v1

Re-run `./linugon.sh` and choose **Install components → Apache** (or run `linugon sync`).
Old `<name>.conf` vhosts and loose `/etc/hosts` lines from v1 are migrated to the
managed format automatically.
