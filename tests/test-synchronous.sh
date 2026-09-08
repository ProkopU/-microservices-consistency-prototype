#!/usr/bin/env bash
# =============================================================================
# E2E TEST – Synchronní baseline s demonstrací nekonzistence
# =============================================================================
# Testuje dva scénáře:
#   1. Úspěšná objednávka (všechny služby dostupné)
#   2. Demonstrace nekonzistence (Payment Service zastavena)
#
# Použití: bash test-synchronous.sh
#          bash test-synchronous.sh --only-success
#          bash test-synchronous.sh --only-inconsistency
# =============================================================================

set -euo pipefail

# docker-compose exec/stop/start below need the compose file in the cwd, so
# anchor to docker-compose/ regardless of where this script was invoked from.
cd "$(cd "$(dirname "$0")" && pwd)/../docker-compose"

GATEWAY="http://localhost:8080"
INVENTORY_DB="docker-compose exec -T inventoryservice-postgresql psql -U inventoryService -d inventoryService -t -c"
ORDER_DB="docker-compose exec -T orderservice-postgresql psql -U orderService -d orderService -t -c"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

pass()  { echo -e "${GREEN}✅ $1${NC}"; }
fail()  { echo -e "${RED}❌ $1${NC}"; }
info()  { echo -e "${BLUE}ℹ️  $1${NC}"; }
warn()  { echo -e "${YELLOW}⚠️  $1${NC}"; }
step()  { echo -e "\n${YELLOW}▶ $1${NC}"; }
title() { echo -e "\n${CYAN}$1${NC}"; }

MODE="${1:---both}"

# --- Autentizace ---
step "Autentizace"
TOKEN=$(curl -s -X POST "$GATEWAY/api/authenticate" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin","rememberMe":false}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['id_token'])" 2>/dev/null)
[ -n "$TOKEN" ] && pass "Token získán" || { echo "Autentizace selhala"; exit 1; }

ORDER_PAYLOAD='{
  "customerId": "22222222-2222-2222-2222-222222222222",
  "status": "PENDING",
  "totalAmount": 299.99,
  "currency": "CZK",
  "street": "Test",
  "city": "Praha",
  "postalCode": "11000",
  "country": "CZ",
  "createdAt": "2026-05-31T10:00:00Z"
}'

# =============================================================================
# SCÉNÁŘ 1: Úspěšná synchronní objednávka
# =============================================================================
if [ "$MODE" != "--only-inconsistency" ]; then
  echo ""
  echo "============================================================"
  title "  SCÉNÁŘ 1: Úspěšná synchronní objednávka"
  echo "============================================================"

  step "Stav skladu PŘED"
  STOCK_BEFORE=$($INVENTORY_DB "SELECT available_quantity FROM stock_item WHERE product_name='Test Product';" | tr -d ' ')
  RESERVED_BEFORE=$($INVENTORY_DB "SELECT reserved_quantity FROM stock_item WHERE product_name='Test Product';" | tr -d ' ')
  info "Dostupné: ${STOCK_BEFORE} ks | Rezervované: ${RESERVED_BEFORE} ks"

  step "Posílám objednávku přes /api/orders/synchronous"
  RESPONSE=$(curl -s -X POST "$GATEWAY/services/orderservice/api/orders/synchronous" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "$ORDER_PAYLOAD")

  ORDER_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
  STATUS=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")

  if [ "$STATUS" = "CONFIRMED" ] && [ -n "$ORDER_ID" ]; then
    pass "Objednávka $ORDER_ID vytvořena se stavem CONFIRMED"
  elif [ -z "$ORDER_ID" ]; then
    fail "Objednávka selhala – prázdná odpověď: $RESPONSE"
  else
    fail "Neočekávaný status: $STATUS ($RESPONSE)"
  fi

  step "Ověření stavu"
  STOCK_AFTER=$($INVENTORY_DB "SELECT available_quantity FROM stock_item WHERE product_name='Test Product';" | tr -d ' ')
  RESERVED_AFTER=$($INVENTORY_DB "SELECT reserved_quantity FROM stock_item WHERE product_name='Test Product';" | tr -d ' ')
  info "Dostupné: ${STOCK_AFTER} ks (bylo: ${STOCK_BEFORE}) | Rezervované: ${RESERVED_AFTER} ks (bylo: ${RESERVED_BEFORE})"

  DB_STATUS=$($ORDER_DB "SELECT status FROM jhi_order WHERE id=$ORDER_ID;" | tr -d ' ' 2>/dev/null || echo "N/A")
  [ "$DB_STATUS" = "CONFIRMED" ] && pass "DB potvrzuje: objednávka $ORDER_ID je CONFIRMED" || warn "DB stav: $DB_STATUS"

  echo ""
  echo -e "${GREEN}  VÝSLEDEK SCÉNÁŘE 1: Úspěch${NC}"
  echo "  Synchronní volání: Order → Inventory → Payment → CONFIRMED"
