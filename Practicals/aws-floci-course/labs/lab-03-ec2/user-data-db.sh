#!/bin/bash
# USMS data tier bootstrap. Idempotent: exits early if the marker exists.
MARKER=/var/log/usms-db-bootstrap.done
[ -f "$MARKER" ] && { echo "already bootstrapped"; exit 0; }
set -x
exec > /var/log/usms-db-bootstrap.log 2>&1

dnf -y install postgresql15-server
postgresql-setup --initdb
systemctl enable --now postgresql
sudo -u postgres psql -c "CREATE DATABASE usms;"

TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
echo "${INSTANCE_ID} $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER"
