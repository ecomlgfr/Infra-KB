# Infra-KB - Infrastructure Knowledge Base

Base de connaissances et configuration pour l'infrastructure Keybuzz.

## Structure du repository

```
Infra-KB/
├── .ssh-config/                 # Configuration SSH pour l'accès aux serveurs
│   ├── README.md               # Documentation complète SSH
│   ├── ssh_servers.json        # Liste des serveurs
│   ├── ssh_credentials.json.template  # Template de credentials
│   └── ssh_connect.py          # Script de connexion
│
└── opt/
    └── keybuzz-installer/      # Scripts et configurations d'installation
        ├── inventory/          # Inventaire Ansible
        ├── credentials/        # Credentials et secrets (gitignored)
        ├── apps/              # Configuration des applications
        ├── k8s-manifests/     # Manifests Kubernetes
        └── logs/              # Logs d'installation
```

## Démarrage rapide

### 1. Configuration SSH

Pour configurer l'accès SSH aux serveurs :

```bash
# Copier le template de credentials
cd .ssh-config
cp ssh_credentials.json.template ssh_credentials.json

# Éditer avec vos informations
nano ssh_credentials.json
```

Voir [.ssh-config/README.md](.ssh-config/README.md) pour la documentation complète.

### 2. Tester la connexion

```bash
# Lister les serveurs disponibles
python3 .ssh-config/ssh_connect.py list

# Tester la connexion à un serveur
python3 .ssh-config/ssh_connect.py test k3s-master-01

# Exécuter une commande
python3 .ssh-config/ssh_connect.py exec k3s-master-01 "hostname"
```

## Infrastructure

L'infrastructure Keybuzz comprend :

- **K3s Cluster** : 3 masters + 5 workers
- **Database Pool** : PostgreSQL avec Patroni (1 master + 2 slaves)
- **MariaDB Cluster** : 3 nœuds avec ProxySQL
- **HAProxy** : 2 load balancers
- **Redis Cluster** : 3 nœuds
- **RabbitMQ Cluster** : 3 nœuds
- **Storage** : MinIO + serveur de backup
- **Security** : Vault + SIEM
- **Monitoring** : Stack de monitoring
- **AI Stack** : LiteLLM + ML Platform + Qdrant
- **Applications** : N8n, Superset, ERPNext, Chatwoot, etc.

## Documentation

- **Configuration SSH** : [.ssh-config/README.md](.ssh-config/README.md)
- **Inventaire des serveurs** : [opt/keybuzz-installer/inventory/](opt/keybuzz-installer/inventory/)
- **Tests d'infrastructure** : [opt/keybuzz-installer/README_TESTS.md](opt/keybuzz-installer/README_TESTS.md)

## Utilisation avec Claude Code

Ce repository est configuré pour permettre à Claude Code de :

1. **Accéder aux serveurs** via SSH pour :
   - Diagnostiquer les problèmes
   - Récupérer des informations
   - Exécuter des commandes de maintenance

2. **Gérer l'infrastructure** :
   - Déployer des configurations
   - Mettre à jour des services
   - Surveiller l'état des systèmes

3. **Documenter les opérations** :
   - Conserver l'historique des changements
   - Documenter les procédures
   - Partager les connaissances

### Configuration pour Claude Code

1. Créez votre fichier `ssh_credentials.json` avec vos clés SSH
2. Claude Code utilisera ce fichier pour se connecter aux serveurs
3. Les commandes seront exécutées via le script `ssh_connect.py`

Exemple :
```bash
python3 .ssh-config/ssh_connect.py exec k3s-master-01 "kubectl get nodes"
```

## Sécurité

**IMPORTANT** : Les fichiers suivants ne sont **jamais** versionnés :

- `.ssh-config/ssh_credentials.json` (vos credentials SSH)
- Clés SSH privées (`*.pem`, `*.key`, `id_rsa`, etc.)
- Fichiers de credentials dans `opt/keybuzz-installer/credentials/`

Ces fichiers sont protégés par `.gitignore`.

## Groupes de serveurs

Les serveurs sont organisés en groupes logiques :

- **management** : Serveurs de gestion
- **k3s-masters** : Nœuds maîtres Kubernetes
- **k3s-workers** : Nœuds workers Kubernetes
- **db-pool** : Pool de bases de données PostgreSQL
- **haproxy-pool** : Load balancers
- **redis-pool** : Cluster Redis
- **queue-pool** : Cluster RabbitMQ
- **storage** : Stockage (MinIO, backup)
- **security** : Sécurité (Vault, SIEM)
- **monitoring** : Monitoring et observabilité
- **ai** : Stack IA (LiteLLM, ML Platform)
- **vector** : Base de données vectorielle (Qdrant)
- **apps** : Applications métier

Voir `opt/keybuzz-installer/inventory/inventory.ini` pour la liste complète.

## Contribution

Ce repository est maintenu pour la gestion de l'infrastructure Keybuzz.

Pour toute modification :

1. Créez une branche : `git checkout -b feature/ma-modification`
2. Commitez vos changements : `git commit -m "Description"`
3. Poussez la branche : `git push origin feature/ma-modification`
4. Créez une Pull Request

## Support

Pour toute question ou problème :

1. Consultez la documentation dans `.ssh-config/README.md`
2. Vérifiez les logs dans `opt/keybuzz-installer/logs/`
3. Consultez l'inventaire dans `opt/keybuzz-installer/inventory/`

## Licence

Propriétaire - Keybuzz Infrastructure
