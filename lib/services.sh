#!/bin/bash
# S-LEMP services library
# Sourced by install.sh — do not execute directly.
# Shares globals (PROJECT_NAME, PHP_VERSION, etc.) and helpers (log, info, wait_for_apt_lock) from parent.

update_and_install_core_system() {
    echo ""
    echo "============================================="
    echo -e "${GREEN}🔄 UPDATING CORE SYSTEM${NC}"
    echo "============================================="
    echo ""
    
    # Initial cleanup and wait for locks
    sudo killall apt apt-get dpkg 2>/dev/null || true
    sleep 3
    
    # Wait for any existing locks to be released
    wait_for_apt_lock
    
    # Fix any broken packages first
    info "Fixing any broken packages..."
    sudo dpkg --configure -a || warning "Some packages may still have issues"
    wait_for_apt_lock
    sudo apt-get -f install -y || warning "Failed to fix some dependencies"
    
    # Update package lists with retries
    local retries=3
    for ((i=1; i<=retries; i++)); do
        wait_for_apt_lock
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
    wait_for_apt_lock
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
    
    wait_for_apt_lock
    sudo apt install -y curl wget git unzip software-properties-common ca-certificates gnupg lsb-release bc
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
    
    wait_for_apt_lock
    sudo apt install -y nginx
    
    echo ""
    echo "============================================="
    echo -e "${GREEN}CONFIGURING NGINX${NC}"
    echo "============================================="
    echo ""
    
    sudo systemctl start nginx
    sudo systemctl enable nginx

    # Harden /etc/nginx/nginx.conf
    info "Hardening Nginx global config..."
    if [[ -f /etc/nginx/nginx.conf ]]; then
        sudo cp /etc/nginx/nginx.conf "/etc/nginx/nginx.conf.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

        if ! grep -q "server_tokens off" /etc/nginx/nginx.conf 2>/dev/null; then
            sudo sed -i 's/^\s*#*\s*server_tokens.*/server_tokens off;/' /etc/nginx/nginx.conf 2>/dev/null || true
            if ! grep -q "server_tokens off" /etc/nginx/nginx.conf 2>/dev/null; then
                sudo sed -i '/http {/a \    server_tokens off;' /etc/nginx/nginx.conf 2>/dev/null || true
            fi
            log "✓ server_tokens off added to nginx.conf"
        fi

        if ! grep -q "limit_req_zone" /etc/nginx/nginx.conf 2>/dev/null; then
            sudo tee /etc/nginx/conf.d/rate-limit.conf >/dev/null <<'RLEOF'
# S-LEMP — rate limiting (included via conf.d/*.conf)
limit_req_zone $binary_remote_addr zone=slemp_login:10m rate=5r/s;
limit_req_zone $binary_remote_addr zone=slemp_global:10m rate=20r/s;
limit_req_status 429;
RLEOF
            log "✓ Rate-limit zones written to /etc/nginx/conf.d/rate-limit.conf"
        fi
    else
        warning "nginx.conf not found — skipping global hardening"
    fi

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

    # Security headers (production-safe: no noindex, no unsafe-inline)
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Content-Security-Policy "default-src 'self' https: data: blob:" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
    add_header X-Permitted-Cross-Domain-Policies "none" always;
    add_header Cross-Origin-Opener-Policy "same-origin" always;
    # HSTS is safe to send on HTTP; browsers only honor on HTTPS. Remove if behind TLS-terminating proxy that already sets it.
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

    # Laravel-specific optimizations
    client_max_body_size 64M;
    fastcgi_read_timeout 300;
    client_body_timeout 20;
    client_header_timeout 20;

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_comp_level 5;
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_proxied expired no-cache no-store private auth;
    gzip_types text/plain text/css text/xml text/javascript application/javascript application/json application/xml application/xml+rss image/svg+xml font/woff font/woff2;

    # Rate limiting (uses zones from /etc/nginx/conf.d/rate-limit.conf)
    limit_req zone=slemp_global burst=40 nodelay;

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

    # Deny dotfiles and sensitive project files
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    location ~* /(\\.env|\\.git|composer\\.(json|lock)|package-lock\\.json|yarn\\.lock)$ {
        deny all;
        access_log off;
        log_not_found off;
    }

    # Block direct access to storage/app and bootstrap/cache outside public/
    location ~* ^/(storage|bootstrap/cache)/ {
        deny all;
    }

    # Laravel public/storage symlink
    location ^~ /storage/ {
        alias ${PROJECT_ROOT}/${PROJECT_NAME}/storage/app/public/;
        try_files \$uri \$uri/ =404;
        expires 1y;
        access_log off;
    }
}
EOF
    
    # Enable the site
    sudo ln -sf /etc/nginx/sites-available/${PROJECT_NAME} /etc/nginx/sites-enabled/

    # Remove default site if it is the stock symlink
    if [[ -L /etc/nginx/sites-enabled/default ]] && [[ "$(readlink -f /etc/nginx/sites-enabled/default 2>/dev/null)" == "/etc/nginx/sites-available/default" ]]; then
        sudo rm -f /etc/nginx/sites-enabled/default
        log "✓ Removed stock default site symlink"
    elif [[ -f /etc/nginx/sites-enabled/default ]] && ! [[ -L /etc/nginx/sites-enabled/default ]]; then
        warning "sites-enabled/default is a regular file (custom?) — leaving it"
    fi
    
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
    
    # OPcache configuration optimized for Laravel (production)
    # validate_timestamps=0 is optimal for production — code changes require
    # `php artisan opcache:clear`, `cachetool opcache:reset`, or `systemctl reload php*-fpm`.
    # For development set opcache.validate_timestamps=1 and opcache.revalidate_freq=2.
    local opcache_config="
