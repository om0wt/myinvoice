#!/usr/bin/env bash
# Build frontend (Vue → web/dist/) pro nasazení.
#
#   cd web
#   pnpm install
#   pnpm build
#
# Použití:
#   cmd/publish.sh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT/web"

if ! command -v pnpm >/dev/null 2>&1; then
  echo "ERROR: pnpm not found in PATH. Install: npm install -g pnpm" >&2
  exit 1
fi

echo "==> pnpm install"
pnpm install

echo ""
echo "==> pnpm build"
pnpm build

echo ""
echo "==> Done. web/dist/ je připravený k nasazení."
