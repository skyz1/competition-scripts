#!/bin/bash

# Ensure jq is available
if ! command -v jq &>/dev/null; then
  echo "jq is required but not installed. Aborting."
  exit 1
fi

CONFIG_FILE="config/config.json"
DOMAIN=$(jq -r '.domain' "$CONFIG_FILE")

# Shut down services
docker compose -f watchtower.yaml down
docker compose -f competitors.yaml down
docker compose -f mysql.yaml down
docker compose -f gitea-runner.yaml down
GITEA_HOSTNAME=$DOMAIN docker compose -f gitea.yaml down
docker compose -f traefik.yaml down

# Delete volumes and data
rm -rf ./data
rm -rf config/mysql/competitors.sql
rm -f competitors.yaml

# Remove competitor-related images
jq -c '.competitors[]' "$CONFIG_FILE" | while read -r competitor; do
  user=$(echo "$competitor" | jq -r '.username')

  echo "Removing Docker images for user: $user"
  docker images | grep "$user" | awk '{print $3}' | xargs -r docker rmi -f
done

# Remove framework folders based on the framework names
jq -r '.frameworks[].name' "$CONFIG_FILE" | while read -r fw; do
  echo "Removing local framework repo: $fw"
  rm -rf "$fw"
done

echo "..cleaned up!"