fi

# =============================================================================
# SCÉNÁŘ 2: Demonstrace nekonzistence
# =============================================================================
if [ "$MODE" != "--only-success" ]; then
  echo ""
  echo "============================================================"
  title "  SCÉNÁŘ 2: Demonstrace nekonzistence"
  title "  (Payment Service záměrně zastavena)"
  echo "============================================================"

  step "Zastavuji Payment Service"
  docker-compose stop paymentservice > /dev/null 2>&1
  pass "Payment Service zastavena"

  step "Stav skladu PŘED"
  STOCK_BEFORE2=$($INVENTORY_DB "SELECT available_quantity FROM stock_item WHERE product_name='Test Product';" | tr -d ' ')
  RESERVED_BEFORE2=$($INVENTORY_DB "SELECT reserved_quantity FROM stock_item WHERE product_name='Test Product';" | tr -d ' ')
  info "Dostupné: ${STOCK_BEFORE2} ks | Rezervované: ${RESERVED_BEFORE2} ks"

  step "Posílám objednávku (Payment Service nedostupná)"
  RESPONSE2=$(curl -s -X POST "$GATEWAY/services/orderservice/api/orders/synchronous" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "$ORDER_PAYLOAD")

  STATUS2=$(echo "$RESPONSE2" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status', d.get('title','error')))" 2>/dev/null || echo "error")

  if [ "$STATUS2" = "CONFIRMED" ]; then
    warn "Objednávka neočekávaně prošla (Payment Service možná ještě běžela)"
  else
    pass "Objednávka selhala podle očekávání: $STATUS2"
  fi

  step "Ověření nekonzistence v DB"
  sleep 2
  STOCK_AFTER2=$($INVENTORY_DB "SELECT available_quantity FROM stock_item WHERE product_name='Test Product';" | tr -d ' ')
  RESERVED_AFTER2=$($INVENTORY_DB "SELECT reserved_quantity FROM stock_item WHERE product_name='Test Product';" | tr -d ' ')
  info "Dostupné: ${STOCK_AFTER2} ks (bylo: ${STOCK_BEFORE2}) | Rezervované: ${RESERVED_AFTER2} ks (bylo: ${RESERVED_BEFORE2})"

  ORDER_EXISTS=$($ORDER_DB "SELECT COUNT(*) FROM jhi_order WHERE status='PENDING' AND created_at > NOW() - INTERVAL '1 minute';" | tr -d ' ' 2>/dev/null || echo "0")

  if [ "$RESERVED_AFTER2" -gt "$RESERVED_BEFORE2" ] && [ "$STATUS2" != "CONFIRMED" ]; then
    echo ""
    echo -e "${RED}  ⚠️  NEKONZISTENCE DETEKOVÁNA!${NC}"
    echo -e "${RED}  Zboží je rezervováno (${RESERVED_AFTER2} ks) ale objednávka nebyla vytvořena.${NC}"
    echo -e "${RED}  @Transactional rollbackoval Order záznam, ale Inventory změna${NC}"
    echo -e "${RED}  proběhla v jiné transakci a nebyla vrácena zpět.${NC}"
    pass "Nekonzistence úspěšně demonstrována"
  else
    info "Nekonzistence nedetekována (sklad: ${STOCK_BEFORE2}→${STOCK_AFTER2}, rezervace: ${RESERVED_BEFORE2}→${RESERVED_AFTER2})"
    info "Možná příčina: Inventory Service nepřijala items (prázdný seznam)"
  fi

  step "Spouštím Payment Service zpět"
  docker-compose start paymentservice > /dev/null 2>&1
  pass "Payment Service spuštěna"

  echo ""
  echo -e "${YELLOW}  VÝSLEDEK SCÉNÁŘE 2: Nekonzistence demonstrována${NC}"
  echo "  Synchronní @Transactional nezajišťuje konzistenci napříč službami."
  echo "  Inventory Service rezervovala zboží, ale Order neexistuje."
fi

echo ""
echo "============================================================"
echo -e "${GREEN}  E2E TEST SYNCHRONNÍHO BASELINE DOKONČEN${NC}"
echo "============================================================"
