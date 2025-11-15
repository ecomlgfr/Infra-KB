#!/usr/bin/env bash

set -euo pipefail

 

###############################################################################

# INSTALLATION MARIADB GALERA CLUSTER - KeyBuzz Standards

###############################################################################

# Auteur: Claude AI Assistant

# Date: 2025-11-13

# Version: 2.0

#

# Description:

#   Installation complète d'un cluster MariaDB Galera 3 noeuds avec :

#   - XFS filesystem sur /opt/keybuzz/mariadb/data

#   - UFW configuré avec tous les ports nécessaires

#   - SST via xtrabackup-v2 (pas rsync)

#   - Monitoring ProxySQL

#   - mysqld_exporter pour Prometheus

#   - Intégration avec Hetzner LB 10.0.0.10:6033

#

# Topologie:

#   DB01: 10.0.0.101

#   DB02: 10.0.0.102

#   DB03: 10.0.0.103

#

# Usage:

#   1. Exécuter sur chaque noeud DB01, DB02, DB03

#   2. Répondre aux questions interactives

#   3. Bootstrap sur DB01 uniquement

###############################################################################

 

OK='\033[0;32m✓\033[0m'

KO='\033[0;31m✗\033[0m'

WARN='\033[0;33m⚠\033[0m'

INFO='\033[0;36mℹ\033[0m'

 

###############################################################################

# CONFIGURATION

###############################################################################

 

# Versions

MARIADB_VERSION="10.11"

XTRABACKUP_VERSION="latest"

 

# Topology

declare -A NODES=(

    ["DB01"]="10.0.0.101"

    ["DB02"]="10.0.0.102"

    ["DB03"]="10.0.0.103"

)

 

CLUSTER_NAME="keybuzz_galera_cluster"

WSREP_CLUSTER_ADDRESS="gcomm://10.0.0.101,10.0.0.102,10.0.0.103"

 

# Paths

DATA_DIR="/opt/keybuzz/mariadb/data"

LOG_DIR="/opt/keybuzz/mariadb/logs"

BACKUP_DIR="/opt/keybuzz/mariadb/backups"

CONFIG_FILE="/etc/mysql/mariadb.conf.d/60-galera.cnf"

 

# Credentials (à modifier en production)

MYSQL_ROOT_PASSWORD="ChangeMe_RootPass_$(openssl rand -hex 8)"

SST_USER="sst_user"

SST_PASSWORD="ChangeMe_SSTPass_$(openssl rand -hex 8)"

PROXYSQL_MONITOR_USER="proxysql-cluster"

PROXYSQL_MONITOR_PASSWORD="ChangeMe_ProxyPass_$(openssl rand -hex 8)"

ERPNEXT_USER="erpnext"

ERPNEXT_PASSWORD="ChangeMe_ERPPass_$(openssl rand -hex 8)"

EXPORTER_USER="mysqld_exporter"

EXPORTER_PASSWORD="ChangeMe_ExportPass_$(openssl rand -hex 8)"

 

# UFW Ports

UFW_PORTS_TCP=(22 3306 4444 4567 4568 9104)

UFW_PORTS_UDP=(4567)

 

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

 

    for node in "${!NODES[@]}"; do

        if [[ "${NODES[$node]}" == "$ip" ]]; then

            NODE_NAME="$node"

            NODE_IP="$ip"

            break

        fi

    done

 

    if [[ -z "$NODE_NAME" ]]; then

        log "${WARN} IP actuelle ($ip) ne correspond à aucun noeud de la topologie"

        echo ""

        echo "Choisissez le noeud :"

        echo "  1) DB01 (10.0.0.101)"

        echo "  2) DB02 (10.0.0.102)"

        echo "  3) DB03 (10.0.0.103)"

        read -p "Votre choix [1-3]: " choice

 

        case $choice in

            1) NODE_NAME="DB01"; NODE_IP="10.0.0.101" ;;

            2) NODE_NAME="DB02"; NODE_IP="10.0.0.102" ;;

            3) NODE_NAME="DB03"; NODE_IP="10.0.0.103" ;;

            *) error_exit "Choix invalide" ;;

        esac

    fi

 

    log "${OK} Noeud détecté: $NODE_NAME ($NODE_IP)"

}

 

