#!/usr/bin/env bash
set -u
set -o pipefail

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║    FIX CHATWOOT - Correction complète du déploiement              ║"
echo "╚════════════════════════════════════════════════════════════════════╝"

OK='\033[0;32mOK\033[0m'
KO='\033[0;31mKO\033[0m'
WARN='\033[0;33mWARN\033[0m'

SERVERS_TSV="/home/user/KB/inventory/servers.tsv"
CREDENTIALS_DIR="/home/user/KB/credentials"

[ ! -f "$SERVERS_TSV" ] && SERVERS_TSV="/opt/keybuzz-installer/inventory/servers.tsv"
[ ! -d "$CREDENTIALS_DIR" ] && CREDENTIALS_DIR="/opt/keybuzz-installer/credentials"

[ ! -f "$SERVERS_TSV" ] && { echo -e "$KO servers.tsv introuvable"; exit 1; }

# Récupérer IP du master K3s
IP_MASTER01=$(awk -F'\t' '$2=="k3s-master-01" {print $3}' "$SERVERS_TSV")
[ -z "$IP_MASTER01" ] && { echo -e "$KO IP k3s-master-01 introuvable"; exit 1; }

echo "Master K3s : $IP_MASTER01"

# Charger credentials
if [ -f "$CREDENTIALS_DIR/postgres.env" ]; then
    source "$CREDENTIALS_DIR/postgres.env"
else
    echo -e "$WARN PostgreSQL credentials non trouvés, utilisation valeur par défaut"
    POSTGRES_PASSWORD="keybuzz2025"
fi

if [ -f "$CREDENTIALS_DIR/redis.env" ]; then
    source "$CREDENTIALS_DIR/redis.env"
else
    echo -e "$WARN Redis credentials non trouvés, utilisation valeur par défaut"
    REDIS_PASSWORD="keybuzz2025"
fi

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 1: Diagnostic du problème actuel                        ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "État actuel des pods Chatwoot :"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get pods -n chatwoot -o wide" || true
echo ""

echo "Récupération des logs des pods Web crashés :"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl logs -n chatwoot -l component=web --tail=50 --all-containers=true 2>&1" || true
echo ""

read -p "Continuer avec la correction complète de Chatwoot ? (yes/NO) : " confirm
[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 2: Nettoyage complet                                    ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'CLEANUP'
# Supprimer toutes les ressources Chatwoot
kubectl delete daemonset chatwoot-web chatwoot-worker -n chatwoot 2>/dev/null || true
kubectl delete deployment chatwoot-web chatwoot-worker -n chatwoot 2>/dev/null || true
kubectl delete job chatwoot-db-migrate -n chatwoot 2>/dev/null || true
kubectl delete configmap -n chatwoot --all 2>/dev/null || true
echo "Attente suppression complète (15s)..."
sleep 15
CLEANUP

echo -e "$OK Nettoyage terminé"

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 3: Recréation des secrets (CORRIGÉS)                    ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Générer SECRET_KEY_BASE unique
CHATWOOT_SECRET_KEY=$(openssl rand -hex 64)

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<SECRETS
# Recréer le namespace
kubectl create namespace chatwoot 2>/dev/null || true
# Créer le secret avec TOUTES les variables nécessaires
kubectl delete secret chatwoot-secrets -n chatwoot 2>/dev/null || true
kubectl create secret generic chatwoot-secrets -n chatwoot \\
  --from-literal=POSTGRES_HOST="10.0.0.10" \\
  --from-literal=POSTGRES_PORT="6432" \\
  --from-literal=POSTGRES_DATABASE="chatwoot" \\
  --from-literal=POSTGRES_USERNAME="chatwoot" \\
  --from-literal=POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \\
  --from-literal=REDIS_URL="redis://:${REDIS_PASSWORD}@10.0.0.10:6379/0" \\
  --from-literal=SECRET_KEY_BASE="${CHATWOOT_SECRET_KEY}" \\
  --from-literal=RAILS_ENV="production" \\
  --from-literal=RAILS_LOG_TO_STDOUT="true" \\
  --from-literal=FORCE_SSL="false" \\
  --from-literal=REDIS_PASSWORD="${REDIS_PASSWORD}" \\
  --from-literal=FRONTEND_URL="http://chat.keybuzz.io" \\
  --from-literal=INSTALLATION_ENV="docker"
SECRETS

echo -e "$OK Secrets recréés avec configuration corrigée"

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 4: Migration base de données                            ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'MIGRATE'
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: chatwoot-db-migrate
  namespace: chatwoot
spec:
  backoffLimit: 5
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: db-migrate
        image: chatwoot/chatwoot:latest
        command:
        - /bin/sh
        - -c
        - |
          set -e
          echo "=== Chatwoot Database Migration ==="
          echo "PostgreSQL: $POSTGRES_HOST:$POSTGRES_PORT"
          echo "Database: $POSTGRES_DATABASE"
          echo "User: $POSTGRES_USERNAME"
          # Test connection first
          echo "Testing database connection..."
          PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USERNAME" -d "$POSTGRES_DATABASE" -c '\l' || {
            echo "ERROR: Cannot connect to database"
            exit 1
          }
          echo "Database connection OK"
          echo "Starting Rails migration..."
          bundle exec rails db:chatwoot_prepare
          echo "=== Migration completed successfully ==="
        env:
        - name: POSTGRES_HOST
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: POSTGRES_HOST
        - name: POSTGRES_PORT
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: POSTGRES_PORT
        - name: POSTGRES_DATABASE
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: POSTGRES_DATABASE
        - name: POSTGRES_USERNAME
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: POSTGRES_USERNAME
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: POSTGRES_PASSWORD
        - name: REDIS_URL
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: REDIS_URL
        - name: SECRET_KEY_BASE
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: SECRET_KEY_BASE
        - name: RAILS_ENV
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: RAILS_ENV
        - name: RAILS_LOG_TO_STDOUT
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: RAILS_LOG_TO_STDOUT
        - name: FORCE_SSL
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: FORCE_SSL
        - name: INSTALLATION_ENV
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: INSTALLATION_ENV
EOF
MIGRATE

