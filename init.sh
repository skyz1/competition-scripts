#!/bin/bash

# Ensure jq is installed
if ! command -v jq &>/dev/null; then
  echo "jq is required but not installed. Aborting."
  exit 1
fi

CONFIG_FILE="config/config.json"

DOMAIN=$(jq -r '.domain' "$CONFIG_FILE")
ENABLE_HTTPS=$(jq -r '.enable_https' "$CONFIG_FILE")
USERNAME=$(jq -r '.username' "$CONFIG_FILE")
PASSWORD=$(jq -r '.password' "$CONFIG_FILE")

export GITEA_HOSTNAME=$DOMAIN
export ENABLE_HTTPS=$ENABLE_HTTPS
export MYSQL_ROOT_PASSWORD=$PASSWORD

if [ "$ENABLE_HTTPS" = "true" ]; then
  export ENTRYPOINT=websecure
  export GITEA_PROTOCOL=https
  export REGISTRY_PORT=443
else
  export ENTRYPOINT=web
  export GITEA_PROTOCOL=http
  export REGISTRY_PORT=5000
fi

# Start Traefik and Gitea
REGISTRY_PORT=$REGISTRY_PORT GITEA_HOSTNAME=$DOMAIN GITEA_PROTOCOL=$GITEA_PROTOCOL ENTRYPOINT=$ENTRYPOINT ENABLE_HTTPS=$ENABLE_HTTPS docker compose -f traefik.yaml up -d --remove-orphans
GITEA_HOSTNAME=$DOMAIN GITEA_PROTOCOL=$GITEA_PROTOCOL ENTRYPOINT=$ENTRYPOINT ENABLE_HTTPS=$ENABLE_HTTPS docker compose -f gitea.yaml up -d

# Wait for Gitea
function wait_for_gitea() {
  local retries=10
  local wait=5
  local count=0

  until curl -s http://localhost:3000/api/v1/version > /dev/null; do
    if [ $count -ge $retries ]; then
      echo "Gitea did not become ready in time."
      exit 1
    fi
    echo "Waiting for Gitea to be ready..."
    sleep $wait
    count=$((count + 1))
  done
}
wait_for_gitea

# Create main admin user
docker exec gitea su -c "/app/gitea/gitea admin user create --username $USERNAME --password $PASSWORD --email $USERNAME@example.com --admin" git

# Generate registration token
REGISTRATION_TOKEN=$(docker exec gitea su -c '/app/gitea/gitea actions generate-runner-token' git)
export REGISTRATION_TOKEN=$REGISTRATION_TOKEN
echo "Registration Token: $REGISTRATION_TOKEN"

# Start Gitea runner
REGISTRATION_TOKEN=$REGISTRATION_TOKEN docker compose -f gitea-runner.yaml up -d

# Create PAT and organizations
GITEA_URL="$GITEA_PROTOCOL://git.$DOMAIN"
GITEA_TOKEN=$(./create_pat.sh "$GITEA_URL" "$USERNAME" "$PASSWORD")

curl -s -k -X POST "$GITEA_URL/api/v1/orgs" \
  -H "Content-Type: application/json" \
  -H "Authorization: token $GITEA_TOKEN" \
  -d '{"username": "frameworks", "full_name": "frameworks"}'

./create_organisation.sh "$GITEA_TOKEN" "$GITEA_URL" "images"
./create_organisation.sh "$GITEA_TOKEN" "$GITEA_URL" "frameworks"
./create_team.sh "$GITEA_TOKEN" "$GITEA_URL" "frameworks" "competitors" false

# Import frameworks
jq -c '.frameworks[]' "$CONFIG_FILE" | while read -r framework; do
  name=$(echo "$framework" | jq -r '.name')
  url=$(echo "$framework" | jq -r '.url')

  ./import_framework.sh "$GITEA_TOKEN" "$USERNAME" "$PASSWORD" "git.$DOMAIN" "$url" "$name"
done

# Docker login
docker pull nginx:latest > /dev/null 2>&1
docker login -u "$USERNAME" -p "$PASSWORD" "git.$DOMAIN" > /dev/null 2>&1

# Prepare YAML & SQL
cat <<EOF > competitors.yaml
services:
EOF

cat <<EOF > config/mysql/competitors.sql
EOF

# Handle competitors
jq -c '.competitors[]' "$CONFIG_FILE" | while read -r competitor; do
  user=$(echo "$competitor" | jq -r '.username')
  pass=$(echo "$competitor" | jq -r '.password')
  modules=$(echo "$competitor" | jq -r '.modules[]')

  docker exec gitea su -c "/app/gitea/gitea admin user create --username $user --password $pass --email $user@example.com --must-change-password=false" git
  ./add_user_to_team.sh "$GITEA_URL" "$GITEA_TOKEN" "frameworks" "competitors" "$user"

  for module in $modules; do
    echo "Processing module: $module for $user"

    cat <<EOF >> competitors.yaml
  ${user}_${module}:
    image: git.${DOMAIN}/${user}/${module}:latest
    container_name: ${user}_${module}
    restart: always
    networks:
      - gitea
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${user}_${module}.rule=Host(\`${user}-${module}.$DOMAIN\`)"
      - "traefik.http.routers.${user}_${module}.entrypoints=${ENTRYPOINT}"
      - "traefik.http.routers.${user}_${module}.tls=${ENABLE_HTTPS}"
      - "traefik.http.services.${user}_${module}.loadbalancer.server.port=80"
      - "com.centurylinklabs.watchtower.enable=true"
EOF

    docker tag nginx:latest git.$DOMAIN/$user/$module:latest
    docker push git.$DOMAIN/$user/$module

    cat <<EOF >> config/mysql/competitors.sql
  CREATE DATABASE IF NOT EXISTS \`${user}_${module}\`;
  CREATE USER IF NOT EXISTS '$user'@'%' IDENTIFIED BY '$pass';
  GRANT ALL PRIVILEGES ON \`${user}_${module}\`.* TO '$user'@'%';
EOF

  done
done

# Finalize competitors.yaml
cat <<EOF >> competitors.yaml

networks:
  gitea:
    external: true
EOF

# Start services
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD docker compose -f mysql.yaml up -d
USERNAME=$USERNAME PASSWORD=$PASSWORD DOMAIN=$DOMAIN docker compose -f watchtower.yaml up -d
docker compose -f competitors.yaml up -d 

echo "..all done!"