setup_xfs_volume() {

    log "${INFO} Configuration du volume XFS pour MariaDB..."

 

    # Détecter le disque de données

    echo ""

    echo "Disques disponibles:"

    lsblk -d -n -o NAME,SIZE,TYPE | grep disk

    echo ""

    read -p "Entrez le nom du disque pour MariaDB (ex: sdb, nvme1n1) [ENTER pour skip]: " DISK_NAME

 

    if [[ -z "$DISK_NAME" ]]; then

        log "${WARN} Configuration XFS skippée - utilisation du filesystem existant"

        mkdir -p "$DATA_DIR" "$LOG_DIR" "$BACKUP_DIR"

        return 0

    fi

 

    DISK_PATH="/dev/$DISK_NAME"

 

    if [[ ! -b "$DISK_PATH" ]]; then

        error_exit "Le disque $DISK_PATH n'existe pas"

    fi

 

    log "${WARN} ATTENTION: Toutes les données sur $DISK_PATH seront EFFACÉES!"

    read -p "Confirmer le formatage de $DISK_PATH ? (tapez 'YES' en majuscules): " confirm

 

    if [[ "$confirm" != "YES" ]]; then

        error_exit "Formatage annulé par l'utilisateur"

    fi

 

    # Arrêter MariaDB s'il tourne

    systemctl stop mariadb 2>/dev/null || true

 

    # Umount si déjà monté

    umount "$DATA_DIR" 2>/dev/null || true

 

    # Formatage XFS

    log "Formatage de $DISK_PATH en XFS..."

    wipefs -a "$DISK_PATH"

    mkfs.xfs -f -L mariadb_data "$DISK_PATH"

 

    # Création des répertoires

    mkdir -p "$DATA_DIR" "$LOG_DIR" "$BACKUP_DIR"

 

    # Montage

    mount "$DISK_PATH" "$DATA_DIR"

 

    # Ajout à /etc/fstab

    DISK_UUID=$(blkid -s UUID -o value "$DISK_PATH")

 

    if ! grep -q "$DISK_UUID" /etc/fstab; then

        echo "UUID=$DISK_UUID $DATA_DIR xfs defaults,noatime 0 2" >> /etc/fstab

        log "${OK} Entrée fstab ajoutée"

    fi

 

    # Permissions

    chown -R mysql:mysql "$DATA_DIR" "$LOG_DIR" "$BACKUP_DIR"

    chmod 750 "$DATA_DIR"

 

    log "${OK} Volume XFS configuré et monté sur $DATA_DIR"

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

        ufw allow "$port/tcp" comment "MariaDB Galera - TCP $port"

        log "  Port TCP $port autorisé"

    done

 

    # Ports UDP

    for port in "${UFW_PORTS_UDP[@]}"; do

        ufw allow "$port/udp" comment "MariaDB Galera - UDP $port"

        log "  Port UDP $port autorisé"

    done

 

    # Autoriser le réseau privé Hetzner (10.0.0.0/16)

    ufw allow from 10.0.0.0/16 comment "Hetzner Private Network"

 

    # Activation

    ufw --force enable

 

    log "${OK} UFW configuré et activé"

    ufw status verbose

}

 

