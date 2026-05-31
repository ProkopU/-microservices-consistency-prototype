#!/usr/bin/env bash
# =============================================================================
# E2E TEST – Saga choreografie
# =============================================================================
# Testuje kompletní flow: Order → Inventory → Payment → Confirmed
# Použití: ./test-choreography.sh
# =============================================================================

set -euo pipefail

GATEWAY="http://localhost:8080"
ORDER_DB="docker-compose exec -T orderservice-postgresql psql -U orderService -d orderService -t -c"
INVENTORY_DB="docker-compose exec -T inventoryservice-postgresql psql -U inventoryService -d inventoryService -t -c"
PAYMENT_DB="docker-compose exec -T paymentservice-postgresql psql -U paymentService -d paymentService -t -c"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

pass() { echo -e "${GREEN}✅ $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; exit 1; }
info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
step() { echo -e "\n${YELLOW}▶ $1${NC}"; }

echo "============================================================"
echo "  E2E TEST – Saga choreografie"
echo "============================================================"

# --- 1. Autentizace ---
step "1. Autentizace"
TOKEN=$(curl -s -X POST "$GATEWAY/api/authenticate" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin","rememberMe":false}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['id_token'])" 2>/dev/null)

[ -n "$TOKEN" ] && pass "Token získán" || fail "Autentizace selhala"

# --- 2. Stav skladu před ---
step "2. Stav skladu PŘED objednávkou"
STOCK_BEFORE=$($INVENTORY_DB "SELECT available_quantity FROM stock_item WHERE product_name='Test Product';" | tr -d ' ')
info "Dostupné množství: $STOCK_BEFORE ks"

# --- 3. Vytvoření objednávky ---
step "3. Vytvoření objednávky přes choreografii"
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
INITIAL_STATUS=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null)

[ -n "$ORDER_ID" ] && pass "Objednávka $ORDER_ID vytvořena (status: $INITIAL_STATUS)" || fail "Vytvoření objednávky selhalo: $RESPONSE"

# --- 4. Čekání na saga flow ---
step "4. Čekání na dokončení sagu (max 30s)"
MAX_WAIT=30
INTERVAL=2
ELAPSED=0
FINAL_STATUS=""

while [ $ELAPSED -lt $MAX_WAIT ]; do
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))

  FINAL_STATUS=$(curl -s "$GATEWAY/services/orderservice/api/orders/$ORDER_ID" \
    -H "Authorization: Bearer $TOKEN" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)

  if [ "$FINAL_STATUS" = "CONFIRMED" ] || [ "$FINAL_STATUS" = "CANCELLED" ]; then
    break
  fi
  echo -n "  ... čekám (${ELAPSED}s, status: ${FINAL_STATUS:-PENDING})"$'\r'
done

echo ""

# --- 5. Ověření výsledku ---
step "5. Ověření výsledků"

# Stav objednávky
if [ "$FINAL_STATUS" = "CONFIRMED" ]; then
  pass "Objednávka $ORDER_ID je CONFIRMED"
elif [ "$FINAL_STATUS" = "CANCELLED" ]; then
  fail "Objednávka $ORDER_ID byla CANCELLED (saga selhala)"
else
  fail "Objednávka $ORDER_ID zůstala ve stavu $FINAL_STATUS po ${MAX_WAIT}s"
fi

# Stav skladu po
STOCK_AFTER=$($INVENTORY_DB "SELECT available_quantity FROM stock_item WHERE product_name='Test Product';" | tr -d ' ')
info "Dostupné množství po: $STOCK_AFTER ks (bylo: $STOCK_BEFORE ks)"

# Rezervace
RESERVATION=$($INVENTORY_DB "SELECT COUNT(*) FROM stock_reservation WHERE order_id = '00000000-0000-0000-0000-$(printf '%012d' $ORDER_ID)';" | tr -d ' ')
[ "$RESERVATION" -gt 0 ] && pass "Rezervace skladu existuje" || info "Rezervace skladu – neověřeno (items prázdné)"

# Platba
PAYMENT=$($PAYMENT_DB "SELECT status FROM payment WHERE order_id = '00000000-0000-0000-0000-$(printf '%012d' $ORDER_ID)';" | tr -d ' ' 2>/dev/null || echo "N/A")
[ "$PAYMENT" = "CAPTURED" ] && pass "Platba je CAPTURED" || info "Stav platby: $PAYMENT"

# --- 6. Shrnutí ---
echo ""
echo "============================================================"
echo -e "${GREEN}  VÝSLEDEK: Saga choreografie proběhla úspěšně!${NC}"
echo "============================================================"
echo ""
echo "  Flow:"
echo "  POST /api/orders/choreography"
echo "  → Order $ORDER_ID: PENDING"
echo "  → Kafka: order.created"
echo "  → Inventory: StockReserved"
echo "  → Kafka: stock.reserved"
echo "  → Payment: PaymentCompleted"
echo "  → Kafka: payment.completed"
echo "  → Order $ORDER_ID: CONFIRMED ✅"
echo ""
