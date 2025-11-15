#!/usr/bin/env bash

set -euo pipefail

 

###############################################################################

# INSTALLATION PROXYSQL - KeyBuzz Standards

###############################################################################

# Auteur: Claude AI Assistant

# Date: 2025-11-13

# Version: 2.0

#

# Description:

#   Installation complète de ProxySQL 2.x avec :

#   - Monitoring des backends MariaDB Galera

#   - Read/Write split

#   - Health checks automatiques

#   - Failover automatique

#   - Intégration avec Hetzner LB

#

# Topologie:

#   ProxySQL01: 10.0.0.104

#   ProxySQL02: 10.0.0.105

#   MariaDB Backends: 10.0.0.101, 10.0.0.102, 10.0.0.103

#   Hetzner LB: 10.0.0.10:6033 -> ProxySQL01:6033, ProxySQL02:6033

#

# Usage:

#   1. Installer MariaDB Galera sur les 3 noeuds DB d'abord

#   2. Exécuter ce script sur ProxySQL01 et ProxySQL02

#   3. Configurer le Hetzner LB pour pointer vers les 2 ProxySQL

###############################################################################

 

OK='\033[0;32m✓\033[0m'

KO='\033[0;31m✗\033[0m'

WARN='\033[0;33m⚠\033[0m'

INFO='\033[0;36mℹ\033[0m'

 

###############################################################################

# CONFIGURATION

###############################################################################

 

# Versions

PROXYSQL_VERSION="2.5.5"

 

# Topology

declare -A PROXYSQL_NODES=(

    ["PROXY01"]="10.0.0.104"

    ["PROXY02"]="10.0.0.105"

)

 

declare -A MARIADB_NODES=(

    ["DB01"]="10.0.0.101"

    ["DB02"]="10.0.0.102"

    ["DB03"]="10.0.0.103"

)

 

HETZNER_LB_IP="10.0.0.10"

HETZNER_LB_PORT="6033"

 

# ProxySQL Settings

PROXYSQL_ADMIN_USER="admin"

PROXYSQL_ADMIN_PASSWORD="ChangeMe_ProxyAdmin_$(openssl rand -hex 8)"

PROXYSQL_MONITOR_USER="proxysql-cluster"  # Doit correspondre à l'utilisateur créé dans MariaDB

PROXYSQL_MONITOR_PASSWORD=""  # Sera demandé interactivement

 

# Application User (ERPNext)

APP_USER="erpnext"

APP_PASSWORD=""  # Sera demandé interactivement

 

# Hostgroups

WRITER_HOSTGROUP=10

READER_HOSTGROUP=20

 

# Ports

PROXYSQL_MYSQL_PORT=6033

PROXYSQL_ADMIN_PORT=6032

 

# UFW Ports

UFW_PORTS_TCP=(22 6032 6033)

 

###############################################################################

# FONCTIONS

###############################################################################

 

log() {

    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] $1"

}

 

error_exit() {

    log "${KO} ERREUR: $1"

    exit 1

}

 

check_root() {

    if [[ $EUID -ne 0 ]]; then

        error_exit "Ce script doit être exécuté en tant que root"

    fi

}

 

detect_node() {

    local ip=$(hostname -I | awk '{print $1}')

    NODE_NAME=""

    NODE_IP=""

 

    for node in "${!PROXYSQL_NODES[@]}"; do

        if [[ "${PROXYSQL_NODES[$node]}" == "$ip" ]]; then

            NODE_NAME="$node"

            NODE_IP="$ip"

            break

        fi

    done

 

    if [[ -z "$NODE_NAME" ]]; then

        log "${WARN} IP actuelle ($ip) ne correspond à aucun noeud ProxySQL"

        echo ""

        echo "Choisissez le noeud :"

        echo "  1) PROXY01 (10.0.0.104)"

        echo "  2) PROXY02 (10.0.0.105)"

        read -p "Votre choix [1-2]: " choice

 

        case $choice in

            1) NODE_NAME="PROXY01"; NODE_IP="10.0.0.104" ;;

            2) NODE_NAME="PROXY02"; NODE_IP="10.0.0.105" ;;

            *) error_exit "Choix invalide" ;;

        esac

    fi

 

    log "${OK} Noeud détecté: $NODE_NAME ($NODE_IP)"

}

 