install_mariadb() {

    log "${INFO} Installation de MariaDB $MARIADB_VERSION..."

 

    # Ajout du dépôt MariaDB

    apt-get update

    apt-get install -y software-properties-common curl

 

    curl -LsS https://r.mariadb.com/downloads/mariadb_repo_setup | \

        bash -s -- --mariadb-server-version="mariadb-$MARIADB_VERSION"

 

    # Installation des paquets

    export DEBIAN_FRONTEND=noninteractive

 

    apt-get update

    apt-get install -y \

        mariadb-server \

        mariadb-client \

        mariadb-backup \

        galera-4 \

        rsync \

        socat \

        percona-xtrabackup-80 \

        qpress

 

    # Arrêter MariaDB (sera reconfiguré)

    systemctl stop mariadb

 

    log "${OK} MariaDB installé"

}

 

initialize_datadir() {

    log "${INFO} Initialisation du répertoire de données..."

 

    # Backup de l'ancien datadir si existe

    if [[ -d "$DATA_DIR/mysql" ]]; then

        log "${WARN} Datadir existant détecté - backup en cours..."

        BACKUP_NAME="datadir_backup_$(date +%Y%m%d_%H%M%S)"

        mv "$DATA_DIR" "${BACKUP_DIR}/${BACKUP_NAME}"

        mkdir -p "$DATA_DIR"

    fi

 

    # Initialisation MySQL

    mysql_install_db \

        --user=mysql \

        --datadir="$DATA_DIR" \

        --skip-test-db

 

    chown -R mysql:mysql "$DATA_DIR"

 

    log "${OK} Datadir initialisé"

}

 

configure_galera() {

    log "${INFO} Configuration de Galera Cluster..."

 

    # Backup de la config existante

    if [[ -f "$CONFIG_FILE" ]]; then

        cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"

    fi

 

    # Déterminer le server-id (101, 102, 103)

    SERVER_ID="${NODE_IP##*.}"

 

    # Création de la configuration Galera

    cat > "$CONFIG_FILE" <<EOF

#

# Galera Cluster Configuration - $NODE_NAME

# Generated: $(date)

#

 

[mysqld]

# Basic Settings

server-id = $SERVER_ID

bind-address = 0.0.0.0

port = 3306

 

# Data Directory

datadir = $DATA_DIR

 

# Logging

log_error = $LOG_DIR/mariadb_error.log

slow_query_log = 1

slow_query_log_file = $LOG_DIR/mariadb_slow.log

long_query_time = 2

log_queries_not_using_indexes = 0

 

# Binary Logging (pour backup et réplication externe si besoin)

log_bin = $LOG_DIR/mariadb-bin

log_bin_index = $LOG_DIR/mariadb-bin.index

binlog_format = ROW

expire_logs_days = 7

max_binlog_size = 100M

 

# InnoDB Settings

innodb_buffer_pool_size = 2G

innodb_log_file_size = 512M

innodb_flush_log_at_trx_commit = 2

innodb_flush_method = O_DIRECT

innodb_file_per_table = 1

innodb_autoinc_lock_mode = 2

 

# Character Set

character_set_server = utf8mb4

collation_server = utf8mb4_unicode_ci

 

# Connection Settings

max_connections = 500

max_connect_errors = 1000000

max_allowed_packet = 256M

 

# Query Cache (désactivé pour Galera)

query_cache_size = 0

query_cache_type = 0

 

# Table Settings

table_open_cache = 4096

table_definition_cache = 2048

 

# Temp Tables

tmp_table_size = 128M

max_heap_table_size = 128M

 

# Thread Settings

thread_cache_size = 50

 

###############################################################################

# GALERA CLUSTER SETTINGS

###############################################################################

 

# Galera Provider Configuration

wsrep_on = ON

wsrep_provider = /usr/lib/galera/libgalera_smm.so

 

# Cluster Configuration

wsrep_cluster_name = "$CLUSTER_NAME"

wsrep_cluster_address = "$WSREP_CLUSTER_ADDRESS"

wsrep_node_name = "$NODE_NAME"

wsrep_node_address = "$NODE_IP"

 

# SST (State Snapshot Transfer) Configuration

wsrep_sst_method = xtrabackup-v2

wsrep_sst_auth = "$SST_USER:$SST_PASSWORD"

 

# Replication Configuration

wsrep_slave_threads = 4

wsrep_replicate_myisam = OFF

 

# Flow Control

wsrep_provider_options = "gcache.size=2G;gcache.page_size=1G"

 

# Certification

wsrep_certify_nonPK = ON

 

# Debug (mettre à OFF en production)

wsrep_debug = OFF

wsrep_log_conflicts = ON

 

# Notification script (optionnel)

# wsrep_notify_cmd = /usr/local/bin/galera_notify.sh

 

###############################################################################

# PERFORMANCE SCHEMA (pour monitoring)

###############################################################################

performance_schema = ON

performance_schema_max_table_instances = 400

performance_schema_max_table_handles = 400

 

EOF

 

    log "${OK} Configuration Galera créée: $CONFIG_FILE"

}

 

