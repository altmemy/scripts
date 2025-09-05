#!/usr/bin/env bash
set -euo pipefail

# ================================================================
# Universal Next.js Deployment Script v5.0 - Production Grade
# ================================================================
# True zero-downtime blue-green deployment with all optimizations
# ================================================================

# ================== CONFIGURATION ==================

# Basic Configuration
APP_NAME="${APP_NAME:-my-app}"
DOMAIN="${DOMAIN:-example.com}"
WWW_DOMAIN="${WWW_DOMAIN:-www.${DOMAIN}}"
APP_PORT="${APP_PORT:-3000}"
STAGING_PORT="${STAGING_PORT:-3001}"

# SSH Configuration
SSH_USER="${SSH_USER:-ubuntu}"
SSH_HOST="${SSH_HOST:-}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
SSH_PORT="${SSH_PORT:-22}"

# Build Configuration
BUILD_MODE="${BUILD_MODE:-auto}"  # auto|standalone|regular
USE_YARN="${USE_YARN:-false}"
USE_PNPM="${USE_PNPM:-false}"
SKIP_BUILD="${SKIP_BUILD:-false}"

# Deployment Configuration
KEEP_RELEASES="${KEEP_RELEASES:-3}"
HEALTH_CHECK_PATH="${HEALTH_CHECK_PATH:-/api/health}"
HEALTH_CHECK_TIMEOUT="${HEALTH_CHECK_TIMEOUT:-30}"
HEALTH_CHECK_EXPECTED_STATUS="${HEALTH_CHECK_EXPECTED_STATUS:-200}"
AUTO_ROLLBACK="${AUTO_ROLLBACK:-true}"
VERIFY_HEALTH_ENDPOINT="${VERIFY_HEALTH_ENDPOINT:-true}"

# Environment Configuration
ENV_FILE="${ENV_FILE:-.env.production}"
REQUIRED_ENV_VARS="${REQUIRED_ENV_VARS:-}"
VALIDATE_ENV="${VALIDATE_ENV:-true}"

# Database Configuration
SKIP_DB="${SKIP_DB:-true}"
USE_PRISMA="${USE_PRISMA:-false}"
USE_DRIZZLE="${USE_DRIZZLE:-false}"
DRIZZLE_GENERATE="${DRIZZLE_GENERATE:-false}"  # Optional generate

# Server Configuration
REQUIRED_NODE_MAJOR="${REQUIRED_NODE_MAJOR:-18}"
INSTALL_NODE_MAJOR="${INSTALL_NODE_MAJOR:-20}"
MIN_FREE_SPACE_GB="${MIN_FREE_SPACE_GB:-3}"

# SSL/Security Configuration
ENABLE_HTTPS="${ENABLE_HTTPS:-true}"
ENABLE_HSTS="${ENABLE_HSTS:-true}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-admin@${DOMAIN}}"

# Performance Configuration
ENABLE_GZIP="${ENABLE_GZIP:-true}"
ENABLE_BROTLI="${ENABLE_BROTLI:-true}"
ENABLE_CACHE_HEADERS="${ENABLE_CACHE_HEADERS:-true}"
CACHE_MAX_AGE="${CACHE_MAX_AGE:-31536000}"
MAX_UPLOAD_SIZE="${MAX_UPLOAD_SIZE:-100M}"

# Nginx Optimization
WORKER_CONNECTIONS="${WORKER_CONNECTIONS:-1024}"
KEEPALIVE_TIMEOUT="${KEEPALIVE_TIMEOUT:-65}"
CLIENT_BODY_TIMEOUT="${CLIENT_BODY_TIMEOUT:-60}"
CLIENT_HEADER_TIMEOUT="${CLIENT_HEADER_TIMEOUT:-60}"
SEND_TIMEOUT="${SEND_TIMEOUT:-60}"

# ====================================================

# Validate configuration
if [[ -z "${SSH_HOST}" ]]; then
  echo "ERROR: SSH_HOST is required"
  exit 1
fi

# Remote paths
REMOTE_BASE="/opt/apps/${APP_NAME}"
REMOTE_SHARED="${REMOTE_BASE}/shared"
REMOTE_ENV_FILE="${REMOTE_SHARED}/.env"
REMOTE_RELEASES="${REMOTE_BASE}/releases"
REMOTE_CURRENT="${REMOTE_BASE}/current"
REMOTE_BLUE="${REMOTE_BASE}/blue"
REMOTE_GREEN="${REMOTE_BASE}/green"
REMOTE_TEMP="${REMOTE_BASE}/temp"

