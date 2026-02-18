#!/bin/bash
# ============================================================
# Setup Cloudflare resources for ZeroEmail framky environment
# Run once before first deploy.
#
# Prerequisites:
#   - npx wrangler login (already authenticated)
#   - jq installed
#
# After running, copy the output IDs into:
#   apps/server/wrangler.jsonc → env.framky
# ============================================================
set -euo pipefail

echo "=== ZeroEmail Framky — Cloudflare Resource Setup ==="
echo ""

# --- 1. KV Namespaces ---
echo "--- Creating KV Namespaces ---"
KV_BINDINGS=(
  gmail_history_id
  gmail_processing_threads
  subscribed_accounts
  connection_labels
  prompts_storage
  gmail_sub_age
  pending_emails_status
  pending_emails_payload
  scheduled_emails
  snoozed_emails
)

for binding in "${KV_BINDINGS[@]}"; do
  echo -n "Creating KV: ${binding}-framky ... "
  result=$(npx wrangler kv namespace create "${binding}-framky" --json 2>/dev/null || true)
  id=$(echo "$result" | jq -r '.id // empty')
  if [ -n "$id" ]; then
    echo "OK → id: $id"
  else
    echo "ALREADY EXISTS or ERROR (check manually)"
    echo "  Run: npx wrangler kv namespace list | grep ${binding}-framky"
  fi
done

echo ""

# --- 2. R2 Bucket ---
echo "--- Creating R2 Bucket ---"
echo -n "Creating R2: threads-framky ... "
npx wrangler r2 bucket create threads-framky 2>/dev/null && echo "OK" || echo "ALREADY EXISTS"

echo ""

# --- 3. Queues ---
echo "--- Creating Queues ---"
QUEUES=(thread-queue-framky subscribe-queue-framky send-email-queue-framky)
for queue in "${QUEUES[@]}"; do
  echo -n "Creating Queue: $queue ... "
  npx wrangler queues create "$queue" 2>/dev/null && echo "OK" || echo "ALREADY EXISTS"
done

echo ""

# --- 4. Vectorize Indexes ---
echo "--- Creating Vectorize Indexes ---"
echo -n "Creating Vectorize: threads-vector-framky ... "
npx wrangler vectorize create threads-vector-framky --dimensions=1536 --metric=cosine 2>/dev/null && echo "OK" || echo "ALREADY EXISTS"

echo -n "Creating Vectorize: messages-vector-framky ... "
npx wrangler vectorize create messages-vector-framky --dimensions=1536 --metric=cosine 2>/dev/null && echo "OK" || echo "ALREADY EXISTS"

echo ""

# --- 5. Hyperdrive ---
echo "--- Creating Hyperdrive Config ---"
echo "NOTE: You need to provide the PostgreSQL connection string."
echo "  Format: postgresql://zerodotemail:PASSWORD@pg-tunnel.framky.com:5432/zerodotemail"
echo "  (Use Cloudflare Tunnel hostname, NOT direct IP)"
echo ""
echo "Run manually:"
echo "  npx wrangler hyperdrive create zerodotemail-framky \\"
echo "    --connection-string=\"postgresql://zerodotemail:PASSWORD@pg-tunnel.framky.com:5432/zerodotemail\""
echo ""

# --- 6. Secrets ---
echo "--- Setting Secrets ---"
echo "Run each of these manually (they prompt for value):"
echo ""
SECRETS=(
  BETTER_AUTH_SECRET
  GOOGLE_CLIENT_ID
  GOOGLE_CLIENT_SECRET
  DATABASE_URL
  OPENAI_API_KEY
  RESEND_API_KEY
  REDIS_URL
  REDIS_TOKEN
  JWT_SECRET
  AUTUMN_SECRET_KEY
)
for secret in "${SECRETS[@]}"; do
  echo "  npx wrangler secret put $secret --env framky"
done

echo ""
echo "=== DONE ==="
echo ""
echo "Next steps:"
echo "  1. Copy KV namespace IDs into apps/server/wrangler.jsonc → env.framky.kv_namespaces"
echo "  2. Copy Hyperdrive ID into env.framky.hyperdrive[0].id"
echo "  3. Set secrets (commands above)"
echo "  4. Deploy: cd apps/server && npx wrangler deploy --env framky"