create_systemd_override() {

    log "${INFO} Configuration systemd pour MariaDB..."

 

    mkdir -p /etc/systemd/system/mariadb.service.d/

 

    cat > /etc/systemd/system/mariadb.service.d/override.conf <<EOF

[Service]

# Augmentation des limites

LimitNOFILE=65535

LimitNPROC=65535

 

# Restart automatique

Restart=on-failure

RestartSec=10s

 

# Security hardening

PrivateTmp=true

NoNewPrivileges=true

ProtectSystem=strict

ProtectHome=true

ReadWritePaths=$DATA_DIR $LOG_DIR $BACKUP_DIR

 

EOF

 

    systemctl daemon-reload

 

    log "${OK} Systemd override configuré"

}

 

create_galera_users() {

    log "${INFO} Création des utilisateurs MariaDB..."

 

    # Démarrage temporaire en mode bootstrap (pour la configuration initiale)

    if [[ ! -S /var/run/mysqld/mysqld.sock ]]; then

        log "Démarrage temporaire de MariaDB..."

        mysqld_safe --datadir="$DATA_DIR" --skip-networking --skip-grant-tables &

        MYSQLD_PID=$!

 

        # Attendre que MySQL soit prêt

        for i in {1..30}; do

            if mysqladmin ping --silent 2>/dev/null; then

                break

            fi

            sleep 1

        done

    fi

 

    # Configuration root password

    mysql <<EOF

FLUSH PRIVILEGES;

ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';

DELETE FROM mysql.user WHERE User='';

DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');

DROP DATABASE IF EXISTS test;

DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';

FLUSH PRIVILEGES;

EOF

 

    # Création des utilisateurs avec mot de passe root

    mysql -u root -p"$MYSQL_ROOT_PASSWORD" <<EOF

-- SST User (State Snapshot Transfer)

CREATE USER IF NOT EXISTS '$SST_USER'@'localhost' IDENTIFIED BY '$SST_PASSWORD';

GRANT RELOAD, LOCK TABLES, PROCESS, REPLICATION CLIENT ON *.* TO '$SST_USER'@'localhost';

 

-- ProxySQL Monitor User

CREATE USER IF NOT EXISTS '$PROXYSQL_MONITOR_USER'@'%' IDENTIFIED BY '$PROXYSQL_MONITOR_PASSWORD';

GRANT USAGE, REPLICATION CLIENT ON *.* TO '$PROXYSQL_MONITOR_USER'@'%';

 

-- mysqld_exporter User (Prometheus)

CREATE USER IF NOT EXISTS '$EXPORTER_USER'@'localhost' IDENTIFIED BY '$EXPORTER_PASSWORD';

GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO '$EXPORTER_USER'@'localhost';

 

-- ERPNext Database and User

CREATE DATABASE IF NOT EXISTS erpnext CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '$ERPNEXT_USER'@'%' IDENTIFIED BY '$ERPNEXT_PASSWORD';

GRANT ALL PRIVILEGES ON erpnext.* TO '$ERPNEXT_USER'@'%';

 

FLUSH PRIVILEGES;

EOF

 

    # Arrêt du mysqld temporaire

    if [[ -n "${MYSQLD_PID:-}" ]]; then

        kill "$MYSQLD_PID" 2>/dev/null || true

        wait "$MYSQLD_PID" 2>/dev/null || true

    fi

 

    log "${OK} Utilisateurs créés"

}

 

