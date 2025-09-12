#!/bin/bash

# Check if script is being run correctly
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    echo "Error: This script should be executed directly, not sourced."
    echo "Usage: ./installation-script.sh [--non-interactive]"
    exit 1
fi

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --non-interactive|-n)
            INTERACTIVE_MODE=false
            # Set default values for non-interactive mode
            PROJECT_NAME="laravel-project"
            DOMAIN_NAME="laravel.local"
            DB_NAME="laravel_db"
            DB_USER="laravel_user"
            DB_PASSWORD=$(openssl rand -base64 12 2>/dev/null || echo "defaultpass123")
            DB_ROOT_PASSWORD=$(openssl rand -base64 16 2>/dev/null || echo "rootpass123")
            REDIS_PASSWORD=$(openssl rand -base64 12 2>/dev/null || echo "redispass123")
            SSL_EMAIL="admin@laravel.local"
            PHP_VERSION="8.3"  # Default to PHP 8.3 LTS for non-interactive mode
            QUEUE_DRIVER="database"  # Default to Database for non-interactive mode (beginner-friendly)
            INSTALL_SSL=false  # Default to manual SSL installation for non-interactive mode
            shift
            ;;
        --php-version)
            if [[ "$2" == "8.3" ]] || [[ "$2" == "8.4" ]]; then
                PHP_VERSION="$2"
                shift 2
            else
                echo "Error: Invalid PHP version. Use 8.3 or 8.4"
                exit 1
            fi
            ;;
        --queue-driver)
            if [[ "$2" == "redis" ]] || [[ "$2" == "database" ]]; then
                QUEUE_DRIVER="$2"
                shift 2
            else
                echo "Error: Invalid queue driver. Use 'redis' or 'database'"
                exit 1
            fi
            ;;
        --help|-h)
            echo "S-LEMP Stack Installation Script"
            echo ""
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --non-interactive, -n       Run in non-interactive mode with defaults"
            echo "  --php-version VERSION       Set PHP version (8.3 or 8.4)"
            echo "  --queue-driver DRIVER       Set queue driver (redis or database)"
            echo "  --help, -h                  Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                          # Interactive mode"
            echo "  $0 --non-interactive        # Non-interactive with PHP 8.3 and Redis"
            echo "  $0 --non-interactive --php-version 8.4 --queue-driver database"
            echo ""
            echo "Interactive mode (default): Run configuration wizard"
            echo "Non-interactive mode: Use predefined defaults"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# =========================================================================
# Enable Strict mode with improved error handling
# =========================================================================
set -Eeuo pipefail

# Custom error handler with cleanup
cleanup_on_error() {
    local exit_code=$?
    local line_number=$1
    error "Installation failed at line $line_number with exit code $exit_code"
    
    # Attempt basic cleanup
    warning "Attempting to clean up partial installation..."
    
    # Stop any services that might be in inconsistent state
    for service in nginx php${PHP_VERSION}-fpm mariadb redis-server supervisor; do
        if systemctl is-active --quiet $service 2>/dev/null; then
            systemctl stop $service 2>/dev/null || true
        fi
    done
    
    # Clean up any package locks
    killall apt apt-get 2>/dev/null || true
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock 2>/dev/null || true
    
    info "Cleanup completed. Check the error above and rerun the script."
    exit $exit_code
}

trap 'cleanup_on_error $LINENO' ERR
export DEBIAN_FRONTEND=noninteractive

# Lock file to prevent multiple instances
LOCK_FILE="/tmp/lemp_install.lock"

# Cleanup lock file on exit
cleanup_lock() {
    rm -f "$LOCK_FILE"
}
trap cleanup_lock EXIT

# Create lock to prevent concurrent installations
create_lock() {
    if [ -f "$LOCK_FILE" ]; then
        error "Another instance of this script is already running or was terminated unexpectedly."
        info "If you're sure no other instance is running, remove the lock file:"
        info "sudo rm $LOCK_FILE"
        exit 1
    fi
    echo $$ > "$LOCK_FILE"
}

# =================================================================================
# GLOBAL VARIABLES (will be set by configuration wizard)
# =================================================================================
PROJECT_ROOT="/var/www"
PROJECT_NAME=""
DOMAIN_NAME=""

DB_NAME=""
DB_USER=""
DB_PASSWORD=""
DB_ROOT_PASSWORD=""

REDIS_PASSWORD=""

SYSTEM_USER="www-data"
PROJECT_GROUP="www-data"
PHP_VERSION="8.3"

NODE_JS_VERSION="24.x"
SUPERVISOR_PROCESS_NUM=3
QUEUE_DRIVER="database"
SSL_EMAIL=""

# Configuration mode
INTERACTIVE_MODE=true
INSTALL_SSL=false
SSL_INSTALL_SUCCESS=false


# =========================================================================
# Colors for output
# =========================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color


# =========================================================================
# Logging Functions
# =========================================================================
log() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

info() {
    echo -e "${BLUE}[INFO] $1${NC}"
}

# Progress indicator function
show_progress() {
    local step="$1"
    local total="$2" 
    local message="$3"
    local percent=$((step * 100 / total))
    local completed=$((percent / 5))
    local remaining=$((20 - completed))
    
    printf "\r${CYAN}[${NC}"
    printf "%*s" $completed | tr ' ' '█'
    printf "%*s" $remaining | tr ' ' '░'
    printf "${CYAN}] ${percent}%% - ${message}${NC}"
    
    if [[ $step -eq $total ]]; then
        echo ""
    fi
}

# =========================================================================
# Interactive Configuration Wizard Functions
# =========================================================================

# Function to validate domain format
validate_domain() {
    local domain="$1"
    # Basic domain validation - allows letters, numbers, dots, and hyphens
    if [[ $domain =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$ ]] && [[ $domain =~ \. ]]; then
        return 0
    else
        return 1
    fi
}

