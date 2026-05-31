#!/usr/bin/env bash
# =============================================================================
# E2E TEST – Outbox pattern
# =============================================================================
set -euo pipefail

GATEWAY="http://localhost:8080"
ORDER_DB="docker-compose exec -T orderservice-postgresql psql -U orderService -d orderService -t -c"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

pass()  { echo -e "${GREEN}✅ $1${NC}"; }
fail()  { echo -e "${RED}❌ $1${NC}"; exit 1; }
info()  { echo -e "${BLUE}ℹ️  $1${NC}"; }
step()  { echo -e "\n${YELLOW}▶ $1${NC}"; }

echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}  E2E TEST – Outbox pattern${NC}"
echo -e "${BOLD}============================================================${NC}"
echo ""
echo "  Princip: Event se zapíše do DB (outbox_message) atomicky"
echo "  s doménovou změnou. Teprve pak ho scheduler odešle do Kafky."
echo "  Eliminuje dual-write problém."
echo ""

step "Autentizace"
TOKEN=$(curl -s -X POST "$GATEWAY/api/authenticate" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin","rememberMe":false}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['id_token'])" 2>/dev/null)
[ -n "$TOKEN" ] && pass "Token získán" || fail "Autentizace selhala"

step "Vytvoření objednávky přes Outbox pattern"
RESPONSE=$(curl -s -X POST "$GATEWAY/services/orderservice/api/orders/outbox" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "customerId": "22222222-2222-2222-2222-222222222222",
    "status": "PENDING", "totalAmount": 299.99, "currency": "CZK",
    "street": "Test", "city": "Praha", "postalCode": "11000",
    "country": "CZ", "createdAt": "2026-05-31T10:00:00Z"
  }')

ORDER_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null)
STATUS=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null)
[ -n "$ORDER_ID" ] && pass "Objednávka $ORDER_ID vytvořena (status: $STATUS)" || fail "Selhalo: $RESPONSE"

step "Okamžitá kontrola Outbox tabulky (PŘED odesláním do Kafky)"
info "Čekám 500ms – OutboxPublisher má 1s interval, zpráva by měla být stále v DB"
sleep 0.5

OUTBOX=$($ORDER_DB "SELECT id, event_type, published FROM outbox_message WHERE aggregate_id='$ORDER_ID' ORDER BY created_at;" | tr -d ' ')
OUTBOX_COUNT=$(echo "$OUTBOX" | grep -c "order.created" || echo "0")

if [ "$OUTBOX_COUNT" -ge 1 ]; then
  pass "Zpráva nalezena v outbox_message tabulce"
  echo ""
  echo -e "  ${BOLD}Obsah Outbox tabulky:${NC}"
  $ORDER_DB "SELECT id, event_type, published::text, to_char(created_at, 'HH24:MI:SS.MS') as created FROM outbox_message WHERE aggregate_id='$ORDER_ID';"
  echo ""
else
  fail "Zpráva v outbox_message nenalezena"
fi

step "Čekání na OutboxPublisher (scheduler odešle do Kafky)"
info "OutboxPublisher běží každou 1s a označí zprávu jako published=true"
sleep 3

PUBLISHED=$($ORDER_DB "SELECT published FROM outbox_message WHERE aggregate_id='$ORDER_ID' ORDER BY created_at LIMIT 1;" | tr -d ' ')
[ "$PUBLISHED" = "t" ] && pass "Zpráva odeslána do Kafky (published=true)" || fail "Zpráva stále nepublikována (published=$PUBLISHED)"

step "Čekání na dokončení sagu (Inventory → Payment → Confirmed)"
MAX_WAIT=30; ELAPSED=0; FINAL_STATUS=""
while [ $ELAPSED -lt $MAX_WAIT ]; do
  sleep 2; ELAPSED=$((ELAPSED + 2))
  FINAL_STATUS=$(curl -s "$GATEWAY/services/orderservice/api/orders/$ORDER_ID" \
    -H "Authorization: Bearer $TOKEN" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
  [ "$FINAL_STATUS" = "CONFIRMED" ] || [ "$FINAL_STATUS" = "CANCELLED" ] && break
  echo -n "  ... čekám (${ELAPSED}s, status: ${FINAL_STATUS:-PENDING})"$'\r'
done
echo ""
[ "$FINAL_STATUS" = "CONFIRMED" ] && pass "Objednávka $ORDER_ID je CONFIRMED" || fail "Status: $FINAL_STATUS"

echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${GREEN}${BOLD}  OUTBOX PATTERN FUNGUJE!${NC}"
echo -e "${BOLD}============================================================${NC}"
echo ""
echo "  Flow:"
echo "  POST /api/orders/outbox"
echo "  → Order $ORDER_ID uložena (PENDING)"
echo "  → OrderCreated zapsán do outbox_message (published=false) ← atomicky!"
echo "  → OutboxPublisher odešle do Kafky → published=true"
echo "  → Inventory → Payment → Order $ORDER_ID CONFIRMED ✅"
echo ""
echo "  Klíčový princip: DB změna a Kafka zpráva jsou atomické."
echo "  Pokud transakce selže, zpráva se do Kafky nikdy nedostane."
echo ""
