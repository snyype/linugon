#!/bin/bash

# Colors for better visibility
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No color

# Base directories
LARAGON_HOME="$HOME/laragon-linux"
WWW_DIR="$LARAGON_HOME/www"
LOGS_DIR="$LARAGON_HOME/logs"
BIN_DIR="$LARAGON_HOME/bin"

# Create base directories
create_directories() {
    echo -e "${YELLOW}Creating Laragon folder structure...${NC}"
    mkdir -p "$WWW_DIR" "$LOGS_DIR" "$BIN_DIR"
    echo -e "${GREEN}Folder structure created:${NC}"
    echo "  - $WWW_DIR (Projects folder)"
    echo "  - $LOGS_DIR (Logs folder)"
    echo "  - $BIN_DIR (Binaries folder)"
}

# Update system
update_system() {
    echo -e "${YELLOW}Updating system...${NC}"
    sudo apt update && sudo apt upgrade -y
}

# Install PHP
install_php() {
    echo -e "${YELLOW}Installing PHP...${NC}"
    sudo apt install -y software-properties-common
    sudo add-apt-repository ppa:ondrej/php -y
    sudo apt update
    sudo apt install -y php libapache2-mod-php php-mysql php-cli php-curl php-mbstring php-xml php-zip
    echo -e "${GREEN}PHP installed successfully!${NC}"
}

# Install MySQL
install_mysql() {
    echo -e "${YELLOW}Installing MySQL...${NC}"
    sudo apt install -y mysql-server
    sudo mysql_secure_installation
    echo -e "${GREEN}MySQL installed successfully!${NC}"
    echo -e "${YELLOW}Storing logs in $LOGS_DIR/mysql.log${NC}"
    sudo systemctl enable mysql
    sudo systemctl start mysql
}

# Install Apache
install_apache() {
    echo -e "${YELLOW}Installing Apache...${NC}"
    sudo apt install -y apache2
    sudo systemctl enable apache2
    sudo systemctl start apache2

    # Set up logs
    echo -e "${YELLOW}Configuring Apache logs...${NC}"
    sudo sed -i "s|ErrorLog .*|ErrorLog ${LOGS_DIR}/apache_error.log|g" /etc/apache2/apache2.conf
    sudo sed -i "s|CustomLog .*|CustomLog ${LOGS_DIR}/apache_access.log combined|g" /etc/apache2/apache2.conf

    # Enable required Apache modules
    sudo a2enmod rewrite
    sudo systemctl restart apache2
    echo -e "${GREEN}Apache installed and configured successfully!${NC}"
}

# Install phpMyAdmin
install_phpmyadmin() {
    echo -e "${YELLOW}Installing phpMyAdmin...${NC}"
    sudo apt install -y phpmyadmin
    sudo ln -s /usr/share/phpmyadmin "$WWW_DIR/phpmyadmin"
    sudo systemctl restart apache2
    echo -e "${GREEN}phpMyAdmin installed successfully!${NC}"
}

# Set up a virtual host
create_virtual_host() {
    read -p "Enter project name (e.g., mysite): " PROJECT_NAME
    PROJECT_DIR="$WWW_DIR/$PROJECT_NAME"
    echo -e "${YELLOW}Creating virtual host for $PROJECT_NAME...${NC}"

    # Create project directory
    mkdir -p "$PROJECT_DIR"
    echo "<?php echo 'Hello from $PROJECT_NAME!';" > "$PROJECT_DIR/index.php"

    # Create Apache virtual host config
    VHOST_CONF="/etc/apache2/sites-available/$PROJECT_NAME.conf"
    sudo bash -c "cat > $VHOST_CONF" <<EOL
<VirtualHost *:80>
    ServerName $PROJECT_NAME.local
    DocumentRoot $PROJECT_DIR
    ErrorLog $LOGS_DIR/$PROJECT_NAME-error.log
    CustomLog $LOGS_DIR/$PROJECT_NAME-access.log combined
    <Directory $PROJECT_DIR>
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOL

    # Enable the site and restart Apache
    sudo a2ensite "$PROJECT_NAME.conf"
    sudo systemctl reload apache2

    # Add to /etc/hosts
    echo -e "${YELLOW}Adding $PROJECT_NAME.local to /etc/hosts...${NC}"
    echo "127.0.0.1 $PROJECT_NAME.local" | sudo tee -a /etc/hosts > /dev/null
    echo -e "${GREEN}Virtual host $PROJECT_NAME created successfully!${NC}"
}

# Menu
show_menu() {
    echo -e "${GREEN}Welcome to Laragon Linux Installer${NC}"
    echo "1. Update System"
    echo "2. Install PHP"
    echo "3. Install MySQL"
    echo "4. Install Apache"
    echo "5. Install phpMyAdmin"
    echo "6. Create Virtual Host"
    echo "7. Install All Components"
    echo "8. Exit"
}

# Main loop
while true; do
    show_menu
    read -p "Enter your choice: " choice

    case $choice in
        1) update_system ;;
        2) install_php ;;
        3) install_mysql ;;
        4) install_apache ;;
        5) install_phpmyadmin ;;
        6) create_virtual_host ;;
        7)
            update_system
            create_directories
            install_php
            install_mysql
            install_apache
            install_phpmyadmin
            echo -e "${GREEN}All components installed successfully!${NC}"
            ;;
        8)
            echo -e "${GREEN}Exiting. Goodbye!${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option! Please choose again.${NC}"
            ;;
    esac
done
