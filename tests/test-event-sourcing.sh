#!/usr/bin/env bash
# =============================================================================
# E2E TEST – Event sourcing
# =============================================================================
# Demonstruje základní principy event sourcingu:
#   1. Každá změna stavu objednávky je zaznamenána jako immutabilní event
#   2. Aktuální stav lze rekonstruovat přehráním sekvence eventů
#   3. Stav z replay odpovídá stavu v DB
#
# Použití: bash test-event-sourcing.sh
# =============================================================================

set -euo pipefail

GATEWAY="http://localhost:8080"
ORDER_SERVICE="http://localhost:8081"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

pass()  { echo -e "${GREEN}✅ $1${NC}"; }
fail()  { echo -e "${RED}❌ $1${NC}"; exit 1; }
info()  { echo -e "${BLUE}ℹ️  $1${NC}"; }
step()  { echo -e "\n${YELLOW}▶ $1${NC}"; }
event() { echo -e "  ${CYAN}⚡ $1${NC}"; }

echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}  E2E TEST – Event sourcing${NC}"
echo -e "${BOLD}============================================================${NC}"
echo ""
echo "  Princip: Stav objednávky není uložen přímo."
echo "  Každá změna je zaznamenána jako event."
echo "  Aktuální stav = přehrání všech eventů v pořadí."
echo ""

# --- Autentizace ---
step "Autentizace"
TOKEN=$(curl -s -X POST "$GATEWAY/api/authenticate" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin","rememberMe":false}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['id_token'])" 2>/dev/null)
[ -n "$TOKEN" ] && pass "Token získán" || fail "Autentizace selhala"

# --- Vytvoření objednávky ---
step "Vytvoření objednávky přes saga choreografii"
info "Choreografie generuje eventy: OrderCreated → StockReserved → PaymentCompleted"

RESPONSE=$(curl -s -X POST "$GATEWAY/services/orderservice/api/orders/choreography" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "customerId": "22222222-2222-2222-2222-222222222222",
    "status": "PENDING",
    "totalAmount": 299.99,
    "currency": "CZK",
    "street": "Test",
    "city": "Praha",
    "postalCode": "11000",
    "country": "CZ",
    "createdAt": "2026-05-31T10:00:00Z"
  }')

ORDER_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null)
[ -n "$ORDER_ID" ] && pass "Objednávka $ORDER_ID vytvořena" || fail "Vytvoření selhalo: $RESPONSE"

# --- Čekání na dokončení sagu ---
step "Čekání na dokončení sagu (max 30s)"
MAX_WAIT=30
ELAPSED=0
DB_STATUS=""
while [ $ELAPSED -lt $MAX_WAIT ]; do
  sleep 2
  ELAPSED=$((ELAPSED + 2))
  DB_STATUS=$(curl -s "$GATEWAY/services/orderservice/api/orders/$ORDER_ID" \
    -H "Authorization: Bearer $TOKEN" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
  [ "$DB_STATUS" = "CONFIRMED" ] || [ "$DB_STATUS" = "CANCELLED" ] && break
  echo -n "  ... čekám (${ELAPSED}s, status: ${DB_STATUS:-PENDING})"$'\r'
done
echo ""
[ "$DB_STATUS" = "CONFIRMED" ] && pass "Saga dokončena – objednávka je CONFIRMED v DB" || fail "Saga selhala – status: $DB_STATUS"

# --- Event history ---
step "Historie eventů z event store"
EVENTS=$(curl -s "$ORDER_SERVICE/api/orders/$ORDER_ID/events" \
  -H "Authorization: Bearer $TOKEN")

EVENT_COUNT=$(echo "$EVENTS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
[ "$EVENT_COUNT" -ge 3 ] && pass "$EVENT_COUNT eventy zaznamenány v event store" || fail "Očekávány ≥3 eventy, nalezeno: $EVENT_COUNT"

echo ""
echo -e "  ${BOLD}Sekvence eventů:${NC}"
echo "$EVENTS" > /tmp/events_$$.json
python3 << PYEOF
import json

with open('/tmp/events_$$.json') as f:
    events = json.load(f)

state = "–"
state_map = {
    "OrderCreated": "PENDING",
    "StockReserved": "STOCK_RESERVED",
    "PaymentCompleted": "CONFIRMED",
    "StockReservationFailed": "CANCELLED",
    "PaymentFailed": "CANCELLED",
    "OrderCancelled": "CANCELLED",
}
colors = {
    "OrderCreated": "\033[0;34m",
    "StockReserved": "\033[0;33m",
    "PaymentCompleted": "\033[0;32m",
}
NC = "\033[0m"

for e in events:
    ts = e['occurredAt'][:19].replace('T', ' ')
    color = colors.get(e['eventType'], "\033[0;36m")
    state = state_map.get(e['eventType'], state)
    print(f"  {color}seq={e['sequenceNumber']}  {e['eventType']:<20}{NC}  [{ts}]  → stav: {state}")
PYEOF
rm -f /tmp/events_$$.json

# --- Replay status ---
step "Rekonstrukce stavu přehráním eventů"
info "Endpoint /replay-status čte POUZE z event store, ne z tabulky objednávek"

REPLAY=$(curl -s "$ORDER_SERVICE/api/orders/$ORDER_ID/replay-status" \
  -H "Authorization: Bearer $TOKEN")

REPLAYED_STATUS=$(echo "$REPLAY" | python3 -c "import sys,json; print(json.load(sys.stdin)['replayedStatus'])" 2>/dev/null)
NOTE=$(echo "$REPLAY" | python3 -c "import sys,json; print(json.load(sys.stdin)['note'])" 2>/dev/null)

echo ""
echo -e "  ${BOLD}Výsledek replay:${NC}"
echo -e "  Rekonstruovaný stav:  ${GREEN}${REPLAYED_STATUS}${NC}"
echo -e "  Poznámka:             ${NOTE}"
echo ""

# --- Porovnání ---
step "Porovnání DB stavu vs. replay stavu"
if [ "$DB_STATUS" = "$REPLAYED_STATUS" ]; then
  pass "DB stav ($DB_STATUS) == replay stav ($REPLAYED_STATUS)"
else
  fail "Neshoda! DB: $DB_STATUS, Replay: $REPLAYED_STATUS"
fi

# --- Shrnutí ---
echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${GREEN}${BOLD}  EVENT SOURCING FUNGUJE!${NC}"
echo -e "${BOLD}============================================================${NC}"
echo ""
echo "  Objednávka:      $ORDER_ID"
echo "  Počet eventů:    $EVENT_COUNT"
echo "  Stav v DB:       $DB_STATUS"
echo "  Stav z replay:   $REPLAYED_STATUS"
echo ""
echo "  Klíčový princip:"
echo "  Stav '${REPLAYED_STATUS}' byl odvozen POUZE přehráním"
echo "  ${EVENT_COUNT} eventů z tabulky order_event_store,"
echo "  bez jediného dotazu do tabulky jhi_order."
echo ""
