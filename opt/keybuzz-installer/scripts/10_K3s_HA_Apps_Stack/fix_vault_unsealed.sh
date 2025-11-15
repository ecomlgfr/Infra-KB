#!/usr/bin/env bash

set -u

set -o pipefail

 

echo "╔════════════════════════════════════════════════════════════════════╗"

echo "║    FIX VAULT - Déverrouillage automatique                        ║"

echo "╚════════════════════════════════════════════════════════════════════╝"

 

OK='\033[0;32m✓\033[0m'

KO='\033[0;31m✗\033[0m'

WARN='\033[0;33m⚠\033[0m'

 

echo ""

echo "ℹ️  À PROPOS DE VAULT SEALED :"

echo ""

echo "  Vault utilise un système de 'seal/unseal' pour la sécurité."

echo "  Quand Vault est 'sealed' (verrouillé) :"

echo "    • Le pod affiche 0/1 Running (pas Ready)"

echo "    • Mais le processus Vault fonctionne normalement"

echo "    • Les health checks retournent HTTP 501/503"

echo ""

echo "  Pour déverrouiller Vault, il faut fournir 3 clés (sur 5)."

echo ""

echo "  ⚠️  ARCHITECTURE DAEMONSET :"

echo "  Vault est déployé en DaemonSet (1 pod par nœud = 8 pods total)."

echo "  SEULEMENT 1 POD doit être 'unsealed' (actif)."

echo "  Les autres restent 'sealed' (standby) - C'EST NORMAL !"

echo ""

 

read -p "Continuer ? (yes/NO) : " confirm

[ "$confirm" != "yes" ] && { echo "Annulé"; exit 0; }

 

echo ""

echo "╔═══════════════════════════════════════════════════════════════╗"

echo "║ ÉTAPE 1 : Diagnostic Vault                                    ║"

echo "╚═══════════════════════════════════════════════════════════════╝"

echo ""

 

echo "→ État des pods Vault..."

kubectl get pods -n vault -o wide

 

echo ""

echo "→ Comptage des pods..."

TOTAL_PODS=$(kubectl get pods -n vault --no-headers 2>/dev/null | wc -l)

RUNNING_READY=$(kubectl get pods -n vault --no-headers 2>/dev/null | grep "1/1.*Running" | wc -l)

RUNNING_NOT_READY=$(kubectl get pods -n vault --no-headers 2>/dev/null | grep "0/1.*Running" | wc -l)

 

echo "  Total pods     : $TOTAL_PODS"

echo "  Running 1/1    : $RUNNING_READY (unsealed)"

echo "  Running 0/1    : $RUNNING_NOT_READY (sealed)"

echo ""

 

if [ "$RUNNING_READY" -ge 1 ]; then

    echo -e "$OK Au moins 1 pod Vault est déjà unsealed"

    echo ""

    UNSEALED_POD=$(kubectl get pods -n vault --no-headers 2>/dev/null | grep "1/1.*Running" | head -1 | awk '{print $1}')

    echo "Pod actif : $UNSEALED_POD"

    echo ""

    kubectl exec -n vault "$UNSEALED_POD" -- vault status

    echo ""

    echo -e "$OK Vault est opérationnel !"

    echo "   Les autres pods en 0/1 Running sont en standby sealed - c'est NORMAL."

    echo ""

    read -p "Voulez-vous quand même déverrouiller d'autres pods ? (yes/NO) : " unseal_more

    [ "$unseal_more" != "yes" ] && { echo "Terminé. Vault fonctionne correctement."; exit 0; }

fi

 

echo ""

echo "╔═══════════════════════════════════════════════════════════════╗"

echo "║ ÉTAPE 2 : Recherche des clés de déverrouillage                ║"

echo "╚═══════════════════════════════════════════════════════════════╝"

echo ""

 

KEYS_FILE=""

 

# Chercher les clés dans différents emplacements

for path in \

    "/home/user/KB/credentials/vault_keys_*.txt" \

    "/opt/keybuzz-installer/credentials/vault_keys_*.txt" \

    "/root/vault_keys*.txt"; do

 

    if ls $path 2>/dev/null | head -1 > /dev/null; then

        KEYS_FILE=$(ls -t $path 2>/dev/null | head -1)

        break

    fi

done

 

if [ -z "$KEYS_FILE" ]; then

    echo -e "$KO Aucun fichier de clés trouvé"

    echo ""

    echo "Emplacements recherchés :"

    echo "  • /home/user/KB/credentials/vault_keys_*.txt"

    echo "  • /opt/keybuzz-installer/credentials/vault_keys_*.txt"

    echo "  • /root/vault_keys*.txt"

    echo ""

    echo "⚠️  Sans clés, impossible de déverrouiller Vault"

    echo ""

    echo "Options :"

    echo "  1. Retrouver les clés de l'installation initiale"

    echo "  2. Réinitialiser complètement Vault (PERTE DE DONNÉES)"

    echo ""

    read -p "Réinitialiser Vault ? (yes/NO) : " reinit

 

    if [ "$reinit" = "yes" ]; then

        echo ""

        echo "→ Suppression et réinitialisation de Vault..."

        echo "  Cette opération va :"

        echo "    • Supprimer tous les secrets stockés dans Vault"

        echo "    • Créer de nouvelles clés de déverrouillage"

        echo "    • Nécessiter une reconfiguration des applications"

        echo ""

        read -p "Êtes-vous SÛR ? Tapez 'CONFIRM' : " final_confirm

 

        if [ "$final_confirm" = "CONFIRM" ]; then

            # Suppression complète

            kubectl delete namespace vault

            sleep 30

            kubectl create namespace vault

 

            # Recréer Vault (utiliser le script existant)

            if [ -f "./fix_all_problems_auto.sh" ]; then

                echo "Relancer ./fix_all_problems_auto.sh pour recréer Vault"

            fi

        fi

    fi

 

    exit 1

