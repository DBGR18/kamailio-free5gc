#!/bin/bash
# Tear the PoC down. The gtp5g module stays loaded; remove it with
# "sudo rmmod gtp5g" if you want a completely clean host.
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${HERE}"
docker compose down -v
echo "[down] containers and volumes removed"