; OPcache Configuration for Laravel — production defaults
; Enable OPcache
opcache.enable=1
opcache.enable_cli=1

; Memory settings
opcache.memory_consumption=256
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000

; Performance settings — production: no timestamp checks (fastest)
opcache.validate_timestamps=0
opcache.revalidate_freq=0
opcache.save_comments=1
opcache.enable_file_override=1

; JIT — tracing mode is the recommended default for PHP 8.3+
opcache.jit=tracing
opcache.jit_buffer_size=100M

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
    local critical_extensions=("mbstring" "xml" "curl" "zip" "gd" "mysql" "bcmath" "intl" "opcache")
    
    # Add Redis extension only if Redis was installed
    if [[ "$INSTALL_REDIS" == "true" ]]; then
        critical_extensions+=("redis")
    fi
    
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
                echo '  • JIT buffer: ' . ini_get('opcache.jit_buffer_size') . PHP_EOL;
                echo '  • JIT mode: ' . ini_get('opcache.jit') . PHP_EOL;
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
    echo -e "${GREEN}Setting up Ondrej PHP repository (signed-by keyring)...${NC}"
    echo "============================================="

    local ondrej_list="/etc/apt/sources.list.d/ondrej-php.list"
    local ondrej_keyring="/etc/apt/keyrings/ondrej-php.gpg"
    local ubuntu_codename
    ubuntu_codename=$(lsb_release -cs 2>/dev/null || grep '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "jammy")

    if [[ -f "$ondrej_list" ]] && grep -q "signed-by=${ondrej_keyring}" "$ondrej_list" 2>/dev/null && [[ -f "$ondrej_keyring" ]]; then
        log "✓ Ondrej PHP repository already configured (signed-by keyring)"
    elif [[ -f "$ondrej_list" ]] && grep -q "ondrej/php" "$ondrej_list" 2>/dev/null; then
        log "✓ Ondrej PHP repository already configured (legacy PPA)"
    else
        sudo install -m 0755 -d /etc/apt/keyrings 2>/dev/null || sudo mkdir -p /etc/apt/keyrings
        sudo install -m 0755 -d /etc/apt/sources.list.d 2>/dev/null || true

        local ondrej_setup_ok=false

        # Prefer manual signed-by keyring flow
        if curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xE5267A6C" 2>/dev/null | gpg --dearmor 2>/dev/null | sudo tee "$ondrej_keyring" >/dev/null 2>&1 && [[ -s "$ondrej_keyring" ]]; then
            echo "deb [signed-by=${ondrej_keyring}] https://ppa.launchpadcontent.net/ondrej/php/ubuntu ${ubuntu_codename} main" | sudo tee "$ondrej_list" >/dev/null
            wait_for_apt_lock
            if sudo apt update 2>&1 | tail -8; then
                log "✓ Ondrej PHP repository configured (signed-by keyring)"
                ondrej_setup_ok=true
            else
                warning "apt update after Ondrej keyring setup failed — trying PPA fallback..."
                sudo rm -f "$ondrej_list" "$ondrej_keyring" 2>/dev/null || true
            fi
        else
            warning "Ondrej keyring fetch failed — trying PPA fallback..."
            sudo rm -f "$ondrej_keyring" 2>/dev/null || true
        fi

        if [[ "$ondrej_setup_ok" == "false" ]]; then
            wait_for_apt_lock
            sudo apt install -y software-properties-common 2>/dev/null || true
            if sudo add-apt-repository ppa:ondrej/php -y 2>&1 | tail -8; then
                log "✓ Ondrej PHP repository configured (PPA fallback)"
            else
                warning "Failed to configure Ondrej PHP repository — will try Ubuntu archive PHP"
            fi
            wait_for_apt_lock
            sudo apt update 2>&1 | tail -5 || warning "apt update failed after Ondrej setup"
        fi
    fi

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
    )

    if [[ "$INSTALL_REDIS" == "true" ]]; then
        php_packages+=("php${PHP_VERSION}-redis")
    fi
    
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

; --- RAM-aware tuning: set pm values based on detected RAM ---
; (computed before writing this file; values injected below)
pm = dynamic
pm.max_children = 20
pm.start_servers = 3
pm.min_spare_servers = 2
pm.max_spare_servers = 6
pm.max_requests = 1000

; Resilience / observability
pm.status_path = /fpm-status
ping.path = /fpm-ping
ping.response = pong
request_terminate_timeout = 300
request_slowlog_timeout = 10s
slowlog = /var/log/php/${PROJECT_NAME}-slow.log
catch_workers_output = yes
clear_env = no
listen.backlog = 511
decorate_workers_output = no

php_admin_value[memory_limit] = 256M
php_admin_value[upload_max_filesize] = 64M
php_admin_value[post_max_size] = 64M
php_admin_value[max_execution_time] = 300
php_admin_value[max_input_vars] = 3000

