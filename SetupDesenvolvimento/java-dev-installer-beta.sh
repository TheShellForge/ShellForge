#!/bin/bash

# ----------------------------------------------#
# Licença
# Distribuído sob a licença Apache2.0. Veja https://www.apache.org/licenses/LICENSE-2.0 para detalhes.
# Desenvolvido por ShellForge
# contato@shellforge.com.br
# Participe da nossa comunidade no WhatsApp
# ----------------------------------------------#

# Abortar em caso de erro
set -euo pipefail

# Cores do output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configurações
LOG_FILE="tuxstart_install_$(date +%Y%m%d_%H%M%S).log"
TEMP_DIR=$(mktemp -d)

# Funções de output
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

# Função para instalar pacotes com tratamento de erro
install_packages() {
	echo -e "\nInstalando: $@"
	sudo apt-get install -y "$@" || {
		print_error "Falha na instalação de: $@"
		return 1
	}
}

cleanup() {
	rm -rf "$TEMP_DIR"
	print_success "Limpeza concluída"
}

install_fastfetch() {
	if ! command -v fastfetch &>/dev/null; then
		print_header "Instalando FastFetch"

		# Instalar dependências de compilação
		install_packages cmake git pkg-config

		# Clonar repositório
		if [ ! -d "$TEMP_DIR/fastfetch" ]; then
			git clone https://github.com/fastfetch-cli/fastfetch.git "$TEMP_DIR/fastfetch"
		fi

		# Compilar e instalar
		cd "$TEMP_DIR/fastfetch"
		mkdir -p build && cd build
		cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local
		make -j$(nproc)
		sudo make install

		print_success "FastFetch instalado com sucesso"
	else
		print_warning "FastFetch já está instalado"
	fi
}

# Configurar trap para limpeza
trap cleanup EXIT

# Iniciar logs
exec > >(tee -a "$LOG_FILE") 2>&1
echo -e "${BLUE}=== Log de instalação TuxStart $(date) ===${NC}"

# Verificações iniciais
print_header "Verificando requisitos do sistema"

if ! grep -qi 'ubuntu\|debian' /etc/os-release; then
	print_error "Este script é compatível apenas com Ubuntu/Debian"
	exit 1
fi

if [ "$EUID" -eq 0 ]; then
	print_error "Não execute como root/sudo. O script pedirá permissões quando necessário."
	exit 1
fi

# Atualizar pacotes
print_header "Atualizando lista de pacotes"
sudo apt-get update

# Instalar pacotes básicos
print_header "Instalando dependências básicas"
BASE_PACKAGES=(
	apt-transport-https
	ca-certificates
	curl
	software-properties-common
	git
	build-essential
	htop
	tmux
	vim
	maven
)
install_packages "${BASE_PACKAGES[@]}"

# Instalar Docker
print_header "Configurando Docker"
# Verificar se Docker já está instalado
if ! command -v docker &>/dev/null; then
	source /etc/os-release

	# Adicionar repositório Docker
	sudo curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /usr/share/keyrings/docker.asc
	echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.asc] https://download.docker.com/linux/$ID $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

	sudo apt-get update
	install_packages docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin

	# Configurar usuário no grupo docker
	sudo usermod -aG docker "$USER"
	print_success "Docker foi instalado. Por favor, reinicie a sessão para usar sem sudo"
else
	print_warning "Docker já está instalado"
fi

# Instalar Node.js
print_header "Configurando Node.js"
if ! command -v node &>/dev/null; then
	curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
	install_packages nodejs
	print_success "Node.js $(node -v) instalado"
else
	print_warning "Node.js já instalado (versão $(node -v))"
fi

# Instalar OpenJDK 21
print_header "Instalando OpenJDK 21"

# Verificar se Java já está instalado
if [ ! -d "/opt/openjdk21" ]; then
	JDK_URL="https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.6%2B7/OpenJDK21U-jdk_x64_linux_hotspot_21.0.6_7.tar.gz"

	curl -L -o "$TEMP_DIR/OpenJDK21.tar.gz" "$JDK_URL"
	sudo tar -xzf "$TEMP_DIR/OpenJDK21.tar.gz" -C /opt/
	sudo mv /opt/jdk-21.0.6+7 /opt/openjdk21

	# Configurar environment se ele não existir
	if ! grep -q "JAVA_HOME=/opt/openjdk21" ~/.bashrc; then
		echo 'export JAVA_HOME=/opt/openjdk21' >>~/.bashrc
		echo 'export PATH=$JAVA_HOME/bin:$PATH' >>~/.bashrc
		source ~/.bashrc
	fi

	print_success "OpenJDK 21 instalado em /opt/openjdk21"
else
	print_warning "OpenJDK 21 já está instalado"
fi
# Instalar FastFetch
install_fastfetch

# Verificar instalações
print_header "Verificando instalações"
echo -e "Docker: $(docker --version)"
echo -e "Java: $(java -version 2>&1 | head -n 1)"
echo -e "Node.js: $(node -v)"
echo -e "npm: $(npm -v)"
echo -e "Git: $(git --version)"

# Finalização
print_header "Instalação concluída"
echo -e "${GREEN}Todas as ferramentas foram instaladas com sucesso!${NC}"
echo -e "Log completo disponível em: ${YELLOW}$LOG_FILE${NC}"
echo -e "\nRecomendações:"
echo -e "1. Reinicie seu terminal para aplicar todas as alterações"
echo -e "2. Execute ${BLUE}newgrp docker${NC} para usar Docker sem sudo"
echo -e "3. Verifique o Java com ${BLUE}java -version${NC}"
exit 0
