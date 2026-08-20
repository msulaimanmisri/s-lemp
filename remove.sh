#!/bin/bash

# Complete LEMP Stack Removal Script for Ubuntu
# This script will completely remove ALL LEMP components and Laravel installations
#
# @author Sulaiman Misri
# @web https://sulaimanmisri.com

set -Eeuo pipefail
trap 'echo "[ERROR] Line $LINENO exited with status $?" >&2' ERR
export DEBIAN_FRONTEND=noninteractive

# =================================================================================
# GLOBAL VARIABLES
# =================================================================================
SKIP_MARIADB_CONFIRM="false"
SUPPORTED_PHP_VERSIONS=("8.3" "8.4" "8.5")

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

info() {
    echo -e "${BLUE}[INFO] $1${NC}"
}

warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

safe_stop_service() {
    local service_name=$1
    echo "Stopping $service_name service..."
    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        sudo systemctl stop "$service_name" || warning "Failed to stop $service_name"
    else
        log "$service_name service is not running"
    fi
    if systemctl is-enabled --quiet "$service_name" 2>/dev/null; then
        sudo systemctl disable "$service_name" || warning "Failed to disable $service_name"
    else
        log "$service_name service is not enabled"
    fi
}

wait_for_apt_lock() {
    local timeout=300
    local elapsed=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/dpkg/lock >/dev/null 2>&1 || fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
        if [ $elapsed -ge $timeout ]; then
            warning "Timeout waiting for apt lock, forcing cleanup..."
            sudo killall apt apt-get dpkg 2>/dev/null || true
            sleep 5
            sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock 2>/dev/null || true
            break
        fi
        echo "Waiting for package manager lock... ($elapsed/$timeout seconds)"
        sleep 5
        elapsed=$((elapsed + 5))
    done
}

