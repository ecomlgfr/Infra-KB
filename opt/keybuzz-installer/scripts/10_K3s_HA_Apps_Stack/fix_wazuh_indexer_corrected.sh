#!/usr/bin/env bash

set -u

set -o pipefail

 

echo "╔════════════════════════════════════════════════════════════════════╗"

echo "║    FIX WAZUH INDEXER - Version Corrigée (YAML valide)            ║"

echo "╚════════════════════════════════════════════════════════════════════╝"

 

OK='\033[0;32m✓\033[0m'

KO='\033[0;31m✗\033[0m'

WARN='\033[0;33m⚠\033[0m'

 

echo ""

echo "🔍 PROBLÈME IDENTIFIÉ :"

echo "  Erreur YAML : fsGroup mal placé dans le securityContext"

echo "  Solution : fsGroup doit être au niveau pod, pas container"

echo ""

 

read -p "Continuer avec la correction ? (yes/NO) : " confirm

[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

 

echo ""

echo "╔═══════════════════════════════════════════════════════════════╗"

echo "║ ÉTAPE 1 : Nettoyage complet                                   ║"

echo "╚═══════════════════════════════════════════════════════════════╝"

echo ""

 

echo "→ Suppression de toutes les ressources Wazuh Indexer..."

kubectl delete statefulset wazuh-indexer -n wazuh --ignore-not-found=true

kubectl delete pvc -n wazuh -l app=wazuh-indexer --ignore-not-found=true

kubectl delete svc wazuh-indexer -n wazuh --ignore-not-found=true

kubectl delete configmap wazuh-indexer-config -n wazuh --ignore-not-found=true

kubectl delete pod wazuh-indexer-0 -n wazuh --force --grace-period=0 2>/dev/null || true

 

echo "Attente suppression complète (20s)..."

sleep 20

 

echo ""

echo "╔═══════════════════════════════════════════════════════════════╗"

echo "║ ÉTAPE 2 : Déploiement avec YAML CORRIGÉ                       ║"

echo "╚═══════════════════════════════════════════════════════════════╝"

echo ""

 

echo "→ Création ConfigMap..."

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

EOF

 

echo -e "$OK ConfigMap créé"

 

echo ""

echo "→ Création Service..."

kubectl apply -f - <<'EOF'

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

 

echo -e "$OK Service créé"

 

echo ""

echo "→ Création StatefulSet (YAML corrigé)..."

kubectl apply -f - <<'EOF'

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

      # SecurityContext au niveau POD (pas container)

      securityContext:

        fsGroup: 1000

        runAsUser: 1000

        runAsGroup: 1000

 

      initContainers:

      # Init 1: Configuration système

      - name: sysctl

        image: busybox:1.35

        command:

        - sh

        - -c

        - |

          sysctl -w vm.max_map_count=262144

          ulimit -n 65536

          echo "✓ vm.max_map_count set to 262144"

          echo "✓ ulimit -n set to 65536"

        securityContext:

          privileged: true

 

      # Init 2: Fix permissions

      - name: fix-permissions

        image: busybox:1.35

        command:

        - sh

        - -c

        - |

          chown -R 1000:1000 /usr/share/wazuh-indexer/data 2>/dev/null || true

          chmod -R 755 /usr/share/wazuh-indexer/data 2>/dev/null || true

          echo "✓ Permissions fixed"

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

 

        # Health checks en mode EXEC (pas httpGet)

        readinessProbe:

          exec:

            command:

            - sh

            - -c

            - |

              curl -sf http://localhost:9200/_cluster/health | grep -E '"status":"(green|yellow)"'

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

              curl -sf http://localhost:9200 > /dev/null

          initialDelaySeconds: 240

          periodSeconds: 30

          timeoutSeconds: 10

          failureThreshold: 5

 

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

EOF

 

if [ $? -eq 0 ]; then

    echo -e "$OK StatefulSet créé avec succès"

else

    echo -e "$KO Erreur lors de la création du StatefulSet"

    exit 1

fi

 

echo ""

echo "╔═══════════════════════════════════════════════════════════════╗"

echo "║ ÉTAPE 3 : Attente du démarrage (3-5 minutes)                  ║"

echo "╚═══════════════════════════════════════════════════════════════╝"

echo ""

 

echo "⏱️  Attente création du pod (30s)..."

sleep 30

 

echo ""

echo "→ État actuel du pod..."

kubectl get pod -n wazuh wazuh-indexer-0 2>&1 || echo "Pod pas encore créé, attente..."

 

echo ""

echo "⏱️  Attente démarrage complet (3 minutes)..."

echo "  Le pod doit :"

echo "    1. Télécharger l'image (si pas en cache)"

echo "    2. Exécuter les init containers (sysctl + permissions)"

echo "    3. Démarrer OpenSearch/Wazuh Indexer"

echo "    4. Initialiser les indices"

echo ""

 

for i in {1..12}; do

    echo -n "  [$i/12] "

    sleep 15

 

    POD_STATUS=$(kubectl get pod -n wazuh wazuh-indexer-0 -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")

    READY=$(kubectl get pod -n wazuh wazuh-indexer-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")

 

    if [ "$POD_STATUS" = "Running" ] && [ "$READY" = "true" ]; then

        echo -e "$OK Pod Running et Ready !"

        break

    else

        echo "État: $POD_STATUS, Ready: $READY"

    fi

done

 

echo ""

echo "╔═══════════════════════════════════════════════════════════════╗"

echo "║ ÉTAPE 4 : Vérifications                                        ║"

echo "╚═══════════════════════════════════════════════════════════════╝"

echo ""

 

echo "→ État final du pod..."

kubectl get pod -n wazuh wazuh-indexer-0 -o wide

 

echo ""

echo "→ Logs du pod (50 dernières lignes)..."

kubectl logs -n wazuh wazuh-indexer-0 --tail=50 2>&1 | tail -60

 

echo ""

echo "→ Test de connectivité HTTP (dans 10s)..."

sleep 10

 

HTTP_TEST=$(kubectl exec -n wazuh wazuh-indexer-0 -- curl -s -o /dev/null -w "%{http_code}" http://localhost:9200 2>/dev/null || echo "000")

 

if [ "$HTTP_TEST" = "200" ]; then

    echo -e "$OK HTTP test réussi (code 200)"

 

    echo ""

    echo "→ Récupération des infos du cluster..."

    kubectl exec -n wazuh wazuh-indexer-0 -- curl -s http://localhost:9200 2>&1 | head -20

 

    echo ""

    echo "→ Health du cluster..."

    kubectl exec -n wazuh wazuh-indexer-0 -- curl -s http://localhost:9200/_cluster/health?pretty 2>&1 | head -20

 

else

    echo -e "$WARN HTTP test échoué (code $HTTP_TEST)"

    echo ""

    echo "Attendre encore quelques minutes et vérifier :"

    echo "  kubectl get pod -n wazuh wazuh-indexer-0"

    echo "  kubectl logs -n wazuh wazuh-indexer-0 --tail=100"

fi

 

echo ""

echo "╔════════════════════════════════════════════════════════════════╗"

echo "║                  RÉSUMÉ FINAL                                  ║"

echo "╚════════════════════════════════════════════════════════════════╝"

echo ""

 

POD_PHASE=$(kubectl get pod -n wazuh wazuh-indexer-0 -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

POD_READY=$(kubectl get pod -n wazuh wazuh-indexer-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")

 

echo "📊 État Wazuh Indexer :"

echo "  Phase : $POD_PHASE"

echo "  Ready : $POD_READY"

echo ""

 

if [ "$POD_PHASE" = "Running" ] && [ "$POD_READY" = "true" ]; then

    echo -e "$OK Wazuh Indexer opérationnel !"

    echo ""

    echo "🎯 PROCHAINE ÉTAPE :"

    echo "  Attendre 10-15 minutes pour stabilisation complète,"

    echo "  puis redéployer les Wazuh Managers :"

    echo ""

    echo "  ./redeploy_wazuh_managers.sh"

    echo ""

 

elif [ "$POD_PHASE" = "Running" ] && [ "$POD_READY" = "false" ]; then

    echo -e "$WARN Pod en cours de démarrage..."

    echo ""

    echo "Attendre encore 5-10 minutes puis vérifier :"

    echo "  kubectl get pod -n wazuh wazuh-indexer-0"

    echo "  kubectl logs -n wazuh wazuh-indexer-0 --tail=100"

    echo ""

 

else

    echo -e "$KO Problème détecté"

    echo ""

    echo "Diagnostic :"

    echo "  kubectl describe pod -n wazuh wazuh-indexer-0"

    echo "  kubectl get events -n wazuh --sort-by='.lastTimestamp' | tail -20"

    echo ""

fi

 

echo "════════════════════════════════════════════════════════════════"

echo ""

 

exit 0
