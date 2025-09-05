# Universal Next.js Deployment Script

A production-grade, zero-downtime deployment script for Next.js applications with true blue-green deployment, automatic rollback, and comprehensive server configuration.

## 📋 Table of Contents
- [Features](#features)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Usage](#usage)
- [Deployment Strategies](#deployment-strategies)
- [Environment Variables](#environment-variables)
- [Health Checks](#health-checks)
- [SSL/HTTPS Setup](#sslhttps-setup)
- [Database Support](#database-support)
- [Troubleshooting](#troubleshooting)
- [Best Practices](#best-practices)
- [Contributing](#contributing)

## ✨ Features

### Core Features
- **Zero-downtime deployments** - True blue-green deployment strategy
- **Automatic rollback** - Reverts to previous version on health check failure
- **Multi-OS support** - Works with Ubuntu, Debian, Amazon Linux, CentOS, RHEL
- **Build mode flexibility** - Supports both standalone and regular Next.js builds
- **Package manager agnostic** - Works with npm, yarn, and pnpm
- **Auto-installation** - Automatically installs required dependencies on server

### Performance & Optimization
- **Static asset caching** - Optimized cache headers for `_next/static`
- **Compression** - Gzip and Brotli compression support
- **WebSocket support** - Proper WebSocket upgrade handling
- **Connection pooling** - Nginx upstream keepalive connections

### Security
- **SSL/HTTPS** - Automatic Let's Encrypt certificate provisioning
- **HSTS** - HTTP Strict Transport Security headers
- **Security headers** - X-Frame-Options, X-Content-Type-Options, X-XSS-Protection
- **Environment validation** - Validates required environment variables before deployment

### Monitoring & Management
- **Health checks** - Configurable health endpoint verification
- **PM2 integration** - Process management with auto-restart and logging
- **Disk space management** - Automatic cleanup of old releases
- **Deployment history** - Keeps configurable number of previous releases

## 📦 Requirements

### Local Machine
- Node.js 18+ 
- npm/yarn/pnpm
- Git
- SSH client
- A Next.js application

### Remote Server
- Linux server (Ubuntu/Debian/Amazon Linux/CentOS/RHEL)
- SSH access with sudo privileges
- Minimum 2GB free disk space
- Open ports: 80, 443 (for HTTPS), and your app port

## 🚀 Quick Start

### 1. Download the Script
```bash
curl -fsSL -o deploy.sh https://raw.githubusercontent.com/altmemy/scripts/main/deploy.sh
chmod +x deploy.sh
```

### 2. Configure Basic Settings
```bash
# Edit the script or use environment variables
export SSH_HOST="your-server-ip"
export SSH_USER="ubuntu"
export DOMAIN="yourdomain.com"
export APP_NAME="my-nextjs-app"
```

### 3. Deploy
```bash
./deploy.sh
```

## ⚙️ Configuration

### Essential Configuration
```bash
# Required
APP_NAME="my-app"                  # Your application name
DOMAIN="example.com"                # Your domain
SSH_HOST="192.168.1.100"           # Server IP or hostname
SSH_USER="ubuntu"                   # SSH username

# Optional but recommended
SSH_KEY="$HOME/.ssh/id_rsa"        # SSH key path (default: ~/.ssh/id_rsa)
APP_PORT="3000"                     # Application port (default: 3000)
STAGING_PORT="3001"                 # Staging port for blue-green (default: 3001)
```

### Build Configuration
```bash
BUILD_MODE="auto"                   # auto|standalone|regular
USE_YARN="false"                    # Use Yarn instead of npm
USE_PNPM="false"                    # Use pnpm instead of npm
SKIP_BUILD="false"                  # Skip local build (use existing)
```

### Deployment Configuration
```bash
KEEP_RELEASES="3"                   # Number of releases to keep
HEALTH_CHECK_PATH="/api/health"     # Health check endpoint
HEALTH_CHECK_TIMEOUT="30"           # Health check timeout in seconds
AUTO_ROLLBACK="true"                # Auto rollback on failure
```

### SSL/Security Configuration
```bash
ENABLE_HTTPS="true"                 # Enable HTTPS with Let's Encrypt
ENABLE_HSTS="true"                  # Enable HSTS header
LETSENCRYPT_EMAIL="admin@example.com" # Email for Let's Encrypt
```

### Performance Configuration
```bash
ENABLE_GZIP="true"                  # Enable gzip compression
ENABLE_BROTLI="true"                # Enable Brotli compression
ENABLE_CACHE_HEADERS="true"         # Enable cache headers for static assets
CACHE_MAX_AGE="31536000"           # Cache max age in seconds (1 year)
```

## 📖 Usage

### Basic Deployment
```bash
# Deploy with default settings
./deploy.sh

# Deploy with custom domain
DOMAIN="myapp.com" ./deploy.sh

# Deploy to specific server
SSH_HOST="192.168.1.100" SSH_USER="ubuntu" ./deploy.sh
```

### Advanced Usage
```bash
# Use Yarn package manager
USE_YARN=true ./deploy.sh

# Deploy with custom ports
APP_PORT=8080 STAGING_PORT=8081 ./deploy.sh

# Skip database migrations
SKIP_DB=true ./deploy.sh

# Deploy without auto-rollback
AUTO_ROLLBACK=false ./deploy.sh

# Keep more releases
KEEP_RELEASES=5 ./deploy.sh
```

### Environment Variables Validation
```bash
# Validate specific environment variables
REQUIRED_ENV_VARS="DATABASE_URL,AUTH_SECRET,API_KEY" ./deploy.sh

# Skip validation
VALIDATE_ENV=false ./deploy.sh
```

### Build Modes
```bash
# Force standalone mode
BUILD_MODE=standalone ./deploy.sh

# Force regular mode
BUILD_MODE=regular ./deploy.sh

# Auto-detect from next.config.js (default)
BUILD_MODE=auto ./deploy.sh
```

## 🔄 Deployment Strategies

### Blue-Green Deployment (Default)
The script implements true blue-green deployment:

1. **Current version** runs on primary port (e.g., 3000)
2. **New version** deploys to staging port (e.g., 3001)
3. **Health checks** verify new version
4. **Traffic switches** via Nginx configuration
5. **Old version** stops after grace period

```
[Blue: Port 3000] ──→ [Active Traffic]
                       ↓ Deploy
[Green: Port 3001] ──→ [New Version]
                       ↓ Health Check ✓
[Blue: Port 3000] ──→ [Stopped]
[Green: Port 3001] ──→ [Active Traffic]
```

## 🔐 Environment Variables

### Required Environment File
Create `.env.production` in your project root:

```env
# Required
NODE_ENV=production
DATABASE_URL=postgresql://user:pass@localhost/db
AUTH_SECRET=your-secret-key

# Optional
API_KEY=your-api-key
REDIS_URL=redis://localhost:6379
```

### Auto-generated Variables
The script automatically adds:
- `NODE_ENV=production`
- `PORT` (from configuration)
- `AUTH_SECRET` (if missing, generates random)

## 🏥 Health Checks

### Creating a Health Endpoint
Create `app/api/health/route.ts`:

```typescript
// app/api/health/route.ts
export async function GET() {
  // Check database connection (optional)
  try {
    // await db.query('SELECT 1')
    return Response.json({ 
      status: 'healthy',
      timestamp: Date.now()
    })
  } catch (error) {
    return Response.json({ 
      status: 'unhealthy',
      error: error.message 
    }, { status: 503 })
  }
}
```

### Health Check Configuration
```bash
# Custom health endpoint
HEALTH_CHECK_PATH="/api/status" ./deploy.sh

# Custom expected status code
HEALTH_CHECK_EXPECTED_STATUS=204 ./deploy.sh

# Longer timeout for slow starts
HEALTH_CHECK_TIMEOUT=60 ./deploy.sh

# Skip health endpoint verification
VERIFY_HEALTH_ENDPOINT=false ./deploy.sh
```

## 🔒 SSL/HTTPS Setup

### Automatic SSL
The script automatically:
1. Installs Certbot
2. Obtains Let's Encrypt certificate
3. Configures Nginx for HTTPS
4. Sets up auto-renewal

### Manual SSL Configuration
```bash
# Disable automatic HTTPS
ENABLE_HTTPS=false ./deploy.sh

# Custom Let's Encrypt email
LETSENCRYPT_EMAIL="ssl@yourdomain.com" ./deploy.sh
```

## 🗄️ Database Support

### Prisma
```bash
# Enable Prisma migrations
USE_PRISMA=true SKIP_DB=false ./deploy.sh
```

### Drizzle
```bash
# Enable Drizzle migrations
USE_DRIZZLE=true SKIP_DB=false ./deploy.sh

# With schema generation (slower)
USE_DRIZZLE=true DRIZZLE_GENERATE=true ./deploy.sh
```

### Skip Database Operations
```bash
# Skip all database operations
SKIP_DB=true ./deploy.sh
```

## 🔧 Troubleshooting

### Common Issues

#### 1. SSH Connection Failed
```bash
# Check SSH connectivity
ssh -i ~/.ssh/your-key.pem ubuntu@your-server-ip

# Verify SSH configuration
SSH_KEY=/path/to/key SSH_PORT=2222 ./deploy.sh
```

#### 2. Build Failed
```bash
# Check Node version
node -v  # Should be 18+

# Clear cache and retry
rm -rf node_modules package-lock.json
npm install
./deploy.sh
```

#### 3. Health Check Failed
```bash
# Check logs on server
ssh user@server
pm2 logs my-app-blue
pm2 logs my-app-green

# Test health endpoint locally
curl http://localhost:3000/api/health
```

#### 4. Insufficient Disk Space
```bash
# Connect to server and clean up
ssh user@server
df -h  # Check disk usage
sudo journalctl --vacuum-time=1d
npm cache clean --force
```

### Debug Mode
```bash
# Run with verbose output
set -x
./deploy.sh
```

### Manual Rollback
```bash
# Connect to server
ssh user@server

# Switch to previous version
pm2 start ecosystem-blue.config.js
pm2 delete my-app-green

# Or restart current
pm2 restart my-app-blue
```

## 📚 Best Practices

### 1. Next.js Configuration
```javascript
// next.config.js
module.exports = {
  output: 'standalone',  // Recommended for production
  compress: false,       // Let Nginx handle compression
  poweredByHeader: false,
  generateEtags: false,
}
```

### 2. Environment Management
- Never commit `.env` files
- Use `.env.production` for production values
- Validate critical variables before deployment
- Use secrets management service for sensitive data

### 3. Performance Optimization
- Enable standalone mode for smaller deployments
- Use CDN for static assets
- Configure appropriate cache headers
- Enable both Gzip and Brotli compression

### 4. Security
- Always enable HTTPS in production
- Use strong environment secrets
- Keep dependencies updated
- Configure firewall rules
- Use SSH keys, not passwords

### 5. Monitoring
```bash
# View PM2 dashboard
pm2 monit

# Check application logs
pm2 logs my-app-blue --lines 100

# View Nginx logs
sudo tail -f /var/log/nginx/access.log
sudo tail -f /var/log/nginx/error.log
```

### 6. Backup Strategy
- Keep at least 3 releases (`KEEP_RELEASES=3`)
- Backup database before migrations
- Document rollback procedures
- Test deployments on staging first

## 🤝 Contributing

Contributions are welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Commit your changes
4. Push to the branch
5. Open a Pull Request

## 📝 License

MIT License - feel free to use in your projects.

## 🙏 Acknowledgments

Built with best practices from:
- Next.js deployment documentation
- Nginx optimization guides
- PM2 production guidelines
- DevOps community feedback
