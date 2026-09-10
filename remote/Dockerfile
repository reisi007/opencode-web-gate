FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PNPM_HOME=/usr/local/pnpm-global \
    PNPM_CONFIG_PM_ON_FAIL=ignore
# pmOnFail=ignore: Repo-Pins (packageManager/devEngines, z.B. pnpm@11) loesen
# nie einen Versionsswitch ins root-owned $PNPM_HOME aus (dev kann dort nicht
# schreiben). Image-pnpm (v12, per CI gepinnt) wird immer verwendet.
ENV PATH=${PNPM_HOME}/bin:${PATH}

# --- Basis + Repos (Node 26.x, PHP 8.5 via Sury, gh, Docker CLI) ---
# Versionen floaten bewusst: woechentlicher CI-Rebuild holt jeweils latest.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg lsb-release apt-transport-https \
      git openssh-client unzip zip sudo nano \
      ripgrep fd-find sqlite3 \
 && rm -rf /var/lib/apt/lists/*

# Node.js 26.x (Nodesource, passend zu lokal v26.8.1) + pnpm (global, alle User)
RUN curl -fsSL https://deb.nodesource.com/setup_26.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && npm i -g npm@latest pnpm@latest \
 && mkdir -p "$PNPM_HOME" && chmod 755 "$PNPM_HOME" \
 && node --version && npm --version && pnpm --version \
 && rm -rf /var/lib/apt/lists/*

# PHP 8.5 (Sury). Bookworm hat kein PHP 8.5 von Haus aus.
RUN curl -fsSL https://packages.sury.org/php/apt.gpg -o /usr/share/keyrings/sury-php.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" \
      > /etc/apt/sources.list.d/sury-php.list \
 && apt-get update && apt-get install -y --no-install-recommends \
      php8.5-cli php8.5-common php8.5-curl php8.5-mbstring php8.5-xml \
      php8.5-zip php8.5-sqlite3 php8.5-mysql php8.5-pgsql php8.5-bcmath \
      php8.5-intl php8.5-readline \
      # kein php8.5-opcache: Sury liefert fuer 8.5 kein separates Paket (in 8.5 im Core)
 && php --version \
 && rm -rf /var/lib/apt/lists/*

# Composer v2 (latest zum Build-Zeitpunkt)
RUN curl -sS https://getcomposer.org/installer | php -- \
      --install-dir=/usr/local/bin --filename=composer \
 && composer --version

# GitHub CLI (offizielles apt-Repo, latest zum Build-Zeitpunkt)
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && gh --version \
 && rm -rf /var/lib/apt/lists/*

# Docker CLI (nur Client, Daemon kommt aus isoliertem dind-Sidecar)
RUN curl -fsSL https://download.docker.com/linux/debian/gpg \
      | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
 && chmod a+r /usr/share/keyrings/docker-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update && apt-get install -y --no-install-recommends docker-ce-cli \
 && docker --version \
 && rm -rf /var/lib/apt/lists/*

# OpenCode 2 (Beta, Binary heisst opencode2, parallel zu v1 möglich).
# Doku: https://opencode.ai/v2 — Tag @beta ist die neueste Beta-Linie.
# allow-build: Postinstall waehlt das native Binary pro Plattform.
# Global nach $PNPM_HOME (alle User via PATH), kein User-Setup noetig.
RUN pnpm add -g --allow-build=@opencode-ai/cli @opencode-ai/cli@beta \
 && opencode2 --version

# CodeGraph CLI (systemweit; Agent-Wiring NICHT hier — `codegraph install`
# ist interaktiv und wird pro Projekt von Hand gemacht, nur fuer opencode).
RUN curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh \
      | CODEGRAPH_INSTALL_DIR=/opt/codegraph CODEGRAPH_BIN_DIR=/usr/local/bin sh \
 && codegraph --version

# Python + uv + markitdown (Office/PDF -> Markdown fuer LLMs).
# pipx mit globalem Home, damit alle User die Binaries sehen.
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-pip python3-venv \
 && rm -rf /var/lib/apt/lists/* \
 && python3 --version \
 && curl -fsSL https://astral.sh/uv/install.sh | sh \
 && mv /root/.local/bin/uv /usr/local/bin/uv \
 && uv --version \
 && python3 -m pip install --break-system-packages --no-cache-dir pipx \
 && PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install 'markitdown[pdf,docx,pptx,xlsx,xls]' \
 && markitdown --version

# --- Non-root User: gh-Auth + Projekte leben in Volumes (ueberleben Image-Upgrades) ---
ARG DEV_UID=1000
ARG DEV_GID=1000
RUN groupadd -g "$DEV_GID" dev 2>/dev/null || true \
 && useradd -m -u "$DEV_UID" -g "$DEV_GID" -s /bin/bash dev \
 && echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev \
 && mkdir -p /projects /home/dev/.config/gh /home/dev/.ssh /home/dev/.local/share/opencode /home/dev/.config/opencode /home/dev/.config/pnpm \
 && chown -R dev:dev /projects /home/dev

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENV HOME=/home/dev \
    DOCKER_HOST=tcp://dind:2375 \
    OPENCODE_DISABLE_AUTOUPDATE=true

USER dev
WORKDIR /projects
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD (command -v curl >/dev/null && curl -sf http://127.0.0.1:8080/ >/dev/null) || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
