#!/bin/bash
# Algo não está funcionando? # tail -f /var/log/messages /var/log/syslog /var/log/tomcat*/*.out /var/log/mysql/*.log

# Verifica se o usuário é root ou sudo
if ! [ $(id -u) = 0 ]; then
    echo "Por favor, execute este script como sudo ou root" 1>&2
    exit 1
fi

# Verifica se há arquivos antigos remanescentes
if [ "$(find . -maxdepth 1 \( -name 'guacamole-*' -o -name 'mysql-connector-java-*' \))" != "" ]; then
    echo "Possíveis arquivos temporários detectados. Por favor, revise 'guacamole-*' e 'mysql-connector-java-*'" 1>&2
    exit 1
fi

# Número da versão do Guacamole para instalar
# Página inicial ~ https://guacamole.apache.org/releases/
GUACVERSION="1.5.4"

# Última Versão do MySQL Connector/J se a instalação manual for necessária (se libmariadb-java/libmysql-java não estiver disponível via apt)
# Página inicial ~ https://dev.mysql.com/downloads/connector/j/
MCJVER="8.0.27"

# Cores a serem usadas para a saída
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m' # Sem Cor

# Localização do Log
LOG="/tmp/guacamole_${GUACVERSION}_build.log"

# Inicializa os valores das variáveis
installTOTP=""
installDuo=""
installMySQL=""
mysqlHost=""
mysqlPort=""
mysqlRootPwd=""
guacDb=""
guacUser=""
guacPwd=""
PROMPT=""
MYSQL=""

# Obtem argumentos do script para o modo não-interativo
while [ "$1" != "" ]; do
    case $1 in
        # Seleção de instalação do MySQL
        -i | --installmysql)
            installMySQL=true
            ;;
        -n | --nomysql)
            installMySQL=false
            ;;

        # Informações do servidor/raiz MySQL
        -h | --mysqlhost)
            shift
            mysqlHost="$1"
            ;;
        -p | --mysqlport)
            shift
            mysqlPort="$1"
            ;;
        -r | --mysqlpwd)
            shift
            mysqlRootPwd="$1"
            ;;

        # Informações do banco de dados/usuario Guac
        -db | --guacdb)
            shift
            guacDb="$1"
            ;;
        -gu | --guacuser)
            shift
            guacUser="$1"
            ;;
        -gp | --guacpwd)
            shift
            guacPwd="$1"
            ;;

        # Seleção MFA
        -t | --totp)
            installTOTP=true
            ;;
        -d | --duo)
            installDuo=true
            ;;
        -o | --nomfa)
            installTOTP=false
            installDuo=false
            ;;
    esac
    shift
done

if [[ -z "${installTOTP}" ]] && [[ "${installDuo}" != true ]]; then
    # Solicita ao usuário se deseja instalar MFA TOTP, padrão de não
    echo -e -n "${CYAN}MFA: Você gostaria de instalar TOTP (escolha 'N' se desejar Duo)? (y/N): ${NC}"
    read PROMPT
    if [[ ${PROMPT} =~ ^[Yy]$ ]]; then
        installTOTP=true
        installDuo=false
    else
        installTOTP=false
    fi
fi

if [[ -z "${installDuo}" ]] && [[ "${installTOTP}" != true ]]; then
    # Solicita ao usuário se deseja instalar MFA Duo, padrão de não
    echo -e -n "${CYAN}MFA: Você gostaria de instalar Duo (valores de configuração devem ser definidos após a instalação em /etc/guacamole/guacamole.properties)? (y/N): ${NC}"
    read PROMPT
    if [[ ${PROMPT} =~ ^[Yy]$ ]]; then
        installDuo=true
        installTOTP=false
    else
        installDuo=false
    fi
fi

# Não podemos instalar TOTP e Duo ao mesmo tempo...
if [[ "${installTOTP}" = true ]] && [ "${installDuo}" = true ]; then
    echo -e "${RED}ERROR: Você não pode instalar TOTP e Duo simultaneamente. Abortando...${NC}"
    exit 1
fi

# Define variáveis de instalação do MySQL para o valor padrão se não for fornecido
if [ -z "${installMySQL}" ]; then
    installMySQL=false
fi