get_credentials() {

    log "${INFO} Récupération des credentials MariaDB..."

    echo ""

    echo "Les credentials suivants doivent correspondre à ceux générés lors de"

    echo "l'installation de MariaDB Galera (voir /opt/keybuzz/mariadb/credentials_*.txt)"

    echo ""

 

    # ProxySQL Monitor User

    read -p "ProxySQL Monitor User [$PROXYSQL_MONITOR_USER]: " input

    PROXYSQL_MONITOR_USER="${input:-$PROXYSQL_MONITOR_USER}"

 

    read -sp "ProxySQL Monitor Password: " PROXYSQL_MONITOR_PASSWORD

    echo ""

 

    if [[ -z "$PROXYSQL_MONITOR_PASSWORD" ]]; then

        error_exit "Le mot de passe monitor est requis"

    fi

 

    # Application User (ERPNext)

    read -p "Application User [$APP_USER]: " input

    APP_USER="${input:-$APP_USER}"

 

    read -sp "Application Password: " APP_PASSWORD

    echo ""

 

    if [[ -z "$APP_PASSWORD" ]]; then

        error_exit "Le mot de passe application est requis"

    fi

 

    log "${OK} Credentials récupérés"

}

 

configure_ufw() {

    log "${INFO} Configuration du pare-feu UFW..."

 

    # Installation UFW si nécessaire

    if ! command -v ufw &> /dev/null; then

        apt-get update

        apt-get install -y ufw

    fi

 

    # Reset UFW (prudence!)

    log "${WARN} Reset UFW - connexions SSH existantes peuvent être coupées!"

    ufw --force reset

 

    # Politique par défaut

    ufw default deny incoming

    ufw default allow outgoing

 

    # Ports TCP

    for port in "${UFW_PORTS_TCP[@]}"; do

        ufw allow "$port/tcp" comment "ProxySQL - TCP $port"

        log "  Port TCP $port autorisé"

    done

 

    # Autoriser le réseau privé Hetzner (10.0.0.0/16)

    ufw allow from 10.0.0.0/16 comment "Hetzner Private Network"

 

    # Activation

    ufw --force enable

 

    log "${OK} UFW configuré et activé"

    ufw status verbose

}

 

install_proxysql() {

    log "${INFO} Installation de ProxySQL $PROXYSQL_VERSION..."

 

    # Ajout du dépôt ProxySQL

    apt-get update

    apt-get install -y lsb-release wget gnupg2

 

    wget -O - 'https://repo.proxysql.com/ProxySQL/proxysql-2.5.x/repo_pub_key' | apt-key add -

 

    echo "deb https://repo.proxysql.com/ProxySQL/proxysql-2.5.x/$(lsb_release -sc)/ ./" | \

        tee /etc/apt/sources.list.d/proxysql.list

 

    # Installation

    apt-get update

    apt-get install -y proxysql mysql-client

 

    # Arrêter ProxySQL (sera reconfiguré)

    systemctl stop proxysql

 

    log "${OK} ProxySQL installé"

}

 