php_admin_flag[display_errors] = off
php_admin_flag[log_errors] = on
php_admin_value[error_log] = /var/log/php/${PROJECT_NAME}-error.log

; Laravel optimizations — keep pool light; authoritative OPcache/JIT settings live in 10-opcache.ini
; Only pool-scoped overrides here; do not duplicate global OPcache directives.
php_admin_flag[expose_php] = off
php_admin_value[cgi.fix_pathinfo] = 0

php_admin_value[session.cookie_httponly] = 1
php_admin_value[session.cookie_secure] = 1
php_admin_value[session.use_strict_mode] = 1

; Additional performance settings
php_admin_value[realpath_cache_size] = 4096K
php_admin_value[realpath_cache_ttl] = 7200
EOF

    # --- Post-process: RAM-aware pm tuning (in-place, keep heredoc readable) ---
    {
        local _ram_gb
        _ram_gb=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}' 2>/dev/null || echo 2)
        [[ "$_ram_gb" -lt 1 ]] && _ram_gb=1
        local _max_children=$(( _ram_gb * 8 ))
        [[ "$_max_children" -lt 5 ]] && _max_children=5
        [[ "$_max_children" -gt 30 ]] && _max_children=30
        local _start_servers=$(( _max_children / 4 ))
        [[ "$_start_servers" -lt 2 ]] && _start_servers=2
        [[ "$_start_servers" -gt 5 ]] && _start_servers=5
        local _min_spare=$(( _max_children / 10 ))
        [[ "$_min_spare" -lt 1 ]] && _min_spare=1
        local _max_spare=$(( _max_children / 3 ))
        [[ "$_max_spare" -lt 3 ]] && _max_spare=3

        sudo sed -i "s/^pm.max_children = .*/pm.max_children = ${_max_children}/" "/etc/php/${PHP_VERSION}/fpm/pool.d/${PROJECT_NAME}.conf" 2>/dev/null || true
        sudo sed -i "s/^pm.start_servers = .*/pm.start_servers = ${_start_servers}/" "/etc/php/${PHP_VERSION}/fpm/pool.d/${PROJECT_NAME}.conf" 2>/dev/null || true
        sudo sed -i "s/^pm.min_spare_servers = .*/pm.min_spare_servers = ${_min_spare}/" "/etc/php/${PHP_VERSION}/fpm/pool.d/${PROJECT_NAME}.conf" 2>/dev/null || true
        sudo sed -i "s/^pm.max_spare_servers = .*/pm.max_spare_servers = ${_max_spare}/" "/etc/php/${PHP_VERSION}/fpm/pool.d/${PROJECT_NAME}.conf" 2>/dev/null || true
        log "✓ PHP-FPM pool tuned for ~${_ram_gb}G RAM (max_children=${_max_children}, start=${_start_servers})"
    }

    # Logrotate for PHP-FPM project logs
    sudo tee "/etc/logrotate.d/php-fpm-${PROJECT_NAME}" >/dev/null <<LREOF
/var/log/php/${PROJECT_NAME}-*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 www-data www-data
    postrotate
        systemctl reload php${PHP_VERSION}-fpm >/dev/null 2>&1 || true
    endscript
}
LREOF
    log "✓ Logrotate installed for PHP-FPM logs (/etc/logrotate.d/php-fpm-${PROJECT_NAME})"
    
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
    local final_check_extensions=("mbstring" "curl" "mysql")
    
    # Add Redis extension only if Redis was installed
    if [[ "$INSTALL_REDIS" == "true" ]]; then
        final_check_extensions+=("redis")
    fi
    
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
# Setup MariaDB 11.4 LTS repository (with fallback to Ubuntu archive)
# =========================================================================

