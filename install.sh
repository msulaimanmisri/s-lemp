#!/bin/bash

# Allow piped install via `wget -qO- ... | sudo bash` — only block sourcing from interactive shell
if [[ "${BASH_SOURCE[0]}" != "${0}" ]] && [[ -t 0 ]]; then
    echo "Error: This script should be executed directly, not sourced."
    echo "Usage: ./installation-script.sh [--non-interactive]"
    echo "Hint: for piped install use: curl -fsSL https://raw.githubusercontent.com/msulaimanmisri/s-lemp/main/install.sh | sudo bash -s -- --help"
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
            PHP_VERSION="8.3"
            MARIADB_VERSION=${MARIADB_VERSION:-11.4}
            REDIS_VERSION=${REDIS_VERSION:-7.4}
            QUEUE_DRIVER="database"
            INSTALL_SSL=false
            INSTALL_DATABASE=true
            INSTALL_REDIS=true
            shift
            ;;
    
        --php-version)
            if [[ "$2" == "8.3" ]] || [[ "$2" == "8.4" ]] || [[ "$2" == "8.5" ]]; then
                PHP_VERSION="$2"
                shift 2
            else
                echo "Error: Invalid PHP version. Use 8.3, 8.4 or 8.5"
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

        --skip-database)
            INSTALL_DATABASE=false
            shift
            ;;

        --skip-redis)
            INSTALL_REDIS=false
            shift
            ;;

        --node-version)
            if [[ "$2" == "22.x" ]] || [[ "$2" == "24.x" ]]; then
                NODE_JS_VERSION="$2"
                shift 2
            else
                echo "Error: Invalid Node.js version. Use 22.x or 24.x"
                exit 1
            fi
            ;;

        --redis-version)
            if [[ "$2" == "system" ]] || [[ "$2" == "7.4" ]] || [[ "$2" == "8.0" ]]; then
                REDIS_VERSION="$2"
                shift 2
            else
                echo "Error: Invalid Redis version. Use 'system' (Ubuntu default), '7.4' or '8.0'"
                exit 1
            fi
            ;;

        --mariadb-version)
            if [[ "$2" == "system" ]] || [[ "$2" == "11.4" ]]; then
                MARIADB_VERSION="$2"
                shift 2
            else
                echo "Error: Invalid MariaDB version. Use 'system' (Ubuntu default) or '11.4' (LTS via MariaDB repo)"
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
            echo "  --php-version VERSION       Set PHP version (8.3, 8.4 or 8.5)"
            echo "  --node-version VERSION      Set Node.js version (22.x LTS or 24.x LTS)"
            echo "  --redis-version VERSION     Set Redis version (system, 7.4 or 8.0)"
            echo "  --mariadb-version VERSION   Set MariaDB version (system or 11.4)"
            echo "  --queue-driver DRIVER       Set queue driver (redis or database)"
            echo "  --skip-database             Skip MariaDB installation (use external database)"
            echo "  --skip-redis                Skip Redis installation (use external cache/sessions)"
            echo "  --help, -h                  Show this help message"
            echo ""

            echo "Examples:"
            echo "  $0                          # Interactive mode"
            echo "  $0 --non-interactive        # Non-interactive with database and Redis"
            echo "  $0 --non-interactive --skip-database --skip-redis  # Minimal installation"
            echo "  $0 --non-interactive --php-version 8.4 --queue-driver database"
            echo "  $0 --non-interactive --mariadb-version 11.4"
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

# Function to wait for apt locks to be released
wait_for_apt_lock() {
    local timeout=300
    local elapsed=0
    
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/dpkg/lock >/dev/null 2>&1 || fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
        if [ $elapsed -ge $timeout ]; then
            warning "Timeout waiting for apt lock, forcing cleanup..."
            sudo killall apt apt-get dpkg 2>/dev/null || true
            sleep 5

            # Remove lock files as last resort
            sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock 2>/dev/null || true
            break
        fi

        echo "Waiting for package manager lock... ($elapsed/$timeout seconds)"
        sleep 5
        elapsed=$((elapsed + 5))
    done
}

