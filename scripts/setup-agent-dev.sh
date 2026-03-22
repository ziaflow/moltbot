#!/usr/bin/env bash
set -euo pipefail

if ! command -v node >/dev/null 2>&1; then
  echo "error: Node.js is not installed. Install Node 22+ first." >&2
  exit 1
fi

NODE_MAJOR="$(node -p 'process.versions.node.split(`.`)[0]')"
if [ "${NODE_MAJOR}" -lt 22 ]; then
  echo "error: Node ${NODE_MAJOR} detected. Moltbot requires Node 22+." >&2
  exit 1
fi

if ! command -v pnpm >/dev/null 2>&1; then
  echo "error: pnpm is not installed. Install pnpm and retry." >&2
  exit 1
fi

echo "==> Installing dependencies"
pnpm install

echo "==> Building TypeScript output"
pnpm build

echo
echo "Setup complete. Next steps:"
echo "  1) Start the gateway in watch mode: pnpm gateway:watch"
echo "  2) In another terminal, run an agent message: pnpm moltbot agent --message 'Hello'"
echo "  3) If first-time setup is needed, run: pnpm moltbot onboard --install-daemon"