setup_mariadb_repo() {
    if [[ "$MARIADB_VERSION" != "11.4" ]]; then
        info "Using system default MariaDB from Ubuntu archive (MARIADB_VERSION=$MARIADB_VERSION)"
        return 0
    fi

    if dpkg -l 2>/dev/null | grep -q "^ii.*mariadb-server"; then
        warning "MariaDB already installed — skipping repository setup to avoid conflicts"
        return 0
    fi

    if [[ -f /etc/apt/sources.list.d/mariadb.list ]] || ls /etc/apt/sources.list.d/*mariadb* >/dev/null 2>&1; then
        log "✓ MariaDB repository already configured"
        return 0
    fi

    info "Setting up MariaDB 11.4 LTS repository..."

    if ! command -v curl >/dev/null 2>&1; then
        warning "curl not available yet — attempting repo setup anyway"
    fi

    if curl -fsSL https://r.mariadb.com/downloads/mariadb_repo_setup 2>/dev/null | sudo bash -s -- --mariadb-server-version="11.4" 2>&1; then
        log "✓ MariaDB 11.4 LTS repository configured"
        wait_for_apt_lock
        return 0
    fi

    warning "MariaDB repo setup script failed — attempting manual keyring setup..."

    local ubuntu_codename
    ubuntu_codename=$(lsb_release -cs 2>/dev/null || grep '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "jammy")

    sudo install -m 0755 -d /etc/apt/keyrings 2>/dev/null || sudo mkdir -p /etc/apt/keyrings

    if curl -fsSL https://r.mariadb.com/downloads/mariadb_repo_setup 2>/dev/null | gpg --dearmor 2>/dev/null | sudo tee /etc/apt/keyrings/mariadb.gpg >/dev/null 2>&1; then
        log "✓ MariaDB GPG key installed"
    else
        warning "Failed to install MariaDB GPG key — falling back to Ubuntu archive"
        MARIADB_VERSION="system"
        return 0
    fi

    echo "deb [signed-by=/etc/apt/keyrings/mariadb.gpg] https://archive.mariadb.org/mariadb-11.4/repo/ubuntu ${ubuntu_codename} main" | sudo tee /etc/apt/sources.list.d/mariadb.list >/dev/null
    echo "deb [signed-by=/etc/apt/keyrings/mariadb.gpg] https://dlm.mariadb.com/repo/mariadb-server/11.4/repo/ubuntu ${ubuntu_codename} main" | sudo tee /etc/apt/sources.list.d/mariadb-enterprise.list >/dev/null 2>&1 || true

    wait_for_apt_lock
    if sudo apt update 2>&1 | tail -5; then
        log "✓ MariaDB 11.4 LTS repository configured (manual)"
    else
        warning "apt update after MariaDB repo setup failed — falling back to Ubuntu archive"
        sudo rm -f /etc/apt/sources.list.d/mariadb.list /etc/apt/sources.list.d/mariadb-enterprise.list 2>/dev/null || true
        MARIADB_VERSION="system"
    fi
}


configure_mariadb_tuning() {
    local tuning_file="/etc/mysql/mariadb.conf.d/60-laravel.cnf"

    if [[ -f "$tuning_file" ]]; then
        log "✓ MariaDB tuning file already exists: $tuning_file"
        return 0
    fi

    info "Writing MariaDB Laravel tuning: $tuning_file"

    local total_ram_gb
    total_ram_gb=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}' 2>/dev/null || echo 2)
    [[ "$total_ram_gb" -lt 1 ]] && total_ram_gb=1

    local innodb_buffer_pool_mb=$(( total_ram_gb * 1024 / 2 ))
    [[ "$innodb_buffer_pool_mb" -lt 128 ]] && innodb_buffer_pool_mb=128
    [[ "$innodb_buffer_pool_mb" -gt 4096 ]] && innodb_buffer_pool_mb=4096

    sudo tee "$tuning_file" >/dev/null <<EOF
# S-LEMP — Laravel-optimized MariaDB tuning (generated $(date -Iseconds))
# Adjust innodb_buffer_pool_size to ~50% RAM (capped 128M–4G for portability).

[mysqld]
character-set-server  = utf8mb4
collation-server      = utf8mb4_uca1400_ai_ci
bind-address          = 127.0.0.1

innodb_buffer_pool_size = ${innodb_buffer_pool_mb}M
innodb_log_file_size    = 96M
innodb_flush_log_at_trx_commit = 1
innodb_file_per_table   = 1

max_connections         = 151
thread_cache_size       = 16

slow_query_log          = 1
slow_query_log_file     = /var/log/mysql/mariadb-slow.log
long_query_time         = 2

# Keep default for compatibility; override per-app if needed
# sql_mode handled by MariaDB defaults (STRICT_TRANS_TABLES)

[mysql]
default-character-set = utf8mb4

[client]
default-character-set = utf8mb4
EOF

    log "✓ MariaDB tuning written (innodb_buffer_pool_size=${innodb_buffer_pool_mb}M for ~${total_ram_gb}G RAM)"
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

    setup_mariadb_repo

    wait_for_apt_lock
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
    # Use 11.4 default collation when available; falls back gracefully on older servers
    local db_collation="utf8mb4_uca1400_ai_ci"
    if [[ "$MARIADB_VERSION" == "system" ]]; then
        db_collation="utf8mb4_unicode_ci"
    fi

    local mysql_root_cmd=(sudo mysql -u root -p"${DB_ROOT_PASSWORD}")

    if sudo mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE ${db_collation};" 2>/dev/null || \
       "${mysql_root_cmd[@]}" -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE ${db_collation};" 2>/dev/null; then
        log "✓ Database '${DB_NAME}' created (${db_collation})"
    else
        error "Failed to create database"
        return 1
    fi

    # Least-privilege user on localhost only (use external DB if '%' is needed)
    local db_host="localhost"
    # Escape single quotes in password for SQL string literal
    local esc_db_password=${DB_PASSWORD//\'/\'\'}

    if sudo mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'${db_host}' IDENTIFIED BY '${esc_db_password}';" 2>/dev/null || \
       "${mysql_root_cmd[@]}" -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'${db_host}' IDENTIFIED BY '${esc_db_password}';" 2>/dev/null; then
        log "✓ Database user '${DB_USER}'@'${db_host}' created"
    else
        warning "Database user might already exist"
    fi

    # Least-privilege grants (no GRANT OPTION, no ALL PRIVILEGES)
    local laravel_grants="SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER, REFERENCES, CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE"

    if sudo mysql -e "GRANT ${laravel_grants} ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${db_host}';" 2>/dev/null || \
       "${mysql_root_cmd[@]}" -e "GRANT ${laravel_grants} ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${db_host}';" 2>/dev/null; then
        log "✓ Least-privilege grants applied to '${DB_USER}'@'${db_host}'"
    else
        error "Failed to grant privileges"
        return 1
    fi

    sudo mysql -e "FLUSH PRIVILEGES;" 2>/dev/null || "${mysql_root_cmd[@]}" -e "FLUSH PRIVILEGES;" 2>/dev/null || {
        error "Failed to flush privileges"
        return 1
    }

    configure_mariadb_tuning
    if sudo systemctl restart mariadb 2>/dev/null; then
        log "✓ MariaDB restarted with Laravel tuning"
        sleep 2
    else
        warning "MariaDB tuning written but restart failed — will apply on next restart"
    fi

    # Test database connection
    if mysql -u "${DB_USER}" -p"${DB_PASSWORD}" -e "USE \`${DB_NAME}\`; SELECT 1;" &>/dev/null; then
        log "✓ Database connection test successful"
    else
        warning "Database connection test failed - check credentials"
    fi
}

# =========================================================================
# Install Node.js — modern keyring flow (no curl|bash)
# =========================================================================

install_nodejs() {
    echo " "
    echo "============================================="
    echo -e "${GREEN}Installing Node.js...${NC}"
    echo "============================================="

    local nodesource_list="/etc/apt/sources.list.d/nodesource.list"
    local nodesource_keyring="/etc/apt/keyrings/nodesource.gpg"
    local expected_version="$NODE_JS_VERSION"
    local needs_setup=true

    if [[ -f "$nodesource_list" ]]; then
        if grep -q "nodesource.*node_${expected_version}" "$nodesource_list" 2>/dev/null && [[ -f "$nodesource_keyring" ]]; then
            needs_setup=false
            log "✓ NodeSource repository already configured for ${expected_version}"
        else
            info "NodeSource list exists but version mismatch — will reconfigure for ${expected_version}"
        fi
    fi

    if [[ "$needs_setup" == "true" ]]; then
        info "Setting up NodeSource repository for Node.js ${expected_version} (signed-by keyring)..."

        sudo install -m 0755 -d /etc/apt/keyrings 2>/dev/null || sudo mkdir -p /etc/apt/keyrings
        sudo install -m 0755 -d /etc/apt/sources.list.d 2>/dev/null || true

        # Try modern keyring flow first
        if curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key 2>/dev/null | sudo gpg --dearmor -o "$nodesource_keyring" 2>/dev/null; then
            echo "deb [signed-by=${nodesource_keyring}] https://deb.nodesource.com/node_${expected_version} nodistro main" | sudo tee "$nodesource_list" >/dev/null
            wait_for_apt_lock
            if sudo apt update 2>&1 | tail -5; then
                log "✓ NodeSource repository configured for ${expected_version}"
            else
                warning "apt update after NodeSource setup failed — attempting legacy setup fallback..."
                if curl -fsSL "https://deb.nodesource.com/setup_${expected_version}" 2>/dev/null | sudo bash - 2>&1 | tail -10; then
                    log "✓ NodeSource repository configured via legacy setup_${expected_version}"
                else
                    error "Failed to configure NodeSource repository for ${expected_version}"
                    return 1
                fi
            fi
        else
            warning "Modern keyring setup failed — falling back to legacy setup_${expected_version}..."
            if curl -fsSL "https://deb.nodesource.com/setup_${expected_version}" 2>/dev/null | sudo bash - 2>&1 | tail -10; then
                log "✓ NodeSource repository configured via legacy setup_${expected_version}"
            else
                error "Failed to add NodeSource repository for ${expected_version}"
                return 1
            fi
        fi
    fi

    wait_for_apt_lock
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

        local node_major_version
        node_major_version=$(echo "$NODE_VERSION" | sed 's/v//' | cut -d. -f1)
        local expected_major
        expected_major=$(echo "$expected_version" | cut -d. -f1 | tr -d 'x')

        if [[ "$node_major_version" == "$expected_major" ]]; then
            log "✓ Node.js major version matches selected ${expected_version} (v${node_major_version})"
        elif [[ "$node_major_version" -ge "18" ]]; then
            warning "Node.js v${node_major_version} installed but expected ${expected_version} — check ${nodesource_list}"
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
        local current_version
        current_version=$(composer --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -n1 || echo "unknown")
        warning "Composer already installed (version: $current_version)"
        info "Updating to latest version..."
        if ! COMPOSER_ALLOW_SUPERUSER=1 composer self-update 2>&1 | tail -5; then
            warning "Failed to update Composer (try: COMPOSER_ALLOW_SUPERUSER=1 composer self-update)"
        fi
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
    
    # Download and verify Composer installer — fail-closed on signature mismatch
    info "Downloading Composer installer..."
    local expected_signature
    expected_signature="$(curl -fsSL --retry 3 https://composer.github.io/installer.sig 2>/dev/null || true)"
    if [[ -z "$expected_signature" ]]; then
        error "Failed to fetch Composer expected signature (https://composer.github.io/installer.sig)"
        return 1
    fi

    local installer_path="/tmp/composer-setup.php"
    if ! curl -fsSL --retry 3 https://getcomposer.org/installer -o "$installer_path" 2>/dev/null; then
        error "Failed to download Composer installer"
        return 1
    fi
    log "✓ Composer installer downloaded"

    local actual_signature
    actual_signature="$(php -r "echo hash_file('sha384', '$installer_path');")"
    if [[ "$expected_signature" == "$actual_signature" ]]; then
        log "✓ Composer installer signature verified"
    else
        error "Composer installer signature mismatch — aborting (expected ${expected_signature:0:16}…, got ${actual_signature:0:16}…)"
        rm -f "$installer_path"
        return 1
    fi

    # Install directly to final location — avoids world-writable /tmp TOCTOU
    info "Installing Composer using PHP ${PHP_VERSION}..."
    if php${PHP_VERSION} "$installer_path" --install-dir=/usr/local/bin --filename=composer; then
        sudo chmod +x /usr/local/bin/composer 2>/dev/null || true
        rm -f "$installer_path"
        log "✓ Composer installed successfully to /usr/local/bin/composer"
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


# =========================================================================
# Setup Redis repository (Redis.io) — with fallback to Ubuntu archive
# =========================================================================

setup_redis_repo() {
    if [[ "$REDIS_VERSION" == "system" ]]; then
        info "Using system default Redis from Ubuntu archive (REDIS_VERSION=system)"
        return 0
    fi

    if dpkg -l 2>/dev/null | grep -q "^ii.*redis-server"; then
        warning "Redis already installed — skipping repository setup to avoid conflicts"
        return 0
    fi

    local redis_list="/etc/apt/sources.list.d/redis.list"
    if [[ -f "$redis_list" ]] || ls /etc/apt/sources.list.d/*redis* >/dev/null 2>&1; then
        if grep -q "packages.redis.io" "$redis_list" 2>/dev/null || grep -q "packages.redis.io" /etc/apt/sources.list.d/*redis* 2>/dev/null; then
            log "✓ Redis.io repository already configured"
            return 0
        fi
    fi

    info "Setting up Redis ${REDIS_VERSION} repository (packages.redis.io)..."

    local ubuntu_codename
    ubuntu_codename=$(lsb_release -cs 2>/dev/null || grep '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "jammy")

    sudo install -m 0755 -d /etc/apt/keyrings 2>/dev/null || sudo mkdir -p /etc/apt/keyrings

    if curl -fsSL https://packages.redis.io/gpg 2>/dev/null | sudo gpg --dearmor -o /etc/apt/keyrings/redis-archive-keyring.gpg 2>/dev/null; then
        log "✓ Redis GPG key installed"
    else
        warning "Failed to install Redis GPG key — falling back to Ubuntu archive"
        REDIS_VERSION="system"
        return 0
    fi

    echo "deb [signed-by=/etc/apt/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb ${ubuntu_codename} main" | sudo tee "$redis_list" >/dev/null

    wait_for_apt_lock
    if sudo apt update 2>&1 | tail -5; then
        log "✓ Redis ${REDIS_VERSION} repository configured"
    else
        warning "apt update after Redis repo setup failed — falling back to Ubuntu archive"
        sudo rm -f "$redis_list" 2>/dev/null || true
        sudo rm -f /etc/apt/keyrings/redis-archive-keyring.gpg 2>/dev/null || true
        REDIS_VERSION="system"
    fi
}

# Install Redis

install_redis() {
    echo "   "
    echo "============================================="
    echo -e "${GREEN}Installing Redis server...${NC}"
    echo "============================================="

    setup_redis_repo
    wait_for_apt_lock
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
    
    info "Configuring Redis authentication..."

    local redis_use_acl=false
    if [[ "$REDIS_VERSION" == "7.4" ]] || [[ "$REDIS_VERSION" == "8.0" ]]; then
        redis_use_acl=true
    fi

    if [[ "$redis_use_acl" == "true" ]]; then
        local acl_file="/etc/redis/users.acl"
        # Remove legacy requirepass lines — ACL is authoritative
        sudo sed -i '/^requirepass\|^# requirepass/d' "$redis_conf" 2>/dev/null || true
        sudo sed -i '/^aclfile\|^# aclfile/d' "$redis_conf" 2>/dev/null || true
        printf 'user default on >%s ~* &* +@all\n' "$REDIS_PASSWORD" | sudo tee "$acl_file" >/dev/null
        sudo chmod 600 "$acl_file" 2>/dev/null || true
        sudo chown redis:redis "$acl_file" 2>/dev/null || sudo chown root:root "$acl_file" 2>/dev/null || true

        # Point redis.conf at ACL file (append if not present)
        if ! sudo grep -q "^aclfile" "$redis_conf" 2>/dev/null; then
            echo "aclfile $acl_file" | sudo tee -a "$redis_conf" >/dev/null
        fi

        log "✓ Redis ACL authentication configured ($acl_file)"
    else
        # Legacy path for system Redis 6.x
        sudo sed -i '/^requirepass\|^# requirepass/d' "$redis_conf" 2>/dev/null || true
        printf 'requirepass %s\n' "$REDIS_PASSWORD" | sudo tee -a "$redis_conf" >/dev/null
        sudo chmod 600 "$redis_conf" 2>/dev/null || true
        sudo chown redis:redis "$redis_conf" 2>/dev/null || true
        log "✓ Redis authentication configured (requirepass — legacy)"
    fi
    
    # Security configurations - check if lines exist before modifying
    info "Applying Redis security configurations..."
    
    if sudo grep -q "^bind " "$redis_conf"; then
        sudo sed -i 's/^bind .*/bind 127.0.0.1/' "$redis_conf"
    else
        sudo sed -i 's/^bind 127.0.0.1 ::1$/bind 127.0.0.1/' "$redis_conf"
    fi
    
    # Memory and policy configurations — RAM-aware (capped 128M–1G)
    info "Configuring Redis memory settings..."

    local total_ram_gb
    total_ram_gb=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}' 2>/dev/null || echo 2)
    [[ "$total_ram_gb" -lt 1 ]] && total_ram_gb=1
    local redis_maxmemory_mb=$(( total_ram_gb * 1024 * 15 / 100 ))
    [[ "$redis_maxmemory_mb" -lt 128 ]] && redis_maxmemory_mb=128
    [[ "$redis_maxmemory_mb" -gt 1024 ]] && redis_maxmemory_mb=1024

    if sudo grep -q "^maxmemory " "$redis_conf"; then
        sudo sed -i "s/^maxmemory .*/maxmemory ${redis_maxmemory_mb}mb/" "$redis_conf"
    else
        sudo sed -i "s/^# maxmemory <bytes>/maxmemory ${redis_maxmemory_mb}mb/" "$redis_conf"
    fi
    log "✓ Redis maxmemory set to ${redis_maxmemory_mb}mb (~15% of ${total_ram_gb}G RAM)"
    
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
    
    # Ensure Redis runs supervised under systemd and data dir is correct
    if sudo grep -q "^supervised " "$redis_conf" 2>/dev/null; then
        sudo sed -i 's/^supervised .*/supervised systemd/' "$redis_conf" 2>/dev/null || true
    elif sudo grep -q "^# supervised" "$redis_conf" 2>/dev/null; then
        sudo sed -i 's/^# supervised .*/supervised systemd/' "$redis_conf" 2>/dev/null || true
    fi
    if sudo grep -q "^dir " "$redis_conf" 2>/dev/null; then
        sudo sed -i 's|^dir .*|dir /var/lib/redis|' "$redis_conf" 2>/dev/null || true
    fi
    if sudo grep -q "^protected-mode" "$redis_conf" 2>/dev/null; then
        sudo sed -i 's/^protected-mode .*/protected-mode yes/' "$redis_conf" 2>/dev/null || true
    fi
    if sudo grep -q "^activedefrag " "$redis_conf" 2>/dev/null; then
        sudo sed -i 's/^activedefrag .*/activedefrag yes/' "$redis_conf" 2>/dev/null || true
    elif sudo grep -q "^# activedefrag" "$redis_conf" 2>/dev/null; then
        sudo sed -i 's/^# activedefrag .*/activedefrag yes/' "$redis_conf" 2>/dev/null || true
    else
        if ! sudo grep -q "^activedefrag" "$redis_conf" 2>/dev/null; then
            echo "activedefrag yes" | sudo tee -a "$redis_conf" >/dev/null 2>&1 || true
        fi
    fi
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
    
    # Test Redis connection with retries (REDISCLI_AUTH avoids -a deprecation/leak)
    local test_retries=5
    for ((i=1; i<=test_retries; i++)); do
        if timeout 10 env REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli ping 2>/dev/null | grep -q "PONG"; then
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
        info "ACL file (if using Redis 7.4/8.0): sudo cat /etc/redis/users.acl"
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
    
    # Create the supervisor configuration file — hardened
    sudo tee "$supervisor_config" > /dev/null <<EOF