echo "Attente de la migration (max 3 minutes)..."
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl wait --for=condition=complete --timeout=180s job/chatwoot-db-migrate -n chatwoot 2>&1" && echo -e "$OK Migration réussie" || {
    echo -e "$WARN Migration a échoué ou pris trop de temps"
    echo "Logs de la migration :"
    ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl logs -n chatwoot job/chatwoot-db-migrate --tail=100"
    read -p "Continuer malgré l'échec de migration ? (yes/NO) : " continue_anyway
    [ "$continue_anyway" != "yes" ] && exit 1
}

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 5: Déploiement DaemonSet Chatwoot Web (CORRIGÉ)         ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'WEBDAEMONSET'
kubectl apply -f - <<'EOF'
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: chatwoot-web
  namespace: chatwoot
  labels:
    app: chatwoot
    component: web
spec:
  selector:
    matchLabels:
      app: chatwoot
      component: web
  template:
    metadata:
      labels:
        app: chatwoot
        component: web
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
      - name: chatwoot-web
        image: chatwoot/chatwoot:latest
        ports:
        - containerPort: 3000
          hostPort: 3000
        command:
        - /bin/sh
        - -c
        - |
          echo "=== Starting Chatwoot Web Server ==="
          echo "Rails environment: $RAILS_ENV"
          echo "PostgreSQL: $POSTGRES_HOST:$POSTGRES_PORT"
          echo "Redis URL configured: ${REDIS_URL%%@*}@..."
          echo "Frontend URL: $FRONTEND_URL"
          # Start Rails server
          bundle exec rails server -b 0.0.0.0 -p 3000
        env:
        - name: POSTGRES_HOST
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: POSTGRES_HOST
        - name: POSTGRES_PORT
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: POSTGRES_PORT
        - name: POSTGRES_DATABASE
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: POSTGRES_DATABASE
        - name: POSTGRES_USERNAME
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: POSTGRES_USERNAME
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: POSTGRES_PASSWORD
        - name: REDIS_URL
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: REDIS_URL
        - name: REDIS_PASSWORD
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: REDIS_PASSWORD
        - name: SECRET_KEY_BASE
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: SECRET_KEY_BASE
        - name: RAILS_ENV
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: RAILS_ENV
        - name: RAILS_LOG_TO_STDOUT
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: RAILS_LOG_TO_STDOUT
        - name: FORCE_SSL
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: FORCE_SSL
        - name: FRONTEND_URL
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: FRONTEND_URL
        - name: INSTALLATION_ENV
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: INSTALLATION_ENV
        - name: LOG_LEVEL
          value: "info"
        - name: RAILS_MAX_THREADS
          value: "5"
        resources:
          requests:
            memory: "512Mi"
            cpu: "200m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
        readinessProbe:
          httpGet:
            path: /
            port: 3000
          initialDelaySeconds: 60
          periodSeconds: 15
          timeoutSeconds: 10
          failureThreshold: 5
        livenessProbe:
          httpGet:
            path: /
            port: 3000
          initialDelaySeconds: 90
          periodSeconds: 30
          timeoutSeconds: 10
          failureThreshold: 3
EOF
WEBDAEMONSET

echo -e "$OK DaemonSet Web déployé"

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 6: Déploiement DaemonSet Chatwoot Worker (CORRIGÉ)      ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'WORKERDAEMONSET'
kubectl apply -f - <<'EOF'
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: chatwoot-worker
  namespace: chatwoot
  labels:
    app: chatwoot
    component: worker