# Package manager
get_package_manager() {
  if [[ "${USE_PNPM}" == "true" ]] && command -v pnpm >/dev/null; then
    echo "pnpm"
  elif [[ "${USE_YARN}" == "true" ]] && command -v yarn >/dev/null; then
    echo "yarn"
  else
    echo "npm"
  fi
}

PM=$(get_package_manager)

# SSH options
SSH_OPTS="-p ${SSH_PORT} -i ${SSH_KEY} -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ConnectTimeout=10"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# ================== HELPER FUNCTIONS ==================

detect_build_mode() {
  if [[ "${BUILD_MODE}" != "auto" ]]; then
    echo "${BUILD_MODE}"
    return
  fi
  
  if grep -q "output.*:.*['\"]standalone['\"]" next.config.* 2>/dev/null; then
    echo "standalone"
  else
    echo "regular"
  fi
}

validate_env_file() {
  local env_file="$1"
  local required_vars="$2"
  
  if [[ -z "${required_vars}" ]]; then
    return 0
  fi
  
  local missing_vars=()
  IFS=',' read -ra VARS <<< "${required_vars}"
  
  for var in "${VARS[@]}"; do
    var=$(echo "$var" | xargs)
    if ! grep -q "^${var}=" "${env_file}" 2>/dev/null; then
      missing_vars+=("$var")
    fi
  done
  
  if [[ ${#missing_vars[@]} -gt 0 ]]; then
    log_error "Missing required environment variables: ${missing_vars[*]}"
    return 1
  fi
  
  return 0
}

verify_health_endpoint() {
  if [[ "${VERIFY_HEALTH_ENDPOINT}" != "true" ]]; then
    return 0
  fi
  
  # Check if health endpoint exists in the codebase
  if ! grep -r "${HEALTH_CHECK_PATH}" --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" . 2>/dev/null | grep -q "export"; then
    log_warn "Health endpoint ${HEALTH_CHECK_PATH} not found in codebase"
    log_warn "Make sure to implement: export async function GET() { return Response.json({ status: 'ok' }) }"
    
    # Create a basic health endpoint if missing
    if [[ -d "app/api" ]]; then
      mkdir -p "app/api/health"
      cat > "app/api/health/route.ts" <<'EOF'
export async function GET() {
  return Response.json({ status: 'ok', timestamp: Date.now() })
}
EOF
      log_info "Created basic health endpoint at ${HEALTH_CHECK_PATH}"
      return 1  # Need rebuild
    fi
  fi
  
  return 0
}

# ================== PRE-FLIGHT CHECKS ==================

log_step "Running pre-flight checks..."

for cmd in ssh scp node $PM; do
  if ! command -v $cmd >/dev/null; then
    log_error "$cmd not found"
    exit 1
  fi
done

if ! ssh ${SSH_OPTS} "${SSH_USER}@${SSH_HOST}" "echo 'SSH OK'" >/dev/null 2>&1; then
  log_error "Cannot connect to ${SSH_HOST}"
  exit 1
fi

if [[ "${VALIDATE_ENV}" == "true" ]] && [[ -f "${ENV_FILE}" ]]; then
  if ! validate_env_file "${ENV_FILE}" "${REQUIRED_ENV_VARS}"; then
    log_error "Environment validation failed"
    exit 1
  fi
fi

ACTUAL_BUILD_MODE=$(detect_build_mode)
log_info "Build mode: ${ACTUAL_BUILD_MODE}"

# Verify health endpoint
NEED_REBUILD=false
if ! verify_health_endpoint; then
  NEED_REBUILD=true
  SKIP_BUILD=false
fi

# ================== REMOTE CLEANUP ==================

log_step "Remote: Checking disk space..."
ssh ${SSH_OPTS} "${SSH_USER}@${SSH_HOST}" \
  "export MIN_FREE_SPACE_GB='${MIN_FREE_SPACE_GB}' KEEP_RELEASES='${KEEP_RELEASES}' REMOTE_RELEASES='${REMOTE_RELEASES}'; bash -s" <<'REMOTE_CLEANUP'
set -euo pipefail

FREE_GB=$(df -BG / | awk 'NR==2 {print int($4)}')
echo "Available space: ${FREE_GB}GB"

if [[ ${FREE_GB} -lt ${MIN_FREE_SPACE_GB} ]]; then
  echo "Cleaning old releases..."
  
  if [[ -d "${REMOTE_RELEASES}" ]]; then
    cd "${REMOTE_RELEASES}"
    ls -1dt * 2>/dev/null | tail -n +$((KEEP_RELEASES + 1)) | xargs -r rm -rf
  fi
  
  npm cache clean --force 2>/dev/null || true
  yarn cache clean 2>/dev/null || true
  pnpm store prune 2>/dev/null || true
  
  sudo journalctl --vacuum-time=2d >/dev/null 2>&1 || true
  find /tmp -type f -mtime +2 -delete 2>/dev/null || true
  
  FREE_GB=$(df -BG / | awk 'NR==2 {print int($4)}')
  echo "Space after cleanup: ${FREE_GB}GB"
  
  if [[ ${FREE_GB} -lt ${MIN_FREE_SPACE_GB} ]]; then
    echo "ERROR: Insufficient space"
    exit 1
  fi
fi
REMOTE_CLEANUP

# ================== LOCAL BUILD ==================

if [[ "${SKIP_BUILD}" != "true" ]]; then
  log_step "Local: Installing dependencies..."
  
  if [[ "$PM" == "npm" ]] && [[ -f "package-lock.json" ]]; then
    npm ci
  elif [[ "$PM" == "yarn" ]] && [[ -f "yarn.lock" ]]; then
    yarn install --frozen-lockfile
  elif [[ "$PM" == "pnpm" ]] && [[ -f "pnpm-lock.yaml" ]]; then
    pnpm install --frozen-lockfile
  else
    $PM install
  fi
  
  if [[ "${USE_PRISMA}" == "true" ]] && [[ -f "prisma/schema.prisma" ]]; then
    log_info "Generating Prisma client..."
    npx prisma generate
  fi
  
  if [[ "${USE_DRIZZLE}" == "true" ]] && [[ "${DRIZZLE_GENERATE}" == "true" ]]; then
    log_info "Generating Drizzle schema..."
    npx drizzle-kit generate || true
  fi
  
  log_step "Local: Building application..."
  NODE_ENV=production $PM run build
fi

# ================== PACKAGE APPLICATION ==================

log_step "Packaging application..."

TIMESTAMP=$(date +%Y%m%d%H%M%S)
DIST_DIR="/tmp/${APP_NAME}-dist-${TIMESTAMP}"
mkdir -p "${DIST_DIR}"

if [[ "${ACTUAL_BUILD_MODE}" == "standalone" ]]; then
  if [[ ! -d ".next/standalone" ]]; then
    log_error "Standalone build not found. Ensure next.config has output: 'standalone'"
    exit 1
  fi
  
  cp -r .next/standalone/* "${DIST_DIR}/"
  mkdir -p "${DIST_DIR}/.next/static"
  cp -r .next/static/* "${DIST_DIR}/.next/static/"
  [[ -d "public" ]] && cp -r public "${DIST_DIR}/"
else
  mkdir -p "${DIST_DIR}/.next"
  rsync -a --exclude='cache' ".next/" "${DIST_DIR}/.next/"
  [[ -d "public" ]] && cp -r public "${DIST_DIR}/"
  
  for file in package*.json next.config.* server.js server.ts; do
    [[ -f "$file" ]] && cp "$file" "${DIST_DIR}/"
  done
  
  # Include next as dependency for regular mode
  if [[ -f "package.json" ]]; then
    if ! grep -q '"next"' "${DIST_DIR}/package.json"; then
      log_warn "Next.js not in dependencies, adding it..."
      jq '.dependencies.next = "*"' "${DIST_DIR}/package.json" > "${DIST_DIR}/package.json.tmp" && \
      mv "${DIST_DIR}/package.json.tmp" "${DIST_DIR}/package.json" 2>/dev/null || true
    fi
  fi
fi

[[ -d "prisma" ]] && cp -r prisma "${DIST_DIR}/"
[[ -f "drizzle.config.ts" ]] && cp "drizzle.config.ts" "${DIST_DIR}/"
[[ -d "drizzle" ]] && cp -r drizzle "${DIST_DIR}/"

cat > "${DIST_DIR}/DEPLOY_META" <<EOF
TIMESTAMP=${TIMESTAMP}
BUILD_MODE=${ACTUAL_BUILD_MODE}
NODE_VERSION=$(node -v)
PACKAGE_MANAGER=${PM}
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
EOF

ARTIFACT="/tmp/${APP_NAME}-${TIMESTAMP}.tar.gz"
tar -czf "${ARTIFACT}" -C "${DIST_DIR}" .

# ================== UPLOAD TO SERVER ==================

log_step "Uploading to server..."

ssh ${SSH_OPTS} "${SSH_USER}@${SSH_HOST}" "mkdir -p ${REMOTE_TEMP}"
scp -P ${SSH_PORT} ${SSH_KEY:+-i "$SSH_KEY"} "${ARTIFACT}" "${SSH_USER}@${SSH_HOST}:${REMOTE_TEMP}/"

if [[ -f "${ENV_FILE}" ]]; then
  log_info "Uploading environment file..."
  scp -P ${SSH_PORT} ${SSH_KEY:+-i "$SSH_KEY"} "${ENV_FILE}" "${SSH_USER}@${SSH_HOST}:${REMOTE_TEMP}/.env"
fi

# ================== DEPLOY ON SERVER ==================

log_step "Deploying on server..."

ssh ${SSH_OPTS} "${SSH_USER}@${SSH_HOST}" \
  "export APP_NAME='${APP_NAME}' DOMAIN='${DOMAIN}' WWW_DOMAIN='${WWW_DOMAIN}' \
          APP_PORT='${APP_PORT}' STAGING_PORT='${STAGING_PORT}' \
          REMOTE_BASE='${REMOTE_BASE}' REMOTE_SHARED='${REMOTE_SHARED}' REMOTE_ENV_FILE='${REMOTE_ENV_FILE}' \
          REMOTE_RELEASES='${REMOTE_RELEASES}' REMOTE_CURRENT='${REMOTE_CURRENT}' \
          REMOTE_BLUE='${REMOTE_BLUE}' REMOTE_GREEN='${REMOTE_GREEN}' REMOTE_TEMP='${REMOTE_TEMP}' \
          TIMESTAMP='${TIMESTAMP}' ACTUAL_BUILD_MODE='${ACTUAL_BUILD_MODE}' \
          HEALTH_CHECK_PATH='${HEALTH_CHECK_PATH}' HEALTH_CHECK_TIMEOUT='${HEALTH_CHECK_TIMEOUT}' \
          HEALTH_CHECK_EXPECTED_STATUS='${HEALTH_CHECK_EXPECTED_STATUS}' \
          AUTO_ROLLBACK='${AUTO_ROLLBACK}' KEEP_RELEASES='${KEEP_RELEASES}' \
          REQUIRED_NODE_MAJOR='${REQUIRED_NODE_MAJOR}' INSTALL_NODE_MAJOR='${INSTALL_NODE_MAJOR}' \
          SKIP_DB='${SKIP_DB}' USE_PRISMA='${USE_PRISMA}' USE_DRIZZLE='${USE_DRIZZLE}' \
          PM='${PM}' ENABLE_HTTPS='${ENABLE_HTTPS}' ENABLE_HSTS='${ENABLE_HSTS}' \
          ENABLE_GZIP='${ENABLE_GZIP}' ENABLE_BROTLI='${ENABLE_BROTLI}' \
          ENABLE_CACHE_HEADERS='${ENABLE_CACHE_HEADERS}' \
          CACHE_MAX_AGE='${CACHE_MAX_AGE}' MAX_UPLOAD_SIZE='${MAX_UPLOAD_SIZE}' \
          WORKER_CONNECTIONS='${WORKER_CONNECTIONS}' KEEPALIVE_TIMEOUT='${KEEPALIVE_TIMEOUT}' \
          CLIENT_BODY_TIMEOUT='${CLIENT_BODY_TIMEOUT}' CLIENT_HEADER_TIMEOUT='${CLIENT_HEADER_TIMEOUT}' \
          SEND_TIMEOUT='${SEND_TIMEOUT}' LETSENCRYPT_EMAIL='${LETSENCRYPT_EMAIL}'; bash -s" <<'REMOTE_DEPLOY'
set -euo pipefail

# Detect OS
source /etc/os-release || true
OS_PM=""
case "${ID:-unknown}" in
  ubuntu|debian) OS_PM="apt-get";;
  amzn|centos|rhel|fedora) OS_PM="dnf";;
  *) command -v dnf >/dev/null && OS_PM="dnf" || OS_PM="apt-get";;
esac

# Install dependencies
install_deps() {
  if command -v node >/dev/null 2>&1; then
    CURRENT_NODE=$(node -v | sed 's/v\([0-9]*\).*/\1/')
  else
    CURRENT_NODE=0
  fi
  
  if [[ "$CURRENT_NODE" -lt "${REQUIRED_NODE_MAJOR}" ]]; then
    echo "Installing Node.js ${INSTALL_NODE_MAJOR}..."
    if [[ "$OS_PM" == "apt-get" ]]; then
      curl -fsSL "https://deb.nodesource.com/setup_${INSTALL_NODE_MAJOR}.x" | sudo -E bash -
      sudo apt-get install -y nodejs
    else
      curl -fsSL "https://rpm.nodesource.com/setup_${INSTALL_NODE_MAJOR}.x" | sudo bash -
      sudo $OS_PM install -y nodejs
    fi
  fi
  
  if [[ "${PM}" == "yarn" ]] && ! command -v yarn >/dev/null; then
    npm install -g yarn
  fi
  if [[ "${PM}" == "pnpm" ]] && ! command -v pnpm >/dev/null; then
    npm install -g pnpm
  fi
  
  if ! command -v pm2 >/dev/null; then
    npm install -g pm2
  fi
  
  if ! command -v nginx >/dev/null; then
    if [[ "$OS_PM" == "apt-get" ]]; then
      sudo apt-get update && sudo apt-get install -y nginx
    else
      sudo $OS_PM install -y nginx
    fi
  fi
}

install_deps

# Directory setup
sudo mkdir -p "${REMOTE_BASE}" "${REMOTE_SHARED}" "${REMOTE_RELEASES}" "${REMOTE_TEMP}"
sudo mkdir -p /var/www/certbot
sudo chown -R "${USER}:${USER}" "${REMOTE_BASE}"

# Environment setup
if [[ -f "${REMOTE_TEMP}/.env" ]]; then
  cp "${REMOTE_TEMP}/.env" "${REMOTE_ENV_FILE}"
else
  touch "${REMOTE_ENV_FILE}"
fi

add_env_var() {
  if ! grep -q "^$1=" "${REMOTE_ENV_FILE}"; then
    echo "$1=$2" >> "${REMOTE_ENV_FILE}"
  fi
}

add_env_var "NODE_ENV" "production"

# Extract release
RELEASE_DIR="${REMOTE_RELEASES}/${TIMESTAMP}"
echo "Extracting to ${RELEASE_DIR}..."
mkdir -p "${RELEASE_DIR}"
tar -xzf "${REMOTE_TEMP}/${APP_NAME}-${TIMESTAMP}.tar.gz" -C "${RELEASE_DIR}"

cd "${RELEASE_DIR}"

# Install dependencies for regular mode
if [[ "${ACTUAL_BUILD_MODE}" == "regular" ]]; then
  echo "Installing production dependencies..."
  if [[ "$PM" == "npm" ]]; then
    npm ci --omit=dev || npm install --production
  elif [[ "$PM" == "yarn" ]]; then
    yarn install --production
  elif [[ "$PM" == "pnpm" ]]; then
    pnpm install --prod
  fi
  
  # Ensure next CLI is available
  if [[ ! -f "node_modules/.bin/next" ]]; then
    echo "Installing Next.js CLI..."
    npm install next
  fi
fi

cp "${REMOTE_ENV_FILE}" "${RELEASE_DIR}/.env"

# Database migrations
if [[ "${SKIP_DB}" != "true" ]]; then
  source "${RELEASE_DIR}/.env"
  
  if [[ "${USE_PRISMA}" == "true" ]] && [[ -f "prisma/schema.prisma" ]]; then
    npx prisma migrate deploy || true
  fi
  
  if [[ "${USE_DRIZZLE}" == "true" ]]; then
    npx drizzle-kit push || true
  fi
fi

# Blue-Green Deployment
perform_blue_green() {
  # Determine current and new colors
  CURRENT_COLOR="blue"
  NEW_COLOR="green"
  CURRENT_PORT="${APP_PORT}"
  NEW_PORT="${STAGING_PORT}"
  
  if [[ -L "${REMOTE_CURRENT}" ]]; then
    CURRENT_LINK=$(readlink "${REMOTE_CURRENT}")
    if [[ "${CURRENT_LINK}" == "${REMOTE_GREEN}" ]]; then
      CURRENT_COLOR="green"
      NEW_COLOR="blue"
      CURRENT_PORT="${STAGING_PORT}"
      NEW_PORT="${APP_PORT}"
    fi
  fi
  
  echo "Current: ${CURRENT_COLOR} (port ${CURRENT_PORT}), New: ${NEW_COLOR} (port ${NEW_PORT})"
  
  # Link new release
  if [[ "${NEW_COLOR}" == "blue" ]]; then
    ln -sfn "${RELEASE_DIR}" "${REMOTE_BLUE}"
    NEW_DIR="${REMOTE_BLUE}"
  else
    ln -sfn "${RELEASE_DIR}" "${REMOTE_GREEN}"
    NEW_DIR="${REMOTE_GREEN}"
  fi
  
  # Configure PM2
  START_SCRIPT=""
  SCRIPT_ARGS=""
  
  if [[ "${ACTUAL_BUILD_MODE}" == "standalone" ]]; then
    START_SCRIPT="${NEW_DIR}/server.js"
  else
    # Check for next CLI
    if [[ -f "${NEW_DIR}/node_modules/.bin/next" ]]; then
      START_SCRIPT="${NEW_DIR}/node_modules/.bin/next"
    elif command -v next >/dev/null; then
      START_SCRIPT="next"
    else
      echo "ERROR: Next.js CLI not found"
      exit 1
    fi
    SCRIPT_ARGS="start -p ${NEW_PORT}"
  fi
  
  cat > "${REMOTE_BASE}/ecosystem-${NEW_COLOR}.config.js" <<EOF
module.exports = {
  apps: [{
    name: '${APP_NAME}-${NEW_COLOR}',
    script: '${START_SCRIPT}',
    args: '${SCRIPT_ARGS}',
    cwd: '${NEW_DIR}',
    instances: 1,
    exec_mode: 'cluster',
    env: {
      PORT: '${NEW_PORT}',
      NODE_ENV: 'production'
    },
    env_file: '${NEW_DIR}/.env',
    max_memory_restart: '500M',
    error_file: '${REMOTE_BASE}/logs/${NEW_COLOR}-error.log',
    out_file: '${REMOTE_BASE}/logs/${NEW_COLOR}-out.log',
    merge_logs: true,
    time: true
  }]
};
EOF
  
  mkdir -p "${REMOTE_BASE}/logs"
  
  # Start new version
  pm2 delete "${APP_NAME}-${NEW_COLOR}" 2>/dev/null || true
  pm2 start "${REMOTE_BASE}/ecosystem-${NEW_COLOR}.config.js"
  
  # Health check
  echo "Health checking new version on port ${NEW_PORT}..."
  HEALTH_CHECK_URL="http://127.0.0.1:${NEW_PORT}${HEALTH_CHECK_PATH}"
  HEALTH_PASSED=false
  
  for i in $(seq 1 ${HEALTH_CHECK_TIMEOUT}); do
    RESPONSE_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${HEALTH_CHECK_URL}" 2>/dev/null || echo "000")
    if [[ "${RESPONSE_CODE}" == "${HEALTH_CHECK_EXPECTED_STATUS}" ]]; then
      HEALTH_PASSED=true
      echo "✅ Health check passed (${RESPONSE_CODE})"
      break
    fi
    echo "Waiting... ($i/${HEALTH_CHECK_TIMEOUT}) [Status: ${RESPONSE_CODE}]"
    sleep 1
  done
  
  if [[ "${HEALTH_PASSED}" != "true" ]]; then
    echo "❌ Health check failed!"
    pm2 delete "${APP_NAME}-${NEW_COLOR}"
    
    if [[ "${AUTO_ROLLBACK}" == "true" ]]; then
      echo "Keeping current version running"
      exit 1
    fi
  fi
  
  # Switch nginx
  configure_nginx "${NEW_PORT}"
  
  # Update symlink
  ln -sfn "${NEW_DIR}" "${REMOTE_CURRENT}"
  
  # Stop old version
  echo "Stopping old version in 10 seconds..."
  sleep 10
  pm2 delete "${APP_NAME}-${CURRENT_COLOR}" 2>/dev/null || true
  
  # Save PM2
  pm2 save
  
  # Configure startup
  PM2_STARTUP=$(pm2 startup systemd -u "${USER}" --hp "/home/${USER}" | tail -n 1)
  if [[ "${PM2_STARTUP}" =~ "sudo" ]]; then
    eval "${PM2_STARTUP}"
  fi
}

# Nginx configuration function
configure_nginx() {
  local UPSTREAM_PORT="${1:-${APP_PORT}}"
  local CONFIG_FILE="/etc/nginx/sites-available/${APP_NAME}"
  [[ ! -d "/etc/nginx/sites-available" ]] && CONFIG_FILE="/etc/nginx/conf.d/${APP_NAME}.conf"
  
  # Check if SSL certificate exists
  local SSL_ENABLED=false
  if [[ "${ENABLE_HTTPS}" == "true" ]] && [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    SSL_ENABLED=true
  fi
  
  # Generate config
  sudo tee "${CONFIG_FILE}" > /dev/null <<EOF
# WebSocket upgrade map
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
}

# Upstream
upstream ${APP_NAME}_backend {
    server 127.0.0.1:${UPSTREAM_PORT};
    keepalive 64;
}

# HTTP server
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} ${WWW_DOMAIN};
    
    # Timeouts
    client_body_timeout ${CLIENT_BODY_TIMEOUT};
    client_header_timeout ${CLIENT_HEADER_TIMEOUT};
    send_timeout ${SEND_TIMEOUT};
    keepalive_timeout ${KEEPALIVE_TIMEOUT};
    
    # Let's Encrypt
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    
    $(if [[ "${SSL_ENABLED}" == "true" ]]; then
      echo "# Redirect to HTTPS"
      echo "location / {"
      echo "    return 301 https://\\\$server_name\\\$request_uri;"
      echo "}"
    else
      echo "# Proxy to application"
      echo "location / {"
      echo "    proxy_pass http://${APP_NAME}_backend;"
      echo "    proxy_http_version 1.1;"
      echo "    proxy_set_header Upgrade \\\$http_upgrade;"
      echo "    proxy_set_header Connection \\\$connection_upgrade;"
      echo "    proxy_set_header Host \\\$host;"
      echo "    proxy_set_header X-Real-IP \\\$remote_addr;"
      echo "    proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;"
      echo "    proxy_set_header X-Forwarded-Proto \\\$scheme;"
      echo "}"
    fi)
}

$(if [[ "${SSL_ENABLED}" == "true" ]]; then
  cat <<HTTPS
# HTTPS server
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN} ${WWW_DOMAIN};
    
    # SSL
    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_stapling on;
    ssl_stapling_verify on;
    
    # Security headers
    $(if [[ "${ENABLE_HSTS}" == "true" ]]; then
      echo "add_header Strict-Transport-Security \"max-age=31536000; includeSubDomains; preload\" always;"
    fi)
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    client_max_body_size ${MAX_UPLOAD_SIZE};
    client_body_timeout ${CLIENT_BODY_TIMEOUT};
    client_header_timeout ${CLIENT_HEADER_TIMEOUT};
    send_timeout ${SEND_TIMEOUT};
    
    # Compression
    $(if [[ "${ENABLE_GZIP}" == "true" ]]; then
      echo "gzip on;"
      echo "gzip_vary on;"
      echo "gzip_proxied any;"
      echo "gzip_comp_level 6;"
      echo "gzip_types text/plain text/css text/xml text/javascript application/json application/javascript application/xml+rss application/rss+xml application/atom+xml image/svg+xml text/x-js text/x-cross-domain-policy application/x-font-ttf application/x-font-opentype application/vnd.ms-fontobject image/x-icon;"
    fi)
    
    $(if [[ "${ENABLE_BROTLI}" == "true" ]]; then
      echo "brotli on;"
      echo "brotli_comp_level 6;"
      echo "brotli_types text/plain text/css text/xml text/javascript application/json application/javascript application/xml+rss application/rss+xml application/atom+xml image/svg+xml;"
    fi)
    
    # Static assets caching
    $(if [[ "${ENABLE_CACHE_HEADERS}" == "true" ]]; then
      echo "location /_next/static {"
      echo "    alias ${REMOTE_CURRENT}/.next/static;"
      echo "    expires ${CACHE_MAX_AGE}s;"
      echo "    add_header Cache-Control \"public, max-age=${CACHE_MAX_AGE}, immutable\";"
      echo "}"
      echo ""
      echo "location ~* \\\.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)$ {"
      echo "    expires 30d;"
      echo "    add_header Cache-Control \"public, max-age=2592000, immutable\";"
      echo "}"
    fi)
    
    # Main proxy
    location / {
        proxy_pass http://${APP_NAME}_backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \\\$http_upgrade;
        proxy_set_header Connection \\\$connection_upgrade;
        proxy_set_header Host \\\$host;
        proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
        proxy_request_buffering off;
    }
}
HTTPS
fi)
EOF
  
  if [[ -d "/etc/nginx/sites-available" ]]; then
    sudo ln -sf "${CONFIG_FILE}" "/etc/nginx/sites-enabled/"
    sudo rm -f /etc/nginx/sites-enabled/default
  fi
  
  # Nginx optimization in main config
  if ! grep -q "worker_connections ${WORKER_CONNECTIONS}" /etc/nginx/nginx.conf; then
    sudo sed -i "s/worker_connections [0-9]*;/worker_connections ${WORKER_CONNECTIONS};/" /etc/nginx/nginx.conf
  fi
  
  sudo nginx -t && sudo systemctl reload nginx
}

