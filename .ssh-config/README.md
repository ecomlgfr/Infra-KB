# Configuration SSH pour l'Infrastructure Keybuzz

Ce dossier contient la configuration nécessaire pour permettre l'accès SSH aux serveurs de l'infrastructure.

## Structure des fichiers

```
.ssh-config/
├── README.md                          # Ce fichier
├── ssh_servers.json                   # Liste des serveurs (VERSIONNÉ)
├── ssh_credentials.json.template      # Template de credentials (VERSIONNÉ)
├── ssh_credentials.json               # Vos credentials (NON VERSIONNÉ)
├── ssh_connect.py                     # Script de connexion Python
└── .gitignore                         # Protection des credentials
```

## Configuration initiale

### 1. Créer votre fichier de credentials

Copiez le template et remplissez vos informations :

```bash
cd .ssh-config
cp ssh_credentials.json.template ssh_credentials.json
```

### 2. Éditer ssh_credentials.json

Modifiez le fichier avec vos informations :

```json
{
  "default": {
    "ssh_key_path": "/home/votre-user/.ssh/id_rsa",
    "ssh_key_passphrase": null,
    "port": 22,
    "connect_via": "ip_public",
    "known_hosts_policy": "auto_add"
  },
  "server_overrides": {
    "exemple-serveur-specifique": {
      "ssh_key_path": "/chemin/vers/cle/specifique",
      "port": 2222,
      "connect_via": "ip_wireguard"
    }
  }
}
```

#### Options de configuration

**connect_via** :
- `ip_public` : Connexion via l'IP publique (par défaut)
- `ip_wireguard` : Connexion via l'IP WireGuard (réseau privé)
- `fqdn` : Connexion via le nom de domaine complet

**known_hosts_policy** :
- `auto_add` : Ajoute automatiquement les clés d'hôte
- `strict` : Vérifie strictement les clés d'hôte
- `ignore` : Ignore la vérification des clés d'hôte (NON RECOMMANDÉ)

### 3. Configurer vos clés SSH

Si vous n'avez pas encore de clé SSH :

```bash
# Générer une paire de clés ED25519 (recommandé)
ssh-keygen -t ed25519 -C "votre-email@exemple.com"

# OU générer une paire de clés RSA 4096
ssh-keygen -t rsa -b 4096 -C "votre-email@exemple.com"
```

### 4. Copier votre clé publique sur les serveurs

```bash
# Pour un serveur spécifique
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@91.98.124.228

# OU manuellement
cat ~/.ssh/id_ed25519.pub | ssh root@91.98.124.228 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
```

## Utilisation du script SSH

### Lister les serveurs disponibles

```bash
python3 .ssh-config/ssh_connect.py list
```

### Lister les groupes de serveurs

```bash
python3 .ssh-config/ssh_connect.py groups
```

### Tester la connexion à un serveur

```bash
python3 .ssh-config/ssh_connect.py test k3s-master-01
```

### Exécuter une commande sur un serveur

```bash
python3 .ssh-config/ssh_connect.py exec k3s-master-01 "hostname && uptime"
```

### Exemples de commandes utiles

```bash
# Vérifier l'uptime
python3 .ssh-config/ssh_connect.py exec k3s-master-01 "uptime"

# Vérifier l'espace disque
python3 .ssh-config/ssh_connect.py exec db-master-01 "df -h"

# Vérifier la mémoire
python3 .ssh-config/ssh_connect.py exec haproxy-01 "free -h"

# Vérifier les services K3s
python3 .ssh-config/ssh_connect.py exec k3s-master-01 "systemctl status k3s"

# Lister les conteneurs Docker
python3 .ssh-config/ssh_connect.py exec install-01 "docker ps"
```

## Ajouter de nouveaux serveurs

Pour ajouter un nouveau serveur, éditez `ssh_servers.json` :

```json
{
  "servers": {
    "nouveau-serveur": {
      "hostname": "nouveau-serveur",
      "ip_public": "1.2.3.4",
      "ip_wireguard": "10.0.0.200",
      "fqdn": "nouveau.keybuzz.io",
      "user": "root",
      "group": "nom-du-groupe",
      "description": "Description du serveur"
    }
  }
}
```

## Intégration avec Claude Code

Pour permettre à Claude Code de se connecter aux serveurs :

1. Assurez-vous que `ssh_credentials.json` est correctement configuré
2. Le fichier contient le chemin vers votre clé SSH privée
3. Claude Code pourra utiliser le script `ssh_connect.py` pour :
   - Tester les connexions
   - Exécuter des commandes de diagnostic
   - Récupérer des informations sur l'infrastructure
   - Déployer des configurations

### Exemples d'utilisation par Claude Code

Claude Code peut exécuter :

```bash
# Diagnostic complet d'un serveur
python3 .ssh-config/ssh_connect.py exec k3s-master-01 "
  echo '=== System Info ===' &&
  uname -a &&
  echo '=== Uptime ===' &&
  uptime &&
  echo '=== Disk Usage ===' &&
  df -h
"

# Vérifier l'état du cluster K3s
python3 .ssh-config/ssh_connect.py exec k3s-master-01 "kubectl get nodes"

# Vérifier les pods
python3 .ssh-config/ssh_connect.py exec k3s-master-01 "kubectl get pods -A"
```

## Sécurité

### Fichiers protégés par .gitignore

Les fichiers suivants ne sont **jamais** versionnés :

- `ssh_credentials.json` (vos credentials réels)
- `*.pem`, `*.key` (clés SSH)
- `id_rsa`, `id_ed25519` (clés SSH)
- `*.log` (fichiers de log)

### Bonnes pratiques

1. **Ne jamais committer de credentials** : Le fichier `ssh_credentials.json` est dans `.gitignore`
2. **Utiliser des clés SSH** : Éviter les mots de passe
3. **Protéger vos clés privées** : `chmod 600 ~/.ssh/id_rsa`
4. **Utiliser WireGuard quand possible** : Plus sécurisé que l'exposition publique
5. **Rotation régulière des clés** : Changer les clés tous les 6-12 mois

## Dépannage

### Erreur : "Permission denied (publickey)"

1. Vérifiez que votre clé publique est bien sur le serveur :
   ```bash
   ssh root@serveur "cat ~/.ssh/authorized_keys"
   ```

2. Vérifiez les permissions de votre clé privée :
   ```bash
   chmod 600 ~/.ssh/id_rsa
   ```

### Erreur : "Connection timeout"

1. Vérifiez que le serveur est accessible :
   ```bash
   ping -c 3 91.98.124.228
   ```

2. Vérifiez que le pare-feu autorise SSH (port 22)

### Erreur : "Host key verification failed"

1. Supprimez l'ancienne clé d'hôte :
   ```bash
   ssh-keygen -R 91.98.124.228
   ```

2. Reconnectez-vous pour ajouter la nouvelle clé

## Support

Pour toute question ou problème :

1. Vérifiez la documentation dans ce README
2. Consultez les logs d'erreur du script Python
3. Testez la connexion SSH manuelle :
   ```bash
   ssh -v root@91.98.124.228
   ```

## Serveurs disponibles

Consultez `ssh_servers.json` pour la liste complète et à jour des serveurs.

### Groupes principaux

- **k3s-masters** : Nœuds maîtres Kubernetes
- **k3s-workers** : Nœuds workers Kubernetes
- **db-pool** : Pool de bases de données
- **haproxy-pool** : Load balancers HAProxy
- **management** : Serveurs de gestion et d'installation

## Licence

Propriétaire - Keybuzz Infrastructure
