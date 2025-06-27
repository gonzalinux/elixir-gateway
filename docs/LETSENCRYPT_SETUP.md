# Let's Encrypt SSL Configuration

ExGateway now supports automatic SSL certificate management using Let's Encrypt via the `site_encrypt` library.

## 🚀 Quick Setup

### 1. **Environment Variables** (Required)

```bash
# Required: Comma-separated list of domains
export LETSENCRYPT_DOMAINS="api.yourdomain.com,service1.yourdomain.com,admin.yourdomain.com"

# Required: Email for Let's Encrypt registration
export LETSENCRYPT_EMAIL="admin@yourdomain.com"

# Optional: Use staging environment for testing (default: false)
export LETSENCRYPT_STAGING="true"

# Optional: Organization name (default: "Exgateway API Gateway")
export LETSENCRYPT_ORGANIZATION="Your Company Name"

# Optional: Certificate storage path (default: /etc/exgateway/certs)
export CERT_DB_FOLDER="/opt/exgateway/certs"
```

### 2. **DNS Configuration**

Point all your domains to your server's IP address:

```bash
# A records pointing to your server IP
api.yourdomain.com      A    192.168.1.100
service1.yourdomain.com A    192.168.1.100
admin.yourdomain.com    A    192.168.1.100
```

### 3. **Start the Gateway**

```bash
# Production (SiteEncrypt automatically enabled)
MIX_ENV=prod mix phx.server

# Development with Let's Encrypt (optional)
LETSENCRYPT_ENABLED=true mix phx.server

# Or with releases
MIX_ENV=prod mix release
_build/prod/rel/exgateway/bin/exgateway start
```

**Note**: SiteEncrypt only starts in production by default. In development, set `LETSENCRYPT_ENABLED=true` to test Let's Encrypt functionality.

## 🔧 How It Works

1. **Initial Certificate Request**: On first startup, SiteEncrypt will request certificates for all domains
2. **ACME HTTP-01 Challenge**: Let's Encrypt validates domain ownership via `/.well-known/acme-challenge/`
3. **Automatic Installation**: Certificates are automatically installed and Phoenix starts HTTPS
4. **Auto-Renewal**: Certificates are automatically renewed 30 days before expiry

## 📁 File Structure

```
/etc/exgateway/certs/          # Certificate storage (configurable)
├── account_key.pem            # Let's Encrypt account key
├── cert.pem                   # SSL certificate
├── chain.pem                  # Certificate chain
├── fullchain.pem              # Full certificate chain
└── privkey.pem                # Private key
```

## 🧪 Testing with Let's Encrypt Staging

For testing, use the staging environment to avoid rate limits:

```bash
export LETSENCRYPT_STAGING="true"
export LETSENCRYPT_DOMAINS="test.yourdomain.com"
export LETSENCRYPT_EMAIL="test@yourdomain.com"

MIX_ENV=prod mix phx.server
```

**Note**: Staging certificates are not trusted by browsers (you'll see security warnings).

## 🔒 Security Considerations

### Certificate Storage Permissions
```bash
# Ensure proper permissions
sudo mkdir -p /etc/exgateway/certs
sudo chown -R exgateway:exgateway /etc/exgateway/certs
sudo chmod 700 /etc/exgateway/certs
```

### Firewall Configuration
```bash
# Allow HTTP (port 80) for ACME challenges
sudo ufw allow 80/tcp

# Allow HTTPS (port 443) for gateway traffic
sudo ufw allow 443/tcp
```

## 📊 Monitoring

### Certificate Status
Check certificate status in the logs:
```bash
# Look for SiteEncrypt messages
journalctl -u exgateway -f | grep -i "certificate"
```

### Automatic Notifications
The gateway logs certificate events:
- Certificate obtained: `New SSL certificate obtained for domains: [...]`
- Certificate renewed: `SSL certificate renewed for domains: [...]`

## 🚨 Troubleshooting

### Common Issues

1. **Domain Validation Failed**
   ```
   Error: Domain validation failed for api.yourdomain.com
   ```
   - Ensure DNS points to your server
   - Check firewall allows port 80
   - Verify domain is accessible via HTTP

2. **Rate Limit Exceeded**
   ```
   Error: Rate limit exceeded
   ```
   - Let's Encrypt limits: 50 certificates per domain per week
   - Use staging environment for testing
   - Wait for rate limit reset

3. **Certificate Storage Permission Denied**
   ```
   Error: Permission denied writing to /etc/exgateway/certs
   ```
   - Check directory permissions
   - Ensure exgateway user owns the directory

### Debug Mode
Enable debug logging:
```bash
export EXGATEWAY_LOG_LEVEL="debug"
MIX_ENV=prod mix phx.server
```

## 🔄 Manual Certificate Management

### Force Certificate Renewal
```elixir
# In IEx console
SiteEncrypt.force_renew(Exgateway.SiteEncrypt)
```

### Check Certificate Expiry
```bash
# Check certificate expiry date
openssl x509 -in /etc/exgateway/certs/cert.pem -noout -dates
```

## 🌐 Multiple Domain Support

### Wildcard Certificates
For subdomains of the same domain:
```bash
export LETSENCRYPT_DOMAINS="*.yourdomain.com,yourdomain.com"
```

### Different Root Domains
For completely different domains:
```bash
export LETSENCRYPT_DOMAINS="api.company1.com,service.company2.com,admin.company3.com"
```

## 📈 Production Deployment

### Systemd Service
```ini
# /etc/systemd/system/exgateway.service
[Unit]
Description=ExGateway API Gateway
After=network.target

[Service]
Type=exec
User=exgateway
Group=exgateway
Environment=LETSENCRYPT_DOMAINS=api.yourdomain.com,service1.yourdomain.com
Environment=LETSENCRYPT_EMAIL=admin@yourdomain.com
Environment=CERT_DB_FOLDER=/etc/exgateway/certs
ExecStart=/opt/exgateway/bin/exgateway start
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### Docker Deployment
```dockerfile
# Dockerfile additions for Let's Encrypt
RUN mkdir -p /etc/exgateway/certs
VOLUME ["/etc/exgateway/certs"]

ENV LETSENCRYPT_DOMAINS=""
ENV LETSENCRYPT_EMAIL=""
ENV CERT_DB_FOLDER="/etc/exgateway/certs"

EXPOSE 80 443
```

## ✅ Verification

Test your SSL setup:
```bash
# Test HTTPS connectivity
curl -I https://api.yourdomain.com

# Check SSL certificate
openssl s_client -connect api.yourdomain.com:443 -servername api.yourdomain.com

# Verify certificate chain
curl -I https://api.yourdomain.com --verbose
```

The gateway will automatically handle SSL certificates for all your domains! 🎉