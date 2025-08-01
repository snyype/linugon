#!/bin/bash

# Colors for better visibility
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No color

# Base directories
LINUGON_HOME="$HOME/linugon-linux"
WWW_DIR="$LINUGON_HOME/www"
LOGS_DIR="$LINUGON_HOME/logs"
BIN_DIR="$LINUGON_HOME/bin"

# PHP versions to install
PHP_VERSIONS=("8.2")

# Function to show loading animation with percentage
loading() {
    local message="$1"
    local max=$2
    local current=0
    echo -n -e "$message"
    while [ $current -le $max ]; do
        echo -n -e "█"
        sleep 0.1
        current=$((current + 1))
        printf "\r$message [%-50s] %3d%%" "" $((current * 100 / max))
    done
    echo ""
}

# Create base directories
create_directories() {
    echo -e "${YELLOW}Creating Linugon folder structure...${NC}"
    mkdir -p "$WWW_DIR" "$LOGS_DIR" "$BIN_DIR"
    loading "Creating directories..." 50
    echo -e "${GREEN}Folder structure created:${NC}"
    echo "  - $WWW_DIR (Projects folder)"
    echo "  - $LOGS_DIR (Logs folder)"
    echo "  - $BIN_DIR (Binaries folder)"
}

# Update system
update_system() {
    echo -e "${YELLOW}Updating system...${NC}"
    sudo apt update && sudo apt upgrade -y
    loading "Updating system..." 50
}

# Install PHP versions
install_php_versions() {
    echo -e "${YELLOW}Installing PHP versions...${NC}"

    for version in "${PHP_VERSIONS[@]}"; do
        echo -e "${YELLOW}Installing PHP $version...${NC}"
        sudo apt install -y "php$version" "libapache2-mod-php$version" "php$version-cli" "php$version-mysql" "php$version-curl" "php$version-mbstring" "php$version-xml" "php$version-zip"
        loading "Installing PHP $version..." 50

        PHP_BIN_DIR="$BIN_DIR/php$version"
        mkdir -p "$PHP_BIN_DIR"

        sudo ln -sf "/usr/bin/php$version" "$PHP_BIN_DIR/php"
        sudo ln -sf "/usr/bin/php$version-cli" "$PHP_BIN_DIR/php-cli"
        sudo ln -sf "/usr/bin/php$version-config" "$PHP_BIN_DIR/php-config"
        echo -e "${GREEN}PHP $version installed successfully!${NC}"
    done
}

# Install MySQL
install_mysql() {
    echo -e "${YELLOW}Installing MySQL...${NC}"
    sudo apt install -y mysql-server
    sudo systemctl start mysql
    sudo systemctl enable mysql
    loading "Installing MySQL..." 50
    echo -e "${GREEN}MySQL installed and running!${NC}"
}

# Install Apache
install_apache() {
    echo -e "${YELLOW}Installing Apache...${NC}"
    sudo apt install -y apache2
    sudo systemctl start apache2
    sudo systemctl enable apache2
    loading "Installing Apache..." 50
    echo -e "${GREEN}Apache installed and running!${NC}"
}

# Install phpMyAdmin (at localhost/phpmyadmin)
install_phpmyadmin() {
    echo -e "${YELLOW}Installing phpMyAdmin...${NC}"
    sudo apt install -y phpmyadmin

    # Link phpMyAdmin to Apache's default document root (/var/www/html)
    sudo ln -sf /usr/share/phpmyadmin /var/www/html/phpmyadmin

    sudo systemctl restart apache2
    loading "Installing phpMyAdmin..." 50
    echo -e "${GREEN}phpMyAdmin installed successfully and accessible at http://localhost/phpmyadmin${NC}"
}

# Automatically create a virtual host for a folder
create_virtual_host() {
    FOLDER_NAME=$(basename "$1")
    PROJECT_DIR="$WWW_DIR/$FOLDER_NAME"
    echo -e "${YELLOW}Creating virtual host for $FOLDER_NAME...${NC}"

    mkdir -p "$PROJECT_DIR"
    echo "<?php echo 'Hello from $FOLDER_NAME!';" > "$PROJECT_DIR/index.php"

    VHOST_CONF="/etc/apache2/sites-available/$FOLDER_NAME.conf"
    sudo bash -c "cat > $VHOST_CONF" <<EOL
<VirtualHost *:80>
    ServerName $FOLDER_NAME.test
    DocumentRoot $PROJECT_DIR
    ErrorLog $LOGS_DIR/$FOLDER_NAME-error.log
    CustomLog $LOGS_DIR/$FOLDER_NAME-access.log combined
    <Directory $PROJECT_DIR>
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOL

    sudo a2ensite "$FOLDER_NAME.conf"
    sudo systemctl reload apache2
    loading "Creating virtual host for $FOLDER_NAME..." 50

    echo -e "${YELLOW}Adding $FOLDER_NAME.test to /etc/hosts...${NC}"
    echo "127.0.0.1 $FOLDER_NAME.test" | sudo tee -a /etc/hosts > /dev/null
    echo -e "${GREEN}Virtual host $FOLDER_NAME.test created successfully!${NC}"
}

# Command to switch PHP versions
php_switch() {
    echo -e "${YELLOW}Switching PHP versions...${NC}"

    echo "Available PHP versions:"
    for dir in "$BIN_DIR"/php*; do
        if [ -d "$dir" ]; then
            version=$(basename "$dir" | sed 's/php//')
            echo "  - PHP $version"
        fi
    done

    read -p "Enter the PHP version to switch to (e.g., 7.4): " selected_version

    if [ -d "$BIN_DIR/php$selected_version" ]; then
        sudo update-alternatives --set php "$BIN_DIR/php$selected_version/php"
        sudo update-alternatives --set php-config "$BIN_DIR/php$selected_version/php-config"
        sudo update-alternatives --set php-cli "$BIN_DIR/php$selected_version/php-cli"
        echo -e "${GREEN}Switched to PHP $selected_version!${NC}"
    else
        echo -e "${RED}PHP version $selected_version not found! Please install it first.${NC}"
    fi
}

# Menu
show_menu() {
    echo -e "${GREEN}Welcome to Linugon Linux Installer${NC}"
    echo "1. Update System"
    echo "2. Install PHP Versions"
    echo "3. Install MySQL"
    echo "4. Install Apache"
    echo "5. Install phpMyAdmin"
    echo "6. Create Virtual Host for Folder"
    echo "7. Install All Components"
    echo "8. Switch PHP Version"
    echo "9. Exit"
}

# Main loop
while true; do
    show_menu
    read -p "Enter your choice: " choice

    case $choice in
        1) update_system ;;
        2) install_php_versions ;;
        3) install_mysql ;;
        4) install_apache ;;
        5) install_phpmyadmin ;;
        6)
            read -p "Enter folder name: " FOLDER_NAME
            create_virtual_host "$WWW_DIR/$FOLDER_NAME"
            ;;
        7)
            update_system
            create_directories
            install_php_versions
            install_mysql
            install_apache
            install_phpmyadmin
            echo -e "${GREEN}All components installed successfully!${NC}"
            ;;
        8) php_switch ;;
        9)
            echo -e "${GREEN}Exiting. Goodbye!${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option! Please choose again.${NC}"
            ;;
    esac
done