# Custom error handler with cleanup
cleanup_on_error() {
    local exit_code=$?
    local line_number=$1
    error "Installation failed at line $line_number with exit code $exit_code"
    
    # Attempt basic cleanup
    warning "Attempting to clean up partial installation..."
    
    # Kill any hanging package management processes
    sudo killall apt apt-get dpkg 2>/dev/null || true
    sleep 3
    
    # Try to fix broken packages
    sudo dpkg --configure -a 2>/dev/null || true
    
    # Clean up any package locks
    sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock 2>/dev/null || true
    
    # Stop any services that might be in inconsistent state
    local cleanup_services=("nginx" "php${PHP_VERSION}-fpm" "redis-server" "supervisor")
    
    # Add MariaDB to cleanup services only if it was being installed
    if [[ "${INSTALL_DATABASE:-true}" == "true" ]]; then
        cleanup_services+=("mariadb")
    fi
    
    for service in "${cleanup_services[@]}"; do
        if systemctl is-active --quiet $service 2>/dev/null; then
            sudo systemctl stop $service 2>/dev/null || true
        fi
    done
    
    info "Cleanup completed. Check the error above and rerun the script."
    exit $exit_code
}

export DEBIAN_FRONTEND=noninteractive

LOCK_FILE="/var/lock/lemp_install.lock"
if [[ ! -d /var/lock ]]; then
    LOCK_FILE="/tmp/lemp_install.lock"
fi

# Cleanup lock file on exit
cleanup_lock() {
    rm -f "$LOCK_FILE" 2>/dev/null || true
}

cleanup_on_error_with_lock() {
    local line_number=$1
    cleanup_on_error "$line_number"
    cleanup_lock
}

trap 'cleanup_on_error_with_lock $LINENO' ERR
trap cleanup_lock EXIT

# Create lock to prevent concurrent installations — uses flock when available
create_lock() {
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCK_FILE" 2>/dev/null || {
            error "Cannot open lock file $LOCK_FILE"
            exit 1
        }
        if ! flock -n 9 2>/dev/null; then
            error "Another instance of this script is already running (lock: $LOCK_FILE)."
            info "If you're sure no other instance is running, remove the lock file:"
            info "sudo rm -f $LOCK_FILE"
            exit 1
        fi
        echo $$ >&9 2>/dev/null || true
        return 0
    fi

    # Fallback: atomic symlink-style check (no flock)
    if [[ -f "$LOCK_FILE" ]]; then
        error "Another instance of this script is already running or was terminated unexpectedly."
        info "If you're sure no other instance is running, remove the lock file:"
        info "sudo rm -f $LOCK_FILE"
        exit 1
    fi
    if ! ( set -C; echo $$ > "$LOCK_FILE" ) 2>/dev/null; then
        error "Failed to acquire lock $LOCK_FILE — another instance may be running."
        exit 1
    fi
}

# =================================================================================
# GLOBAL VARIABLES
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
MARIADB_VERSION="11.4"
REDIS_VERSION="7.4"

NODE_JS_VERSION="22.x"
SUPERVISOR_PROCESS_NUM=3
QUEUE_DRIVER="database"
SSL_EMAIL=""

