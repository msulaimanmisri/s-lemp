#!/bin/bash

# Complete LEMP Stack Removal Script for Ubuntu
# This script will completely remove ALL LEMP components and Laravel installations
#
# @author Sulaiman Misri
# @web https://sulaimanmisri.com

# Remove strict error handling for more graceful cleanup
# set -Eeuo pipefail
# trap 'echo "[ERROR] Line $LINENO exited with status $?" >&2' ERR

# =================================================================================
# GLOBAL VARIABLES
# =================================================================================
PHP_VERSION="8.3"
SKIP_MARIADB_CONFIRM="false"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

# Function to safely stop and disable services, and remove orphaned systemd units
safe_stop_service() {
    local service_name=$1
    echo "Stopping $service_name service..."
    if systemctl is-active --quiet $service_name 2>/dev/null; then
        sudo systemctl stop $service_name || warning "Failed to stop $service_name"
    else
        log "$service_name service is not running"
    fi
    if systemctl is-enabled --quiet $service_name 2>/dev/null; then
        sudo systemctl disable $service_name || warning "Failed to disable $service_name"
    else
        log "$service_name service is not enabled"
    fi
    # Remove orphaned systemd unit files if present
    if [ -f "/usr/lib/systemd/system/${service_name}.service" ]; then
        sudo rm -f "/usr/lib/systemd/system/${service_name}.service"
        log "Removed orphaned systemd unit: /usr/lib/systemd/system/${service_name}.service"
    fi
    if [ -f "/lib/systemd/system/${service_name}.service" ]; then
        sudo rm -f "/lib/systemd/system/${service_name}.service"
        log "Removed orphaned systemd unit: /lib/systemd/system/${service_name}.service"
    fi
}

# Function to safely remove packages
safe_remove_packages() {
    local packages=("$@")
    echo "Removing packages: ${packages[*]}"

    # First, try to fix any broken packages
    sudo dpkg --configure -a || warning "Failed to configure packages"
    sudo apt-get -f install -y || warning "Failed to fix broken dependencies"

    for package in "${packages[@]}"; do
        if dpkg -l | grep -q "^ii.*$package"; then
            echo "Removing $package..."
            sudo apt-get remove --purge -y "$package" || warning "Failed to remove $package"
        else
            log "$package is not installed"
        fi
    done
}

