#!/usr/bin/env bash
# Окружение Codespace: те же версии, что в CI (.github/workflows/ci.yml).
set -euo pipefail

SUPABASE_CLI_VERSION=2.116.0

corepack enable
pnpm install --frozen-lockfile

if ! supabase --version 2>/dev/null | grep -q "$SUPABASE_CLI_VERSION"; then
  curl -fsSL -o /tmp/supabase.deb \
    "https://github.com/supabase/cli/releases/download/v${SUPABASE_CLI_VERSION}/supabase_${SUPABASE_CLI_VERSION}_linux_amd64.deb"
  sudo dpkg -i /tmp/supabase.deb
  rm /tmp/supabase.deb
fi
supabase --version