spec:
  selector:
    matchLabels:
      app: chatwoot
      component: worker
  template:
    metadata:
      labels:
        app: chatwoot
        component: worker
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
      - name: chatwoot-worker
        image: chatwoot/chatwoot:latest
        command:
        - /bin/sh
        - -c
        - |
          echo "=== Starting Chatwoot Sidekiq Worker ==="
          echo "Rails environment: $RAILS_ENV"
          echo "PostgreSQL: $POSTGRES_HOST:$POSTGRES_PORT"
          echo "Redis URL configured"
          # Start Sidekiq
          bundle exec sidekiq -C config/sidekiq.yml
        env:
        - name: POSTGRES_HOST
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: POSTGRES_HOST
        - name: POSTGRES_PORT
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: POSTGRES_PORT
        - name: POSTGRES_DATABASE
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: POSTGRES_DATABASE
        - name: POSTGRES_USERNAME
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: POSTGRES_USERNAME
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: POSTGRES_PASSWORD
        - name: REDIS_URL
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: REDIS_URL
        - name: REDIS_PASSWORD
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: REDIS_PASSWORD
        - name: SECRET_KEY_BASE
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: SECRET_KEY_BASE
        - name: RAILS_ENV
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: RAILS_ENV
        - name: RAILS_LOG_TO_STDOUT
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: RAILS_LOG_TO_STDOUT
        - name: INSTALLATION_ENV
          valueFrom:
            secretKeyRef:
              name: chatwoot-secrets
              key: INSTALLATION_ENV
        resources:
          requests:
            memory: "512Mi"
            cpu: "200m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
EOF
WORKERDAEMONSET

echo -e "$OK DaemonSet Worker déployé"

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 7: Configuration Services et Ingress                    ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" bash <<'SERVICEINGRESS'
kubectl apply -f - <<'EOF'
---
apiVersion: v1
kind: Service
metadata:
  name: chatwoot
  namespace: chatwoot
spec:
  selector:
    app: chatwoot
    component: web
  ports:
  - port: 3000
    targetPort: 3000
  type: ClusterIP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: chatwoot
  namespace: chatwoot
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/proxy-body-size: "100m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "300"
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "300"
spec:
  ingressClassName: nginx
  rules:
  - host: chat.keybuzz.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: chatwoot
            port:
              number: 3000
EOF
SERVICEINGRESS

echo -e "$OK Services et Ingress configurés"

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║ ÉTAPE 8: Attente et vérification (2 minutes)                  ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "Attente du démarrage des pods (120s)..."
sleep 120

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "ÉTAT FINAL DES PODS CHATWOOT"
echo "═══════════════════════════════════════════════════════════════════"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get pods -n chatwoot -o wide"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "LOGS DES PODS WEB (dernières 30 lignes)"
echo "═══════════════════════════════════════════════════════════════════"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl logs -n chatwoot -l component=web --tail=30 --all-containers=true 2>&1" || true

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "SERVICES ET INGRESS"
echo "═══════════════════════════════════════════════════════════════════"
ssh -o StrictHostKeyChecking=no root@"$IP_MASTER01" "kubectl get svc,ingress -n chatwoot"

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                    CORRECTION TERMINÉE                         ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "📱 URL d'accès : http://chat.keybuzz.io"
echo ""
echo "🔍 Commandes de diagnostic :"
echo "  # Voir l'état des pods"
echo "  kubectl get pods -n chatwoot -o wide"
echo ""
echo "  # Voir les logs Web"
echo "  kubectl logs -n chatwoot -l component=web --tail=100 -f"
echo ""
echo "  # Voir les logs Worker"
echo "  kubectl logs -n chatwoot -l component=worker --tail=100 -f"
echo ""
echo "  # Voir les logs de migration"
echo "  kubectl logs -n chatwoot job/chatwoot-db-migrate"
echo ""
echo "  # Tester la connexion"
echo "  curl -I http://chat.keybuzz.io"
echo ""
echo "🎯 Prochaines étapes :"
echo "  1. Vérifier que tous les pods sont en état 'Running'"
echo "  2. Accéder à http://chat.keybuzz.io"
echo "  3. Créer le premier compte (sera automatiquement admin)"
echo "  4. Configurer votre workspace Chatwoot"
echo ""
echo "Architecture utilisée :"
echo "  ✓ DaemonSet avec hostNetwork"
echo "  ✓ PostgreSQL via PgBouncer (10.0.0.10:6432)"
echo "  ✓ Redis via Sentinel (10.0.0.10:6379)"
echo "  ✓ 5 pods Web (1 par worker K3s)"
echo "  ✓ 5 pods Worker (1 par worker K3s)"
echo ""

exit 0