[program:${PROJECT_NAME}-queue]
process_name=%(program_name)s_%(process_num)02d
command=${queue_command}
directory=${PROJECT_ROOT}/${PROJECT_NAME}
autostart=true
autorestart=true
user=www-data
numprocs=${SUPERVISOR_PROCESS_NUM}
startsecs=5
startretries=3
killasgroup=true
stopasgroup=true
stopwaitsecs=90
redirect_stderr=true
stdout_logfile=${PROJECT_ROOT}/${PROJECT_NAME}/storage/logs/queue-worker.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=5
environment=APP_ENV="production"
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
    
    # Create Laravel permission script — hardened: path guard + quoted vars + set -u
    sudo tee /usr/local/bin/fix-laravel-permissions > /dev/null <<'EOF'
#!/bin/bash
set -u

# Laravel Permission Fixer Script
# Usage: fix-laravel-permissions [project-path]

PROJECT_PATH="${1:-/var/www}"
WEBSERVER_USER="www-data"
WEBSERVER_GROUP="www-data"

if [[ "$PROJECT_PATH" != /var/www/* ]]; then
    echo "Error: Refusing to operate outside /var/www (got: $PROJECT_PATH)"
    exit 1
fi

if [[ ! -d "$PROJECT_PATH" ]]; then
    echo "Error: Directory $PROJECT_PATH does not exist"
    exit 1
fi

# Resolve symlinks and re-check prefix (defense in depth)
RESOLVED="$(realpath -m "$PROJECT_PATH" 2>/dev/null || echo "$PROJECT_PATH")"
if [[ "$RESOLVED" != /var/www/* ]]; then
    echo "Error: Resolved path outside /var/www (got: $RESOLVED)"
    exit 1
fi

echo "Setting Laravel permissions for: $PROJECT_PATH"

# Set ownership
chown -R "$WEBSERVER_USER:$WEBSERVER_GROUP" "$PROJECT_PATH"

# Set base permissions
find "$PROJECT_PATH" -type d -exec chmod 755 {} \;
find "$PROJECT_PATH" -type f -exec chmod 644 {} \;

# Set Laravel-specific permissions
if [[ -d "$PROJECT_PATH/storage" ]]; then
    chmod -R 775 "$PROJECT_PATH/storage"
    chown -R "$WEBSERVER_USER:$WEBSERVER_GROUP" "$PROJECT_PATH/storage"
    echo "✓ Storage directory permissions set"
fi

if [[ -d "$PROJECT_PATH/bootstrap/cache" ]]; then
    chmod -R 775 "$PROJECT_PATH/bootstrap/cache"
    chown -R "$WEBSERVER_USER:$WEBSERVER_GROUP" "$PROJECT_PATH/bootstrap/cache"
    echo "✓ Bootstrap cache permissions set"
fi

# Make artisan executable if exists
if [[ -f "$PROJECT_PATH/artisan" ]]; then
    chmod +x "$PROJECT_PATH/artisan"
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

    # Reset — only if inactive; otherwise backup before reset
    echo " "
    echo "============================================="
    echo -e "${GREEN}Preparing UFW...${NC}"
    echo "============================================="

    if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        warning "UFW is already active — backing up current rules before reset"
        sudo ufw status verbose > "/tmp/ufw.backup.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
        sudo ufw status numbered > "/tmp/ufw.backup-numbered.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
        info "Backups: /tmp/ufw.backup.*"
        sudo ufw --force reset || {
            error "Failed to reset UFW"
            return 1
        }
    else
        sudo ufw --force reset || {
            error "Failed to reset UFW"
            return 1
        }
    fi

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

    # Allow SSH with rate limiting — single rule, auto-detect custom port
    echo " "
    echo "============================================="
    echo -e "${GREEN}Configuring SSH access with rate limiting...${NC}"
    echo "============================================="

    local ssh_port="22"
    local detected_port
    detected_port=$(grep -E '^\s*Port\s+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1 || true)
    if [[ -n "$detected_port" ]] && [[ "$detected_port" =~ ^[0-9]+$ ]]; then
        ssh_port="$detected_port"
        if [[ "$ssh_port" != "22" ]]; then
            info "Detected custom SSH port: $ssh_port (from /etc/ssh/sshd_config)"
        fi
    fi

    # Prefer OpenSSH app profile when on default port; otherwise limit the detected port
    if [[ "$ssh_port" == "22" ]] && sudo ufw app info OpenSSH >/dev/null 2>&1; then
        sudo ufw limit OpenSSH comment 'SSH rate-limited' || {
            error "Failed to configure SSH rate limiting (OpenSSH profile)"
            return 1
        }
    else
        sudo ufw limit "${ssh_port}/tcp" comment 'SSH rate-limited' || {
            error "Failed to configure SSH rate limiting on port ${ssh_port}"
            return 1
        }
        if [[ "$ssh_port" != "22" ]]; then
            warning "Custom SSH port ${ssh_port} configured — ensure your client uses -p ${ssh_port}"
        fi
    fi

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

    # Enable logging and apply IPv6 change
    sudo ufw logging on 2>/dev/null || true
    sudo ufw reload 2>/dev/null || true

    # Enable UFW
    echo " "
    echo "============================================="
    echo -e "${GREEN}Enabling UFW firewall...${NC}"
    echo "============================================="
    sudo ufw --force enable || {
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
    
    # Prefer apt on Ubuntu (especially 24.04 noble); snap as fallback
    info "Installing Certbot via apt..."
    wait_for_apt_lock
    sudo apt update 2>&1 | tail -5 || true
    if sudo apt install -y certbot python3-certbot-nginx 2>&1 | tail -10; then
        log "✓ Certbot installed via apt"
        if command -v certbot &>/dev/null; then
            local version
            version=$(certbot --version 2>/dev/null | head -n1 || echo "certbot installed")
            info "$version"
        fi
        sudo systemctl enable --now certbot.timer 2>/dev/null || sudo systemctl enable certbot.timer 2>/dev/null || true
        if sudo certbot renew --dry-run 2>&1 | tail -10; then
            log "✓ Certbot renew dry-run passed"
        else
            warning "Certbot renew dry-run failed — check: sudo certbot renew --dry-run"
        fi
        return 0
    else
        warning "apt Certbot install failed, trying snap fallback..."
    fi

    if command -v snap &>/dev/null && systemctl is-active --quiet snapd 2>/dev/null; then
        info "Trying snap fallback for Certbot..."
        sudo snap install core 2>/dev/null || true
        sudo snap refresh core 2>/dev/null || true
        if sudo snap install --classic certbot 2>&1 | tail -10; then
            sudo ln -sf /snap/bin/certbot /usr/bin/certbot 2>/dev/null || true
            log "✓ Certbot installed via snap"
            sudo systemctl enable --now snap.certbot.renew.timer 2>/dev/null || true
            return 0
        else
            warning "Snap Certbot install failed"
        fi
    fi

    error "All Certbot installation methods failed"
    warning "Install manually: sudo apt update && sudo apt install -y certbot python3-certbot-nginx"
    return 1
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

