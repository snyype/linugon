# Laragon for Linux

A lightweight, portable, and powerful local development environment inspired by Laragon, designed specifically for Linux users. This script automates the installation and configuration of a LAMP stack (Linux, Apache, MySQL, PHP) along with phpMyAdmin and virtual hosts.

## Features
- **Structured Environment**:
  - `www/`: Store your projects.
  - `logs/`: Collect Apache and MySQL logs.
  - `bin/`: Reserve space for binaries or additional tools.
- **Components Installed**:
  - **PHP**: Supports multiple versions with essential extensions.
  - **MySQL**: Secured installation and logging.
  - **Apache**: Pre-configured with log handling and virtual host support.
  - **phpMyAdmin**: Easily manage databases through a web interface.
- **Virtual Host Automation**:
  - Dynamically create virtual hosts for projects.
  - Add hostnames automatically to `/etc/hosts`.
- **Interactive Menu**:
  - Choose to install individual components or set up everything at once.
  - Manage projects easily through the menu.

## Prerequisites
- A Linux system (tested on Debian-based distributions like Ubuntu).
- `sudo` privileges.

## Installation
1. Clone the repository or download the script:
   ```bash
   git clone https://github.com/your-repo/laragon-linux.git
   cd linugon
```


# Laragon for Linux

## Make the script executable:
```bash
chmod +x linugon.sh
```

#Run the script
```
./linugon.sh
```

# Folder Structure
```
$HOME/laragon-linux/
├── www/          # Contains all user projects
├── bin/          # Stores binaries like PHP, MySQL, etc.
└── logs/         # Apache and MySQL logs
```

# Default Locations:
```
www/: Place all your project files here. Each project will have its own virtual host.
logs/: Stores logs for Apache and MySQL.
bin/: Reserved for tools like additional PHP versions or utilities.
```

#Virtual Hosts

```
Choose "Create Virtual Host" from the script menu.
Provide a project name, e.g., mysite.
The script will:
Create a folder in www/ for the project.
Set up an Apache virtual host configuration.
Add an entry to /etc/hosts (e.g., mysite.local).
Access the project in your browser at http://mysite.local.
```