fi

 

echo -e "$OK Clés trouvées : $KEYS_FILE"

echo ""

 

echo "→ Extraction des clés de déverrouillage..."

KEY1=$(grep "Unseal Key 1:" "$KEYS_FILE" | awk '{print $NF}')

KEY2=$(grep "Unseal Key 2:" "$KEYS_FILE" | awk '{print $NF}')

KEY3=$(grep "Unseal Key 3:" "$KEYS_FILE" | awk '{print $NF}')

 

if [ -z "$KEY1" ] || [ -z "$KEY2" ] || [ -z "$KEY3" ]; then

    echo -e "$KO Impossible d'extraire les 3 clés du fichier"

    echo "Vérifiez le format du fichier : $KEYS_FILE"

    exit 1

fi

 

echo -e "$OK 3 clés extraites avec succès"

echo ""

 

echo "╔═══════════════════════════════════════════════════════════════╗"

echo "║ ÉTAPE 3 : Déverrouillage des pods Vault sealed                ║"

echo "╚═══════════════════════════════════════════════════════════════╝"

echo ""

 

SEALED_PODS=$(kubectl get pods -n vault --no-headers 2>/dev/null | grep "0/1.*Running" | awk '{print $1}')

 

if [ -z "$SEALED_PODS" ]; then

    echo -e "$OK Aucun pod sealed à déverrouiller"

    exit 0

fi

 

echo "Pods à déverrouiller :"

echo "$SEALED_PODS"

echo ""

 

read -p "Déverrouiller ces pods ? (yes/NO) : " do_unseal

[ "$do_unseal" != "yes" ] && { echo "Annulé"; exit 0; }

 

echo ""

for pod in $SEALED_PODS; do

    echo "→ Déverrouillage de $pod..."

 

    # Vérifier que le pod est bien sealed

    SEALED=$(kubectl exec -n vault "$pod" -- vault status -format=json 2>/dev/null | grep -o '"sealed":[^,]*' | cut -d: -f2)

 

    if [ "$SEALED" = "true" ]; then

        echo "  Pod sealed : OUI"

        echo "  Application des 3 clés..."

 

        kubectl exec -n vault "$pod" -- vault operator unseal "$KEY1" > /dev/null 2>&1

        echo "    Clé 1/3 appliquée"

 

        kubectl exec -n vault "$pod" -- vault operator unseal "$KEY2" > /dev/null 2>&1

        echo "    Clé 2/3 appliquée"

 

        kubectl exec -n vault "$pod" -- vault operator unseal "$KEY3" > /dev/null 2>&1

        echo "    Clé 3/3 appliquée"

 

        # Vérifier le résultat

        sleep 2

        NEW_STATUS=$(kubectl exec -n vault "$pod" -- vault status -format=json 2>/dev/null | grep -o '"sealed":[^,]*' | cut -d: -f2)

 

        if [ "$NEW_STATUS" = "false" ]; then

            echo -e "  $OK Pod déverrouillé avec succès"

        else

            echo -e "  $WARN Pod toujours sealed, vérifier les clés"

        fi

    else

        echo "  Pod déjà unsealed, ignoré"

    fi

 

    echo ""

done

 

echo ""

echo "╔════════════════════════════════════════════════════════════════╗"

echo "║                  RÉSUMÉ FINAL                                  ║"

echo "╚════════════════════════════════════════════════════════════════╝"

echo ""

 

echo "État final des pods Vault :"

kubectl get pods -n vault

echo ""

 

FINAL_UNSEALED=$(kubectl get pods -n vault --no-headers 2>/dev/null | grep "1/1.*Running" | wc -l)

echo "Pods unsealed (actifs) : $FINAL_UNSEALED"

echo ""

 

if [ "$FINAL_UNSEALED" -ge 1 ]; then

    echo -e "$OK Vault est opérationnel !"

    echo ""

    echo "ℹ️  RAPPEL IMPORTANT :"

    echo "  • Seul 1 pod Vault doit être unsealed (actif)"

    echo "  • Les autres pods en 0/1 Running sont en standby - C'EST NORMAL"

    echo "  • Vault ne supporte pas vraiment le HA en mode file storage"

    echo "  • Pour du vrai HA : migrer vers Consul storage (à faire plus tard)"

    echo ""

else

    echo -e "$WARN Aucun pod Vault unsealed"

    echo "  Vérifiez les clés et relancez le script"

fi

 

echo "🔐 Fichier de clés utilisé : $KEYS_FILE"

echo "   ⚠️  Sauvegarder ce fichier précieusement !"

echo ""

 

exit 0
