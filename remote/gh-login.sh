#!/usr/bin/env bash
# gh-login.sh — AUF DEM VPS ausfuehren (als root).
# 1. Rechte auf /projects/gh-Config sicherstellen (dev-User)
# 2. GitHub-Login (einmalig, bleibt im Volume)
# 3. Optional Repo klonen: ./gh-login.sh owner/repo
set -euo pipefail

docker exec -u root code-dev chown -R dev:dev /projects /home/dev/.config/gh /home/dev/.ssh
echo "Rechte ok."

if docker exec code-dev gh auth status >/dev/null 2>&1; then
  echo "gh bereits angemeldet als: $(docker exec code-dev gh api user --jq '.login')"
else
  echo "Bitte einloggen (Device-Code oder Token):"
  docker exec -it code-dev gh auth login
fi

if [ -n "${1:-}" ]; then
  docker exec -it code-dev bash -lc "cd /projects && gh repo clone '$1'"
fi

echo "--- /projects ---"
docker exec code-dev ls -la /projects
echo "Hinweis: Browser-Tab von remote-code neu laden, dann erscheint das Projekt in OpenCode."
