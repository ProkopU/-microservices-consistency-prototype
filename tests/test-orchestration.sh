#!/usr/bin/env bash
# =============================================================================
# E2E TEST – Saga orchestrace
# =============================================================================
# Demonstruje klíčový rozdíl oproti choreografii:
#   - Orchestrátor (Order Service) explicitně řídí každý krok sagu
#   - Každý příchozí event je routován na dedikovaný orchestration handler
#   - Stav celého procesu je vždy viditelný na jednom místě
#
# Použití: bash test-orchestration.sh
# =============================================================================

set -euo pipefail

# docker-compose logs below needs the compose file in the cwd, so anchor
# to docker-compose/ regardless of where this script was invoked from.
cd "$(cd "$(dirname "$0")" && pwd)/../docker-compose"

GATEWAY="http://localhost:8080"
ORDER_SERVICE="http://localhost:8081"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

pass()  { echo -e "${GREEN}✅ $1${NC}"; }
fail()  { echo -e "${RED}❌ $1${NC}"; exit 1; }
info()  { echo -e "${BLUE}ℹ️  $1${NC}"; }
step()  { echo -e "\n${YELLOW}▶ $1${NC}"; }
orch()  { echo -e "  ${CYAN}🎯 $1${NC}"; }

echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}  E2E TEST – Saga orchestrace${NC}"
echo -e "${BOLD}============================================================${NC}"
echo ""
echo "  Princip: Order Service je centrální orchestrátor."
echo "  Každý krok sagu je explicitně schválen a řízen orchestrátorem."
echo "  Stav procesu je vždy viditelný na jednom místě."
echo ""
echo "  Srovnání s choreografií:"
echo "  Choreografie  → služby reagují AUTONOMNĚ na eventy"
echo "  Orchestrace   → orchestrátor EXPLICITNĚ řídí každý krok"
echo ""

# --- Autentizace ---
step "Autentizace"
TOKEN=$(curl -s -X POST "$GATEWAY/api/authenticate" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin","rememberMe":false}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['id_token'])" 2>/dev/null)
[ -n "$TOKEN" ] && pass "Token získán" || fail "Autentizace selhala"

# --- Vytvoření objednávky ---
step "Vytvoření objednávky přes orchestraci"
RESPONSE=$(curl -s -X POST "$GATEWAY/services/orderservice/api/orders/orchestration" \
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

# --- Čekání na dokončení ---
step "Čekání na dokončení orchestrovaného sagu (max 30s)"
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
[ "$FINAL_STATUS" = "CONFIRMED" ] && pass "Objednávka $ORDER_ID je CONFIRMED" || fail "Saga selhala – status: $FINAL_STATUS"

# --- Ověření z logů ---
step "Ověření orchestration logů"
echo ""
echo -e "  ${BOLD}Kroky orchestrátoru:${NC}"

LOGS=$(docker-compose logs orderservice 2>/dev/null | grep "ORCHESTRATION" | grep -v "DEBUG" | tail -20)

STEP1=$(echo "$LOGS" | grep "ReserveStock command sent for order $ORDER_ID")
STEP2=$(echo "$LOGS" | grep "Step 2.*stock reserved for order $ORDER_ID")
STEP3=$(echo "$LOGS" | grep "Step 3.*payment completed for order $ORDER_ID")
ROUTING_STOCK=$(echo "$LOGS" | grep "Routing StockReserved to orchestrator for order $ORDER_ID")
ROUTING_PAYMENT=$(echo "$LOGS" | grep "Routing PaymentCompleted to orchestrator for order $ORDER_ID")
CONFIRMED=$(echo "$LOGS" | grep "Saga completed.*order $ORDER_ID CONFIRMED")

if [ -n "$STEP1" ]; then
  orch "Step 1: $(echo "$STEP1" | sed 's/.*\[ORCHESTRATION\]//' | xargs)"
  pass "Krok 1 – ReserveStock command odeslán"
else
  fail "Krok 1 nenalezen v logách"
fi

if [ -n "$ROUTING_STOCK" ]; then
  orch "Router: StockReserved → orchestrator handler"
  pass "StockReserved routován na orchestrátor"
else
  fail "Routing StockReserved nenalezen"
fi

if [ -n "$STEP2" ]; then
  orch "Step 2: $(echo "$STEP2" | sed 's/.*\[ORCHESTRATION\]//' | xargs)"
  pass "Krok 2 – orchestrátor schválil platbu"
else
  fail "Krok 2 nenalezen v logách"
fi

if [ -n "$ROUTING_PAYMENT" ]; then
  orch "Router: PaymentCompleted → orchestrator handler"
  pass "PaymentCompleted routován na orchestrátor"
else
  fail "Routing PaymentCompleted nenalezen"
fi

if [ -n "$STEP3" ]; then
  orch "Step 3: $(echo "$STEP3" | sed 's/.*\[ORCHESTRATION\]//' | xargs)"
  pass "Krok 3 – orchestrátor potvrdil objednávku"
else
  fail "Krok 3 nenalezen v logách"
fi

# --- Shrnutí ---
echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${GREEN}${BOLD}  SAGA ORCHESTRACE FUNGUJE!${NC}"
echo -e "${BOLD}============================================================${NC}"
echo ""
echo "  Objednávka: $ORDER_ID → CONFIRMED"
echo ""
echo "  Orchestrátor explicitně řídil každý krok:"
echo "  1. Odeslal ReserveStock command do Inventory Service"
echo "  2. Přijal StockReserved → schválil platbu"  
echo "  3. Přijal PaymentCompleted → potvrdil objednávku"
echo ""
echo "  Klíčový rozdíl oproti choreografii:"
echo "  Každý event prošel rozhodnutím orchestrátoru."
echo "  Stav sagu byl vždy viditelný v Order Service."
echo ""