# Function to validate project name (safe for filesystem)
validate_project_name() {
    local name="$1"
    # Only allow letters, numbers, hyphens, and underscores
    if [[ $name =~ ^[a-zA-Z0-9_-]+$ ]] && [[ ${#name} -ge 3 ]] && [[ ${#name} -le 50 ]]; then
        return 0
    else
        return 1
    fi
}

# Function to validate email format
validate_email() {
    local email="$1"
    if [[ $email =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Function to check password strength
check_password_strength() {
    local password="$1"
    local score=0
    
    # Length check
    if [[ ${#password} -ge 12 ]]; then
        score=$((score + 2))
    elif [[ ${#password} -ge 8 ]]; then
        score=$((score + 1))
    fi
    
    # Character variety checks
    if [[ $password =~ [a-z] ]]; then score=$((score + 1)); fi
    if [[ $password =~ [A-Z] ]]; then score=$((score + 1)); fi
    if [[ $password =~ [0-9] ]]; then score=$((score + 1)); fi
    if [[ $password =~ [^a-zA-Z0-9] ]]; then score=$((score + 1)); fi
    
    # Return score and feedback
    if [[ $score -ge 5 ]]; then
        echo "STRONG"
    elif [[ $score -ge 3 ]]; then
        echo "MEDIUM"
    else
        echo "WEAK"
    fi
}

# Function to generate a secure random password
generate_password() {
    local length=${1:-16}
    
    # Try multiple methods to generate password
    local password=""
    
    # Method 1: Use /dev/urandom with tr (most secure)
    if [[ -r /dev/urandom ]] && command -v tr >/dev/null 2>&1; then
        password=$(tr -dc 'A-Za-z0-9!@#$%^&*()_+=' < /dev/urandom 2>/dev/null | head -c "$length" 2>/dev/null || true)
    fi
    
    # Method 2: Use openssl if tr method failed
    if [[ -z "$password" ]] && command -v openssl >/dev/null 2>&1; then
        password=$(openssl rand -base64 $((length * 2)) 2>/dev/null | tr -dc 'A-Za-z0-9!@#$%^&*()_+=' | head -c "$length" 2>/dev/null || true)
    fi
    
    # Method 3: Fallback to simple random method
    if [[ -z "$password" ]]; then
        local chars="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()_+="
        for ((i=0; i<length; i++)); do
            password+="${chars:$((RANDOM % ${#chars})):1}"
        done
    fi
    
    # Ensure we have a password of the right length
    if [[ ${#password} -lt "$length" ]]; then
        # Pad with simple characters if needed
        while [[ ${#password} -lt "$length" ]]; do
            password+="$(printf "%c" $((65 + RANDOM % 26)))"
        done
    fi
    
    # Truncate if too long
    password="${password:0:$length}"
    
    echo "$password"
}

# Function to display S-LEMP banner
show_slemp_banner() {
    clear
    echo ""
    echo -e "${CYAN}"
    echo "███████╗      ██╗     ███████╗███╗   ███╗██████╗ "
    echo "██╔════╝      ██║     ██╔════╝████╗ ████║██╔══██╗"
    echo "███████╗█████╗██║     █████╗  ██╔████╔██║██████╔╝"
    echo "╚════██║╚════╝██║     ██╔══╝  ██║╚██╔╝██║██╔═══╝ "
    echo "███████║      ███████╗███████╗██║ ╚═╝ ██║██║     "
    echo "╚══════╝      ╚══════╝╚══════╝╚═╝     ╚═╝╚═╝     "
    echo -e "${NC}"
    echo ""
    echo -e "${GREEN}S-LEMP INSTALLATION FRAMEWORK BY SULAIMAN MISRI${NC}"
    echo -e "${YELLOW}** Deploy a production-ready Laravel environment effortlessly. ${NC}"
    echo -e "${YELLOW}** All optimized for your Laravel application. ${NC}"
    echo ""
}

# Function to display configuration wizard header (no clear)
show_config_wizard_header() {
    echo ""
    echo "============================================="
    echo -e "${GREEN}CONFIGURATION WIZARD${NC}"
    echo "============================================="
    echo -e "${YELLOW}This wizard will help you configure your S-LEMP stack installation.${NC}"
    echo -e "${BLUE}You can press Enter without specifying any value to use default values shown in [brackets].${NC}"
    echo ""
}

# Main configuration wizard
run_configuration_wizard() {
    show_config_wizard_header
    
    if [[ ! -t 0 ]]; then
        INTERACTIVE_MODE=false
    fi

    if [[ "$INTERACTIVE_MODE" == "false" ]]; then
        # Set default values for non-interactive mode
        PROJECT_NAME=${PROJECT_NAME:-laravel-project}
        DOMAIN_NAME=${DOMAIN_NAME:-${PROJECT_NAME}.local}
        SSL_EMAIL=${SSL_EMAIL:-admin@${DOMAIN_NAME}}
        DB_NAME=${DB_NAME:-${PROJECT_NAME}_db}
        DB_USER=${DB_USER:-${PROJECT_NAME}_user}
        DB_PASSWORD=${DB_PASSWORD:-$(openssl rand -base64 12 2>/dev/null || echo "defaultpass123")}
        DB_ROOT_PASSWORD=${DB_ROOT_PASSWORD:-$(openssl rand -base64 16 2>/dev/null || echo "rootpass123")}
        REDIS_PASSWORD=${REDIS_PASSWORD:-$(openssl rand -base64 12 2>/dev/null || echo "redispass123")}
        PHP_VERSION=${PHP_VERSION:-8.3}
        QUEUE_DRIVER=${QUEUE_DRIVER:-database}
        SUPERVISOR_PROCESS_NUM=${SUPERVISOR_PROCESS_NUM:-3}
        INSTALL_SSL=false
        return
    fi

    # Project Configuration
    echo ""
    echo "============================================="
    echo -e "${GREEN}PROJECT CONFIGURATION${NC}"
    echo "============================================="
    
    # Project Name
    while true; do
        read -p "Enter project name: " input_project_name
        PROJECT_NAME=${input_project_name:-"laravel-project"}
        
        if validate_project_name "$PROJECT_NAME"; then
            log "✓ Project name: $PROJECT_NAME"
            break
        else
            error "Invalid project name. Use only letters, numbers, hyphens, underscores (3-50 chars)"
        fi
    done
    echo ""
    
    # Domain Name
    while true; do
        read -p "Enter domain name [${PROJECT_NAME}.com]: " input_domain
        DOMAIN_NAME=${input_domain:-"${PROJECT_NAME}.com"}
        
        if validate_domain "$DOMAIN_NAME"; then
            log "✓ Domain name: $DOMAIN_NAME"
            break
        else
            error "Invalid domain format. Example: example.com or sub.example.com"
        fi
    done
    echo ""
    
    # SSL Email
    while true; do
        read -p "Enter email for SSL certificates [admin@${DOMAIN_NAME}]: " input_email
        SSL_EMAIL=${input_email:-"admin@${DOMAIN_NAME}"}
        
        if validate_email "$SSL_EMAIL"; then
            log "✓ SSL email: $SSL_EMAIL"
            break
        else
            error "Invalid email format"
        fi
    done
    echo ""
    
    echo ""
    echo "============================================="
    echo -e "${GREEN}DATABASE CONFIGURATION${NC}"
    echo "============================================="
    
    # Database Name
    while true; do
        read -p "Enter database name [${PROJECT_NAME//-/_}_db]: " input_db_name
        DB_NAME=${input_db_name:-"${PROJECT_NAME//-/_}_db"}
        
        if [[ $DB_NAME =~ ^[a-zA-Z0-9_]+$ ]] && [[ ${#DB_NAME} -le 64 ]]; then
            log "✓ Database name: $DB_NAME"
            break
        else
            error "Invalid database name. Use only letters, numbers, underscores (max 64 chars)"
        fi
    done
    echo ""
    
    # Database User
    while true; do
        read -p "Enter database username [${PROJECT_NAME//-/_}_db_usr]: " input_db_user
        DB_USER=${input_db_user:-"${PROJECT_NAME//-/_}_db_usr"}
        
        if [[ $DB_USER =~ ^[a-zA-Z0-9_]+$ ]] && [[ ${#DB_USER} -le 32 ]]; then
            log "✓ Database user: $DB_USER"
            break
        else
            error "Invalid username. Use only letters, numbers, underscores (max 32 chars)"
        fi
    done
    echo ""
    
    # Database Password
    echo ""
    info "Database Password Options:"
    echo "  1) Generate secure password automatically"
    echo "  2) Enter custom password"
    echo ""
    
    while true; do
        read -p "Choose option [1]: " password_option
        password_option=${password_option:-1}
        
        case $password_option in
            1)
                DB_PASSWORD=$(generate_password 16)
                log "✓ Generated secure database password"
                break
                ;;
            2)
                while true; do
                    read -s -p "Enter database password: " input_db_password
                    echo ""
                    
                    if [[ ${#input_db_password} -ge 8 ]]; then
                        strength=$(check_password_strength "$input_db_password")
                        case $strength in
                            STRONG) log "✓ Password strength: STRONG"; DB_PASSWORD="$input_db_password"; break 2;;
                            MEDIUM) warning "Password strength: MEDIUM"; 
                                   read -p "Continue with this password? (y/N): " confirm
                                   if [[ $confirm =~ ^[Yy]$ ]]; then DB_PASSWORD="$input_db_password"; break 2; fi;;
                            WEAK) error "Password too weak. Please use a stronger password.";;
                        esac
                    else
                        error "Password must be at least 8 characters long"
                    fi
                done
                ;;
            *)
                error "Invalid option. Please choose 1 or 2."
                ;;
        esac
    done
    echo ""
    
    # Database Root Password
    echo ""
    while true; do
        read -p "Generate MariaDB root password automatically? (Y/n): " auto_root_pass
        auto_root_pass=${auto_root_pass:-Y}
        
        case $auto_root_pass in
            [Yy]*)
                DB_ROOT_PASSWORD=$(generate_password 20)
                log "✓ Generated secure MariaDB root password"
                break
                ;;
            [Nn]*)
                while true; do
                    read -s -p "Enter MariaDB root password: " input_root_password
                    echo ""
                    
                    if [[ ${#input_root_password} -ge 8 ]]; then
                        DB_ROOT_PASSWORD="$input_root_password"
                        log "✓ MariaDB root password set"
                        break 2
                    else
                        error "Root password must be at least 8 characters long"
                    fi
                done
                ;;
            *)
                error "Please answer Y or N"
                ;;
        esac
    done
    echo ""
    
    echo ""
    echo "============================================="
    echo -e "${GREEN}REDIS CONFIGURATION${NC}"
    echo "============================================="
    
    # Redis Password
    while true; do
        read -p "Generate Redis password automatically? (Y/n): " auto_redis_pass
        auto_redis_pass=${auto_redis_pass:-Y}
        
        case $auto_redis_pass in
            [Yy]*)
                REDIS_PASSWORD=$(generate_password 16)
                log "✓ Generated secure Redis password"
                break
                ;;
            [Nn]*)
                while true; do
                    read -s -p "Enter Redis password: " input_redis_password
                    echo ""
                    
                    if [[ ${#input_redis_password} -ge 8 ]]; then
                        REDIS_PASSWORD="$input_redis_password"
                        log "✓ Redis password set"
                        break 2
                    else
                        error "Redis password must be at least 8 characters long"
                    fi
                done
                ;;
            *)
                error "Please answer Y or N"
                ;;
        esac
    done
    echo ""
    
    echo ""
    echo "============================================="
    echo -e "${GREEN}ADVANCED CONFIGURATION${NC}"
    echo "============================================="
    
    # PHP Version Selection
    echo ""
    info "PHP Version Selection:"
    echo "  1) PHP 8.3 LTS (Recommended for production)"
    echo "  2) PHP 8.4 (Latest stable)"
    echo ""
    
    while true; do
        read -p "Choose PHP version [1]: " php_version_option
        php_version_option=${php_version_option:-1}
        
        case $php_version_option in
            1)
                PHP_VERSION="8.3"
                log "✓ Selected PHP 8.3 LTS"
                break
                ;;
            2)
                PHP_VERSION="8.4"
                log "✓ Selected PHP 8.4"
                break
                ;;
            *)
                error "Please choose option 1 or 2"
                ;;
        esac
    done
    echo ""
    
    # Queue Driver Selection
    echo ""
    info "Queue Driver Selection:"
    echo "  1) Database (Simple setup, uses database for queues)"
    echo "  2) Redis (Recommended for performance and scalability)"
    echo ""
    
    while true; do
        read -p "Choose queue driver [1]: " queue_driver_option
        queue_driver_option=${queue_driver_option:-1}
        
        case $queue_driver_option in
            1)
                QUEUE_DRIVER="database"
                log "✓ Selected Database queue driver"
                break
                ;;
            2)
                QUEUE_DRIVER="redis"
                log "✓ Selected Redis queue driver"
                break
                ;;
            *)
                error "Please choose option 1 or 2"
                ;;
        esac
    done
    echo ""
    
    # Supervisor Process Number
    echo ""
    while true; do
        read -p "Number of queue worker processes [3]: " input_processes
        SUPERVISOR_PROCESS_NUM=${input_processes:-3}
        
        if [[ $SUPERVISOR_PROCESS_NUM =~ ^[1-9][0-9]*$ ]] && [[ $SUPERVISOR_PROCESS_NUM -le 20 ]]; then
            log "✓ Queue worker processes: $SUPERVISOR_PROCESS_NUM"
            break
        else
            error "Please enter a number between 1 and 20"
        fi
    done
    echo ""
    
    # Show Configuration Summary
    show_configuration_summary
}

# Function to show configuration summary
show_configuration_summary() {
    echo ""
    echo "============================================="
    echo -e "${CYAN}CONFIGURATION SUMMARY${NC}"
    echo "============================================="
    echo ""
    echo -e "${YELLOW}📁 Project Configuration:${NC}"
    echo -e "   ${WHITE}├─${NC} Project Name: ${GREEN}$PROJECT_NAME${NC}"
    echo -e "   ${WHITE}├─${NC} Domain: ${GREEN}$DOMAIN_NAME${NC}"
    echo -e "   ${WHITE}├─${NC} SSL Email: ${GREEN}$SSL_EMAIL${NC}"
    echo -e "   ${WHITE}└─${NC} Project Path: ${GREEN}$PROJECT_ROOT/$PROJECT_NAME${NC}"
    echo ""
    echo -e "${YELLOW}🗄️  Database Configuration:${NC}"
    echo -e "   ${WHITE}├─${NC} Database Name: ${GREEN}$DB_NAME${NC}"
    echo -e "   ${WHITE}├─${NC} Database User: ${GREEN}$DB_USER${NC}"
    echo -e "   ${WHITE}├─${NC} Database Password: ${GREEN}[HIDDEN]${NC}"
    echo -e "   ${WHITE}└─${NC} Root Password: ${GREEN}[HIDDEN]${NC}"
    echo ""
    echo -e "${YELLOW}Services Configuration:${NC}"
    echo -e "   ${WHITE}├─${NC} Redis Password: ${GREEN}[HIDDEN]${NC}"
    echo -e "   ${WHITE}├─${NC} Queue Workers: ${GREEN}$SUPERVISOR_PROCESS_NUM${NC}"
    echo -e "   ${WHITE}├─${NC} Queue Driver: ${GREEN}$QUEUE_DRIVER${NC}"
    echo -e "   ${WHITE}├─${NC} PHP Version: ${GREEN}$PHP_VERSION${NC}"
    echo -e "   ${WHITE}└─${NC} Node.js Version: ${GREEN}$NODE_JS_VERSION${NC}"
    echo ""
    echo "============================================="
    echo ""
    
    # Save configuration to file for reference
    save_configuration_file
    
    # Set SSL installation to false (manual setup later)
    INSTALL_SSL=false
    
    while true; do
        read -p "Proceed with this configuration? (Y/n): " confirm_config
        confirm_config=${confirm_config:-Y}
        
        case $confirm_config in
            [Yy]*)
                log "✓ Configuration confirmed. Starting installation..."
                return 0
                ;;
            [Nn]*)
                echo ""
                warning "Installation cancelled by user."
                echo ""
                info "You can run the script again to reconfigure."
                exit 0
                ;;
            *)
                error "Please answer Y or N"
                ;;
        esac
    done
    echo ""
}

# Function to save configuration to a file
save_configuration_file() {
    local config_file="/tmp/laravel_lemp_config.txt"
    
    # Remove existing config file if it exists
    rm -f "$config_file" 2>/dev/null || true
    
    # Create the configuration file with proper error handling
    if cat > "$config_file" 2>/dev/null <<EOF
# S-LEMP Stack Configuration
# Generated on: $(date)

PROJECT_NAME=$PROJECT_NAME
DOMAIN_NAME=$DOMAIN_NAME
SSL_EMAIL=$SSL_EMAIL
PROJECT_ROOT=$PROJECT_ROOT

DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
DB_ROOT_PASSWORD=$DB_ROOT_PASSWORD

REDIS_PASSWORD=$REDIS_PASSWORD
SUPERVISOR_PROCESS_NUM=$SUPERVISOR_PROCESS_NUM
QUEUE_DRIVER=$QUEUE_DRIVER
PHP_VERSION=$PHP_VERSION
NODE_JS_VERSION=$NODE_JS_VERSION
INSTALL_SSL=$INSTALL_SSL

# Access URLs after installation:
# HTTP: http://$DOMAIN_NAME
# HTTPS: https://$DOMAIN_NAME (after SSL setup)

# Database Connection:
# Host: localhost
# Database: $DB_NAME
# Username: $DB_USER
# Password: [see above]

# Important Commands:
# Fix Laravel permissions: fix-laravel-permissions $PROJECT_ROOT/$PROJECT_NAME
# Supervisor status: sudo supervisorctl status
# SSL setup: sudo certbot --nginx -d $DOMAIN_NAME --email $SSL_EMAIL --agree-tos
EOF
    then
        # Ensure proper permissions
        chmod 644 "$config_file" 2>/dev/null || true
        info "Configuration saved to: $config_file"
        echo ""
    else
        warning "Failed to save configuration to $config_file - continuing without saving"
        # Try alternative location if /tmp fails
        local alt_config_file="/root/laravel_lemp_config.txt"
        if cat > "$alt_config_file" 2>/dev/null <<EOF
# S-LEMP Stack Configuration
# Generated on: $(date)

PROJECT_NAME=$PROJECT_NAME
DOMAIN_NAME=$DOMAIN_NAME
SSL_EMAIL=$SSL_EMAIL
PROJECT_ROOT=$PROJECT_ROOT

DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
DB_ROOT_PASSWORD=$DB_ROOT_PASSWORD

REDIS_PASSWORD=$REDIS_PASSWORD
SUPERVISOR_PROCESS_NUM=$SUPERVISOR_PROCESS_NUM
QUEUE_DRIVER=$QUEUE_DRIVER
PHP_VERSION=$PHP_VERSION
NODE_JS_VERSION=$NODE_JS_VERSION
INSTALL_SSL=$INSTALL_SSL

# Access URLs after installation:
# HTTP: http://$DOMAIN_NAME
# HTTPS: https://$DOMAIN_NAME (after SSL setup)

# Database Connection:
# Host: localhost
# Database: $DB_NAME
# Username: $DB_USER
# Password: [see above]

# Important Commands:
# Fix Laravel permissions: fix-laravel-permissions $PROJECT_ROOT/$PROJECT_NAME
# Supervisor status: sudo supervisorctl status
# SSL setup: sudo certbot --nginx -d $DOMAIN_NAME --email $SSL_EMAIL --agree-tos
EOF
        then
            chmod 644 "$alt_config_file" 2>/dev/null || true
            info "Configuration saved to alternative location: $alt_config_file"
        else
            warning "Could not save configuration file to any location"
        fi
    fi
}

# =========================================================================
# Check if running as root
# =========================================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
        exit 1
    fi
    echo ""
}

# =========================================================================
# Checking Ubuntu Version and Server Specifications
# =========================================================================
check_ubuntu() {
    if [[ ! -f /etc/lsb-release ]]; then
        error "This script is designed for Ubuntu systems"
        exit 1
    fi
    
    echo " "
    echo "============================================="
    echo -e "${GREEN}CURRENT SERVER SPECS${NC}"
    echo "============================================="
    echo ""
    
    # Operating System Information
    UBUNTU_VERSION=$(lsb_release -rs)
    UBUNTU_CODENAME=$(lsb_release -cs)
    KERNEL_VERSION=$(uname -r)
    ARCHITECTURE=$(uname -m)
    
    echo -e "${YELLOW}🖥️  Operating System:${NC}"
    echo -e "   ${WHITE}├─${NC} Ubuntu: ${GREEN}$UBUNTU_VERSION ($UBUNTU_CODENAME)${NC}"
    echo -e "   ${WHITE}├─${NC} Kernel: ${GREEN}$KERNEL_VERSION${NC}"
    echo -e "   ${WHITE}└─${NC} Architecture: ${GREEN}$ARCHITECTURE${NC}"
    
    # CPU Information
    CPU_MODEL=$(grep "model name" /proc/cpuinfo | head -n1 | cut -d':' -f2 | xargs)
    CPU_CORES=$(nproc --all)
    CPU_THREADS=$(grep -c ^processor /proc/cpuinfo)
    
    echo ""
    echo -e "${YELLOW}🔧 CPU Information:${NC}"
    echo -e "   ${WHITE}├─${NC} Model: ${GREEN}$CPU_MODEL${NC}"
    echo -e "   ${WHITE}├─${NC} Cores: ${GREEN}$CPU_CORES${NC}"
    echo -e "   ${WHITE}└─${NC} Threads: ${GREEN}$CPU_THREADS${NC}"
    
    # Memory Information
    TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    TOTAL_RAM_GB=$(printf "%.2f" $(echo "scale=2; $TOTAL_RAM_KB/1024/1024" | bc -l 2>/dev/null) 2>/dev/null || echo "$(($TOTAL_RAM_KB/1024/1024))")
    AVAILABLE_RAM_KB=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    AVAILABLE_RAM_GB=$(printf "%.2f" $(echo "scale=2; $AVAILABLE_RAM_KB/1024/1024" | bc -l 2>/dev/null) 2>/dev/null || echo "$(($AVAILABLE_RAM_KB/1024/1024))")
    
    echo ""
    echo -e "${YELLOW}💾 Memory Information:${NC}"
    echo -e "   ${WHITE}├─${NC} Total RAM: ${GREEN}${TOTAL_RAM_GB} GB${NC}"
    echo -e "   ${WHITE}└─${NC} Available RAM: ${GREEN}${AVAILABLE_RAM_GB} GB${NC}"
    
    # Disk Information
    echo ""
    echo -e "${YELLOW}💽 Storage Information:${NC}"
    df -h / | tail -n1 | while read filesystem size used available percent mountpoint; do
        echo -e "   ${WHITE}└─${NC} Root Partition: ${GREEN}$size total, $used used, $available available ($percent used)${NC}"
    done
    
    # Additional disk information
    TOTAL_DISK_GB=$(df -BG / | tail -n1 | awk '{print $2}' | sed 's/G//')
    info "Total Disk Space: ${TOTAL_DISK_GB} GB"
    
    # Network Information
    echo ""
    echo -e "${YELLOW}🌐 Network Information:${NC}"
    # Get primary network interface
    PRIMARY_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    if [[ -n "$PRIMARY_INTERFACE" ]]; then
        LOCAL_IP=$(ip addr show $PRIMARY_INTERFACE | grep "inet " | awk '{print $2}' | cut -d/ -f1)
        echo -e "   ${WHITE}├─${NC} Primary Interface: ${GREEN}$PRIMARY_INTERFACE${NC}"
        echo -e "   ${WHITE}├─${NC} Local IP: ${GREEN}$LOCAL_IP${NC}"
    fi
    
    # Try to get public IP
    PUBLIC_IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || echo "Unable to detect")
    echo -e "   ${WHITE}└─${NC} Public IP: ${GREEN}$PUBLIC_IP${NC}"
    
    # System Load and Uptime
    echo ""
    echo -e "${YELLOW}📊 System Status:${NC}"
    UPTIME=$(uptime -p 2>/dev/null || uptime | awk '{print $3,$4}')
    LOAD_AVERAGE=$(uptime | awk -F'load average:' '{print $2}' | xargs)
    echo -e "   ${WHITE}├─${NC} Uptime: ${GREEN}$UPTIME${NC}"
    echo -e "   ${WHITE}└─${NC} Load Average: ${GREEN}$LOAD_AVERAGE${NC}"
    
    # Check if system meets Laravel requirements
    echo ""
    echo "============================================="
    echo -e "${GREEN}S-LEMP INSPECTION${NC}"
    echo "============================================="
    echo ""
    
    # RAM Check (minimum 1GB recommended for Laravel)
    if (( $(echo "$TOTAL_RAM_GB >= 1" | bc -l 2>/dev/null || echo "$(($TOTAL_RAM_KB >= 1048576))") )); then
        echo -e "${GREEN}✅ RAM: ${TOTAL_RAM_GB} GB (Sufficient for Laravel)${NC}"
    else
        echo -e "${YELLOW}⚠️  RAM: ${TOTAL_RAM_GB} GB (Low - 1GB+ recommended for Laravel)${NC}"
    fi
    
    # CPU Check
    if [[ $CPU_CORES -ge 1 ]]; then
        echo -e "${GREEN}✅ CPU: $CPU_CORES cores (Sufficient)${NC}"
    else
        echo -e "${YELLOW}⚠️  CPU: $CPU_CORES cores (May be insufficient)${NC}"
    fi
    
    # Disk Check (minimum 10GB recommended)
    if [[ $TOTAL_DISK_GB -ge 10 ]]; then
        echo -e "${GREEN}✅ Disk: ${TOTAL_DISK_GB} GB (Sufficient)${NC}"
    else
        echo -e "${YELLOW}⚠️  Disk: ${TOTAL_DISK_GB} GB (Low - 10GB+ recommended)${NC}"
    fi

    # Ubuntu version compatibility check
    if [[ ! "$UBUNTU_VERSION" =~ ^(22|24)\. ]]; then
        echo -e "${YELLOW}⚠️  Ubuntu version $UBUNTU_VERSION may not be fully supported${NC}"
    else
        echo -e "${GREEN}✅ Ubuntu version $UBUNTU_VERSION is fully supported${NC}"
    fi
    echo ""
    
    # Additional Ubuntu version compatibility check with user prompt
    if [[ ! "$UBUNTU_VERSION" =~ ^(22|24)\. ]]; then
        warning "This script is optimized for Ubuntu 22.04 and 24.04"
        warning "Your version ($UBUNTU_VERSION) may not be fully supported"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# =========================================================================
# UPDATE SYSTEM AND INSTALL CORE SERVICES
# =========================================================================
update_and_install_core_system() {
    echo ""
    echo "============================================="
    echo -e "${GREEN}🔄 UPDATING CORE SYSTEM${NC}"
    echo "============================================="
    echo ""
    
    # Kill any apt processes that might be hanging
    sudo killall apt apt-get 2>/dev/null || true
    sleep 2
    
    # Wait for apt locks to be released
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        warning "Waiting for other package managers to finish..."
        sleep 5
    done
    
    # Update package lists with retries
    local retries=3
    for ((i=1; i<=retries; i++)); do
        if sudo apt update; then
            log "✓ Package lists updated successfully"
            break
        else
            warning "Attempt $i/$retries: Failed to update package lists"
            if [[ $i -lt $retries ]]; then
                sleep 5
            else
                error "Failed to update package lists after $retries attempts"
                return 1
            fi
        fi
    done
    
    # Upgrade system packages
    info "Upgrading system packages (this may take a while)..."
    if sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y; then
        log "✓ System packages upgraded successfully"
    else
        warning "Some packages failed to upgrade, continuing anyway..."
    fi

    echo ""
    echo "============================================="
    echo -e "${GREEN}📦 INSTALLING ESSENTIAL PACKAGES${NC}"
    echo "============================================="
    echo ""
    
    sudo apt install -y curl wget git unzip software-properties-common apt-transport-https ca-certificates gnupg lsb-release bc
}

# =========================================================================
# INSTALL NGINX
# =========================================================================
install_nginx() {
    echo ""
    echo "============================================="
    echo -e "${GREEN}🌐 INSTALLING NGINX${NC}"
    echo "============================================="
    echo ""
    
    sudo apt install -y nginx
    
    echo ""
    echo "============================================="
    echo -e "${GREEN}CONFIGURING NGINX${NC}"
    echo "============================================="
    echo ""
    
    sudo systemctl start nginx
    sudo systemctl enable nginx
    
    # Test nginx configuration
    if sudo nginx -t; then
        log "✓ Nginx configuration is valid"
    else
        error "Nginx configuration test failed"
        return 1
    fi
    
    # Clean up default web files
    echo "   "
    echo "============================================="
    echo -e "${GREEN}Cleaning up default web files...${NC}"
    echo "============================================="
    
    # Remove default Nginx/Apache HTML files
    if [[ -d "/var/www/html" ]]; then
        sudo rm -rf /var/www/html/*
        log "✓ Default HTML files removed from /var/www/html"
    fi
    
    # Remove any default index files in /var/www
    if [[ -f "/var/www/index.nginx-debian.html" ]]; then
        sudo rm -f /var/www/index.nginx-debian.html
        log "✓ Default Nginx index file removed"
    fi
    
    if [[ -f "/var/www/index.html" ]]; then
        sudo rm -f /var/www/index.html
        log "✓ Default index.html removed"
    fi
    
    # Ensure /var/www has proper permissions
    sudo chown root:root /var/www
    sudo chmod 755 /var/www
    
    log "✓ Web directory cleanup completed"
    
    log "✓ Nginx installed and started successfully"
}

# =========================================================================
# Create Project Directory and Nginx Site Configuration
# =========================================================================
create_project_structure() {
    echo " "
    echo "============================================="
    echo -e "${GREEN}Creating project directory and Nginx site configuration${NC}"
    echo "============================================="
    
    # Create project directory (empty, ready for Laravel deployment)
    sudo mkdir -p ${PROJECT_ROOT}/${PROJECT_NAME}
    sudo chown -R ${SYSTEM_USER}:${PROJECT_GROUP} ${PROJECT_ROOT}/${PROJECT_NAME}
    sudo chmod -R 755 ${PROJECT_ROOT}/${PROJECT_NAME}
    
    # Create a placeholder file to indicate the directory is ready for Laravel
    echo " "
    echo "============================================="
    echo -e "${GREEN}Preparing directory for Laravel deployment...${NC}"
    echo "============================================="
    
    # Create a README file explaining how to deploy Laravel
    sudo tee ${PROJECT_ROOT}/${PROJECT_NAME}/DEPLOY_LARAVEL_HERE.md > /dev/null <<EOF
# Laravel Deployment Instructions

This directory is ready for your Laravel project deployment.

## To deploy your Laravel project:

1. Remove this file:
   \`\`\`bash
   sudo rm ${PROJECT_ROOT}/${PROJECT_NAME}/DEPLOY_LARAVEL_HERE.md
   \`\`\`

2. Clone your Laravel project:
   \`\`\`bash
   sudo git clone https://your-repo-url.git ${PROJECT_ROOT}/${PROJECT_NAME}
   \`\`\`
   
   OR if cloning into current directory:
   \`\`\`bash
   cd ${PROJECT_ROOT}/${PROJECT_NAME}
   sudo git clone https://your-repo-url.git .
   \`\`\`

3. Install dependencies:
   \`\`\`bash
   cd ${PROJECT_ROOT}/${PROJECT_NAME}
   sudo -u www-data composer install
   sudo -u www-data npm install
   \`\`\`

4. Set up environment:
   \`\`\`bash
   sudo -u www-data cp .env.example .env
   sudo -u www-data php artisan key:generate
   \`\`\`

5. Fix permissions:
   \`\`\`bash
   sudo fix-laravel-permissions ${PROJECT_ROOT}/${PROJECT_NAME}
   \`\`\`

6. Run migrations (if needed):
   \`\`\`bash
   cd ${PROJECT_ROOT}/${PROJECT_NAME}
   sudo -u www-data php artisan migrate
   \`\`\`

Your LEMP stack is configured and ready!
EOF
    
    # Set ownership for Laravel directories
    sudo chown -R ${SYSTEM_USER}:${PROJECT_GROUP} ${PROJECT_ROOT}/${PROJECT_NAME}
    
    log "✓ Project directory created: ${PROJECT_ROOT}/${PROJECT_NAME}"
    log "✓ Directory is ready for Laravel deployment"
    info "Check ${PROJECT_ROOT}/${PROJECT_NAME}/DEPLOY_LARAVEL_HERE.md for deployment instructions"
    
    # Create Nginx site configuration
    sudo tee /etc/nginx/sites-available/${PROJECT_NAME} > /dev/null <<EOF
server {
    listen 80;
    server_name ${DOMAIN_NAME};
    root ${PROJECT_ROOT}/${PROJECT_NAME}/public;
    index index.php index.html index.htm;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'" always;
    add_header X-Robots-Tag "noindex, nofollow" always;

    # Laravel-specific optimizations
    client_max_body_size 64M;
    fastcgi_read_timeout 300;

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_proxied expired no-cache no-store private auth;
    gzip_types text/plain text/css text/xml text/javascript application/x-javascript application/xml+rss application/json;

    # Handle Laravel public assets
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    # Handle PHP files
    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm-${PROJECT_NAME}.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        
        # Laravel-specific fastcgi params
        fastcgi_param HTTP_PROXY "";
        fastcgi_param HTTPS \$https if_not_empty;
    }

    # Laravel URL rewriting
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    # Deny access to sensitive files
    location ~ /\.(ht|env) {
        deny all;
    }
    
    location ~ /storage/ {
        deny all;
    }
    
    location ~ /bootstrap/cache/ {
        deny all;
    }

    # Handle Laravel storage symlink
    location ^~ /storage {
        alias ${PROJECT_ROOT}/${PROJECT_NAME}/public/storage;
        try_files \$uri \$uri/ =404;
    }
}
EOF
    
    # Enable the site
    sudo ln -sf /etc/nginx/sites-available/${PROJECT_NAME} /etc/nginx/sites-enabled/
    
    # Remove default site if exists
    sudo rm -f /etc/nginx/sites-enabled/default
    
    log "✓ Nginx site configuration created and enabled: ${PROJECT_NAME}"
    
    # Test Nginx configuration
    if sudo nginx -t; then
        sudo systemctl reload nginx
        log "✓ Nginx reloaded successfully"
    else
        error "Nginx configuration test failed"
        exit 1
    fi
}

# =========================================================================
# Configure OPcache Settings for Optimal Laravel Performance
# =========================================================================
configure_opcache_settings() {
    info "Configuring OPcache for optimal Laravel performance..."
    
    local opcache_ini_files=(
        "/etc/php/${PHP_VERSION}/fpm/conf.d/10-opcache.ini"
        "/etc/php/${PHP_VERSION}/cli/conf.d/10-opcache.ini"
    )
    
    # OPcache configuration optimized for Laravel
    local opcache_config="
; OPcache Configuration for Laravel
; Enable OPcache
opcache.enable=1
opcache.enable_cli=1

; Memory settings
opcache.memory_consumption=256
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000

; Performance settings
opcache.revalidate_freq=2
opcache.fast_shutdown=1
opcache.save_comments=1
opcache.validate_timestamps=1

; Laravel-specific optimizations
opcache.max_wasted_percentage=10
opcache.consistency_checks=0
opcache.force_restart_timeout=180
opcache.blacklist_filename=/etc/php/${PHP_VERSION}/opcache-blacklist.txt
"
    
    # Apply configuration to both FPM and CLI
    for ini_file in "${opcache_ini_files[@]}"; do
        if [[ -f "$ini_file" ]]; then
            info "Updating OPcache configuration in $ini_file"
            
            # Backup original file
            sudo cp "$ini_file" "${ini_file}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
            
            # Update OPcache settings
            echo "$opcache_config" | sudo tee "$ini_file" > /dev/null
            
            log "✓ OPcache configuration updated in $ini_file"
        else
            warning "OPcache ini file not found: $ini_file"
            
            # Create the file if it doesn't exist
            sudo mkdir -p "$(dirname "$ini_file")" 2>/dev/null || true
            echo "$opcache_config" | sudo tee "$ini_file" > /dev/null
            log "✓ Created OPcache configuration file: $ini_file"
        fi
    done
    
    # Create OPcache blacklist file (empty for now, can be customized later)
    local blacklist_file="/etc/php/${PHP_VERSION}/opcache-blacklist.txt"
    if [[ ! -f "$blacklist_file" ]]; then
        sudo tee "$blacklist_file" > /dev/null <<EOF
; OPcache blacklist for Laravel
; Add files or directories that should not be cached
; Example:
; /var/www/*/storage/*
; /var/www/*/bootstrap/cache/*
EOF
        log "✓ Created OPcache blacklist file: $blacklist_file"
    fi
    
    # Restart PHP-FPM to apply OPcache configuration
    info "Restarting PHP-FPM to apply OPcache configuration..."
    if sudo systemctl restart php${PHP_VERSION}-fpm; then
        log "✓ PHP-FPM restarted successfully"
        sleep 3  # Allow time for service to fully restart
    else
        warning "Failed to restart PHP-FPM"
    fi
    
    log "✓ OPcache configuration completed"
}

# =========================================================================
# Verify and Fix PHP Extensions
# =========================================================================
verify_php_extensions() {
    echo " "
    echo "============================================="
    echo -e "${GREEN}Verifying and fixing PHP extensions...${NC}"
    echo "============================================="
    
    # Wait for PHP to be fully ready
    info "Waiting for PHP extensions to be fully loaded..."
    sleep 3
    
    # Define critical extensions that must be working
    local critical_extensions=("redis" "mbstring" "xml" "curl" "zip" "gd" "mysql" "bcmath" "intl" "opcache")
    local missing_extensions=()
    local retry_count=0
    local max_retries=2
    
    while [[ $retry_count -le $max_retries ]]; do
        missing_extensions=()
        
        info "Checking PHP extensions (attempt $((retry_count + 1))/$((max_retries + 1)))..."
        
        for ext in "${critical_extensions[@]}"; do
            # Special case for mysql extension (check multiple possible names)
            if [[ "$ext" == "mysql" ]]; then
                if php${PHP_VERSION} -m | grep -qE "(mysqli|mysqlnd|pdo_mysql)"; then
                    log "✓ PHP MySQL support is loaded"
                else
                    warning "⚠ PHP MySQL support is not loaded"
                    missing_extensions+=("php${PHP_VERSION}-mysql")
                fi
            # Special case for redis extension
            elif [[ "$ext" == "redis" ]]; then
                if php${PHP_VERSION} -m | grep -q "redis"; then
                    echo ""
                    log "✓ PHP Redis extension is loaded"
                else
                    warning "⚠ PHP Redis extension is not loaded"
                    missing_extensions+=("php${PHP_VERSION}-redis")
                fi
            # Special case for opcache extension (requires different detection method)
            elif [[ "$ext" == "opcache" ]]; then
                if php${PHP_VERSION} -r "if (extension_loaded('Zend OPcache')) { exit(0); } else { exit(1); }" 2>/dev/null; then
                    log "✓ PHP OPcache extension is loaded"
                else
                    warning "⚠ PHP OPcache extension is not loaded"
                    missing_extensions+=("php${PHP_VERSION}-opcache")
                fi
            # Handle pcntl separately as it may not be available on all systems
            elif [[ "$ext" == "pcntl" ]]; then
                if php${PHP_VERSION} -m | grep -q "pcntl"; then
                    log "✓ PHP $ext extension is loaded"
                else
                    info "ℹ PHP $ext extension is not loaded (this is normal for web installations)"
                fi
            else
                if php${PHP_VERSION} -m | grep -q "$ext"; then
                    log "✓ PHP $ext extension is loaded"
                else
                    warning "⚠ PHP $ext extension is not loaded"
                    missing_extensions+=("php${PHP_VERSION}-$ext")
                fi
            fi
        done
        
        # If no missing extensions, we're done
        if [[ ${#missing_extensions[@]} -eq 0 ]]; then
            log "✓ All critical PHP extensions are loaded successfully!"
            break
        fi
        
        # If this is our last retry, report the issue
        if [[ $retry_count -eq $max_retries ]]; then
            error "Some PHP extensions are still missing after $max_retries retries"
            info "Missing extensions: ${missing_extensions[*]}"
            warning "Continuing installation, but some Laravel features may not work properly"
            break
        fi
        
        # Try to install missing extensions
        info "Attempting to install missing extensions: ${missing_extensions[*]}"
        for package in "${missing_extensions[@]}"; do
            if sudo apt install -y "$package" 2>/dev/null; then
                log "✓ Successfully installed: $package"
            else
                warning "Failed to install: $package"
            fi
        done
        
        # Wait before retry
        info "Waiting for extensions to be loaded..."
        sleep 5
        retry_count=$((retry_count + 1))
    done
    
    # Additional Redis-specific verification
    echo " "
    info "Performing Redis extension specific verification..."
    if php${PHP_VERSION} -r "if (extension_loaded('redis')) { exit(0); } else { exit(1); }" 2>/dev/null; then
        log "✓ Redis extension verified through PHP code execution"
    else
        warning "⚠ Redis extension verification failed"
        info "Attempting to force-install Redis extension..."
        
        # Try alternative Redis installation methods
        if sudo apt install -y php${PHP_VERSION}-redis; then
            log "✓ Redis extension reinstalled"
            
            # Test again after reinstallation
            if php${PHP_VERSION} -r "if (extension_loaded('redis')) { exit(0); } else { exit(1); }" 2>/dev/null; then
                log "✓ Redis extension now working after reinstallation"
            else
                warning "Redis extension still not working - may need manual configuration"
            fi
        else
            warning "Failed to reinstall Redis extension"
        fi
    fi
    
    # Additional OPcache-specific verification and configuration
    echo " "
    info "Performing OPcache extension specific verification and optimization..."
    if php${PHP_VERSION} -r "if (extension_loaded('Zend OPcache')) { exit(0); } else { exit(1); }" 2>/dev/null; then
        log "✓ OPcache extension verified through PHP code execution"
        
        # Check if OPcache is enabled and properly configured
        local opcache_enabled=$(php${PHP_VERSION} -r "echo ini_get('opcache.enable') ? 'enabled' : 'disabled';" 2>/dev/null || echo "unknown")
        if [[ "$opcache_enabled" == "enabled" ]]; then
            log "✓ OPcache is enabled and active"
            
            # Display OPcache configuration for verification
            info "OPcache configuration:"
            php${PHP_VERSION} -r "
                echo '  • Memory consumption: ' . ini_get('opcache.memory_consumption') . ' MB' . PHP_EOL;
                echo '  • Max accelerated files: ' . ini_get('opcache.max_accelerated_files') . PHP_EOL;
                echo '  • Revalidate frequency: ' . ini_get('opcache.revalidate_freq') . ' seconds' . PHP_EOL;
                echo '  • Fast shutdown: ' . (ini_get('opcache.fast_shutdown') ? 'enabled' : 'disabled') . PHP_EOL;
            " 2>/dev/null || info "  Unable to read OPcache configuration"
        else
            warning "⚠ OPcache extension is loaded but not enabled"
            info "Attempting to configure OPcache..."
            
            # Create or update OPcache configuration
            configure_opcache_settings
        fi
    else
        warning "⚠ OPcache extension verification failed"
        info "Attempting to force-install and configure OPcache extension..."
        
        # Try to install and configure OPcache
        if sudo apt install -y php${PHP_VERSION}-opcache; then
            log "✓ OPcache extension reinstalled"
            
            # Configure OPcache settings
            configure_opcache_settings
            
            # Test again after reinstallation and configuration
            if php${PHP_VERSION} -r "if (extension_loaded('Zend OPcache')) { exit(0); } else { exit(1); }" 2>/dev/null; then
                log "✓ OPcache extension now working after reinstallation"
            else
                warning "OPcache extension still not working - may need manual configuration"
            fi
        else
            warning "Failed to reinstall OPcache extension"
        fi
    fi
    
    log "✓ PHP extension verification completed"
}

# =========================================================================
# Install PHP with Laravel extensions
# =========================================================================
install_php() {
    if dpkg -l | grep -q apache2; then
        echo "   "
        echo "============================================="
        echo "Apache detected. Removing..."
        echo "============================================="
        sudo systemctl stop apache2
        sudo systemctl disable apache2
        sudo apt remove --purge apache2 libapache2-mod-php* -y
        sudo apt autoremove -y
    fi

    echo "   "
    echo "============================================="
    echo -e "${GREEN}Start Installing Ondrej PHP PPA${NC}"
    echo "============================================="
    sudo apt install -y software-properties-common
    sudo add-apt-repository ppa:ondrej/php -y 
    sudo apt update -y

    echo "   "
    echo "============================================="
    echo -e "${GREEN}Installing PHP ${PHP_VERSION} + Extensions${NC}"
    echo "============================================="
    sudo systemctl stop php${PHP_VERSION}-fpm 2>/dev/null || true # ignore error if not running

    # Define core PHP packages
    local php_packages=(
        "php${PHP_VERSION}-fpm"
        "php${PHP_VERSION}-cli"
        "php${PHP_VERSION}-common"
        "php${PHP_VERSION}-mysql"
        "php${PHP_VERSION}-zip"
        "php${PHP_VERSION}-gd"
        "php${PHP_VERSION}-mbstring"
        "php${PHP_VERSION}-curl"
        "php${PHP_VERSION}-xml"
        "php${PHP_VERSION}-bcmath"
        "php${PHP_VERSION}-intl"
        "php${PHP_VERSION}-readline"
        "php${PHP_VERSION}-opcache"
        "php${PHP_VERSION}-redis"
    )
    
    # Define optional PHP packages (install if available)
    local optional_packages=(
        "php${PHP_VERSION}-tokenizer"
        "php${PHP_VERSION}-xmlwriter"
        "php${PHP_VERSION}-simplexml"
        "php${PHP_VERSION}-dom"
        "php${PHP_VERSION}-fileinfo"
        "php${PHP_VERSION}-imagick"
        "php${PHP_VERSION}-exif"
        "php${PHP_VERSION}-soap"
        "php${PHP_VERSION}-phar"
        "php${PHP_VERSION}-iconv"
        "php${PHP_VERSION}-ctype"
        "php${PHP_VERSION}-pcntl"
        "php${PHP_VERSION}-posix"
    )
    
    # Install core packages
    sudo apt install -y "${php_packages[@]}"
    
    # Install optional packages (don't fail if some are missing)
    for package in "${optional_packages[@]}"; do
        if sudo apt install -y "$package" 2>/dev/null; then
            log "✓ Installed optional package: $package"
        else
            warning "Optional package not available: $package"
        fi
    done

    echo "   "
    echo "============================================="
    echo -e "${GREEN}Create Directory and Files${NC}"
    echo "============================================="
    sudo mkdir -p /var/log/php
    sudo chown www-data:www-data /var/log/php
    sudo mkdir -p /etc/php/${PHP_VERSION}/fpm/pool.d
    echo "Success creating directory and files"

    # Verify and fix PHP extensions
    verify_php_extensions

    echo "   "
    echo "============================================="
    echo -e "${GREEN}Creating PHP-FPM pool configuration${NC}"
    echo "============================================="
    sudo tee /etc/php/${PHP_VERSION}/fpm/pool.d/${PROJECT_NAME}.conf > /dev/null <<EOF
[${PROJECT_NAME}]
user = www-data
group = www-data
listen = /run/php/php${PHP_VERSION}-fpm-${PROJECT_NAME}.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

pm = dynamic
pm.max_children = 20
pm.start_servers = 3
pm.min_spare_servers = 2
pm.max_spare_servers = 6
pm.max_requests = 1000

php_admin_value[memory_limit] = 256M
php_admin_value[upload_max_filesize] = 64M
php_admin_value[post_max_size] = 64M
php_admin_value[max_execution_time] = 300
php_admin_value[max_input_vars] = 3000

php_admin_flag[display_errors] = off
php_admin_flag[log_errors] = on
php_admin_value[error_log] = /var/log/php/${PROJECT_NAME}-error.log

; Laravel optimizations with enhanced OPcache
php_admin_value[opcache.enable] = 1
php_admin_value[opcache.memory_consumption] = 256
php_admin_value[opcache.interned_strings_buffer] = 16
php_admin_value[opcache.max_accelerated_files] = 10000
php_admin_value[opcache.revalidate_freq] = 2
php_admin_value[opcache.fast_shutdown] = 1
php_admin_value[opcache.enable_cli] = 1
php_admin_value[opcache.save_comments] = 1
php_admin_value[opcache.validate_timestamps] = 1

; Additional performance settings
php_admin_value[realpath_cache_size] = 2M
php_admin_value[realpath_cache_ttl] = 7200
EOF
    
    # Verify pool configuration syntax
    if sudo php-fpm${PHP_VERSION} -t -y /etc/php/${PHP_VERSION}/fpm/pool.d/${PROJECT_NAME}.conf 2>/dev/null; then
        log "✓ PHP-FPM pool configuration syntax is valid"
    else
        warning "PHP-FPM pool configuration syntax check failed (continuing anyway)"
    fi

    echo "   "
    echo "============================================="
    echo -e "${GREEN}Optimizing PHP-FPM Complete${NC}"
    echo "============================================="
    echo "Optimizing PHP-FPM for Laravel is complete"
    echo " "

    echo "============================================="
    echo -e "${GREEN}Starting and configuring PHP-FPM...${NC}"
    echo "============================================="
    
    sudo systemctl start php${PHP_VERSION}-fpm
    sudo systemctl enable php${PHP_VERSION}-fpm
    
    # Wait for PHP-FPM service to be fully ready
    info "Waiting for PHP-FPM service to initialize..."
    sleep 5
    
    # Reload PHP-FPM to apply the new pool configuration immediately
    info "Applying custom pool configuration..."
    sudo systemctl reload php${PHP_VERSION}-fpm
    sleep 3
    
    # Final verification of PHP extensions after PHP-FPM restart
    echo " "
    echo "============================================="
    echo -e "${GREEN}Final verification of PHP extensions...${NC}"
    echo "============================================="
    
    # Quick verification of critical extensions
    local final_check_extensions=("redis" "mbstring" "curl" "mysql")
    for ext in "${final_check_extensions[@]}"; do
        if [[ "$ext" == "mysql" ]]; then
            if php${PHP_VERSION} -m | grep -qE "(mysqli|mysqlnd|pdo_mysql)"; then
                log "✓ Final check: PHP MySQL support is working"
            else
                warning "⚠ Final check: PHP MySQL support issue detected"
            fi
        elif php${PHP_VERSION} -m | grep -q "$ext"; then
            log "✓ Final check: PHP $ext extension is working"
        else
            warning "⚠ Final check: PHP $ext extension issue detected"
        fi
    done
    
    # Verify PHP installation
    if php${PHP_VERSION} -v &>/dev/null; then
        log "✓ PHP ${PHP_VERSION} installed successfully"
    else
        error "PHP installation verification failed"
        return 1
    fi
    
    # Test PHP-FPM socket with enhanced detection
    local socket_path="/run/php/php${PHP_VERSION}-fpm-${PROJECT_NAME}.sock"
    local retries=8
    local socket_found=false

    for ((i=1; i<=retries; i++)); do
        if [[ -S "$socket_path" ]]; then
            log "✓ PHP-FPM socket created successfully: $socket_path"
            socket_found=true
            break
        else
            if [[ $i -lt $retries ]]; then
                info "Waiting for PHP-FPM socket... (attempt $i/$retries)"
                sleep 2
            fi
        fi
    done
    
    if [[ "$socket_found" = false ]]; then
        warning "Custom PHP-FPM socket not found after initial wait"
        info "This is normal - applying pool configuration and retrying..."
        
        # Check if PHP-FPM service is running
        if systemctl is-active --quiet php${PHP_VERSION}-fpm; then
            log "✓ PHP-FPM service is running"
        else
            error "PHP-FPM service is not running"
            info "Checking PHP-FPM logs: sudo journalctl -u php${PHP_VERSION}-fpm --no-pager -l"
            return 1
        fi
        
        # Check if the pool configuration exists
        if [[ -f "/etc/php/${PHP_VERSION}/fpm/pool.d/${PROJECT_NAME}.conf" ]]; then
            log "✓ PHP-FPM pool configuration exists"
        else
            error "PHP-FPM pool configuration not found"
            return 1
        fi
        
        # Force reload PHP-FPM to ensure pool is loaded
        info "Forcing PHP-FPM reload to apply pool configuration..."
        sudo systemctl reload php${PHP_VERSION}-fpm
        sleep 5
        
        # Final check after reload
        if [[ -S "$socket_path" ]]; then
            log "✓ PHP-FPM socket created after configuration reload: $socket_path"
        else
            error "PHP-FPM socket still not found after reload"
            info "Pool configuration may have syntax errors"
            info "Check PHP-FPM error logs: sudo journalctl -u php${PHP_VERSION}-fpm --no-pager -l"
            return 1
        fi
    fi
}

# =========================================================================
# Install Database
# =========================================================================
#
install_mariadb() {
    echo " "
    echo "============================================="
    echo -e "${GREEN}Installing MariaDB database server...${NC}"
    echo "============================================="
    
    sudo apt install -y mariadb-server mariadb-client
    
    echo " "
    echo "============================================="
    echo -e "${GREEN}Starting and configuring MariaDB...${NC}"
    echo "============================================="
    
    sudo systemctl start mariadb
    sudo systemctl enable mariadb

    echo "   "
    echo "============================================="
    echo -e "${GREEN}Securing MariaDB installation${NC}"
    echo "============================================="
    
    # Wait for MariaDB to be fully ready
    local retries=10
    for ((i=1; i<=retries; i++)); do
        if mysql -e "SELECT 1" &>/dev/null; then
            log "✓ MariaDB is ready for configuration"
            break
        else
            warning "Waiting for MariaDB to be ready... ($i/$retries)"
            sleep 3
        fi
    done
    
    # Secure MariaDB with error handling
    if sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';"; then
        log "✓ Root password set"
    else
        warning "Failed to set root password, might already be set"
    fi
    
    # Continue with other security steps
    sudo mysql -u root -p"${DB_ROOT_PASSWORD}" -e "DELETE FROM mysql.user WHERE User='';" 2>/dev/null || warning "Failed to remove anonymous users"
    sudo mysql -u root -p"${DB_ROOT_PASSWORD}" -e "DROP DATABASE IF EXISTS test;" 2>/dev/null || warning "Test database might not exist"
    sudo mysql -u root -p"${DB_ROOT_PASSWORD}" -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';" 2>/dev/null || true
    sudo mysql -u root -p"${DB_ROOT_PASSWORD}" -e "FLUSH PRIVILEGES;" || {
        error "Failed to flush privileges"
        return 1
    }

    echo "   "
    echo "============================================="
    echo -e "${GREEN}Creating database and user for Laravel${NC}"
    echo "============================================="
    
    # Create database and user with error handling
    if sudo mysql -u root -p"${DB_ROOT_PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"; then
        log "✓ Database '${DB_NAME}' created"
    else
        error "Failed to create database"
        return 1
    fi
    
    if sudo mysql -u root -p"${DB_ROOT_PASSWORD}" -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';"; then
        log "✓ Database user '${DB_USER}' created"
    else
        warning "Database user might already exist"
    fi
    
    if sudo mysql -u root -p"${DB_ROOT_PASSWORD}" -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'%';"; then
        log "✓ Privileges granted to '${DB_USER}'"
    else
        error "Failed to grant privileges"
        return 1
    fi
    
    sudo mysql -u root -p"${DB_ROOT_PASSWORD}" -e "FLUSH PRIVILEGES;"
    
    # Test database connection
    if mysql -u "${DB_USER}" -p"${DB_PASSWORD}" -e "USE ${DB_NAME}; SELECT 1;" &>/dev/null; then
        log "✓ Database connection test successful"
    else
        warning "Database connection test failed - check credentials"
    fi
}

# =========================================================================
# Install Node.js
# =========================================================================
install_nodejs() {
    echo " "
    echo "============================================="
    echo -e "${GREEN}Installing Node.js...${NC}"
    echo "============================================="
    
    # Check if NodeSource repository is already added
    if [[ ! -f /etc/apt/sources.list.d/nodesource.list ]]; then
        info "Adding NodeSource repository..."
        if curl -fsSL https://deb.nodesource.com/setup_${NODE_JS_VERSION} | sudo -E bash -; then
            log "✓ NodeSource repository added successfully"
        else
            error "Failed to add NodeSource repository"
            return 1
        fi
    else
        log "✓ NodeSource repository already exists"
    fi
    
    sudo apt install -y nodejs
    
    echo " "
    echo "============================================="
    echo -e "${GREEN}Verifying Node.js installation...${NC}"
    echo "============================================="
    
    if command -v node &>/dev/null && command -v npm &>/dev/null; then
        NODE_VERSION=$(node --version)
        NPM_VERSION=$(npm --version)
        log "✓ Node.js installed successfully"
        info "Node.js version: $NODE_VERSION"
        info "NPM version: $NPM_VERSION"
        
        # Verify versions meet minimum requirements
        local node_major_version=$(echo "$NODE_VERSION" | sed 's/v//' | cut -d. -f1)
        if [[ "$node_major_version" -ge "18" ]]; then
            log "✓ Node.js version meets Laravel requirements"
        else
            warning "Node.js version might be too old for some Laravel features"
        fi
    else
        error "Node.js installation verification failed"
        return 1
    fi
}

# =========================================================================
# Install Composer
# =========================================================================
install_composer() {
    echo "   "
    echo "============================================="
    echo -e "${GREEN}Installing Composer${NC}"
    echo "============================================="
    
    # Check if Composer is already installed
    if command -v composer &>/dev/null; then
        local current_version=$(composer --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -n1)
        warning "Composer already installed (version: $current_version)"
        info "Updating to latest version..."
        sudo composer self-update || warning "Failed to update Composer"
        return 0
    fi
    
    # Wait for PHP to be fully ready
    info "Waiting for PHP extensions to be fully loaded..."
    sleep 5
    
    # Verify required PHP extensions
    local required_extensions=("Phar" "mbstring" "curl" "openssl")
    for ext in "${required_extensions[@]}"; do
        if ! php${PHP_VERSION} -m | grep -q "$ext"; then
            warning "Required PHP extension '$ext' not found"
            info "Restarting PHP-FPM and waiting..."
            sudo systemctl restart php${PHP_VERSION}-fpm
            sleep 3
            break
        fi
    done
    
    # Download and verify Composer installer
    info "Downloading Composer installer..."
    local expected_signature="$(curl -s https://composer.github.io/installer.sig)"
    local installer_path="/tmp/composer-setup.php"
    
    if curl -s https://getcomposer.org/installer -o "$installer_path"; then
        log "✓ Composer installer downloaded"
    else
        error "Failed to download Composer installer"
        return 1
    fi
    
    # Verify installer signature
    local actual_signature="$(php -r "echo hash_file('sha384', '$installer_path');")"
    if [[ "$expected_signature" == "$actual_signature" ]]; then
        log "✓ Composer installer signature verified"
    else
        warning "Composer installer signature verification failed, but continuing..."
    fi
    
    # Install Composer
    info "Installing Composer using PHP ${PHP_VERSION}..."
    if php${PHP_VERSION} "$installer_path" --install-dir=/tmp; then
        sudo mv /tmp/composer.phar /usr/local/bin/composer
        sudo chmod +x /usr/local/bin/composer
        rm -f "$installer_path"
        log "✓ Composer installed successfully"
    else
        error "Composer installation failed"
        rm -f "$installer_path"
        return 1
    fi
    
    # Verify Composer installation
    if command -v composer &>/dev/null; then
        local version=$(timeout 10 composer --version 2>/dev/null || echo "Composer version check timed out")
        log "✓ Composer verification successful"
        info "$version"
        
        # Test Composer functionality with timeout
        info "Running quick Composer diagnostic check..."
        if timeout 15 composer diagnose --no-interaction &>/dev/null; then
            log "✓ Composer diagnostic check passed"
        else
            warning "Composer diagnostic check failed or timed out, but installation appears successful"
            info "This is normal and doesn't affect functionality"
        fi
        
        log "✓ Composer installation completed - proceeding to next component installation..."
    else
        error "Composer installation verification failed"
        return 1
    fi
}


# Install Redis
install_redis() {
    echo "   "
    echo "============================================="
    echo -e "${GREEN}Installing Redis server...${NC}"
    echo "============================================="
    
    sudo apt install -y redis-server
    
    # Configure Redis for production use
    echo "   "
    echo "============================================="
    echo -e "${GREEN}Configuring Redis for Laravel...${NC}"
    echo "============================================="
    
    # Apply Laravel-optimized Redis configuration
    local redis_conf="/etc/redis/redis.conf"
    
    # Backup the original configuration file
    if [[ ! -f "${redis_conf}.backup" ]]; then
        sudo cp "$redis_conf" "${redis_conf}.backup"
        log "✓ Created backup of original Redis configuration"
    fi
    
    # Set password - handle special characters properly
    info "Configuring Redis authentication..."
    
    # Remove any existing requirepass lines to avoid duplicates
    sudo sed -i '/^requirepass\|^# requirepass/d' "$redis_conf"
    
    # Add the new requirepass line at the end of the authentication section
    # Find the line number where authentication directives are typically located
    local auth_line=$(sudo grep -n "# requirepass foobared" "${redis_conf}.backup" | head -1 | cut -d: -f1 || echo "999")
    if [[ "$auth_line" == "999" ]]; then
        # If we can't find the usual location, append to the end
        echo "requirepass $REDIS_PASSWORD" | sudo tee -a "$redis_conf" > /dev/null
    else
        # Insert at the appropriate location
        sudo sed -i "${auth_line}i requirepass $REDIS_PASSWORD" "$redis_conf"
    fi
    
    log "✓ Redis authentication configured"
    
    # Security configurations - check if lines exist before modifying
    info "Applying Redis security configurations..."
    
    if sudo grep -q "^bind " "$redis_conf"; then
        sudo sed -i 's/^bind .*/bind 127.0.0.1/' "$redis_conf"
    else
        # Find and replace the default bind configuration
        sudo sed -i 's/^bind 127.0.0.1 ::1$/bind 127.0.0.1/' "$redis_conf"
    fi
    
    # Memory and policy configurations
    info "Configuring Redis memory settings..."
    
    if sudo grep -q "^maxmemory " "$redis_conf"; then
        sudo sed -i 's/^maxmemory .*/maxmemory 256mb/' "$redis_conf"
    else
        sudo sed -i 's/^# maxmemory <bytes>/maxmemory 256mb/' "$redis_conf"
    fi
    
    if sudo grep -q "^maxmemory-policy " "$redis_conf"; then
        sudo sed -i 's/^maxmemory-policy .*/maxmemory-policy allkeys-lru/' "$redis_conf"
    else
        sudo sed -i 's/^# maxmemory-policy noeviction/maxmemory-policy allkeys-lru/' "$redis_conf"
    fi
    
    # Laravel-specific Redis optimizations
    info "Applying Laravel-specific Redis optimizations..."
    
    if sudo grep -q "^tcp-keepalive " "$redis_conf"; then
        sudo sed -i 's/^tcp-keepalive .*/tcp-keepalive 60/' "$redis_conf"
    else
        sudo sed -i 's/^# tcp-keepalive 300/tcp-keepalive 60/' "$redis_conf"
    fi
    
    if sudo grep -q "^timeout " "$redis_conf"; then
        sudo sed -i 's/^timeout .*/timeout 300/' "$redis_conf"
    else
        sudo sed -i 's/^timeout 0/timeout 300/' "$redis_conf"
    fi
    
    # Additional performance tuning
    if sudo grep -q "^tcp-backlog " "$redis_conf"; then
        sudo sed -i 's/^tcp-backlog .*/tcp-backlog 511/' "$redis_conf"
    else
        sudo sed -i 's/^# tcp-backlog 511/tcp-backlog 511/' "$redis_conf"
    fi
    
    # Save configurations - only uncomment if they're commented
    info "Configuring Redis persistence settings..."
    sudo sed -i 's/^# save 900 1/save 900 1/' "$redis_conf"
    sudo sed -i 's/^# save 300 10/save 300 10/' "$redis_conf"
    sudo sed -i 's/^# save 60 10000/save 60 10000/' "$redis_conf"
    
    log "✓ Redis configuration applied successfully"
    
    # Test Redis configuration before starting
    echo "   "
    echo "============================================="
    echo -e "${GREEN}Testing Redis configuration...${NC}"
    echo "============================================="
    
    if sudo redis-server -t -c "$redis_conf" 2>/dev/null; then
        log "✓ Redis configuration is valid"
    else
        warning "Redis configuration test failed"
        info "Checking for syntax errors in Redis configuration..."
        
        # Show the actual configuration test output for debugging
        echo "Configuration test output:"
        sudo redis-server -t -c "$redis_conf" 2>&1 || true
        
        warning "Continuing with potentially invalid Redis configuration"
    fi
    
    # Start and enable Redis
    sudo systemctl start redis-server
    sudo systemctl enable redis-server
    
    # Wait for Redis to be ready
    sleep 3
    
    log "✓ Redis installed and configured"
    
    # Test Redis connection with retries
    local test_retries=5
    for ((i=1; i<=test_retries; i++)); do
        if timeout 10 redis-cli -a "${REDIS_PASSWORD}" ping 2>/dev/null | grep -q "PONG"; then
            log "✓ Redis connection test successful"
            return 0
        else
            warning "Redis connection test failed (attempt $i/$test_retries)"
            if [[ $i -lt $test_retries ]]; then
                sleep 2
            fi
        fi
    done
    
    warning "Redis connection test failed after $test_retries attempts"
    info "Redis might need manual configuration - check /etc/redis/redis.conf"
    
    # Try without password if authentication fails
    if timeout 5 redis-cli ping 2>/dev/null | grep -q "PONG"; then
        warning "Redis is running but authentication might not be configured correctly"
        info "Check Redis configuration: sudo nano /etc/redis/redis.conf"
    fi
}


# Install Supervisor
install_supervisor() {
    echo " "
    echo "============================================="
    echo -e "${GREEN}Installing Supervisor (process manager)...${NC}"
    echo "============================================="
    
    sudo apt install -y supervisor
    
    # Create Laravel queue worker configuration directory
    sudo mkdir -p /etc/supervisor/conf.d
    
    # Start and enable Supervisor
    sudo systemctl start supervisor
    sudo systemctl enable supervisor
    
    # Test Supervisor functionality
    if sudo supervisorctl status &>/dev/null; then
        log "✓ Supervisor is working correctly"
    else
        warning "Supervisor status check failed"
    fi
    
    log "✓ Supervisor installed and started"
    info "You can create Laravel queue worker configs in /etc/supervisor/conf.d/"
    info "Use 'sudo supervisorctl reread && sudo supervisorctl update' after adding configs"
}

# =========================================================================
# Create Laravel Queue Worker Supervisor Configuration
# =========================================================================
create_laravel_queue_config() {
    echo " "
    echo "============================================="
    echo -e "${GREEN}Creating Laravel queue worker configuration...${NC}"
    echo "============================================="
    
    # Define the supervisor config file path
    local supervisor_config="/etc/supervisor/conf.d/${PROJECT_NAME}-queue.conf"
    
    # Set the command based on queue driver
    local queue_command
    if [[ "$QUEUE_DRIVER" == "database" ]]; then
        queue_command="php ${PROJECT_ROOT}/${PROJECT_NAME}/artisan queue:work --tries=3 --timeout=90"
    else
        queue_command="php ${PROJECT_ROOT}/${PROJECT_NAME}/artisan queue:work ${QUEUE_DRIVER} --tries=3 --timeout=90"
    fi
    
    # Create the supervisor configuration file
    sudo tee "$supervisor_config" > /dev/null <<EOF
[program:${PROJECT_NAME}-queue]
process_name=%(program_name)s_%(process_num)02d
command=${queue_command}
autostart=true
autorestart=true
user=www-data
numprocs=${SUPERVISOR_PROCESS_NUM}
redirect_stderr=true
stdout_logfile=${PROJECT_ROOT}/${PROJECT_NAME}/storage/logs/queue-worker.log
stopwaitsecs=3600
EOF
    
    # Verify the configuration file was created
    if [[ -f "$supervisor_config" ]]; then
        log "✓ Supervisor queue configuration created: $supervisor_config"
        info "Configuration details:"
        info "  • Program name: ${PROJECT_NAME}-queue"
        info "  • Number of processes: ${SUPERVISOR_PROCESS_NUM}"
        info "  • Log file: ${PROJECT_ROOT}/${PROJECT_NAME}/storage/logs/queue-worker.log"

        echo " "

        info "  • Queue connection: ${QUEUE_DRIVER}"
        if [[ "$QUEUE_DRIVER" == "database" ]]; then
            info "  • Command: php artisan queue:work --tries=3 --timeout=90"
        else
            info "  • Command: php artisan queue:work ${QUEUE_DRIVER} --tries=3 --timeout=90"
        fi
    else
        warning "Failed to create supervisor configuration file"
        return 1
    fi
    
    # Create the log directory if it doesn't exist
    sudo mkdir -p "${PROJECT_ROOT}/${PROJECT_NAME}/storage/logs"
    sudo chown -R ${SYSTEM_USER}:${PROJECT_GROUP} "${PROJECT_ROOT}/${PROJECT_NAME}/storage/logs"
    sudo chmod -R 775 "${PROJECT_ROOT}/${PROJECT_NAME}/storage/logs"
    
    # Reload supervisor to read the new configuration
    info "Reloading Supervisor to apply new configuration..."
    if sudo supervisorctl reread; then
        log "✓ Supervisor configuration reloaded"
    else
        warning "Failed to reload Supervisor configuration"
    fi
    
    if sudo supervisorctl update >/dev/null 2>&1; then
        log "✓ Supervisor programs updated"
    else
        warning "Failed to update Supervisor programs"
    fi
    
    # Show status
    echo " "
    info "Supervisor queue worker status:"
    sudo supervisorctl status "${PROJECT_NAME}-queue:*" 2>/dev/null || {
        info "Queue workers will start automatically when Laravel is deployed"
        info "After deploying Laravel, run: sudo supervisorctl start ${PROJECT_NAME}-queue:*"
    }
    
    log "✓ Laravel queue worker configuration completed"
    info "The queue workers will automatically start when your Laravel project is deployed"
}


# =========================================================================
# Create Laravel Permission Helper Script
# =========================================================================
create_laravel_permission_helper() {
    echo " "
    echo "============================================="
    echo -e "${GREEN}Creating Laravel permission helper script...${NC}"
    echo "============================================="
    
    # Create Laravel permission script
    sudo tee /usr/local/bin/fix-laravel-permissions > /dev/null <<'EOF'
#!/bin/bash

# Laravel Permission Fixer Script
# Usage: fix-laravel-permissions [project-path]

PROJECT_PATH=${1:-"/var/www"}
WEBSERVER_USER="www-data"
WEBSERVER_GROUP="www-data"

if [ ! -d "$PROJECT_PATH" ]; then
    echo "Error: Directory $PROJECT_PATH does not exist"
    exit 1
fi

echo "Setting Laravel permissions for: $PROJECT_PATH"

# Set ownership
chown -R $WEBSERVER_USER:$WEBSERVER_GROUP $PROJECT_PATH

# Set base permissions
find $PROJECT_PATH -type d -exec chmod 755 {} \;
find $PROJECT_PATH -type f -exec chmod 644 {} \;

# Set Laravel-specific permissions
if [ -d "$PROJECT_PATH/storage" ]; then
    chmod -R 775 $PROJECT_PATH/storage
    chown -R $WEBSERVER_USER:$WEBSERVER_GROUP $PROJECT_PATH/storage
    echo "✓ Storage directory permissions set"
fi

if [ -d "$PROJECT_PATH/bootstrap/cache" ]; then
    chmod -R 775 $PROJECT_PATH/bootstrap/cache
    chown -R $WEBSERVER_USER:$WEBSERVER_GROUP $PROJECT_PATH/bootstrap/cache
    echo "✓ Bootstrap cache permissions set"
fi

# Make artisan executable if exists
if [ -f "$PROJECT_PATH/artisan" ]; then
    chmod +x $PROJECT_PATH/artisan
    echo "✓ Artisan made executable"
fi

echo "✅ Laravel permissions fixed successfully!"
EOF
    
    sudo chmod +x /usr/local/bin/fix-laravel-permissions
    
    log "✓ Laravel permission helper script created"
    info "Use 'fix-laravel-permissions /path/to/laravel' to fix permissions anytime"
}

# =========================================================================
# Setup Laravel Scheduler Cronjob
# =========================================================================
setup_laravel_scheduler() {
    echo " "
    echo "============================================="
    echo -e "${GREEN}Setting up Laravel scheduler cronjob...${NC}"
    echo "============================================="
    
    # Define the cron job command
    local cron_command="* * * * * cd ${PROJECT_ROOT}/${PROJECT_NAME} && php artisan schedule:run >> /dev/null 2>&1"
    
    # Check if cron job already exists for www-data user
    if sudo crontab -u www-data -l 2>/dev/null | grep -q "artisan schedule:run"; then
        log "✓ Laravel scheduler cron job already exists"
        return 0
    fi
    
    # Get existing crontab for www-data user (if any)
    local temp_cron_file=$(mktemp)
    sudo crontab -u www-data -l 2>/dev/null > "$temp_cron_file" || true
    
    # Add Laravel scheduler cron job
    echo "$cron_command" >> "$temp_cron_file"
    
    # Install the updated crontab
    if sudo crontab -u www-data "$temp_cron_file"; then
        log "✓ Laravel scheduler cron job added successfully"
        info "Cron job: $cron_command"
        info "The scheduler will run every minute as the www-data user"
    else
        warning "Failed to add Laravel scheduler cron job"
        rm -f "$temp_cron_file"
        return 1
    fi
    
    # Clean up temporary file
    rm -f "$temp_cron_file"
    
    # Verify cron service is running
    if systemctl is-active --quiet cron; then
        log "✓ Cron service is running"
    else
        warning "Cron service is not running, attempting to start..."
        if sudo systemctl start cron && sudo systemctl enable cron; then
            log "✓ Cron service started and enabled"
        else
            warning "Failed to start cron service"
        fi
    fi
    
    # Show current crontab for verification
    echo " "
    info "Current crontab for www-data user:"
    if sudo crontab -u www-data -l 2>/dev/null; then
        log "✓ Crontab entries found for www-data user"
    else
        warning "No crontab entries found for www-data user"
    fi
    
    log "✓ Laravel scheduler setup completed"
    info "The scheduler will automatically run Laravel scheduled tasks every minute"
    info "Make sure to define your scheduled tasks in app/Console/Kernel.php"
    echo ""
    echo "============================================="
    info "📋 How to verify the Laravel scheduler:"
    echo "============================================="
    info "• Check www-data crontab: sudo crontab -u www-data -l"
    info "• Check cron service: sudo systemctl status cron"
    info "• View cron logs: sudo tail -f /var/log/syslog | grep CRON"
    info "• Test scheduler manually: cd ${PROJECT_ROOT}/${PROJECT_NAME} && php artisan schedule:run"
    echo "============================================="
}


# Configure firewall with enhanced security
configure_firewall() {
    echo " "
    echo "============================================="
    echo -e "${GREEN}Configuring UFW firewall with enhanced security...${NC}"
    echo "============================================="

    # Check if UFW is already installed
    if ! command -v ufw &> /dev/null; then
        echo " "
        echo "============================================="
        echo -e "${GREEN}Installing UFW firewall...${NC}"
        echo "============================================="
        sudo apt update
        sudo apt install -y ufw || {
            error "Failed to install UFW"
            return 1
        }
    else
        echo " "
        echo "============================================="
        echo "UFW is already installed"
        echo "============================================="
    fi

    # Reset to defaults (force to avoid prompts)
    echo " "
    echo "============================================="
    echo -e "${GREEN}Resetting UFW to default configuration...${NC}"
    echo "============================================="
    echo "y" | sudo ufw --force reset || {
        error "Failed to reset UFW"
        return 1
    }

    # Configure default policies
    echo " "
    echo "============================================="
    echo -e "${GREEN}Setting default security policies...${NC}"
    echo "============================================="
    sudo ufw default deny incoming || {
        error "Failed to set default deny incoming"
        return 1
    }
    sudo ufw default allow outgoing || {
        error "Failed to set default allow outgoing"
        return 1
    }

    # Allow SSH with rate limiting (prevents brute force attacks)
    echo " "
    echo "============================================="
    echo -e "${GREEN}Configuring SSH access with rate limiting...${NC}"
    echo "============================================="
    sudo ufw limit ssh/tcp || {
        error "Failed to configure SSH with rate limiting"
        return 1
    }
    sudo ufw allow 22/tcp || {
        error "Failed to allow SSH port 22"
        return 1
    }

    # Allow HTTP and HTTPS for web traffic
    echo " "
    echo "============================================="
    echo -e "${GREEN}Configuring web server ports...${NC}"
    echo "============================================="
    sudo ufw allow 80/tcp || {
        error "Failed to allow HTTP port 80"
        return 1
    }
    sudo ufw allow 443/tcp || {
        error "Failed to allow HTTPS port 443"
        return 1
    }

    # Configure IPv6 support
    echo " "
    echo "============================================="
    echo -e "${GREEN}Configuring IPv6 support...${NC}"
    echo "============================================="
    sudo sed -i 's/IPV6=no/IPV6=yes/' /etc/default/ufw 2>/dev/null || true

    # Enable UFW with force flag
    echo " "
    echo "============================================="
    echo -e "${GREEN}Enabling UFW firewall...${NC}"
    echo "============================================="
    echo "y" | sudo ufw --force enable || {
        error "Failed to enable UFW"
        return 1
    }

    # Verify configuration
    echo " "
    echo "============================================="
    echo -e "${GREEN}Verifying Firewall configuration...${NC}"
    echo "============================================="
    if sudo ufw status | grep -q "Status: active"; then
        echo " "
        echo "============================================="
        echo "✅ UFW firewall is active and properly configured"
        echo "============================================="

        # Show current status
        echo " "
        echo "============================================="
        echo "Current firewall status:"
        echo "============================================="
        sudo ufw status verbose

        # Show allowed ports
        echo " "
        echo "============================================="
        echo "🔓 Allowed incoming connections"
        echo " • SSH (port 22) - Rate limited for security"
        echo " • SSH (port 80) - For web traffic"
        echo " • HTTPS (port 443) - For secure web traffic"
        echo " • All outgoing connections - Allowed by default"
        echo "============================================="

        warning "⚠️  Remember to open additional ports as needed for your applications"
        warning "⚠️  Use 'sudo ufw allow <port>/<protocol>' to open additional ports"

    else
        error "❌ UFW firewall failed to activate properly"
        return 1
    fi

    # Additional security recommendations
    echo
    log "🛡️  Security Recommendations:"
    info "• Consider enabling fail2ban for additional SSH protection"
    info "• Regularly review firewall rules with 'sudo ufw status'"
    info "• Monitor firewall logs in /var/log/ufw.log"
    info "• Use 'sudo ufw delete <rule_number>' to remove unwanted rules"

    echo""
    log "✅ Firewall configuration completed successfully!"
}


# =========================================================================
# Install Certbot for SSL
# =========================================================================
install_certbot() {
    echo "   "
    echo "============================================="
    echo -e "${GREEN}Installing Certbot for SSL management${NC}"
    echo "============================================="
    
    # Check if Certbot is already installed
    if command -v certbot &>/dev/null; then
        log "✓ Certbot is already installed"
        local version=$(certbot --version 2>/dev/null | head -n1)
        info "$version"
        return 0
    fi
    
    # Try snap installation first (for Ubuntu systems with snap support)
    if command -v snap &>/dev/null && systemctl is-active --quiet snapd 2>/dev/null; then
        info "Using snap package manager for Certbot installation..."
        
        # Install via snap
        if sudo snap install core 2>/dev/null && sudo snap refresh core 2>/dev/null; then
            if sudo snap install --classic certbot; then
                sudo ln -sf /snap/bin/certbot /usr/bin/certbot 2>/dev/null || true
                log "✓ Certbot installed via snap"
                info "Use 'sudo certbot --nginx' to obtain SSL certificates for your domains"
                return 0
            else
                warning "Snap installation failed, trying alternative method..."
            fi
        else
            warning "Snap core installation failed, trying alternative method..."
        fi
    fi
    
    # Alternative installation using system packages
    info "Installing Certbot using system package manager..."
    
    # Update package list
    sudo apt update
    
    # Install certbot and nginx plugin
    if sudo apt install -y certbot python3-certbot-nginx; then
        log "✓ Certbot installed via apt package manager"
        info "Use 'sudo certbot --nginx' to obtain SSL certificates for your domains"
        
        # Verify installation
        if command -v certbot &>/dev/null; then
            local version=$(certbot --version 2>/dev/null | head -n1)
            info "$version"
            return 0
        else
            error "Certbot installation verification failed"
            return 1
        fi
    else
        warning "Failed to install Certbot via apt, trying pip installation..."
        
        # Last resort: pip installation
        if command -v pip3 &>/dev/null || sudo apt install -y python3-pip; then
            if sudo pip3 install certbot certbot-nginx; then
                log "✓ Certbot installed via pip"
                info "Use 'sudo certbot --nginx' to obtain SSL certificates for your domains"
                return 0
            else
                error "All Certbot installation methods failed"
                warning "You can manually install Certbot later using:"
                warning "  sudo apt install certbot python3-certbot-nginx"
                return 1
            fi
        else
            error "Could not install Certbot using any available method"
            warning "Please install Certbot manually after the script completes"
            return 1
        fi
    fi
}

# =========================================================================
# Install SSL Certificate
# =========================================================================
install_ssl() {
    echo "   "
    echo "============================================="
    echo -e "${GREEN}Installing SSL certificate for ${DOMAIN_NAME}${NC}"
    echo "============================================="
    
    # Check if Certbot is installed
    if ! command -v certbot &> /dev/null; then
        error "Certbot not found. Skipping SSL installation."
        return 1
    fi
    
    # Obtain SSL certificate
    info "Requesting SSL certificate from Let's Encrypt..."
    info "Domain: ${DOMAIN_NAME}"
    info "Email: ${SSL_EMAIL}"
    
    if sudo certbot --nginx -d ${DOMAIN_NAME} --email ${SSL_EMAIL} --agree-tos --non-interactive; then
        log "✓ SSL certificate installed successfully for ${DOMAIN_NAME}"
        
        # Test Nginx configuration after SSL
        info "Testing Nginx configuration after SSL installation..."
        if sudo nginx -t; then
            sudo systemctl reload nginx
            log "✓ Nginx reloaded with SSL configuration"
        else
            error "Nginx configuration test failed after SSL installation"
            warning "SSL certificate was installed but Nginx configuration may have issues"
            return 1
        fi
        
        info "SSL certificate will auto-renew via cron job"
        info "Test your site: https://${DOMAIN_NAME}"
    else
        error "Failed to obtain SSL certificate from Let's Encrypt"
        warning "This could be due to:"
        warning "  • Domain not accessible from internet"
        warning "  • DNS not properly configured"  
        warning "  • Firewall blocking ports 80/443"
        warning "  • Rate limiting by Let's Encrypt"
        return 1
    fi
}

# =========================================================================
# Comprehensive System Verification
# =========================================================================
verify_installation() {
    echo " "
    echo "============================================="
    echo -e "${GREEN}Performing comprehensive system verification...${NC}"
    echo "============================================="
    
    local errors=0
    
    # Check services
    local services=("nginx" "php${PHP_VERSION}-fpm" "mariadb" "redis-server" "supervisor")
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service"; then
            log "✓ Service $service is running"
        else
            error "✗ Service $service is not running"
            ((errors++))
        fi
    done
    
    # Check ports
    local ports=("80:nginx" "22:ssh" "3306:mysql")
    for port_service in "${ports[@]}"; do
        local port="${port_service%:*}"
        local service="${port_service#*:}"
        if ss -ln | grep -q ":$port "; then
            log "✓ Port $port ($service) is listening"
        else
            warning "⚠ Port $port ($service) is not listening"
        fi
    done
    
    # Check PHP
    if php${PHP_VERSION} -v &>/dev/null; then
        log "✓ PHP ${PHP_VERSION} is working"
        
        # Check critical PHP extensions with better error reporting
        local extensions=("redis" "mbstring" "xml" "curl" "zip" "gd")
        local missing_count=0
        
        for ext in "${extensions[@]}"; do
            if php${PHP_VERSION} -m | grep -q "$ext"; then
                log "✓ PHP extension $ext is loaded"
            else
                warning "⚠ PHP extension $ext is not loaded"
                ((missing_count++))
            fi
        done
        
        # Special check for OPcache (requires different detection method)
        if php${PHP_VERSION} -r "if (extension_loaded('Zend OPcache')) { exit(0); } else { exit(1); }" 2>/dev/null; then
            local opcache_enabled=$(php${PHP_VERSION} -r "echo ini_get('opcache.enable') ? 'enabled' : 'disabled';" 2>/dev/null || echo "unknown")
            if [[ "$opcache_enabled" == "enabled" ]]; then
                log "✓ PHP OPcache extension is loaded and enabled"
            else
                warning "⚠ PHP OPcache extension is loaded but not enabled"
                ((missing_count++))
            fi
        else
            warning "⚠ PHP OPcache extension is not loaded"
            ((missing_count++))
        fi
        
        # Check MySQL/MariaDB support (multiple possible extension names)
        if php${PHP_VERSION} -m | grep -qE "(mysqli|mysqlnd|pdo_mysql)"; then
            log "✓ PHP MySQL/MariaDB support is loaded"
        else
            warning "⚠ PHP MySQL/MariaDB support is not loaded"
            ((missing_count++))
        fi
        
        # Provide guidance if extensions are missing
        if [[ $missing_count -gt 0 ]]; then
            echo " "
            warning "Found $missing_count missing or misconfigured PHP extensions"
            info "To fix missing extensions, you can run:"
            info "  sudo apt update && sudo apt install php${PHP_VERSION}-redis php${PHP_VERSION}-mbstring php${PHP_VERSION}-xml php${PHP_VERSION}-curl php${PHP_VERSION}-zip php${PHP_VERSION}-gd php${PHP_VERSION}-opcache"
            info "  sudo systemctl restart php${PHP_VERSION}-fpm"
            info "For OPcache issues, check: /etc/php/${PHP_VERSION}/fpm/conf.d/10-opcache.ini"
            echo " "
        else
            log "✓ All critical PHP extensions are properly loaded and configured"
        fi
    else
        error "✗ PHP ${PHP_VERSION} is not working"
        ((errors++))
    fi
    
    # Check Composer
    if command -v composer &>/dev/null; then
        log "✓ Composer is installed"
    else
        error "✗ Composer is not installed"
        ((errors++))
    fi
    
    # Check Node.js
    if command -v node &>/dev/null && command -v npm &>/dev/null; then
        log "✓ Node.js and NPM are installed"
    else
        error "✗ Node.js or NPM is not installed"
        ((errors++))
    fi
    
    # Check database connectivity
    if mysql -u "${DB_USER}" -p"${DB_PASSWORD}" -e "USE ${DB_NAME}; SELECT 1;" &>/dev/null; then
        log "✓ Database connectivity works"
    else
        warning "⚠ Database connectivity test failed"
    fi
    
    # Check Redis connectivity
    if timeout 5 redis-cli -a "${REDIS_PASSWORD}" ping 2>/dev/null | grep -q "PONG"; then
        log "✓ Redis server connectivity works"
        
        # Also test PHP Redis extension connectivity
        if php${PHP_VERSION} -r "
            try {
                \$redis = new Redis();
                \$redis->connect('127.0.0.1', 6379);
                \$redis->auth('${REDIS_PASSWORD}');
                \$result = \$redis->ping();
                exit(0);
            } catch (Exception \$e) {
                echo 'PHP Redis extension test: FAILED - ' . \$e->getMessage();
                exit(1);
            }
        " 2>/dev/null; then
            log "✓ PHP Redis extension connectivity works"
        else
            warning "⚠ PHP Redis extension connectivity test failed"
            info "Redis server is running but PHP extension may have issues"
        fi
    else
        warning "⚠ Redis server connectivity test failed"
    fi
    
    # Check Nginx configuration
    if sudo nginx -t &>/dev/null; then
        log "✓ Nginx configuration is valid"
    else
        error "✗ Nginx configuration has errors"
        ((errors++))
    fi
    
    # Check project directory
    if [[ -d "${PROJECT_ROOT}/${PROJECT_NAME}" ]]; then
        log "✓ Project directory exists"
    else
        warning "⚠ Project directory not found"
    fi
    
    # Summary
    echo " "
    if [[ $errors -eq 0 ]]; then
        echo "============================================="
        log "🎉 Installation verification completed successfully!"
        log "All critical components are working properly."
        echo "============================================="
    else
        echo "============================================="
        warning "⚠ Installation completed with $errors critical errors"
        warning "Please review the errors above and fix them manually"
        echo "============================================="
    fi
    
    return $errors
}


# Display completion message and next steps
show_completion_message() {
    echo ""
    echo -e "${GREEN}"
    echo "███████╗██╗   ██╗ ██████╗ ██████╗███████╗███████╗███████╗"
    echo "██╔════╝██║   ██║██╔════╝██╔════╝██╔════╝██╔════╝██╔════╝"
    echo "███████╗██║   ██║██║     ██║     █████╗  ███████╗███████╗"
    echo "╚════██║██║   ██║██║     ██║     ██╔══╝  ╚════██║╚════██║"
    echo "███████║╚██████╔╝╚██████╗╚██████╗███████╗███████║███████║"
    echo "╚══════╝ ╚═════╝  ╚═════╝ ╚═════╝╚══════╝╚══════╝╚══════╝"
    echo -e "${NC}"
    echo ""
    echo -e "${CYAN}🎉 S-LEMP Stack has been successfully installed! 🎉${NC}"
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Your Server is now ready for production!${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
    echo ""
}


# Main installation function
main() {
    # Create lock file to prevent concurrent runs
    create_lock

    # Show S-LEMP banner for all modes
    show_slemp_banner

    # check_root
    check_ubuntu

    # Show welcome message
    if [[ $INTERACTIVE_MODE == true ]]; then
        echo "============================================="
        echo -e "${GREEN}WELCOME TO S-LEMP INSTALLER${NC}"
        echo "============================================="
        echo ""
        echo -e "${CYAN}This script will install and configure:${NC}"
        echo "  - Nginx web server (optimized for Laravel)"
        echo "  - PHP 8.3/8.4 with all Laravel extensions"
        echo "  - MariaDB database server"
        echo "  - Redis server for caching and sessions"
        echo "  - Node.js for asset compilation"
        echo "  - Composer for PHP dependencies"
        echo "  - PHP OPcache for performance"
        echo "  - Supervisor for queue management"
        echo "  - Cron job for Laravel scheduler"
        echo "  - UFW firewall and SSL with Certbot"
        echo ""
        echo -e "${YELLOW}Let's configure your installation...${NC}"
        echo ""
    fi

    # Run interactive configuration wizard
    if [[ $INTERACTIVE_MODE == true ]]; then
        # Temporarily disable strict error handling for the configuration wizard
        set +e
        
        if run_configuration_wizard; then
            log "✓ Configuration completed successfully"
        else
            error "Configuration wizard failed. Please try again."
            exit 1
        fi
        
        # Re-enable strict error handling
        set -e
    else
        info "Running in non-interactive mode with default configuration"
        info "Project: $PROJECT_NAME | Domain: $DOMAIN_NAME | PHP: $PHP_VERSION"
    fi

    # Main installation sequence
    update_and_install_core_system
    install_nginx
    create_project_structure
    install_php
    install_mariadb
    install_composer
    install_nodejs
    install_redis
    install_supervisor
    create_laravel_queue_config
    create_laravel_permission_helper
    setup_laravel_scheduler
    configure_firewall
    
    # Install Certbot (non-critical - continue if it fails)
    if install_certbot; then
        log "✓ Certbot installation completed successfully"
    else
        warning "Certbot installation failed, but continuing with LEMP stack setup"
        info "You can install Certbot manually later using: sudo apt install certbot python3-certbot-nginx"
    fi
    
    # Install SSL certificate if requested
    # Note: SSL installation is now always manual - just install Certbot
    info "Installing Certbot for SSL certificate management..."
    if install_certbot; then
        log "✓ Certbot installation completed successfully"
        info "SSL certificate can be installed manually after server setup is complete"
    else
        warning "Certbot installation failed, but continuing with LEMP stack setup"
        info "You can install Certbot manually later using: sudo apt install certbot python3-certbot-nginx"
    fi

    echo " "
    echo "============================================="
    echo "All components installed successfully!"
    echo "============================================="
    info "Restarting services to ensure all components start properly..."

    # Temporarily disable strict error handling for service restarts
    set +e

    # Helper function to restart a service if it exists
    restart_service() {
        local svc="$1"
        if systemctl status "$svc" &>/dev/null; then
            info "Restarting service: $svc"
            if sudo systemctl restart "$svc"; then
                info "Service '$svc' restarted successfully."
            else
                warning "Failed to restart service '$svc'"
                info "Checking service status..."
                
                # Special handling for Redis
                if [[ "$svc" == "redis-server" ]]; then
                    warning "Redis restart failed. Attempting to diagnose and fix..."
                    
                    # Check Redis configuration
                    if sudo redis-server -t -c /etc/redis/redis.conf 2>/dev/null; then
                        info "Redis configuration is valid"
                    else
                        warning "Redis configuration is invalid"
                        info "Configuration test output:"
                        sudo redis-server -t -c /etc/redis/redis.conf 2>&1 | while read -r line; do
                            debug "  $line"
                        done
                        info "Manual Redis configuration review required"
                    fi
                    
                    # Try to start Redis again
                    if sudo systemctl start redis-server; then
                        log "✓ Redis started successfully after configuration fix"
                    else
                        error "Redis failed to start even after fixes"
                        info "Check Redis logs: sudo journalctl -u redis-server --no-pager -l"
                        info "Manual Redis troubleshooting required"
                    fi
                else
                    # For other services, try to start them
                    sudo systemctl start "$svc" || warning "Failed to start service '$svc'"
                fi
            fi
        else
            info "Service '$svc' not found. Skipping restart."
        fi
    }

    restart_service nginx
    restart_service php${PHP_VERSION}-fpm
    restart_service mariadb
    restart_service redis-server
    restart_service supervisor
    
    # Re-enable strict error handling
    set -e
    
    echo " "
    info "Service restart operations completed."
    
    # Run comprehensive verification
    echo " "
    echo "============================================="
    echo -e "${GREEN}Running final system verification...${NC}"
    echo "============================================="
    
    if verify_installation; then
        echo " "
        echo "============================================="
        echo "Next Steps:"
        echo "============================================="
        info "- Go to your project folder inside the ${PROJECT_ROOT}/${PROJECT_NAME} and read the further instruction for deploying your laravel app using GIT."
        info "- If you already know what to do, you can delete all the files inside your project folder and continue clone your project using GIT."
        info "- Deploy your Laravel project: git clone <repository> ${PROJECT_ROOT}/${PROJECT_NAME}"
        info "- Permissions are automatically set for Laravel structure"
        info "- Use 'fix-laravel-permissions ${PROJECT_ROOT}/${PROJECT_NAME}' if needed"
        info "- Configure your domain DNS to point to this server"
        echo ""
        info "⚠️  Important: Supervisor Queue Workers"
        info "- Queue workers will show 'FATAL' errors until Laravel is deployed"
        info "- After deploying Laravel, restart Supervisor: sudo supervisorctl restart all"
        info "- Check status with: sudo supervisorctl status"
        echo ""
        
        echo "SSL Certificate Setup (Manual):"
        info "Certbot is installed and ready for SSL certificate generation"
        info "After your domain is properly configured and accessible:"
        info "1. Test domain accessibility: curl -I http://${DOMAIN_NAME}"
        info "2. Install SSL certificate: sudo certbot --nginx -d ${DOMAIN_NAME} --email ${SSL_EMAIL} --agree-tos"
        info "3. Verify SSL: curl -I https://${DOMAIN_NAME}"

        echo " "
        echo " "

        echo "============================================="
        echo "Advertisement"
        echo "============================================="
        info "- If you need any help with Laravel development, feel free to reach out to me for freelance services."
        info "- I offer expert assistance to ensure your Laravel projects run smoothly and efficiently."
        info "- Contact me at saya@sulaimanmisri.com"
        info "- Visit my website at https://sulaimanmisri.com"
        info "- PM me on Facebook at https://www.fb.com/designcarasaya"
        info "- Or Whatsapp me at https://wa.me/60145777229"

        echo " "
        
        # Show the completion message with ASCII art
        show_completion_message
    else
        warning "Installation completed with some issues. Please review the verification results above."
    fi
    
    # Clean up lock file
    cleanup_lock
}


# Trap any errors and exit gracefully
trap 'error "Installation failed! Check the output above for details."; exit 1' ERR


# Run main installation
main "$@"