save_credentials() {

    log "${INFO} Sauvegarde des credentials..."

 

    CRED_FILE="/opt/keybuzz/mariadb/credentials_${NODE_NAME}.txt"

 

    cat > "$CRED_FILE" <<EOF

#######################################################################

# CREDENTIALS MARIADB GALERA - $NODE_NAME

# Généré: $(date)

# ATTENTION: Fichier sensible - à sécuriser!

#######################################################################

 

# MySQL Root

MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD"

 

# SST User (pour Galera replication)

SST_USER="$SST_USER"

SST_PASSWORD="$SST_PASSWORD"

 

# ProxySQL Monitor

PROXYSQL_MONITOR_USER="$PROXYSQL_MONITOR_USER"

PROXYSQL_MONITOR_PASSWORD="$PROXYSQL_MONITOR_PASSWORD"

 

# ERPNext Application

ERPNEXT_USER="$ERPNEXT_USER"

ERPNEXT_PASSWORD="$ERPNEXT_PASSWORD"

ERPNEXT_DATABASE="erpnext"

 

# mysqld_exporter (Prometheus)

EXPORTER_USER="$EXPORTER_USER"

EXPORTER_PASSWORD="$EXPORTER_PASSWORD"

 

# Connexion depuis les applications

MARIADB_LB_HOST="10.0.0.10"

MARIADB_LB_PORT="6033"

MARIADB_CONNECTION_STRING="mysql://$ERPNEXT_USER:$ERPNEXT_PASSWORD@10.0.0.10:6033/erpnext"

 

EOF

 

    chmod 600 "$CRED_FILE"

 

    log "${OK} Credentials sauvegardés: $CRED_FILE"

    log "${WARN} IMPORTANT: Copiez ce fichier dans un endroit sûr!"

}

 

install_mysqld_exporter() {

    log "${INFO} Installation de mysqld_exporter pour Prometheus..."

 

    # Téléchargement

    EXPORTER_VERSION="0.15.1"

    EXPORTER_URL="https://github.com/prometheus/mysqld_exporter/releases/download/v${EXPORTER_VERSION}/mysqld_exporter-${EXPORTER_VERSION}.linux-amd64.tar.gz"

 

    cd /tmp

    curl -LO "$EXPORTER_URL"

    tar xzf "mysqld_exporter-${EXPORTER_VERSION}.linux-amd64.tar.gz"

    mv "mysqld_exporter-${EXPORTER_VERSION}.linux-amd64/mysqld_exporter" /usr/local/bin/

    chmod +x /usr/local/bin/mysqld_exporter

    rm -rf "/tmp/mysqld_exporter-${EXPORTER_VERSION}.linux-amd64"*

 

    # Création du fichier de config

    cat > /etc/.mysqld_exporter.cnf <<EOF

[client]

user=$EXPORTER_USER

password=$EXPORTER_PASSWORD

host=localhost

port=3306

EOF

    chmod 600 /etc/.mysqld_exporter.cnf

 

    # Service systemd

    cat > /etc/systemd/system/mysqld_exporter.service <<EOF

[Unit]

Description=MySQL Exporter for Prometheus

After=mariadb.service

Wants=mariadb.service

 

[Service]

Type=simple

User=mysql

Group=mysql

ExecStart=/usr/local/bin/mysqld_exporter \\

    --config.my-cnf=/etc/.mysqld_exporter.cnf \\

    --web.listen-address=0.0.0.0:9104 \\

    --collect.info_schema.processlist \\

    --collect.info_schema.innodb_metrics \\

    --collect.global_status \\

    --collect.global_variables \\

    --collect.slave_status \\

    --collect.info_schema.tables \\

    --collect.perf_schema.tableiowaits \\

    --collect.perf_schema.tablelocks

 

Restart=always

RestartSec=10s

 

[Install]

WantedBy=multi-user.target

EOF

 

    systemctl daemon-reload

    systemctl enable mysqld_exporter

 

    log "${OK} mysqld_exporter installé (port 9104)"

}

 

