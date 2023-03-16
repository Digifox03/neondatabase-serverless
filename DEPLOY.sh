# To deploy wsproxy behind nginx (for TLS) on a host ws.example.com
# running Ubuntu 22.04 (and Postgres locally), you'd do something similar to
# the following.

# note: be sure port 443 isn't firewalled off

# upgrade to 22.04 if on earlier version (required for recent enough Golang)

sudo su  # do this all as root

apt update -y && apt upgrade -y && apt dist-upgrade -y
apt autoremove -y && apt autoclean -y
apt install -y update-manager-core
do-release-upgrade  # and answer yes to all defaults

# ... reboots, then ...

sudo su  # we do the rest as root too

export HOSTDOMAIN=ws.example.com  # edit the domain name for your case

# if required: install postgres + create a password-auth user

apt install -y postgresql

echo 'create database wstest; create user wsclear; grant all privileges on database wstest to wsclear;' | sudo -u postgres psql
sudo -u postgres psql  # and run: \password wsclear

perl -pi -e 's/^# IPv4 local connections:\n/# IPv4 local connections:\nhost all wsclear 127.0.0.1\/32 password\n/' /etc/postgresql/14/main/pg_hba.conf
service postgresql restart

# install wsproxy

adduser wsproxy --disabled-login

sudo su wsproxy
cd
git clone https://github.com/neondatabase/wsproxy.git
cd wsproxy
go build
exit

echo "
[Unit]
Description=wsproxy

[Service]
Type=simple
Restart=always
RestartSec=5s
User=wsproxy
Environment=LISTEN_PORT=:6543 ALLOW_ADDR_REGEX='^${HOSTDOMAIN}:5432\$'
ExecStart=/home/wsproxy/wsproxy/wsproxy

[Install]
WantedBy=multi-user.target
" > /lib/systemd/system/wsproxy.service

systemctl enable wsproxy
service wsproxy start

# install nginx as tls proxy

apt install -y golang nginx certbot python3-certbot-nginx

echo "127.0.0.1 ${HOSTDOMAIN}" >> /etc/hosts

echo "                                                                       
server {
  listen 80;
  listen [::]:80;
  server_name ${HOSTDOMAIN};
  location / {
    proxy_pass http://127.0.0.1:6543/;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection Upgrade;
    proxy_set_header Host \$host;
  }
}
" > /etc/nginx/sites-available/wsproxy   

ln -s /etc/nginx/sites-available/wsproxy /etc/nginx/sites-enabled/wsproxy

certbot --nginx -d ${HOSTDOMAIN}

echo "
server {
  server_name ${HOSTDOMAIN};

  location / {
    proxy_pass http://127.0.0.1:6543/;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection Upgrade;
    proxy_set_header Host \$host;
  }

  listen [::]:80 ipv6only=on;
  listen 80;

  listen [::]:443 ssl ipv6only=on; # managed by Certbot
  listen 443 ssl; # managed by Certbot
  ssl_certificate /etc/letsencrypt/live/${HOSTDOMAIN}/fullchain.pem; # managed by Certbot
  ssl_certificate_key /etc/letsencrypt/live/${HOSTDOMAIN}/privkey.pem; # managed by Certbot
  include /etc/letsencrypt/options-ssl-nginx.conf; # managed by Certbot
  ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # managed by Certbot
}
" > /etc/nginx/sites-available/wsproxy

service nginx restart