configure_proxysql() {

    log "${INFO} Configuration de ProxySQL..."

 

    # Backup de la config par défaut

    if [[ -f /etc/proxysql.cnf ]]; then

        cp /etc/proxysql.cnf /etc/proxysql.cnf.bak.$(date +%Y%m%d_%H%M%S)

    fi

 

    # Création de la configuration

    cat > /etc/proxysql.cnf <<EOF

#

# ProxySQL Configuration - $NODE_NAME

# Generated: $(date)

#

 

datadir="/var/lib/proxysql"

 

admin_variables=

{

    admin_credentials="$PROXYSQL_ADMIN_USER:$PROXYSQL_ADMIN_PASSWORD"

    mysql_ifaces="0.0.0.0:$PROXYSQL_ADMIN_PORT"

    refresh_interval=2000

    stats_credentials="stats:stats"

}

 

mysql_variables=

{

    threads=4

    max_connections=2048

    default_query_delay=0

    default_query_timeout=36000000

    have_compress=true

    poll_timeout=2000

    interfaces="0.0.0.0:$PROXYSQL_MYSQL_PORT"

    default_schema="information_schema"

    stacksize=1048576

    server_version="8.0.30"

    connect_timeout_server=3000

    monitor_username="$PROXYSQL_MONITOR_USER"

    monitor_password="$PROXYSQL_MONITOR_PASSWORD"

    monitor_history=600000

    monitor_connect_interval=60000

    monitor_ping_interval=10000

    monitor_read_only_interval=1500

    monitor_read_only_timeout=500

    ping_interval_server_msec=120000

    ping_timeout_server=500

    commands_stats=true

    sessions_sort=true

    connect_retries_on_failure=10

}

 

# MySQL Servers (backends MariaDB Galera)

mysql_servers=

(

EOF

 

    # Ajout des serveurs MariaDB

    local server_id=1

    for node in "${!MARIADB_NODES[@]}"; do

        local ip="${MARIADB_NODES[$node]}"

        cat >> /etc/proxysql.cnf <<EOF

    {

        address="$ip"

        port=3306

        hostgroup=$WRITER_HOSTGROUP

        max_connections=500

        comment="$node - Writer"

    },

    {

        address="$ip"

        port=3306

        hostgroup=$READER_HOSTGROUP

        max_connections=1000

        comment="$node - Reader"

    }$([ $server_id -lt ${#MARIADB_NODES[@]} ] && echo "," || echo "")

EOF

        ((server_id++))

    done

 

    cat >> /etc/proxysql.cnf <<EOF

)

 

# MySQL Users (application users)

mysql_users=

(

    {

        username="$APP_USER"

        password="$APP_PASSWORD"

        default_hostgroup=$WRITER_HOSTGROUP

        max_connections=200

        active=1

        comment="Application User - ERPNext"

    }

)

 

# Query Rules (read/write split)

mysql_query_rules=

(

    {

        rule_id=100

        active=1

        match_pattern="^SELECT.*FOR UPDATE"

        destination_hostgroup=$WRITER_HOSTGROUP

        apply=1

        comment="SELECT FOR UPDATE -> Writer"

    },

    {

        rule_id=200

        active=1

        match_pattern="^SELECT"

        destination_hostgroup=$READER_HOSTGROUP

        apply=1

        comment="SELECT -> Reader"

    },

    {

        rule_id=300

        active=1

        match_pattern=".*"

        destination_hostgroup=$WRITER_HOSTGROUP

        apply=1

        comment="Default -> Writer"

    }

)

 

# MySQL Replication Hostgroups (pour Galera)

mysql_galera_hostgroups=

(

    {

        writer_hostgroup=$WRITER_HOSTGROUP

        backup_writer_hostgroup=$WRITER_HOSTGROUP

        reader_hostgroup=$READER_HOSTGROUP

        offline_hostgroup=30

        max_writers=3

        writer_is_also_reader=1

        max_transactions_behind=30

        active=1

        comment="Galera Cluster Hostgroups"

    }

)

 

EOF

 

    log "${OK} Configuration ProxySQL créée"

}

 

start_proxysql() {

    log "${INFO} Démarrage de ProxySQL..."

 

    # Nettoyage de l'ancienne DB (si existe)

    rm -f /var/lib/proxysql/proxysql.db

 

    # Démarrage

    systemctl enable proxysql

    systemctl restart proxysql

 

    # Attendre que ProxySQL soit prêt

    for i in {1..30}; do

        if mysql -h 127.0.0.1 -P $PROXYSQL_ADMIN_PORT -u"$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASSWORD" \

            -e "SELECT 1" &>/dev/null; then

            log "${OK} ProxySQL démarré et prêt"

            return 0

        fi

        sleep 1

    done

 

    error_exit "ProxySQL n'a pas démarré correctement"

}

 

load_config_to_runtime() {

    log "${INFO} Chargement de la configuration dans le runtime..."

 

    mysql -h 127.0.0.1 -P $PROXYSQL_ADMIN_PORT -u"$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASSWORD" <<EOF

-- Charger la config depuis le fichier vers la mémoire

LOAD MYSQL SERVERS FROM CONFIG;

LOAD MYSQL USERS FROM CONFIG;

LOAD MYSQL QUERY RULES FROM CONFIG;

LOAD MYSQL VARIABLES FROM CONFIG;

LOAD ADMIN VARIABLES FROM CONFIG;

 

-- Charger de la mémoire vers le runtime

LOAD MYSQL SERVERS TO RUNTIME;

LOAD MYSQL USERS TO RUNTIME;

LOAD MYSQL QUERY RULES TO RUNTIME;

LOAD MYSQL VARIABLES TO RUNTIME;

LOAD ADMIN VARIABLES TO RUNTIME;

 

-- Sauvegarder sur disque

SAVE MYSQL SERVERS TO DISK;

SAVE MYSQL USERS TO DISK;

SAVE MYSQL QUERY RULES TO DISK;

SAVE MYSQL VARIABLES TO DISK;

SAVE ADMIN VARIABLES TO DISK;

EOF

 

    log "${OK} Configuration chargée"

}

 

verify_backends() {

    log "${INFO} Vérification de la connectivité aux backends MariaDB..."

 

    echo ""

    echo "État des serveurs MariaDB:"

    echo ""

 

    mysql -h 127.0.0.1 -P $PROXYSQL_ADMIN_PORT -u"$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASSWORD" \

        -e "SELECT hostgroup_id, hostname, port, status, Queries, Latency_us FROM stats_mysql_connection_pool ORDER BY hostgroup_id, hostname;"

 

    echo ""

    echo "Logs de monitoring:"

    echo ""

 

    mysql -h 127.0.0.1 -P $PROXYSQL_ADMIN_PORT -u"$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASSWORD" \

        -e "SELECT * FROM monitor.mysql_server_connect_log ORDER BY time_start_us DESC LIMIT 10;" 2>/dev/null || true

 

    echo ""

    echo "Health checks:"

    echo ""

 

    mysql -h 127.0.0.1 -P $PROXYSQL_ADMIN_PORT -u"$PROXYSQL_ADMIN_USER" -p"$PROXYSQL_ADMIN_PASSWORD" \

        -e "SELECT * FROM monitor.mysql_server_ping_log ORDER BY time_start_us DESC LIMIT 10;" 2>/dev/null || true

}

 

test_connection() {

    log "${INFO} Test de connexion applicative..."

 

    echo ""

    echo "Test connexion via ProxySQL (port $PROXYSQL_MYSQL_PORT):"

    echo ""

 

    if mysql -h 127.0.0.1 -P $PROXYSQL_MYSQL_PORT -u"$APP_USER" -p"$APP_PASSWORD" \

        -e "SELECT 'Connection OK' AS status, @@hostname AS backend_server, DATABASE() AS current_db;" 2>/dev/null; then

        log "${OK} Connexion applicative réussie"

    else

        log "${WARN} Connexion applicative échouée - vérifier les credentials"

    fi

}

 

save_credentials() {

    log "${INFO} Sauvegarde des credentials..."

 

    CRED_FILE="/opt/keybuzz/proxysql/credentials_${NODE_NAME}.txt"

    mkdir -p /opt/keybuzz/proxysql

 

    cat > "$CRED_FILE" <<EOF

#######################################################################

# CREDENTIALS PROXYSQL - $NODE_NAME

# Généré: $(date)

# ATTENTION: Fichier sensible - à sécuriser!

#######################################################################

 

# ProxySQL Admin

PROXYSQL_ADMIN_USER="$PROXYSQL_ADMIN_USER"

PROXYSQL_ADMIN_PASSWORD="$PROXYSQL_ADMIN_PASSWORD"

PROXYSQL_ADMIN_PORT=$PROXYSQL_ADMIN_PORT

 

# ProxySQL MySQL Interface

PROXYSQL_MYSQL_PORT=$PROXYSQL_MYSQL_PORT

 

# Application User

APP_USER="$APP_USER"

APP_PASSWORD="$APP_PASSWORD"

 

# Connexion Admin

mysql -h $NODE_IP -P $PROXYSQL_ADMIN_PORT -u$PROXYSQL_ADMIN_USER -p'$PROXYSQL_ADMIN_PASSWORD'

 

# Connexion Application (depuis les apps)

mysql -h $HETZNER_LB_IP -P $HETZNER_LB_PORT -u$APP_USER -p'$APP_PASSWORD' erpnext

 

# String de connexion pour ERPNext

DB_HOST="$HETZNER_LB_IP"

DB_PORT="$HETZNER_LB_PORT"

DB_NAME="erpnext"

DB_USER="$APP_USER"

DB_PASSWORD="$APP_PASSWORD"

 

# Connection String

mysql://$APP_USER:$APP_PASSWORD@$HETZNER_LB_IP:$HETZNER_LB_PORT/erpnext

 

EOF

 

    chmod 600 "$CRED_FILE"

 

    log "${OK} Credentials sauvegardés: $CRED_FILE"

}

 

display_next_steps() {

    echo ""

    echo "═══════════════════════════════════════════════════════════════════"

    echo "            INSTALLATION TERMINÉE - $NODE_NAME"

    echo "═══════════════════════════════════════════════════════════════════"

    echo ""

    log "${OK} ProxySQL installé et configuré sur $NODE_NAME ($NODE_IP)"

    echo ""

    echo "📋 PROCHAINES ÉTAPES:"

    echo ""

 

    if [[ "$NODE_NAME" == "PROXY01" ]]; then

        echo "  1️⃣  Installer ProxySQL sur PROXY02 (10.0.0.105)"

        echo "     Exécuter le même script sur le second noeud"

        echo ""

        echo "  2️⃣  Configurer le Hetzner Load Balancer"

        echo "     • Type: TCP"

        echo "     • Frontend: $HETZNER_LB_IP:$HETZNER_LB_PORT"

        echo "     • Backends:"

        echo "       - 10.0.0.104:$PROXYSQL_MYSQL_PORT (PROXY01)"

        echo "       - 10.0.0.105:$PROXYSQL_MYSQL_PORT (PROXY02)"

        echo "     • Health Check: TCP sur port $PROXYSQL_MYSQL_PORT"

        echo "     • Algorithm: Round Robin ou Least Connections"

        echo ""

    fi

 

    echo "  3️⃣  Vérifier la configuration ProxySQL"

    echo "     mysql -h $NODE_IP -P $PROXYSQL_ADMIN_PORT -u$PROXYSQL_ADMIN_USER -p'$PROXYSQL_ADMIN_PASSWORD'"

    echo ""

    echo "     Commandes utiles:"

    echo "     • SELECT * FROM mysql_servers;"

    echo "     • SELECT * FROM mysql_users;"

    echo "     • SELECT * FROM stats_mysql_connection_pool;"

    echo "     • SELECT * FROM stats_mysql_query_rules;"

    echo ""

    echo "  4️⃣  Tester la connexion depuis les applications"

    echo "     mysql -h $HETZNER_LB_IP -P $HETZNER_LB_PORT -u$APP_USER -p erpnext"

    echo ""

    echo "═══════════════════════════════════════════════════════════════════"

    echo ""

    echo "📁 Fichiers importants:"

    echo "   • Credentials: /opt/keybuzz/proxysql/credentials_${NODE_NAME}.txt"

    echo "   • Config: /etc/proxysql.cnf"

    echo "   • Data: /var/lib/proxysql"

    echo "   • Logs: /var/lib/proxysql/proxysql.log"

    echo ""

    echo "🔌 Ports:"

    echo "   • $PROXYSQL_MYSQL_PORT (MySQL Interface - pour applications)"

    echo "   • $PROXYSQL_ADMIN_PORT (Admin Interface - pour gestion)"

    echo ""

    echo "📊 Monitoring:"

    echo "   • Admin Stats: mysql -h 127.0.0.1 -P $PROXYSQL_ADMIN_PORT -u$PROXYSQL_ADMIN_USER -p"

    echo "   • Stats DB: USE stats;"

    echo "   • Monitor DB: USE monitor;"

    echo ""

    echo "🎯 Read/Write Split configuré:"

    echo "   • SELECT -> Hostgroup $READER_HOSTGROUP (tous les backends)"

    echo "   • INSERT/UPDATE/DELETE -> Hostgroup $WRITER_HOSTGROUP (tous les backends)"

    echo "   • SELECT FOR UPDATE -> Hostgroup $WRITER_HOSTGROUP"

    echo ""

    echo "═══════════════════════════════════════════════════════════════════"

    echo ""

}

 

###############################################################################

# MAIN

###############################################################################

 

main() {

    echo ""

    echo "╔═══════════════════════════════════════════════════════════════════╗"

    echo "║                                                                   ║"

    echo "║           INSTALLATION PROXYSQL - KeyBuzz v2.0                   ║"

    echo "║                                                                   ║"

    echo "╚═══════════════════════════════════════════════════════════════════╝"

    echo ""

 

    check_root

    detect_node

    get_credentials

 

    echo ""

    log "${INFO} Configuration pour: $NODE_NAME ($NODE_IP)"

    echo ""

    read -p "Continuer l'installation ? (yes/NO): " confirm

    [[ "$confirm" != "yes" ]] && error_exit "Installation annulée"

 

    echo ""

    log "Début de l'installation..."

    echo ""

 

    # Étapes d'installation

    configure_ufw

    install_proxysql

    configure_proxysql

    start_proxysql

    load_config_to_runtime

    sleep 5

    verify_backends

    test_connection

    save_credentials

 

    display_next_steps

 

    log "${OK} Installation terminée avec succès!"

}

 

# Exécution

main "$@"