# Se estivermos instalando o MySQL, precisamos garantir que todos os parâmetros estejam definidos
if [ "${installMySQL}" = true ]; then
    if [ -z "${mysqlHost}" ]; then
        read -p "Informe o endereço IP do servidor MySQL (press Enter para 'localhost'): " mysqlHost
        mysqlHost=${mysqlHost:-localhost}
    fi
    if [ -z "${mysqlPort}" ]; then
        read -p "Informe a porta do servidor MySQL (press Enter para '3306'): " mysqlPort
        mysqlPort=${mysqlPort:-3306}
    fi
    if [ -z "${mysqlRootPwd}" ]; then
        read -p "Informe a senha do usuário root do MySQL: " -s mysqlRootPwd
    fi
    echo
fi

# Define valores padrão se não estiverem definidos
if [ -z "${guacDb}" ]; then
    guacDb="guacamole_db"
fi
if [ -z "${guacUser}" ]; then
    guacUser="guacamole_user"
fi
if [ -z "${guacPwd}" ]; then
    guacPwd=$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-32};echo;)
    echo "Senha gerada automaticamente para o usuário Guacamole: ${guacPwd}"
fi

# Instala dependências
echo -e "${GREEN}Instalando dependências do sistema...${NC}"
apt-get update >> "${LOG}" 2>&1
apt-get install -yq \
    wget curl tar gnupg2 dpkg-dev debhelper devscripts \
    ghostscript tomcat9 freerdp2-x11 jq libcairo2-dev libjpeg-turbo8-dev libpng-dev \
    libtool-bin libossp-uuid-dev libvncserver-dev libpulse-dev libvorbis-dev \
    libwebp-dev libssl-dev libwebsockets-dev libmysql-java >> "${LOG}" 2>&1
echo -e "${GREEN}Dependências instaladas.${NC}"

# Baixa o código-fonte do Guacamole Server e do Cliente
echo -e "${GREEN}Baixando e compilando Guacamole Server ${GUACVERSION}...${NC}"
wget -O guacamole-server-${GUACVERSION}.tar.gz "https://downloads.apache.org/guacamole/${GUACVERSION}/source/guacamole-server-${GUACVERSION}.tar.gz" >> "${LOG}" 2>&1
tar -xzf guacamole-server-${GUACVERSION}.tar.gz >> "${LOG}" 2>&1
cd "guacamole-server-${GUACVERSION}" || exit
./configure --with-init-dir=/etc/init.d >> "${LOG}" 2>&1
make >> "${LOG}" 2>&1
make install >> "${LOG}" 2>&1
ldconfig >> "${LOG}" 2>&1
systemctl enable guacd >> "${LOG}" 2>&1
cd ..

# Baixa o arquivo Guacamole auth JDBC
echo -e "${GREEN}Baixando e compilando Guacamole auth JDBC ${GUACVERSION}...${NC}"
wget -O guacamole-auth-jdbc-${GUACVERSION}.tar.gz "https://downloads.apache.org/guacamole/${GUACVERSION}/source/guacamole-auth-jdbc-${GUACVERSION}.tar.gz" >> "${LOG}" 2>&1
tar -xzf guacamole-auth-jdbc-${GUACVERSION}.tar.gz >> "${LOG}" 2>&1
cd "guacamole-auth-jdbc-${GUACVERSION}/extensions/guacamole-auth-jdbc/modules/guacamole-auth-jdbc-mysql" || exit
mvn package >> "${LOG}" 2>&1
cp target/guacamole-auth-jdbc-mysql-${GUACVERSION}.jar /etc/guacamole/extensions/guacamole-auth-jdbc-mysql-${GUACVERSION}.jar >> "${LOG}" 2>&1

# Cria o arquivo Guacamole Properties
echo -e "${GREEN}Criando o arquivo de propriedades do Guacamole...${NC}"
cat << EOF > /etc/guacamole/guacamole.properties
mysql-hostname: ${mysqlHost}
mysql-port: ${mysqlPort}
mysql-database: ${guacDb}
mysql-username: ${guacUser}
mysql-password: ${guacPwd}
EOF

# Reinicia o serviço do Tomcat
systemctl restart tomcat9 >> "${LOG}" 2>&1

# Confirmação da Instalação
echo -e "${GREEN}Instalação do Guacamole e do MySQL Connector/J concluída com sucesso!${NC}"
