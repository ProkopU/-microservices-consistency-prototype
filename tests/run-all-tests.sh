#!/usr/bin/env bash
# =============================================================================
# Spustí všechny E2E testy v pořadí
# Použití: bash run-all-tests.sh
# =============================================================================

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCKER_DIR="$(cd "$TESTS_DIR/../docker-compose" && pwd)"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; NC='\033[0m'

PASSED=0; FAILED=0; RESULTS=()

run_test() {
  local name="$1"
  local file="$2"
  echo ""
  echo -e "${YELLOW}${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo -e "${YELLOW}${BOLD}  Spouštím: $name${NC}"
  echo -e "${YELLOW}${BOLD}════════════════════════════════════════════════════════════${NC}"

  if bash "$file"; then
    PASSED=$((PASSED + 1))
    RESULTS+=("${GREEN}✅ $name${NC}")
  else
    FAILED=$((FAILED + 1))
    RESULTS+=("${RED}❌ $name${NC}")
  fi
}

# Přepni do docker-compose adresáře (testy ho potřebují)
cd "$DOCKER_DIR"

echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  E2E TEST SUITE – Přístupy ke konzistenci dat${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"

run_test "Synchronní baseline"    "$TESTS_DIR/test-synchronous.sh"
run_test "Saga choreografie"      "$TESTS_DIR/test-choreography.sh"
run_test "Outbox pattern"         "$TESTS_DIR/test-outbox.sh"
run_test "Event sourcing"         "$TESTS_DIR/test-event-sourcing.sh"
run_test "Saga orchestrace"       "$TESTS_DIR/test-orchestration.sh"

# Shrnutí
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  VÝSLEDKY${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
echo ""
for r in "${RESULTS[@]}"; do
  echo -e "  $r"
done
echo ""
echo -e "  Prošlo: ${GREEN}${PASSED}${NC}  |  Selhalo: ${RED}${FAILED}${NC}"
echo ""

[ "$FAILED" -eq 0 ] && exit 0 || exit 1