# Configuration mode
INTERACTIVE_MODE=true
INSTALL_SSL=false
SSL_INSTALL_SUCCESS=false
INSTALL_DATABASE=true
INSTALL_REDIS=true

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
NC='\033[0m'

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
# Charset intentionally excludes shell/SQL/Redis-unsafe chars: ' " ` $ \ / & ; | < > ! ( ) { }
generate_password() {
    local length=${1:-16}
    local safe_chars='A-Za-z0-9#%^*+=-_'

    if [[ -r /dev/urandom ]] && command -v tr >/dev/null 2>&1; then
        local pw
        pw=$(tr -dc "$safe_chars" < /dev/urandom 2>/dev/null | head -c "$length" 2>/dev/null || true)
        if [[ ${#pw} -eq "$length" ]]; then
            echo "$pw"
            return 0
        fi
    fi

    if command -v openssl >/dev/null 2>&1; then
        local pw2
        pw2=$(openssl rand -base64 $((length * 3)) 2>/dev/null | tr -dc "$safe_chars" | head -c "$length" 2>/dev/null || true)
        if [[ ${#pw2} -eq "$length" ]]; then
            echo "$pw2"
            return 0
        fi
    fi

    error "Failed to generate secure password (no /dev/urandom or openssl)"
    return 1
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
    echo -e "${GREEN}S-LEMP INSTALLATION AUTOMATION BY SULAIMAN MISRI${NC}"
    echo -e "${YELLOW}** Deploy a production-ready Laravel environment effortlessly. ${NC}"
    echo -e "${YELLOW}** All optimized for your Laravel application. ${NC}"
    echo ""
}

# Function to display configuration wizard header
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
        MARIADB_VERSION=${MARIADB_VERSION:-11.4}
        REDIS_VERSION=${REDIS_VERSION:-7.4}
        QUEUE_DRIVER=${QUEUE_DRIVER:-database}
        SUPERVISOR_PROCESS_NUM=${SUPERVISOR_PROCESS_NUM:-3}
        INSTALL_SSL=false
        INSTALL_DATABASE=${INSTALL_DATABASE:-true}
        INSTALL_REDIS=${INSTALL_REDIS:-true}  # Default to true in non-interactive mode
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
    
    # Database Installation Option
    echo ""
    info "Database Installation Option:"
    echo "  1) Install MariaDB"
    echo "  2) Skip MariaDB installation (If you want to use external database server)"
    echo ""
    
    while true; do
        read -p "Choose database option [1]: " db_install_option
        db_install_option=${db_install_option:-1}
        
        case $db_install_option in
            1)
                INSTALL_DATABASE=true
                log "✓ MariaDB will be installed locally"
                break
                ;;
            2)
                INSTALL_DATABASE=false
                log "✓ Database installation will be skipped"
                info "You will need to configure your Laravel app to connect to an external database"
                break
                ;;
            *)
                error "Invalid option. Please choose 1 or 2."
                ;;
        esac
    done
    echo ""
    
    # MariaDB version selection (only if installing locally)
    if [[ "$INSTALL_DATABASE" == "true" ]]; then
        echo ""
        info "MariaDB Version Selection:"
        echo "  1) System default (Ubuntu archive: 10.6 on 22.04, 10.11 on 24.04)"
        echo "  2) MariaDB 11.4 LTS (via MariaDB Foundation repo, recommended)"
        echo ""
        while true; do
            read -p "Choose MariaDB version [2]: " mariadb_version_option
            mariadb_version_option=${mariadb_version_option:-2}
            case $mariadb_version_option in
                1) MARIADB_VERSION="system"; log "✓ Selected MariaDB: system default"; break ;;
                2) MARIADB_VERSION="11.4"; log "✓ Selected MariaDB 11.4 LTS"; break ;;
                *) error "Please choose option 1 or 2" ;;
            esac
        done
        echo ""
    fi

    # Only show database name/user/password prompts if installing locally
    if [[ "$INSTALL_DATABASE" == "true" ]]; then
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
    
    fi
    
    echo ""
    echo "============================================="
    echo -e "${GREEN}REDIS CONFIGURATION${NC}"
    echo "============================================="
    
    # Redis Installation Option
    echo ""
    info "Redis Installation Option:"
    echo "  1) Install Redis"
    echo "  2) Skip Redis installation"
    echo ""
    
    while true; do
        read -p "Choose Redis option [1]: " redis_install_option
        redis_install_option=${redis_install_option:-1}
        
        case $redis_install_option in
            1)
                INSTALL_REDIS=true
                log "✓ Redis will be installed"
                break
                ;;
            2)
                INSTALL_REDIS=false
                log "✓ Redis installation will be skipped"
                info "You can configure external caching in your Laravel app if needed"
                break
                ;;
            *)
                error "Invalid option. Please choose 1 or 2."
                ;;
        esac
    done
    echo ""
    
    # Redis version selection (only if installing locally)
    if [[ "$INSTALL_REDIS" == "true" ]]; then
        echo ""
        info "Redis Version Selection:"
        echo "  1) System default (Ubuntu archive: 6.0/7.0)"
        echo "  2) Redis 7.4 (via Redis.io repo, recommended)"
        echo "  3) Redis 8.0 (via Redis.io repo, latest)"
        echo ""
        while true; do
            read -p "Choose Redis version [2]: " redis_version_option
            redis_version_option=${redis_version_option:-2}
            case $redis_version_option in
                1) REDIS_VERSION="system"; log "✓ Selected Redis: system default"; break ;;
                2) REDIS_VERSION="7.4"; log "✓ Selected Redis 7.4"; break ;;
                3) REDIS_VERSION="8.0"; log "✓ Selected Redis 8.0"; break ;;
                *) error "Please choose option 1, 2 or 3" ;;
            esac
        done
        echo ""
    fi

    # Only show Redis password prompt if installing locally
    if [[ "$INSTALL_REDIS" == "true" ]]; then
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
    
    fi  # End of Redis configuration for local installation
    
    echo ""
    echo "============================================="
    echo -e "${GREEN}ADVANCED CONFIGURATION${NC}"
    echo "============================================="
    
    # PHP Version Selection
    echo ""
    info "PHP Version Selection:"
    echo "  1) PHP 8.3 LTS (Recommended for production)"
    echo "  2) PHP 8.4 (Stable)"
    echo "  3) PHP 8.5 (Latest stable, recommended)"
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
            3)
                PHP_VERSION="8.5"
                log "✓ Selected PHP 8.5"
                break
                ;;
            *)
                error "Please choose option 1, 2 or 3"
                ;;
        esac
    done
    echo ""
    
    # Queue Driver Selection
    echo ""
    info "Queue Driver Selection:"
    echo "  1) Database (Simple setup, uses database for queues)"
    
    if [[ "$INSTALL_REDIS" == "true" ]]; then
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
    else
        echo ""
        info "Redis is not being installed, auto selecting Database queue driver"
        QUEUE_DRIVER="database"
        log "✓ Selected Database queue driver"
    fi
    echo ""
    
    # Node.js Version Selection
    echo ""
    info "Node.js Version Selection:"
    echo "  1) Node.js 22.x LTS (Recommended, mature)"
    echo "  2) Node.js 24.x LTS (Latest)"
    echo ""
    while true; do
        read -p "Choose Node.js version [1]: " node_version_option
        node_version_option=${node_version_option:-1}
        case $node_version_option in
            1) NODE_JS_VERSION="22.x"; log "✓ Selected Node.js 22.x LTS"; break ;;
            2) NODE_JS_VERSION="24.x"; log "✓ Selected Node.js 24.x LTS"; break ;;
            *) error "Please choose option 1 or 2" ;;
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
    if [[ "$INSTALL_DATABASE" == "true" ]]; then
        echo -e "${YELLOW}🗄️  Database Configuration:${NC}"
        if [[ "$MARIADB_VERSION" == "11.4" ]]; then
            echo -e "   ${WHITE}├─${NC} Install MariaDB: ${GREEN}Yes — 11.4 LTS (MariaDB repo)${NC}"
        else
            echo -e "   ${WHITE}├─${NC} Install MariaDB: ${GREEN}Yes — system default (Ubuntu archive)${NC}"
        fi
        echo -e "   ${WHITE}├─${NC} Database Name: ${GREEN}$DB_NAME${NC}"
        echo -e "   ${WHITE}├─${NC} Database User: ${GREEN}$DB_USER${NC}"
        echo -e "   ${WHITE}├─${NC} Database Password: ${GREEN}[HIDDEN]${NC}"
        echo -e "   ${WHITE}└─${NC} Root Password: ${GREEN}[HIDDEN]${NC}"
    else
        echo -e "${YELLOW}🗄️  Database Configuration:${NC}"
        echo -e "   ${WHITE}└─${NC} Install MariaDB: ${YELLOW}No (Use external database)${NC}"
    fi
    echo ""
    if [[ "$INSTALL_REDIS" == "true" ]]; then
        echo -e "${YELLOW}🔴 Redis Configuration:${NC}"
        if [[ "$REDIS_VERSION" == "system" ]]; then
            echo -e "   ${WHITE}├─${NC} Install Redis: ${GREEN}Yes — system default (Ubuntu archive)${NC}"
        else
            echo -e "   ${WHITE}├─${NC} Install Redis: ${GREEN}Yes — ${REDIS_VERSION} (Redis.io repo)${NC}"
        fi
        echo -e "   ${WHITE}└─${NC} Redis Password: ${GREEN}[HIDDEN]${NC}"
    else
        echo -e "${YELLOW}🔴 Redis Configuration:${NC}"
        echo -e "   ${WHITE}└─${NC} Install Redis: ${YELLOW}No (Use external cache)${NC}"
    fi
    echo ""
    echo -e "${YELLOW}Services Configuration:${NC}"
    echo -e "   ${WHITE}├─${NC} Queue Workers: ${GREEN}$SUPERVISOR_PROCESS_NUM${NC}"
    echo -e "   ${WHITE}├─${NC} Queue Driver: ${GREEN}$QUEUE_DRIVER${NC}"
    echo -e "   ${WHITE}├─${NC} PHP Version: ${GREEN}$PHP_VERSION${NC}"
    echo -e "   ${WHITE}├─${NC} Redis Version: ${GREEN}$REDIS_VERSION${NC}"
    echo -e "   ${WHITE}├─${NC} MariaDB Version: ${GREEN}$MARIADB_VERSION${NC}"
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

