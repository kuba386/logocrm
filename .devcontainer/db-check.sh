#!/usr/bin/env bash
# Тот же путь, что джоб db в CI: номера миграций → supabase start → db reset → pgTAP.
# Повторный запуск не поднимает базу заново — только reset и тесты.
set -euo pipefail
cd "$(dirname "$0")/../packages/db"

node scripts/check-migration-versions.mjs

if ! supabase status >/dev/null 2>&1; then
  # Студия, картинки и edge-функции схему не создают — не ждём их.
  EXCLUDE=studio,imgproxy,edge-runtime
  n=0
  until supabase start -x "$EXCLUDE"; do
    n=$((n + 1))
    if [ "$n" -ge 5 ]; then
      echo "supabase start не поднялся за 5 попыток" >&2
      exit 1
    fi
    echo "supabase start упал (попытка $n/5), повтор…" >&2
    supabase stop --no-backup >/dev/null 2>&1 || true
    sleep $((n * 15))
  done
fi

supabase db reset
supabase test db "$@"