# SSL setup
setup_ssl() {
  if [[ "${ENABLE_HTTPS}" != "true" ]]; then
    return 0
  fi
  
  if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    echo "SSL certificate already exists"
    return 0
  fi
  
  echo "Setting up SSL certificate..."
  
  if ! command -v certbot >/dev/null; then
    if [[ "$OS_PM" == "apt-get" ]]; then
      sudo apt-get install -y certbot
    else
      sudo $OS_PM install -y certbot || {
        sudo $OS_PM install -y python3-pip
        sudo pip3 install certbot
      }
    fi
  fi
  
  # Configure nginx for acme challenge first
  configure_nginx "${APP_PORT}"
  
  # Get certificate
  sudo certbot certonly --webroot -w /var/www/certbot \
    -d "${DOMAIN}" -d "${WWW_DOMAIN}" \
    --non-interactive --agree-tos -m "${LETSENCRYPT_EMAIL}"
  
  # Reconfigure nginx with SSL
  if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    echo "SSL certificate obtained, reconfiguring nginx..."
    configure_nginx "${APP_PORT}"
  fi
}

# Setup SSL first
setup_ssl

# Perform deployment
perform_blue_green

# Cleanup
echo "Cleaning old releases..."
cd "${REMOTE_RELEASES}"
ls -1dt * | tail -n +$((KEEP_RELEASES + 1)) | xargs -r rm -rf

rm -rf "${REMOTE_TEMP}"/*

echo ""
echo "=========================================="
echo " Deployment Complete!"
echo "=========================================="
echo " Application: ${APP_NAME}"
echo " Build Mode: ${ACTUAL_BUILD_MODE}"
[[ "${ENABLE_HTTPS}" == "true" ]] && echo " URL: https://${DOMAIN}" || echo " URL: http://${DOMAIN}"
echo " Health: ${HEALTH_CHECK_PATH}"
echo ""
echo " PM2 Commands:"
echo "   pm2 status"
echo "   pm2 logs ${APP_NAME}-blue"
echo "   pm2 logs ${APP_NAME}-green"
echo "=========================================="

REMOTE_DEPLOY

# ================== DONE ==================

log_info "Deployment complete!"
[[ "${ENABLE_HTTPS}" == "true" ]] && log_info "URL: https://${DOMAIN}" || log_info "URL: http://${DOMAIN}"
log_info "Health endpoint: ${HEALTH_CHECK_PATH}"
