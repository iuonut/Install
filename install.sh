#!/bin/bash

# Script to automate the installation of N8N, Nginx, CertBot, and optionally PostgreSQL on an Ubuntu VPS

echo "Updating and upgrading the system..."
sudo apt update && sudo apt upgrade -y

echo "Installing NVM and Node.js 18..."
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.1/install.sh | bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm install 18
nvm use 18
nvm alias default 18

echo "Installing N8N globally..."
npm install n8n -g

echo "Getting N8N installation path..."
N8N_PATH=$(which n8n)

echo "Creating n8n_start.sh script..."
cat <<EOT > /root/n8n_start.sh
#!/bin/bash
export NVM_DIR="/root/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh"
nvm use 18
$N8N_PATH start
EOT

chmod +x /root/n8n_start.sh

# Prompt for domain and timezone
read -p "Enter your domain (e.g., server.leadtoconnection.com): " DOMAIN
read -p "Enter your timezone (e.g., America/Los_Angeles): " TIMEZONE

# Ask if PostgreSQL should be installed
read -p "Do you want to install and configure PostgreSQL for N8N? (yes/no): " INSTALL_POSTGRESQL

POSTGRESQL_DETAILS=""

if [ "$INSTALL_POSTGRESQL" == "yes" ]; then
    echo "Installing PostgreSQL..."
    sudo apt install postgresql postgresql-contrib -y

    # Generate a random password for the PostgreSQL user
    POSTGRES_PASSWORD=$(openssl rand -base64 12)

    echo "Setting up PostgreSQL for N8N..."
    sudo -u postgres psql -c "CREATE DATABASE n8n;"
    sudo -u postgres psql -c "CREATE USER n8nuser WITH PASSWORD '$POSTGRES_PASSWORD';"
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE n8n TO n8nuser;"
    sudo -u postgres psql -c "ALTER USER n8nuser WITH SUPERUSER;"

    # Update n8n.service file to use PostgreSQL
    echo "Updating n8n.service to use PostgreSQL..."
    sed -i "/^Environment=\"N8N_DIAGNOSTICS_ENABLED=false\"/a Environment=\"DB_TYPE=postgresdb\"\nEnvironment=\"DB_POSTGRESDB_HOST=localhost\"\nEnvironment=\"DB_POSTGRESDB_PORT=5432\"\nEnvironment=\"DB_POSTGRESDB_DATABASE=n8n\"\nEnvironment=\"DB_POSTGRESDB_USER=n8nuser\"\nEnvironment=\"DB_POSTGRESDB_PASSWORD=$POSTGRES_PASSWORD\"" /etc/systemd/system/n8n.service

    # Save PostgreSQL details for final echo
    POSTGRESQL_DETAILS="PostgreSQL has been installed and configured for N8N.\nDatabase: n8n\nUser: n8nuser\nPassword: $POSTGRES_PASSWORD"
fi

echo "Creating n8n.service file..."
cat <<EOT > /etc/systemd/system/n8n.service
[Unit]
Description=n8n, Workflow Automation Tool
After=network.target

[Service]
Type=simple
User=root
Environment="WEBHOOK_TUNNEL_URL=https://$DOMAIN"
Environment="N8N_HOST=$DOMAIN"
Environment="N8N_PORT=5678"
Environment="N8N_PROTOCOL=https"
Environment="WEBHOOK_URL=https://$DOMAIN/"
Environment="VUE_APP_URL_BASE_API=https://$DOMAIN/"
Environment="N8N_DIAGNOSTICS_ENABLED=false"
Environment="GENERIC_TIMEZONE=$TIMEZONE"
Environment="TZ=$TIMEZONE"
ExecStart=/root/n8n_start.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOT

echo "Reloading systemd and enabling n8n service..."
sudo systemctl daemon-reload
sudo systemctl restart n8n
sudo systemctl enable n8n
sudo systemctl status n8n

echo "Installing and configuring Nginx..."
sudo apt install nginx -y
cat <<EOT > /etc/nginx/sites-available/$DOMAIN
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://localhost:5678;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOT

sudo ln -s /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx

echo "Installing CertBot and obtaining SSL certificate..."
sudo apt install certbot python3-certbot-nginx -y
sudo certbot --nginx -d $DOMAIN
sudo certbot renew --dry-run

echo "Creating update_n8n.sh script..."
cat <<EOT > /root/update_n8n.sh
#!/bin/bash

# Stop n8n service if running
sudo systemctl stop n8n

# Run npm update for n8n
npm update -g n8n

# Start n8n service
sudo systemctl start n8n
EOT

chmod +x /root/update_n8n.sh

echo "Configuring cron job for updating n8n..."
(crontab -l ; echo "0 3 * * 0 /root/update_n8n.sh >> /var/log/n8n_update.log 2>&1") | crontab -

echo "Displaying crontab entries..."
crontab -l

echo "Installation and configuration complete!"

# If PostgreSQL was installed, echo the details
if [ "$INSTALL_POSTGRESQL" == "yes" ]; then
    echo -e "\n$POSTGRESQL_DETAILS"
fi