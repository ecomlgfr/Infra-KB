#!/usr/bin/env python3
"""
Script de connexion SSH pour l'infrastructure Keybuzz
Permet de tester et exécuter des commandes sur les serveurs
"""

import json
import sys
import os
from pathlib import Path
import subprocess
from typing import Dict, Any, Optional

class SSHConnector:
    def __init__(self, config_dir: str = ".ssh-config"):
        self.config_dir = Path(config_dir)
        self.servers = self._load_servers()
        self.credentials = self._load_credentials()

    def _load_servers(self) -> Dict[str, Any]:
        """Charge la configuration des serveurs"""
        servers_file = self.config_dir / "ssh_servers.json"
        if not servers_file.exists():
            raise FileNotFoundError(f"Fichier de serveurs non trouvé: {servers_file}")

        with open(servers_file, 'r') as f:
            return json.load(f)

    def _load_credentials(self) -> Dict[str, Any]:
        """Charge les credentials SSH"""
        creds_file = self.config_dir / "ssh_credentials.json"
        if not creds_file.exists():
            print(f"⚠️  Fichier de credentials non trouvé: {creds_file}")
            print("   Utilisez ssh_credentials.json.template comme modèle")
            return {"default": {}}

        with open(creds_file, 'r') as f:
            return json.load(f)

    def get_server_config(self, server_name: str) -> Optional[Dict[str, Any]]:
        """Récupère la configuration d'un serveur"""
        return self.servers.get("servers", {}).get(server_name)

    def get_connection_params(self, server_name: str) -> Dict[str, Any]:
        """Détermine les paramètres de connexion pour un serveur"""
        server = self.get_server_config(server_name)
        if not server:
            raise ValueError(f"Serveur non trouvé: {server_name}")

        # Récupère les credentials par défaut
        default_creds = self.credentials.get("default", {})

        # Vérifie s'il y a des overrides pour ce serveur
        server_creds = self.credentials.get("server_overrides", {}).get(server_name, {})

        # Fusionne les configurations
        creds = {**default_creds, **server_creds}

        # Détermine l'adresse de connexion
        connect_via = creds.get("connect_via", "ip_public")
        host = server.get(connect_via, server.get("ip_public"))

        return {
            "host": host,
            "user": server.get("user", "root"),
            "port": creds.get("port", 22),
            "ssh_key_path": creds.get("ssh_key_path"),
            "server_info": server
        }

    def test_connection(self, server_name: str) -> bool:
        """Teste la connexion à un serveur"""
        try:
            params = self.get_connection_params(server_name)

            print(f"\n🔍 Test de connexion à {server_name}")
            print(f"   Host: {params['host']}")
            print(f"   User: {params['user']}")
            print(f"   Port: {params['port']}")

            cmd = [
                "ssh",
                "-o", "ConnectTimeout=10",
                "-o", "StrictHostKeyChecking=no",
                "-p", str(params['port']),
                f"{params['user']}@{params['host']}",
                "echo 'Connection successful'"
            ]

            if params.get("ssh_key_path"):
                cmd.insert(1, "-i")
                cmd.insert(2, params["ssh_key_path"])

            result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)

            if result.returncode == 0:
                print(f"✅ Connexion réussie à {server_name}")
                return True
            else:
                print(f"❌ Échec de connexion à {server_name}")
                print(f"   Erreur: {result.stderr}")
                return False

        except Exception as e:
            print(f"❌ Erreur lors du test de connexion: {e}")
            return False

    def execute_command(self, server_name: str, command: str) -> Optional[str]:
        """Exécute une commande sur un serveur"""
        try:
            params = self.get_connection_params(server_name)

            print(f"\n🚀 Exécution sur {server_name}: {command}")

            cmd = [
                "ssh",
                "-o", "ConnectTimeout=10",
                "-o", "StrictHostKeyChecking=no",
                "-p", str(params['port']),
                f"{params['user']}@{params['host']}",
                command
            ]

            if params.get("ssh_key_path"):
                cmd.insert(1, "-i")
                cmd.insert(2, params["ssh_key_path"])

            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)

            if result.returncode == 0:
                print(f"✅ Commande exécutée avec succès")
                print(f"\nRésultat:\n{result.stdout}")
                return result.stdout
            else:
                print(f"❌ Échec de l'exécution")
                print(f"   Erreur: {result.stderr}")
                return None

        except Exception as e:
            print(f"❌ Erreur lors de l'exécution: {e}")
            return None

    def list_servers(self):
        """Liste tous les serveurs disponibles"""
        print("\n📋 Serveurs disponibles:\n")

        for name, config in self.servers.get("servers", {}).items():
            print(f"  • {name:20} - {config.get('description', 'N/A')}")
            print(f"    IP Public:    {config.get('ip_public', 'N/A')}")
            print(f"    IP Wireguard: {config.get('ip_wireguard', 'N/A')}")
            print(f"    Groupe:       {config.get('group', 'N/A')}")
            print()

    def list_groups(self):
        """Liste tous les groupes de serveurs"""
        print("\n📦 Groupes de serveurs:\n")

        for name, config in self.servers.get("groups", {}).items():
            print(f"  • {name:20} - {config.get('description', 'N/A')}")
            print(f"    Serveurs: {', '.join(config.get('servers', []))}")
            print()


def main():
    """Fonction principale"""
    if len(sys.argv) < 2:
        print("Usage:")
        print("  python ssh_connect.py list              - Liste les serveurs")
        print("  python ssh_connect.py groups            - Liste les groupes")
        print("  python ssh_connect.py test <server>     - Teste la connexion")
        print("  python ssh_connect.py exec <server> <command> - Exécute une commande")
        sys.exit(1)

    connector = SSHConnector()

    action = sys.argv[1]

    if action == "list":
        connector.list_servers()

    elif action == "groups":
        connector.list_groups()

    elif action == "test":
        if len(sys.argv) < 3:
            print("❌ Veuillez spécifier un nom de serveur")
            sys.exit(1)

        server_name = sys.argv[2]
        connector.test_connection(server_name)

    elif action == "exec":
        if len(sys.argv) < 4:
            print("❌ Veuillez spécifier un nom de serveur et une commande")
            sys.exit(1)

        server_name = sys.argv[2]
        command = " ".join(sys.argv[3:])
        connector.execute_command(server_name, command)

    else:
        print(f"❌ Action inconnue: {action}")
        sys.exit(1)


if __name__ == "__main__":
    main()
