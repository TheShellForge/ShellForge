#!/bin/bash
set -euo pipefail

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configurações
LOG_FILE="laravel_server_setup_$(date +%Y%m%d_%H%M%S).log"
DB_PASSWORD=$(openssl rand -base64 16)
APP_USER="laraveluser"
APP_NAME="meularavel"
APP_ROOT="/var/www/$APP_NAME"

# Funções auxiliares
print_header() {
    echo -e "\n${BLUE}###########################################"
    echo -e "### $1"
    echo -e "###########################################${NC}\n"
}

print_success() {
    echo -e "${GREEN}[✓] $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}[!] $1${NC}"
}

print_error() {
    echo -e "${RED}[✗] $1${NC}"
}

run_as_app_user() {
    sudo -u $APP_USER bash -c "$1"
}

# Iniciar log
exec > >(tee -a "$LOG_FILE") 2>&1
print_header "Iniciando configuração do servidor Laravel - $(date)"

# Verificações iniciais
print_header "Verificando requisitos do sistema"
if [ "$EUID" -ne 0 ]; then
    print_error "Este script deve ser executado como root"
    exit 1
fi

# Atualizar sistema
print_header "Atualizando o sistema"
apt-get update
apt-get upgrade -y

# Instalar dependências básicas
print_header "Instalando dependências do sistema"
apt-get install -y \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    ufw \
    git \
    unzip \
    make

# Configurar firewall
print_header "Configurando UFW"
ufw allow ssh
ufw allow http
ufw allow https
ufw --force enable

# Instalar e configurar MariaDB
print_header "Instalando MariaDB"
apt-get install -y mariadb-server mariadb-client

# Criar banco de dados para a aplicação
print_header "Criando banco de dados"
mysql -u root -e "CREATE DATABASE IF NOT EXISTS ${APP_NAME}_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -u root -e "CREATE USER IF NOT EXISTS '${APP_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"
mysql -u root -e "GRANT ALL PRIVILEGES ON ${APP_NAME}_db.* TO '${APP_USER}'@'localhost';"
mysql -u root -e "FLUSH PRIVILEGES;"

# Instalar PHP e extensões necessárias
print_header "Instalando PHP e extensões"
apt-get install -y \
    php8.1 \
    php8.1-cli \
    php8.1-fpm \
    php8.1-mysql \
    php8.1-pgsql \
    php8.1-sqlite3 \
    php8.1-curl \
    php8.1-gd \
    php8.1-mbstring \
    php8.1-xml \
    php8.1-zip \
    php8.1-bcmath \
    php8.1-intl \
    php8.1-redis \
    php8.1-soap \
    php8.1-imagick

# Instalar Nginx
print_header "Instalando Nginx"
apt-get install -y nginx

# Configurar usuário da aplicação
print_header "Configurando usuário da aplicação"
if ! id "$APP_USER" &>/dev/null; then
    useradd -m -s /bin/bash -d /home/$APP_USER $APP_USER
    usermod -aG www-data $APP_USER
    print_success "Usuário $APP_USER criado"
else
    print_warning "Usuário $APP_USER já existe"
fi

# Configurar diretório da aplicação
print_header "Configurando diretório da aplicação"
mkdir -p $APP_ROOT
chown -R $APP_USER:www-data $APP_ROOT
chmod -R 775 $APP_ROOT/storage || true
chmod -R 775 $APP_ROOT/bootstrap/cache || true

# Instalar Composer
print_header "Instalando Composer"
if [ ! -f "/usr/local/bin/composer" ]; then
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
    chmod +x /usr/local/bin/composer
    print_success "Composer instalado"
else
    print_warning "Composer já está instalado"
fi

# Configurar Nginx para a aplicação Laravel
print_header "Configurando Nginx"
cat > /etc/nginx/sites-available/$APP_NAME <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name _;
    root $APP_ROOT/public;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";
    add_header X-XSS-Protection "1; mode=block";

    index index.php;

    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ \.php$ {
        fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF

ln -sf /etc/nginx/sites-available/$APP_NAME /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx

# Instalar Node.js e NPM
print_header "Instalando Node.js"
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt-get install -y nodejs

# Configurar supervisor para queues
print_header "Configurando Supervisor para Queues"
apt-get install -y supervisor
cat > /etc/supervisor/conf.d/laravel-worker.conf <<EOF
[program:laravel-worker]
process_name=%(program_name)s_%(process_num)02d
command=php $APP_ROOT/artisan queue:work --sleep=3 --tries=3
autostart=true
autorestart=true
user=$APP_USER
numprocs=2
redirect_stderr=true
stdout_logfile=$APP_ROOT/storage/logs/worker.log
stopwaitsecs=3600
EOF

supervisorctl reread
supervisorctl update
supervisorctl start laravel-worker:*

# Configurar cron jobs
print_header "Configurando Cron Jobs"
(crontab -u $APP_USER -l 2>/dev/null; echo "* * * * * php $APP_ROOT/artisan schedule:run >> /dev/null 2>&1") | crontab -u $APP_USER -

# Instalar Redis
print_header "Instalando Redis"
apt-get install -y redis-server
systemctl enable redis-server
systemctl start redis-server

# Otimizações de performance
print_header "Otimizando configurações"
# Otimizar PHP-FPM
sed -i 's/^pm.max_children = .*/pm.max_children = 50/' /etc/php/8.1/fpm/pool.d/www.conf
sed -i 's/^pm.start_servers = .*/pm.start_servers = 10/' /etc/php/8.1/fpm/pool.d/www.conf
sed -i 's/^pm.min_spare_servers = .*/pm.min_spare_servers = 5/' /etc/php/8.1/fpm/pool.d/www.conf
sed -i 's/^pm.max_spare_servers = .*/pm.max_spare_servers = 15/' /etc/php/8.1/fpm/pool.d/www.conf

# Otimizar MariaDB
cat >> /etc/mysql/mariadb.conf.d/50-server.cnf <<EOF
[mysqld]
innodb_buffer_pool_size = 256M
innodb_log_file_size = 64M
query_cache_size = 32M
query_cache_limit = 2M
max_connections = 100
EOF

# Reiniciar serviços
print_header "Reiniciando serviços"
systemctl restart php8.1-fpm
systemctl restart mysql
systemctl restart nginx
systemctl restart supervisor

# Resumo da instalação
print_header "Configuração concluída com sucesso!"
echo -e "${GREEN}=== Detalhes da Instalação ==="
echo -e "Diretório da aplicação: ${APP_ROOT}"
echo -e "Usuário da aplicação: ${APP_USER}"
echo -e "Banco de dados: ${APP_NAME}_db"
echo -e "Usuário DB: ${APP_USER}"
echo -e "Senha DB: ${DB_PASSWORD}"
echo -e "Servidor Web: Nginx"
echo -e "PHP Version: 8.1"
echo -e "Node.js Version: $(node -v)"
echo -e "NPM Version: $(npm -v)"
echo -e "Composer Version: $(composer --version)"
echo -e "=============================${NC}"

print_header "Próximos passos:"
echo -e "1. Coloque seus arquivos Laravel em ${APP_ROOT}"
echo -e "2. Configure seu arquivo .env com as credenciais do banco de dados"
echo -e "3. Execute 'composer install' e 'npm install'"
echo -e "4. Configure seu DNS para apontar para este servidor"
echo -e "\n${YELLOW}Log completo disponível em: ${LOG_FILE}${NC}"

exit 0