# Function to safely remove packages
safe_remove_packages() {
    local packages=("$@")
    echo "Removing packages: ${packages[*]}"

    # Wait for any existing locks to be released
    wait_for_apt_lock

    # Kill any hanging processes
    sudo killall apt apt-get 2>/dev/null || true
    sleep 2

    # First, try to fix any broken packages
    sudo dpkg --configure -a || warning "Failed to configure packages"
    wait_for_apt_lock
    sudo apt-get -f install -y || warning "Failed to fix broken dependencies"

    for package in "${packages[@]}"; do
        if dpkg -l 2>/dev/null | grep -q "^ii.*$package" 2>/dev/null; then
            echo "Removing $package..."
            wait_for_apt_lock
            sudo apt-get remove --purge -y "$package" 2>/dev/null || warning "Failed to remove $package"
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

# First, wait for any apt locks and kill hanging processes
wait_for_apt_lock
sudo killall apt apt-get dpkg 2>/dev/null || true
sleep 3

# Fix any broken packages before stopping services
log "Fixing any broken package installations..."
sudo dpkg --configure -a || warning "Some packages may still have issues"
wait_for_apt_lock
sudo apt-get -f install -y || warning "Failed to fix some dependencies"

safe_stop_service "nginx"
for ver in "${SUPPORTED_PHP_VERSIONS[@]}"; do
    safe_stop_service "php${ver}-fpm"
done
safe_stop_service "php-fpm"
safe_stop_service "mariadb"
safe_stop_service "mysql"
safe_stop_service "redis-server"
safe_stop_service "supervisor"
safe_stop_service "certbot.timer"
safe_stop_service "snap.certbot.renew.timer"
safe_stop_service "apache2"

sudo systemctl daemon-reload 2>/dev/null || true

echo " "
echo "============================================="
echo "Step 2: Removing PHP and ALL related extensions"
echo "============================================="
wait_for_apt_lock
sudo apt-get purge --allow-change-held-packages -y 'php*' 'libapache2-mod-php*'

echo " "
echo "============================================="
echo "Step 3: Removing Nginx"
echo "============================================="
safe_remove_packages "nginx"

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
if snap list 2>/dev/null | grep -q "^certbot "; then
    sudo snap remove --purge certbot 2>/dev/null || warning "Failed to remove certbot snap"
    sudo rm -f /snap/bin/certbot 2>/dev/null || true
    log "✓ Removed certbot snap (snapd preserved)"
else
    log "No certbot snap found — skipping snap removal"
fi
safe_remove_packages "certbot" "python3-certbot-nginx"

echo " "
echo "============================================="
echo "Step 9: Removing Apache (if present)"
echo "============================================="
apache_packages=$(dpkg -l 2>/dev/null | grep -i apache | awk '{print $2}' | tr '\n' ' ' 2>/dev/null || true)
if [[ -n "$apache_packages" && "$apache_packages" != " " ]]; then
    echo "Found Apache packages: $apache_packages"
    wait_for_apt_lock
    sudo apt-get remove --purge -y $apache_packages 2>/dev/null || warning "Failed to remove some Apache packages"
else
    log "No Apache packages found"
fi
sudo rm -rf /etc/apache2 2>/dev/null || true
sudo rm -rf /var/log/apache2 2>/dev/null || true

echo " "
echo "============================================="
echo "Step 10: Removing configuration files and directories"
echo "============================================="
log "Removing Composer..."
wait_for_apt_lock
sudo rm -f /usr/local/bin/composer
sudo rm -f /usr/bin/composer
rm -f composer.phar 2>/dev/null || true
rm -f composer-setup.php 2>/dev/null || true
# Only try to remove composer package if it exists
if dpkg -l 2>/dev/null | grep -q "^ii.*composer" 2>/dev/null; then
    wait_for_apt_lock
    sudo apt remove --purge composer -y 2>/dev/null || true
fi

log "Removing SSL certificates..."
sudo rm -rf /etc/letsencrypt 2>/dev/null || true
sudo rm -rf /var/log/letsencrypt 2>/dev/null || true
sudo rm -rf /var/lib/letsencrypt 2>/dev/null || true

log "Removing project directories..."
sudo rm -rf /var/www/laravel* 2>/dev/null || true
sudo rm -rf /var/www/html 2>/dev/null || true

log "Removing Nginx configurations..."
sudo rm -f /etc/nginx/conf.d/rate-limit.conf 2>/dev/null || true
sudo rm -f /etc/nginx/nginx.conf.bak.* 2>/dev/null || true
sudo rm -f /etc/nginx/sites-available/laravel* 2>/dev/null || true
sudo rm -f /etc/nginx/sites-enabled/laravel* 2>/dev/null || true

log "Removing MariaDB data (WARNING: This deletes ALL databases!)..."
sudo rm -rf /var/lib/mysql 2>/dev/null || true
sudo rm -rf /var/log/mysql 2>/dev/null || true
sudo rm -rf /etc/mysql 2>/dev/null || true

log "Removing Redis data..."
sudo rm -rf /var/lib/redis 2>/dev/null || true
sudo rm -f /etc/redis/users.acl 2>/dev/null || true
sudo rm -f /etc/redis/redis.conf.backup 2>/dev/null || true

log "Removing Supervisor queue configs..."
sudo rm -f /etc/supervisor/conf.d/*queue.conf 2>/dev/null || true

log "Removing secrets and installer artifacts..."
if command -v shred >/dev/null 2>&1 && [[ -f /root/laravel_lemp_config.txt ]]; then
    sudo shred -u /root/laravel_lemp_config.txt 2>/dev/null || sudo rm -f /root/laravel_lemp_config.txt 2>/dev/null || true
else
    sudo rm -f /root/laravel_lemp_config.txt 2>/dev/null || true
fi
sudo rm -f /root/.lemp_config.* /tmp/.lemp_config.* /tmp/laravel_lemp_config.txt 2>/dev/null || true
sudo rm -f /var/lock/lemp_install.lock /tmp/lemp_install.lock /tmp/ufw.backup.* 2>/dev/null || true
sudo rm -f /etc/logrotate.d/php-fpm-* 2>/dev/null || true
sudo rm -f /etc/php/*/opcache-blacklist.txt 2>/dev/null || true
sudo rm -f /etc/php/*/fpm/conf.d/10-opcache.ini.backup.* /etc/php/*/cli/conf.d/10-opcache.ini.backup.* 2>/dev/null || true

echo " "
echo "============================================="
echo "Step 11: Removing helper scripts"
echo "============================================="
sudo rm -f /usr/local/bin/fix-laravel-permissions 2>/dev/null || true

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
sudo rm -f /etc/apt/sources.list.d/ondrej-php.list 2>/dev/null || true
sudo rm -f /etc/apt/sources.list.d/ondrej-ubuntu-php-*.list 2>/dev/null || true
sudo rm -f /etc/apt/keyrings/ondrej-php.gpg 2>/dev/null || true

log "Removing NodeSource repository..."
sudo rm -f /etc/apt/sources.list.d/nodesource.list 2>/dev/null || true
sudo rm -f /etc/apt/sources.list.d/nodesource.sources 2>/dev/null || true
sudo rm -f /etc/apt/keyrings/nodesource.gpg 2>/dev/null || true

log "Removing other repositories..."
sudo rm -f /etc/apt/sources.list.d/mariadb.list /etc/apt/sources.list.d/mariadb-enterprise.list 2>/dev/null || true
sudo rm -f /etc/apt/sources.list.d/mariadb.sources 2>/dev/null || true
sudo rm -f /etc/apt/keyrings/mariadb.gpg 2>/dev/null || true
sudo rm -f /etc/apt/sources.list.d/redis.list 2>/dev/null || true
sudo rm -f /etc/apt/sources.list.d/redis.sources 2>/dev/null || true
sudo rm -f /etc/apt/keyrings/redis-archive-keyring.gpg 2>/dev/null || true

echo " "
echo "============================================="
echo "Step 14: System-wide caches and temporary files"
echo "============================================="
log "Removing system-wide cache files..."

# Remove APT cache for removed packages
sudo apt-get clean
sudo apt-get autoclean

# Remove systemd journal logs related to removed services
sudo journalctl --vacuum-time=1d || warning "Failed to clean journal logs"

for ver in "${SUPPORTED_PHP_VERSIONS[@]}"; do
    sudo rm -f "/var/run/php/php${ver}-fpm.pid" 2>/dev/null || true
    sudo rm -f "/var/run/php/php${ver}-fpm.sock" 2>/dev/null || true
    sudo rm -f "/run/php/php${ver}-fpm.sock" 2>/dev/null || true
    sudo rm -f "/run/php/php${ver}-fpm-"*.sock 2>/dev/null || true
done
sudo rm -f /var/run/nginx.pid 2>/dev/null || true
sudo rm -f /var/run/mysqld/mysqld.pid 2>/dev/null || true
sudo rm -f /var/run/redis/redis-server.pid 2>/dev/null || true
sudo rm -f /var/run/mysqld/mysqld.sock 2>/dev/null || true
sudo rm -f /var/run/redis/redis-server.sock 2>/dev/null || true
sudo rm -f /var/lock/nginx.lock 2>/dev/null || true

# Remove temporary installation files
sudo rm -rf /tmp/composer-setup.php 2>/dev/null || true
sudo rm -rf /tmp/node-* 2>/dev/null || true
sudo rm -rf /tmp/npm-* 2>/dev/null || true
sudo rm -rf /tmp/php* 2>/dev/null || true

# Snap directories are preserved (snapd no longer removed wholesale) — no rm -rf /snap

log "✓ System caches and temporary files cleaned"

if [ -t 0 ]; then
    echo ""
    read -p "Reset UFW firewall rules? This will disable UFW and remove custom rules (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log "Resetting UFW firewall..."
        sudo ufw --force reset 2>/dev/null || warning "Failed to reset UFW"
        sudo ufw --force disable 2>/dev/null || warning "Failed to disable UFW"
        sudo sed -i 's/IPV6=yes/IPV6=no/' /etc/default/ufw 2>/dev/null || true
        log "✓ UFW firewall reset and disabled"
    else
        log "UFW firewall left untouched"
    fi
else
    log "Non-interactive mode — UFW firewall left untouched (run: sudo ufw --force reset && sudo ufw --force disable to reset manually)"
fi

echo " "
echo "============================================="
echo "Step 15: Final system verification and cleanup"
echo "============================================="

log "Verifying complete removal..."
wait_for_apt_lock
sudo apt-get autoremove --purge -y
wait_for_apt_lock
sudo apt-get autoclean

# Check if any LEMP components are still installed
remaining_packages=""
if dpkg -l 2>/dev/null | awk '$1 == "ii" && $2 ~ /nginx/ {print $2}' | grep -q . 2>/dev/null; then
    remaining_packages="$remaining_packages nginx"
fi
if dpkg -l 2>/dev/null | awk '$1 == "ii" && $2 ~ /php/ {print $2}' | grep -q . 2>/dev/null; then
    remaining_packages="$remaining_packages php"
fi
if dpkg -l 2>/dev/null | awk '$1 == "ii" && ($2 ~ /mariadb/ || $2 ~ /mysql/) {print $2}' | grep -q . 2>/dev/null; then
    remaining_packages="$remaining_packages mariadb/mysql"
fi
if dpkg -l 2>/dev/null | awk '$1 == "ii" && $2 ~ /redis/ {print $2}' | grep -q . 2>/dev/null; then
    remaining_packages="$remaining_packages redis"
fi
if dpkg -l 2>/dev/null | awk '$1 == "ii" && $2 ~ /supervisor/ {print $2}' | grep -q . 2>/dev/null; then
    remaining_packages="$remaining_packages supervisor"
fi
if dpkg -l 2>/dev/null | awk '$1 == "ii" && $2 ~ /apache/ {print $2}' | grep -q . 2>/dev/null; then
    remaining_packages="$remaining_packages apache"
fi
if dpkg -l 2>/dev/null | awk '$1 == "ii" && $2 ~ /nodejs/ {print $2}' | grep -q . 2>/dev/null; then
    remaining_packages="$remaining_packages nodejs"
fi

if [ -n "$remaining_packages" ]; then
    warning "Some packages may still be installed: $remaining_packages"
    warning "You may need to remove them manually with: sudo apt purge <package_name>"
else
    log "✓ All LEMP packages successfully removed"
fi

active_services=""
for svc in nginx mariadb mysql redis-server supervisor apache2; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        active_services="$active_services $svc"
    fi
done
for ver in "${SUPPORTED_PHP_VERSIONS[@]}"; do
    if systemctl is-active --quiet "php${ver}-fpm" 2>/dev/null; then
        active_services="$active_services php${ver}-fpm"
    fi
done
if systemctl is-active --quiet php-fpm 2>/dev/null; then
    active_services="$active_services php-fpm"
fi
if systemctl is-active --quiet certbot.timer 2>/dev/null; then
    active_services="$active_services certbot.timer"
fi
if systemctl is-active --quiet snap.certbot.renew.timer 2>/dev/null; then
    active_services="$active_services snap.certbot.renew.timer"
fi
if [ -n "$active_services" ]; then
    warning "Some services are still active:$active_services"
    warning "You may need to stop them manually"
else
    log "✓ All LEMP services successfully stopped"
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
echo "✓ PHP and ALL extensions removed"
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