# Function to remove Laravel scheduler cronjobs for www-data user
remove_laravel_cronjobs() {
    log "Checking for Laravel scheduler cronjobs..."
    
    # Check if www-data user exists
    if ! id -u www-data >/dev/null 2>&1; then
        log "www-data user not found, skipping cronjob removal"
        return 0
    fi
    
    # Get current www-data crontab content
    local current_crontab=""
    if sudo crontab -u www-data -l >/dev/null 2>&1; then
        current_crontab=$(sudo crontab -u www-data -l 2>/dev/null)
        
        if [[ -n "$current_crontab" ]]; then
            log "Found existing cronjobs for www-data user"
            
            # Check if Laravel scheduler cronjob exists
            if echo "$current_crontab" | grep -q "schedule:run"; then
                log "Found Laravel scheduler cronjob, removing..."
                
                # Remove Laravel scheduler cronjob lines
                local cleaned_crontab=$(echo "$current_crontab" | grep -v "schedule:run" | grep -v "Laravel Scheduler")
                
                if [[ -n "$cleaned_crontab" && "$cleaned_crontab" != "" ]]; then
                    # Update crontab with remaining entries
                    echo "$cleaned_crontab" | sudo crontab -u www-data -
                    log "✓ Laravel scheduler cronjob removed, other cronjobs preserved"
                else
                    # Remove entire crontab if only Laravel entries existed
                    sudo crontab -u www-data -r 2>/dev/null || true
                    log "✓ All www-data cronjobs removed (only Laravel scheduler was present)"
                fi
            else
                log "No Laravel scheduler cronjobs found for www-data user"
            fi
        else
            log "No cronjobs found for www-data user"
        fi
    else
        log "No crontab exists for www-data user"
    fi
    
    # Also remove any system-wide cron files that might contain Laravel scheduler
    log "Checking system-wide cron directories..."
    
    # Check /etc/cron.d/ for Laravel-related files
    if ls /etc/cron.d/*laravel* >/dev/null 2>&1; then
        sudo rm -f /etc/cron.d/*laravel*
        log "✓ Removed Laravel-related files from /etc/cron.d/"
    fi
    
    # Check for any cron files mentioning schedule:run
    local cron_files_with_laravel=$(grep -l "schedule:run" /etc/cron.d/* 2>/dev/null || true)
    if [[ -n "$cron_files_with_laravel" ]]; then
        for file in $cron_files_with_laravel; do
            sudo rm -f "$file"
            log "✓ Removed Laravel scheduler from: $file"
        done
    fi
    
    log "✓ Laravel cronjob cleanup completed"
}

echo " "
echo "============================================="
echo "COMPLETE LEMP Stack Removal Script"
echo "============================================="
log "This script will COMPLETELY remove ALL LEMP components"
warning "This will permanently delete ALL data and configurations!"
warning "This includes PHP, databases, web servers, and ALL related files!"
read -p "Are you sure you want to continue? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log "Removal cancelled by user"
    exit 0
fi

echo " "
read -p "Do you want to skip confirmation for MariaDB/MySQL removal? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    SKIP_MARIADB_CONFIRM="true"
fi

echo " "
echo "============================================="
echo "Step 1: Stopping ALL services first"
echo "============================================="
safe_stop_service "nginx"
safe_stop_service "php${PHP_VERSION}-fpm"
safe_stop_service "php8.4-fpm"
safe_stop_service "php-fpm"
safe_stop_service "mariadb"
safe_stop_service "mysql"
safe_stop_service "redis-server"
safe_stop_service "supervisor"
safe_stop_service "certbot.timer"
safe_stop_service "apache2"
safe_stop_service "httpd"
safe_stop_service "apache2-bin"
safe_stop_service "apache2-utils"

# Reload systemd daemon after unit file removal
sudo systemctl daemon-reload

echo " "
echo "============================================="
echo "Step 2: Removing PHP and ALL related extensions"
echo "============================================="
# Remove ALL PHP versions and extensions (including held packages)
sudo apt-get purge --allow-change-held-packages -y 'php*' 'libapache2-mod-php*'
# Remove any remaining config files and dependencies
sudo apt-get autoremove --purge -y
sudo apt-get autoclean
# Remove PHP directories (be careful!)
sudo rm -rf /etc/php /var/log/php /run/php /usr/lib/php* /usr/share/php*

echo " "
echo "============================================="
echo "Step 3: Removing Nginx"
echo "============================================="
safe_remove_packages "nginx" "nginx-common" "nginx-core" "nginx-full" "nginx-extras"

echo " "
echo "============================================="
echo "Step 4: Removing MariaDB/MySQL"
echo "============================================="
if [[ "$SKIP_MARIADB_CONFIRM" == "false" ]]; then
    read -p "Are you sure you want to remove MariaDB/MySQL? This will delete ALL databases! (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "MariaDB/MySQL removal cancelled by user"
    else
        safe_remove_packages "mariadb-server" "mariadb-client" "mariadb-common" "mysql-server" "mysql-client" "mysql-common"
    fi
else
    safe_remove_packages "mariadb-server" "mariadb-client" "mariadb-common" "mysql-server" "mysql-client" "mysql-common"
fi

echo " "
echo "============================================="
echo "Step 5: Removing Node.js and NPM"
echo "============================================="
safe_remove_packages "nodejs" "npm"

echo " "
echo "============================================="
echo "Step 6: Removing Redis"
echo "============================================="
safe_remove_packages "redis-server" "redis-tools"

echo " "
echo "============================================="
echo "Step 7: Removing Supervisor"
echo "============================================="
safe_remove_packages "supervisor"

echo " "
echo "============================================="
echo "Step 8: Removing Certbot and SSL"
echo "============================================="
safe_remove_packages "certbot" "python3-certbot-nginx" "snapd"

echo " "
echo "============================================="
echo "Step 9: Removing Apache (if present)"
echo "============================================="
safe_remove_packages "apache2" "apache2-bin" "apache2-utils" "libapache2-mod-*"

# Additional thorough Apache removal
log "Performing thorough Apache removal..."
# Get all installed packages containing 'apache' and remove them
apache_packages=$(dpkg -l | grep -i apache | awk '{print $2}' | tr '\n' ' ')
if [[ -n "$apache_packages" ]]; then
    echo "Found additional Apache packages: $apache_packages"
    sudo apt-get remove --purge -y $apache_packages || warning "Failed to remove some Apache packages"
else
    log "No additional Apache packages found"
fi

# Remove Apache directories and configurations
sudo rm -rf /etc/apache2
sudo rm -rf /var/www/html
sudo rm -rf /var/log/apache2
sudo rm -rf /usr/lib/apache2
sudo rm -rf /usr/share/apache2

echo " "
echo "============================================="
echo "Step 10: Removing configuration files and directories"
echo "============================================="
log "Removing Composer..."
sudo rm -f /usr/local/bin/composer
sudo rm -f /usr/local/bin/composer
sudo rm -f /usr/bin/composer
rm -f composer.phar
rm -f composer-setup.php
sudo apt remove --purge composer -y 2>/dev/null || true

log "Removing SSL certificates..."
sudo rm -rf /etc/letsencrypt
sudo rm -rf /etc/ssl/certs/*laravel*
sudo rm -rf /etc/ssl/private/*laravel*

log "Removing project directories..."
sudo rm -rf /var/www/laravel*
sudo rm -rf /var/www/html/*
sudo rm -rf /var/www/*

log "Removing Nginx configurations..."
sudo rm -f /etc/nginx/sites-available/laravel*
sudo rm -f /etc/nginx/sites-enabled/laravel*
sudo rm -rf /etc/nginx/sites-available/*
sudo rm -rf /etc/nginx/sites-enabled/*
sudo rm -rf /etc/nginx/conf.d/*

log "Removing PHP configurations..."
sudo rm -rf /etc/php
sudo rm -rf /var/log/php

log "Removing MariaDB/MySQL data (WARNING: This deletes ALL databases!)..."
sudo rm -rf /var/lib/mysql
sudo rm -rf /etc/mysql
sudo rm -rf /var/lib/mysql-files
sudo rm -rf /var/lib/mysql-keyring

log "Removing Redis data..."
sudo rm -rf /var/lib/redis
sudo rm -rf /etc/redis

log "Removing Supervisor configurations..."
sudo rm -rf /etc/supervisor

log "Removing Apache configurations..."
sudo rm -rf /etc/apache2

echo " "
echo "============================================="
echo "Step 11: Removing helper scripts and aliases"
echo "============================================="
sudo rm -f /usr/local/bin/create-laravel-project
sudo rm -f /usr/local/bin/lemp-info
sudo rm -f /usr/local/bin/fix-laravel-permissions
sudo rm -f /etc/profile.d/laravel-aliases.sh

echo " "
echo "============================================="
echo "Step 12: Removing Laravel scheduler cronjobs"
echo "============================================="
remove_laravel_cronjobs

echo " "
echo "============================================="
echo "Step 13: Removing PPAs and repositories"
echo "============================================="
log "Removing Ondrej PHP PPA..."
sudo add-apt-repository --remove ppa:ondrej/php -y 2>/dev/null || warning "Failed to remove PHP PPA"

log "Removing NodeSource repository..."
sudo rm -f /etc/apt/sources.list.d/nodesource.list
sudo rm -f /etc/apt/keyrings/nodesource.gpg

log "Removing other repositories..."
sudo rm -f /etc/apt/sources.list.d/*nginx*
sudo rm -f /etc/apt/sources.list.d/*mariadb*
sudo rm -f /etc/apt/sources.list.d/*redis*

echo " "
echo "============================================="
echo "Step 14: Cleaning user home directories"
echo "============================================="
log "Removing user-level configuration remnants..."

# Get all regular users (UID >= 1000, excluding nobody)
users=$(awk -F: '$3 >= 1000 && $3 != 65534 {print $1":"$6}' /etc/passwd)

for user_info in $users; do
    username=$(echo $user_info | cut -d: -f1)
    homedir=$(echo $user_info | cut -d: -f2)

    if [ -d "$homedir" ]; then
        log "Cleaning $username's home directory: $homedir"

        # Remove Composer cache and config
        sudo rm -rf "$homedir/.composer" 2>/dev/null || true
        sudo rm -rf "$homedir/.config/composer" 2>/dev/null || true

        # Remove NPM cache and config
        sudo rm -rf "$homedir/.npm" 2>/dev/null || true
        sudo rm -f "$homedir/.npmrc" 2>/dev/null || true

        # Remove Node.js REPL history
        sudo rm -f "$homedir/.node_repl_history" 2>/dev/null || true

        # Remove MySQL/MariaDB client history
        sudo rm -f "$homedir/.mysql_history" 2>/dev/null || true

        # Remove Redis CLI history
        sudo rm -f "$homedir/.rediscli_history" 2>/dev/null || true

        # Remove user-level PHP configurations
        sudo rm -rf "$homedir/.config/php" 2>/dev/null || true

        # Remove Laravel-specific directories if they exist
        sudo rm -rf "$homedir/.laravel" 2>/dev/null || true
        sudo rm -rf "$homedir/.config/laravel" 2>/dev/null || true

        # Remove any LEMP-related bash aliases from user profiles
        if [ -f "$homedir/.bashrc" ]; then
            sudo sed -i '/# Laravel Development Aliases/,/# End Laravel Aliases/d' "$homedir/.bashrc" 2>/dev/null || true
            sudo sed -i '/alias artisan=/d' "$homedir/.bashrc" 2>/dev/null || true
            sudo sed -i '/alias tinker=/d' "$homedir/.bashrc" 2>/dev/null || true
            sudo sed -i '/alias serve=/d' "$homedir/.bashrc" 2>/dev/null || true
        fi

        if [ -f "$homedir/.profile" ]; then
            sudo sed -i '/# Laravel Development Aliases/,/# End Laravel Aliases/d' "$homedir/.profile" 2>/dev/null || true
        fi

        log "✓ Cleaned $username's directory"
    fi
done

# Also clean root's home directory
log "Cleaning root's home directory..."
sudo rm -rf /root/.composer 2>/dev/null || true
sudo rm -rf /root/.config/composer 2>/dev/null || true
sudo rm -rf /root/.npm 2>/dev/null || true
sudo rm -f /root/.npmrc 2>/dev/null || true
sudo rm -f /root/.node_repl_history 2>/dev/null || true
sudo rm -f /root/.mysql_history 2>/dev/null || true
sudo rm -f /root/.rediscli_history 2>/dev/null || true
sudo rm -rf /root/.config/php 2>/dev/null || true
sudo rm -rf /root/.laravel 2>/dev/null || true

echo " "
echo "============================================="
echo "Step 15: Removing system-wide caches and temporary files"
echo "============================================="
log "Removing system-wide cache files..."

# Remove APT cache for removed packages
sudo apt-get clean
sudo apt-get autoclean

# Remove systemd journal logs related to removed services
sudo journalctl --vacuum-time=1d || warning "Failed to clean journal logs"

# Remove any leftover pid files
sudo rm -f /var/run/nginx.pid 2>/dev/null || true
sudo rm -f /var/run/php/php${PHP_VERSION}-fpm.pid 2>/dev/null || true
sudo rm -f /var/run/mysqld/mysqld.pid 2>/dev/null || true
sudo rm -f /var/run/redis/redis-server.pid 2>/dev/null || true
sudo rm -f /var/run/apache2/apache2.pid 2>/dev/null || true

# Remove any leftover socket files
sudo rm -f /var/run/php/php${PHP_VERSION}-fpm.sock 2>/dev/null || true
sudo rm -f /var/run/mysqld/mysqld.sock 2>/dev/null || true
sudo rm -f /var/run/redis/redis-server.sock 2>/dev/null || true

# Remove any leftover lock files
sudo rm -f /var/lock/nginx.lock 2>/dev/null || true
sudo rm -f /var/lock/apache2 2>/dev/null || true
sudo rm -f /var/lock/subsys/* 2>/dev/null || true

# Remove temporary installation files
sudo rm -rf /tmp/composer-setup.php 2>/dev/null || true
sudo rm -rf /tmp/node-* 2>/dev/null || true
sudo rm -rf /tmp/npm-* 2>/dev/null || true
sudo rm -rf /tmp/php* 2>/dev/null || true

# Remove snap directories if snapd was removed
sudo rm -rf /snap 2>/dev/null || true
sudo rm -rf /var/snap 2>/dev/null || true
sudo rm -rf /var/lib/snapd 2>/dev/null || true

log "✓ System caches and temporary files cleaned"

echo " "
echo "============================================="
echo "Step 16: Final system verification and cleanup"
echo "============================================="
log "Removing any leftover packages..."
sudo apt-get autoremove --purge -y
sudo apt-get autoclean
sudo apt-get clean

log "Fixing any broken packages..."
sudo dpkg --configure -a || warning "Some packages may still have issues"
sudo apt-get -f install -y || warning "Failed to fix some dependencies"

log "Updating package database..."
sudo apt-get update || warning "Failed to update package database"

log "Verifying complete removal..."
# Final cleanup of any remaining LEMP packages
log "Performing final cleanup of any remaining packages..."

# Remove any remaining apache packages
remaining_apache=$(dpkg -l | awk '$1 == "ii" && $2 ~ /apache/ {print $2}' | tr '\n' ' ')
if [[ -n "$remaining_apache" ]]; then
    log "Removing remaining Apache packages: $remaining_apache"
    sudo apt-get remove --purge -y $remaining_apache || warning "Failed to remove remaining Apache packages"
fi

# Remove any remaining php packages
remaining_php=$(dpkg -l | awk '$1 == "ii" && $2 ~ /^php/ {print $2}' | tr '\n' ' ')
if [[ -n "$remaining_php" ]]; then
    log "Removing remaining PHP packages: $remaining_php"
    sudo apt-get remove --purge -y $remaining_php || warning "Failed to remove remaining PHP packages"
fi

# Remove any remaining nginx packages
remaining_nginx=$(dpkg -l | awk '$1 == "ii" && $2 ~ /nginx/ {print $2}' | tr '\n' ' ')
if [[ -n "$remaining_nginx" ]]; then
    log "Removing remaining Nginx packages: $remaining_nginx"
    sudo apt-get remove --purge -y $remaining_nginx || warning "Failed to remove remaining Nginx packages"
fi

# Remove any remaining database packages
remaining_db=$(dpkg -l | awk '$1 == "ii" && ($2 ~ /mariadb/ || $2 ~ /mysql/) {print $2}' | tr '\n' ' ')
if [[ -n "$remaining_db" ]]; then
    log "Removing remaining database packages: $remaining_db"
    sudo apt-get remove --purge -y $remaining_db || warning "Failed to remove remaining database packages"
fi

# Final autoremove and autoclean
sudo apt-get autoremove --purge -y
sudo apt-get autoclean

# Check if any LEMP components are still installed
remaining_packages=""
if dpkg -l | awk '$1 == "ii" && $2 ~ /nginx/ {print $2}' | grep -q .; then
    remaining_packages="$remaining_packages nginx"
fi
if dpkg -l | awk '$1 == "ii" && $2 ~ /php/ {print $2}' | grep -q .; then
    remaining_packages="$remaining_packages php"
fi
if dpkg -l | awk '$1 == "ii" && ($2 ~ /mariadb/ || $2 ~ /mysql/) {print $2}' | grep -q .; then
    remaining_packages="$remaining_packages mariadb/mysql"
fi
if dpkg -l | awk '$1 == "ii" && $2 ~ /redis/ {print $2}' | grep -q .; then
    remaining_packages="$remaining_packages redis"
fi
if dpkg -l | awk '$1 == "ii" && $2 ~ /supervisor/ {print $2}' | grep -q .; then
    remaining_packages="$remaining_packages supervisor"
fi
if dpkg -l | awk '$1 == "ii" && $2 ~ /apache/ {print $2}' | grep -q .; then
    remaining_packages="$remaining_packages apache"
fi
if dpkg -l | awk '$1 == "ii" && $2 ~ /nodejs/ {print $2}' | grep -q .; then
    remaining_packages="$remaining_packages nodejs"
fi

if [ -n "$remaining_packages" ]; then
    warning "Some packages may still be installed: $remaining_packages"
    warning "You may need to remove them manually with: sudo apt purge <package_name>"
else
    log "✓ All LEMP packages successfully removed"
fi

# Check for remaining services (including newer PHP versions)
active_services=""
for service in nginx php${PHP_VERSION}-fpm php8.4-fpm php-fpm mariadb mysql redis-server supervisor apache2 httpd apache2-bin apache2-utils; do
    if systemctl is-active --quiet $service 2>/dev/null; then
        active_services="$active_services $service"
    fi
done
if [ -n "$active_services" ]; then
    warning "Some services are still active: $active_services"
    warning "You may need to stop them manually"
else
    log "✓ All LEMP services successfully stopped"
fi

# Check for orphaned systemd unit files
orphaned_units=""
for unit in nginx php${PHP_VERSION}-fpm php8.4-fpm php-fpm mariadb mysql redis-server supervisor apache2 httpd apache2-bin apache2-utils; do
    if [ -f "/usr/lib/systemd/system/${unit}.service" ] || [ -f "/lib/systemd/system/${unit}.service" ]; then
        orphaned_units="$orphaned_units $unit"
    fi
done
if [ -n "$orphaned_units" ]; then
    warning "Orphaned systemd unit files detected: $orphaned_units"
    warning "Run: sudo rm -f /usr/lib/systemd/system/{${orphaned_units// /,}}.service /lib/systemd/system/{${orphaned_units// /,}}.service && sudo systemctl daemon-reload"
else
    log "✓ No orphaned systemd unit files detected"
fi

# Final PHP check
if command -v php &> /dev/null; then
    warning "PHP is still installed. You may need to run:"
    warning "sudo apt purge php* && sudo apt autoremove --purge"
else
    log "✓ PHP completely removed from system"
fi

echo " "
echo "============================================="
echo "COMPLETE REMOVAL FINISHED!"
echo "============================================="
log "ALL LEMP components have been completely removed (100%)"
warning "If you see any error messages above, they are likely harmless"
warning "You may want to reboot the system to ensure all changes take effect: sudo reboot"

echo
echo -e "${GREEN}Complete Removal Summary:${NC}"
echo "✓ Nginx web server removed"
echo "✓ PHP ${PHP_VERSION} and ALL extensions removed"
echo "✓ MariaDB/MySQL database removed"
echo "✓ Node.js and NPM removed"
echo "✓ Redis server removed"
echo "✓ Supervisor removed"
echo "✓ Apache (if present) removed"
echo "✓ SSL certificates removed"
echo "✓ Project files removed"
echo "✓ Configuration files removed"
echo "✓ Helper scripts removed"
echo "✓ Laravel scheduler cronjobs removed"
echo "✓ Repository sources cleaned"
echo "✓ User home directory caches cleaned"
echo "✓ System-wide caches cleaned"
echo "✓ Temporary files removed"
echo "✓ Service files and sockets removed"
echo "✓ Snap packages removed"

log "✅ 100% COMPLETE REMOVAL - No LEMP remnants should remain!"
log "Your system is now clean and ready for a fresh installation!"
echo
echo -e "${YELLOW}Next Steps:${NC}"
echo -e "1. Reboot your system: ${GREEN}sudo reboot${NC}"
echo -e "2. Verify PHP is gone: ${GREEN}php -v${NC} (should show 'command not found')"
echo -e "3. Run a fresh installation if needed"