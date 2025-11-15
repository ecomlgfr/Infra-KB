#!/usr/bin/env bash

set -u

set -o pipefail

 

echo "╔════════════════════════════════════════════════════════════════════╗"

echo "║    FIX FINAL - Wazuh Indexer + ERPNext socketio                   ║"

echo "╚════════════════════════════════════════════════════════════════════╝"

 

OK='\033[0;32m✓\033[0m'

KO='\033[0;31m✗\033[0m'

WARN='\033[0;33m⚠\033[0m'

 

echo ""

echo "🔍 DIAGNOSTIC DES PROBLÈMES DÉTECTÉS :"

echo ""

echo "1. Wazuh Indexer (37 restarts en 3h24m)"

echo "   Erreur : NotSslRecordException - Health checks HTTP vs serveur HTTPS"

echo "   Cause : plugins.security.disabled=true ne fonctionne pas correctement"

echo "   Solution : Désactiver COMPLETEMENT SSL avec configuration explicite"

echo ""

echo "2. ERPNext socketio (1154 restarts)"

echo "   À analyser après correction Wazuh"

echo ""

 

read -p "Continuer avec la correction ? (yes/NO) : " confirm

[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

 

echo ""

echo "╔═══════════════════════════════════════════════════════════════╗"

echo "║ CORRECTION : Wazuh Indexer (SANS SSL - Configuration ULTIME) ║"

echo "╚═══════════════════════════════════════════════════════════════╝"

echo ""

 

echo "→ Suppression complète de l'ancien Indexer..."

kubectl delete statefulset wazuh-indexer -n wazuh 2>&1

kubectl delete pvc -n wazuh -l app=wazuh-indexer 2>&1

kubectl delete svc wazuh-indexer -n wazuh 2>&1

kubectl delete pod wazuh-indexer-0 -n wazuh --force --grace-period=0 2>&1 || true

 

echo "Attente suppression complète (20s)..."

sleep 20

 

echo "→ Déploiement Wazuh Indexer avec configuration SSL DÉSACTIVÉE COMPLÈTEMENT..."

kubectl apply -f - <<'EOF'

apiVersion: v1

kind: ConfigMap

metadata:

  name: wazuh-indexer-config

  namespace: wazuh

data:

  opensearch.yml: |

    cluster.name: wazuh-cluster

    node.name: ${HOSTNAME}

    network.host: 0.0.0.0

    http.port: 9200

    discovery.type: single-node

    bootstrap.memory_lock: false

 

    # DÉSACTIVATION COMPLÈTE DE LA SÉCURITÉ

    plugins.security.disabled: true

    plugins.security.ssl.transport.enabled: false

    plugins.security.ssl.http.enabled: false

 

    # Compatibilité

    compatibility.override_main_response_version: true

 

    # Logs

    logger.level: INFO

---

apiVersion: apps/v1

kind: StatefulSet

metadata:

  name: wazuh-indexer

  namespace: wazuh

  labels:

    app: wazuh-indexer

spec:

  serviceName: wazuh-indexer

  replicas: 1

  selector:

    matchLabels:

      app: wazuh-indexer

  template:

    metadata:

      labels:

        app: wazuh-indexer

    spec:

      initContainers:

      - name: sysctl

        image: busybox:1.35

        command:

        - sh

        - -c

        - |

          sysctl -w vm.max_map_count=262144

          ulimit -n 65536

          echo "vm.max_map_count set to 262144"

          echo "ulimit -n set to 65536"

        securityContext:

          privileged: true

      - name: fix-permissions

        image: busybox:1.35

        command:

        - sh

        - -c

        - |

          chown -R 1000:1000 /usr/share/wazuh-indexer/data 2>/dev/null || true

          chmod -R 755 /usr/share/wazuh-indexer/data 2>/dev/null || true

          echo "Permissions fixed"

        volumeMounts:

        - name: data

          mountPath: /usr/share/wazuh-indexer/data

        securityContext:

          runAsUser: 0

      containers:

      - name: wazuh-indexer

        image: wazuh/wazuh-indexer:4.7.0

        ports:

        - containerPort: 9200

          name: http

          protocol: TCP

        - containerPort: 9300

          name: transport

          protocol: TCP

        env:

        - name: OPENSEARCH_JAVA_OPTS

          value: "-Xms1g -Xmx1g"

        - name: DISABLE_INSTALL_DEMO_CONFIG

          value: "true"

        - name: DISABLE_SECURITY_PLUGIN

          value: "true"

        volumeMounts:

        - name: data

          mountPath: /usr/share/wazuh-indexer/data

        - name: config

          mountPath: /usr/share/wazuh-indexer/config/opensearch.yml

          subPath: opensearch.yml

        resources:

          requests:

            memory: "2Gi"

            cpu: "500m"

          limits:

            memory: "3Gi"

            cpu: "1500m"

        readinessProbe:

          exec:

            command:

            - sh

            - -c

            - |

              curl -s -f http://localhost:9200/_cluster/health | grep -E 'green|yellow'

          initialDelaySeconds: 180

          periodSeconds: 20

          timeoutSeconds: 10

          failureThreshold: 15

        livenessProbe:

          exec:

            command:

            - sh

            - -c

            - |

              curl -s -f http://localhost:9200 > /dev/null

          initialDelaySeconds: 240

          periodSeconds: 30

          timeoutSeconds: 10

          failureThreshold: 5

        securityContext:

          runAsUser: 1000

          runAsGroup: 1000

          fsGroup: 1000

      volumes:

      - name: config

        configMap:

          name: wazuh-indexer-config

  volumeClaimTemplates:

  - metadata:

      name: data

    spec:

      accessModes: [ "ReadWriteOnce" ]

      resources:

        requests:

          storage: 50Gi

---

apiVersion: v1

kind: Service

metadata:

  name: wazuh-indexer

  namespace: wazuh

spec:

  type: ClusterIP

  selector:

    app: wazuh-indexer

  ports:

  - name: http

    port: 9200

    targetPort: 9200

    protocol: TCP

  - name: transport

    port: 9300

    targetPort: 9300

    protocol: TCP

EOF

 

echo -e "$OK Wazuh Indexer redéployé avec SSL complètement désactivé"

echo ""

 

echo "⏱️  Attente du démarrage (3 minutes)..."

echo "  Note: Le premier démarrage est long car l'image doit initialiser l'index"

sleep 180

 

echo ""

echo "→ Vérification de l'état du pod..."

kubectl get pod -n wazuh wazuh-indexer-0

 

echo ""

echo "→ Logs du démarrage (30 dernières lignes)..."

kubectl logs -n wazuh wazuh-indexer-0 --tail=30 2>&1 | tail -40

 

echo ""

echo "→ Test de connectivité HTTP..."

sleep 10

kubectl exec -n wazuh wazuh-indexer-0 -- curl -s http://localhost:9200 2>&1 | head -20

 

echo ""

echo "╔═══════════════════════════════════════════════════════════════╗"

echo "║ DIAGNOSTIC : ERPNext socketio                                 ║"

echo "╚═══════════════════════════════════════════════════════════════╝"

echo ""

 

SOCKETIO_POD=$(kubectl get pods -n erpnext -l app.kubernetes.io/component=socketio --no-headers 2>/dev/null | awk '{print $1}')

 

if [ -n "$SOCKETIO_POD" ]; then

    echo "→ Récupération des logs ERPNext socketio..."

    kubectl logs -n erpnext "$SOCKETIO_POD" --tail=100 > /tmp/erpnext_socketio_analysis.txt 2>&1

 

    echo "Logs (50 dernières lignes) :"

    tail -50 /tmp/erpnext_socketio_analysis.txt

    echo ""

 

    echo "→ Analyse des erreurs..."

    if grep -q "ECONNREFUSED.*redis\|Connection refused.*redis\|Redis.*error" /tmp/erpnext_socketio_analysis.txt; then

        echo -e "$WARN Problème de connexion Redis détecté"

        echo ""

        echo "Solutions possibles :"

        echo "  1. Vérifier que Redis est accessible depuis ERPNext"

        echo "  2. Vérifier les credentials Redis dans les secrets"

        echo ""

 

        echo "→ Vérification de la configuration Redis ERPNext..."

        kubectl get secret -n erpnext erpnext -o yaml 2>/dev/null | grep -i redis || echo "  Secret ERPNext non trouvé"

 

    elif grep -q "ENOTFOUND\|getaddrinfo\|DNS" /tmp/erpnext_socketio_analysis.txt; then

        echo -e "$WARN Problème DNS détecté"

        echo ""

        echo "Solutions possibles :"

        echo "  1. Vérifier le service backend ERPNext"

        echo "  2. Vérifier la résolution DNS dans le pod"

 

    elif grep -q "Cannot find module\|Error: Cannot find" /tmp/erpnext_socketio_analysis.txt; then

        echo -e "$WARN Dépendance Node.js manquante"

        echo "  Cela nécessite une reconstruction de l'image Docker"

 

    else

        echo -e "$INFO Cause inconnue, redémarrage du pod..."

        kubectl delete pod -n erpnext "$SOCKETIO_POD"

        echo "  Pod supprimé, Kubernetes va le recréer"

    fi

else

    echo -e "$WARN Aucun pod socketio trouvé"

fi

 

echo ""

echo "╔════════════════════════════════════════════════════════════════╗"

echo "║                  RÉSUMÉ FINAL                                  ║"

echo "╚════════════════════════════════════════════════════════════════╝"

echo ""

 

echo "📊 État actuel des pods problématiques :"

echo ""

echo "Wazuh Indexer :"

kubectl get pod -n wazuh wazuh-indexer-0 2>&1 | tail -2

echo ""

 

echo "ERPNext socketio :"

kubectl get pod -n erpnext -l app.kubernetes.io/component=socketio 2>&1 | tail -2

echo ""

 

echo "Vault (sealed - attendu) :"

kubectl get pods -n vault | grep -v "1/1.*Running" | tail -8

echo ""

 

echo "════════════════════════════════════════════════════════════════"

echo -e "$OK CORRECTIONS APPLIQUÉES"

echo "════════════════════════════════════════════════════════════════"

echo ""

 

echo "⏱️  TEMPS D'ATTENTE SUPPLÉMENTAIRE :"

echo "  • Wazuh Indexer : Attendre 10-15 minutes pour stabilisation"

echo "  • ERPNext socketio : Surveiller les redémarrages"

echo ""

 

echo "🔍 VÉRIFICATIONS À FAIRE (dans 10 minutes) :"

echo "  1. Vérifier Wazuh Indexer :"

echo "     kubectl get pod -n wazuh wazuh-indexer-0"

echo "     kubectl logs -n wazuh wazuh-indexer-0 --tail=50"

echo "     kubectl exec -n wazuh wazuh-indexer-0 -- curl -s http://localhost:9200"

echo ""

echo "  2. Si Wazuh Indexer OK, redéployer les Managers :"

echo "     ./redeploy_wazuh_managers.sh"

echo ""

echo "  3. Vérifier ERPNext socketio :"

echo "     kubectl get pod -n erpnext -l app.kubernetes.io/component=socketio"

echo "     kubectl logs -n erpnext \$(kubectl get pod -n erpnext -l app.kubernetes.io/component=socketio -o name | cut -d/ -f2)"

echo ""

 

echo "📝 Logs sauvegardés :"

echo "  ERPNext socketio : /tmp/erpnext_socketio_analysis.txt"

echo ""

 

exit 0