display_next_steps() {

    echo ""

    echo "═══════════════════════════════════════════════════════════════════"

    echo "              INSTALLATION TERMINÉE - $NODE_NAME"

    echo "═══════════════════════════════════════════════════════════════════"

    echo ""

    log "${OK} MariaDB Galera installé et configuré sur $NODE_NAME ($NODE_IP)"

    echo ""

    echo "📋 PROCHAINES ÉTAPES:"

    echo ""

 

    if [[ "$NODE_NAME" == "DB01" ]]; then

        echo "  🔴 ÉTAPE 1 (sur DB01 UNIQUEMENT):"

        echo "     Bootstrapper le cluster Galera:"

        echo ""

        echo "     systemctl stop mariadb"

        echo "     galera_new_cluster"

        echo "     systemctl start mysqld_exporter"

        echo ""

        echo "  🟢 ÉTAPE 2 (sur DB02 et DB03):"

        echo "     Démarrer les noeuds suivants:"

        echo ""

        echo "     systemctl start mariadb"

        echo "     systemctl start mysqld_exporter"

        echo ""

    else

        echo "  ⚠️  IMPORTANT:"

        echo "     NE PAS démarrer ce noeud maintenant!"

        echo "     Attendre que DB01 soit bootstrappé en premier."

        echo ""

        echo "  Quand DB01 est prêt, exécuter:"

        echo ""

        echo "     systemctl start mariadb"

        echo "     systemctl start mysqld_exporter"

        echo ""

    fi

 

    echo "  🔍 ÉTAPE 3: Vérifier le cluster"

    echo "     mysql -u root -p -e \"SHOW STATUS LIKE 'wsrep_cluster_size';\""

    echo "     mysql -u root -p -e \"SHOW STATUS LIKE 'wsrep_ready';\""

    echo ""

    echo "═══════════════════════════════════════════════════════════════════"

    echo ""

    echo "📁 Fichiers importants:"

    echo "   • Credentials: /opt/keybuzz/mariadb/credentials_${NODE_NAME}.txt"

    echo "   • Config Galera: $CONFIG_FILE"

    echo "   • Data: $DATA_DIR"

    echo "   • Logs: $LOG_DIR"

    echo ""

    echo "🔌 Ports ouverts:"

    echo "   • 3306 (MySQL)"

    echo "   • 4444 (SST)"

    echo "   • 4567 (Galera Cluster)"

    echo "   • 4568 (IST)"

    echo "   • 9104 (mysqld_exporter)"

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

    echo "║       INSTALLATION MARIADB GALERA CLUSTER - KeyBuzz v2.0         ║"

    echo "║                                                                   ║"

    echo "╚═══════════════════════════════════════════════════════════════════╝"

    echo ""

 

    check_root

    detect_node

 

    echo ""

    log "${INFO} Configuration pour: $NODE_NAME ($NODE_IP)"

    echo ""

    read -p "Continuer l'installation ? (yes/NO): " confirm

    [[ "$confirm" != "yes" ]] && error_exit "Installation annulée"

 

    echo ""

    log "Début de l'installation..."

    echo ""

 

    # Étapes d'installation

    setup_xfs_volume

    configure_ufw

    install_mariadb

    initialize_datadir

    configure_galera

    create_systemd_override

    create_galera_users

    save_credentials

    install_mysqld_exporter

 

    display_next_steps

 

    log "${OK} Installation terminée avec succès!"

}

 

# Exécution

main "$@"