# Function to save configuration to a file — secrets stored 600, no world-readable /tmp copy
save_configuration_file() {
    local config_file="/root/laravel_lemp_config.txt"

    local tmp_file
    tmp_file=$(mktemp /root/.lemp_config.XXXXXX 2>/dev/null || mktemp /tmp/.lemp_config.XXXXXX)

    cat > "$tmp_file" 2>/dev/null <<EOF
# S-LEMP Stack Configuration
# Generated on: $(date -Iseconds 2>/dev/null || date)
# Permissions: 600 — contains secrets, do not share or commit

PROJECT_NAME=$PROJECT_NAME
DOMAIN_NAME=$DOMAIN_NAME
SSL_EMAIL=$SSL_EMAIL
PROJECT_ROOT=$PROJECT_ROOT

INSTALL_DATABASE=$INSTALL_DATABASE
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
DB_ROOT_PASSWORD=$DB_ROOT_PASSWORD

INSTALL_REDIS=$INSTALL_REDIS
REDIS_VERSION=$REDIS_VERSION
REDIS_PASSWORD=$REDIS_PASSWORD
SUPERVISOR_PROCESS_NUM=$SUPERVISOR_PROCESS_NUM
QUEUE_DRIVER=$QUEUE_DRIVER
PHP_VERSION=$PHP_VERSION
MARIADB_VERSION=$MARIADB_VERSION
NODE_JS_VERSION=$NODE_JS_VERSION
INSTALL_SSL=$INSTALL_SSL

# Access URLs after installation:
# HTTP: http://$DOMAIN_NAME
# HTTPS: https://$DOMAIN_NAME (after SSL setup)

# Database Connection:$(if [[ "$INSTALL_DATABASE" == "true" ]]; then echo "
# Host: localhost
# Database: $DB_NAME
# Username: $DB_USER
# Password: [see above]"; else echo "
# Database installation was skipped - configure external database in your Laravel .env file"; fi)

# Important Commands:
# Fix Laravel permissions: fix-laravel-permissions $PROJECT_ROOT/$PROJECT_NAME
# Supervisor status: sudo supervisorctl status
# SSL setup: sudo certbot --nginx -d $DOMAIN_NAME --email $SSL_EMAIL --agree-tos
EOF

    chmod 600 "$tmp_file" 2>/dev/null || true

    if sudo install -m 600 "$tmp_file" "$config_file" 2>/dev/null || install -m 600 "$tmp_file" "$config_file" 2>/dev/null || cp "$tmp_file" "$config_file" 2>/dev/null; then
        sudo chmod 600 "$config_file" 2>/dev/null || chmod 600 "$config_file" 2>/dev/null || true
        sudo chown root:root "$config_file" 2>/dev/null || true
        rm -f "$tmp_file" 2>/dev/null || true
        # Remove any legacy world-readable copy if it exists
        sudo rm -f /tmp/laravel_lemp_config.txt 2>/dev/null || rm -f /tmp/laravel_lemp_config.txt 2>/dev/null || true
        info "Configuration saved to: $config_file (600)"
        echo ""
    else
        warning "Failed to save configuration to $config_file"
        rm -f "$tmp_file" 2>/dev/null || true
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
# Load service modules
# =========================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null || dirname "$0")"
SERVICES_LIB="${SCRIPT_DIR}/lib/services.sh"
if [[ -f "${SERVICES_LIB}" ]]; then
    # shellcheck source=lib/services.sh
    source "${SERVICES_LIB}"
else
    echo "[ERROR] Missing services library: ${SERVICES_LIB}" >&2
    echo "        For piped install this is not yet supported — clone the repo and run ./install.sh" >&2
    exit 1
fi

# =========================================================================
# System verification + completion helpers
# =========================================================================
verify_installation() {
    echo " "
    echo "============================================="
    echo -e "${GREEN}Performing comprehensive system verification...${NC}"
    echo "============================================="
    
    local errors=0
    
    # Check services
    local services=("nginx" "php${PHP_VERSION}-fpm" "supervisor")
    
    # Add Redis to services list only if it was installed
    if [[ "$INSTALL_REDIS" == "true" ]]; then
        services+=("redis-server")
    fi
    
    # Add MariaDB to services list only if it was installed
    if [[ "$INSTALL_DATABASE" == "true" ]]; then
        services+=("mariadb")
    fi
    
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service"; then
            log "✓ Service $service is running"
        else
            error "✗ Service $service is not running"
            ((errors++))
        fi
    done
    
    # Check ports
    local ports=("80:nginx" "22:ssh")
    
    # Add MySQL port only if database was installed locally
    if [[ "$INSTALL_DATABASE" == "true" ]]; then
        ports+=("3306:mysql")
    fi
    
    for port_service in "${ports[@]}"; do
        local port="${port_service%:*}"
        local service="${port_service#*:}"
        if ss -ln | grep -q ":$port "; then
            log "✓ Port $port ($service) is listening"
        else
            if [[ "$service" == "mysql" ]] && [[ "$INSTALL_DATABASE" == "false" ]]; then
                log "✓ Port $port ($service) not listening (external database expected)"
            else
                warning "⚠ Port $port ($service) is not listening"
            fi
        fi
    done
    
    # Check PHP
    if php${PHP_VERSION} -v &>/dev/null; then
        log "✓ PHP ${PHP_VERSION} is working"
        
        # Check critical PHP extensions with better error reporting
        local extensions=("mbstring" "xml" "curl" "zip" "gd")
        
        # Add Redis extension to check list only if Redis was installed
        if [[ "$INSTALL_REDIS" == "true" ]]; then
            extensions+=("redis")
        fi
        
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
    
    # Check database connectivity (only if MariaDB was installed locally)
    if [[ "$INSTALL_DATABASE" == "true" ]]; then
        if mysql -u "${DB_USER}" -p"${DB_PASSWORD}" -e "USE ${DB_NAME}; SELECT 1;" &>/dev/null; then
            log "✓ Database connectivity works"
        else
            warning "⚠ Database connectivity test failed"
        fi
    else
        log "✓ Database installation skipped - external database configuration required"
    fi
    
    # Check Redis connectivity (only if Redis was installed locally)
    if [[ "$INSTALL_REDIS" == "true" ]]; then
        if timeout 5 env REDISCLI_AUTH="${REDIS_PASSWORD}" redis-cli ping 2>/dev/null | grep -q "PONG"; then
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
    else
        log "✓ Redis installation skipped - no Redis connectivity check needed"
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

    # Pre-installation system check and cleanup
    echo ""
    echo "============================================="
    echo -e "${GREEN}🔧 PRE-INSTALLATION SYSTEM CHECK${NC}"
    echo "============================================="
    echo ""
    
    # Kill any hanging processes first
    info "Checking for hanging package management processes..."
    sudo killall apt apt-get dpkg 2>/dev/null || true
    sleep 3
    
    # Fix any broken dpkg state
    info "Checking dpkg state and fixing any issues..."
    if ! sudo dpkg --configure -a; then
        warning "Found dpkg issues, attempting to fix..."
        wait_for_apt_lock
        sudo apt-get -f install -y || warning "Some issues may persist"
    fi
    
    # Wait for any locks and clean up
    wait_for_apt_lock
    
    log "✓ System check completed successfully"

    # Show S-LEMP banner for all modes
    show_slemp_banner

    check_root
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
        echo "  - MariaDB database server (optional)"
        echo "  - Redis server (optional)"
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
    
    # Conditionally install MariaDB
    if [[ "$INSTALL_DATABASE" == "true" ]]; then
        install_mariadb
    else
        info "Skipping MariaDB installation as requested"
        info "Remember to configure your Laravel app to connect to an external database"
    fi
    
    install_composer
    install_nodejs
    
    if [[ "$INSTALL_REDIS" == "true" ]]; then
        install_redis
    else
        info "Skipping Redis installation as requested"
        info "Redis will not be available for caching or sessions"
    fi
    
    install_supervisor
    create_laravel_queue_config
    create_laravel_permission_helper
    setup_laravel_scheduler
    configure_firewall
    
    # Install Certbot once (non-critical - continue if it fails)
    if install_certbot; then
        log "✓ Certbot installation completed successfully"
        info "SSL certificate can be installed manually after server setup is complete"
    else
        warning "Certbot installation failed, but continuing with LEMP stack setup"
        info "Install manually: sudo apt update && sudo apt install -y certbot python3-certbot-nginx"
    fi

    echo " "
    echo "============================================="
    echo "All components installed successfully!"
    echo "============================================="
    info "Restarting services to ensure all components start properly..."

    # Temporarily disable strict error handling for service restarts (preserve pipefail/errexit flags)
    set +Eeuo pipefail

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
    set -Eeuo pipefail
    
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

# Run main installation
main "$@"
