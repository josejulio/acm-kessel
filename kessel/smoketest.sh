#!/bin/bash
# Don't use set -e because we want to continue testing even if some tests fail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

NAMESPACE="acm-kessel"
FAILED_TESTS=0
PASSED_TESTS=0

# Function to print test result
print_test() {
    local test_name=$1
    local result=$2
    if [ "$result" = "PASS" ]; then
        echo -e "${GREEN}✓${NC} $test_name"
        ((PASSED_TESTS++))
    else
        echo -e "${RED}✗${NC} $test_name"
        ((FAILED_TESTS++))
    fi
}

# Function to run test
run_test() {
    local test_name=$1
    shift
    local cmd="$*"
    # Execute the command in a subshell to handle pipes properly
    if eval "$cmd" > /dev/null 2>&1; then
        print_test "$test_name" "PASS"
        return 0
    else
        print_test "$test_name" "FAIL"
        return 1
    fi
}

echo -e "${BLUE}=====================================${NC}"
echo -e "${BLUE}  Kessel Stack Smoke Tests${NC}"
echo -e "${BLUE}=====================================${NC}"
echo ""

# ============================================================================
# 1. PostgreSQL Tests
# ============================================================================
echo -e "${YELLOW}Testing PostgreSQL...${NC}"

run_test "PostgreSQL pod is running" \
    "kubectl get pod -n ${NAMESPACE} -l app=acm-kessel-postgres -o jsonpath='{.items[0].status.phase}' | grep -q 'Running'"

run_test "PostgreSQL is accepting connections" \
    "kubectl exec -n ${NAMESPACE} deployment/acm-kessel-postgres -- psql -U inventoryapi -d inventory -c 'SELECT 1' | grep -q '1 row'"

run_test "Inventory database exists" \
    "kubectl exec -n ${NAMESPACE} deployment/acm-kessel-postgres -- psql -U inventoryapi -d inventory -c \"SELECT datname FROM pg_database WHERE datname='inventory'\" | grep -q 'inventory'"

run_test "Inventory user can query database" \
    "kubectl exec -n ${NAMESPACE} deployment/acm-kessel-postgres -- psql -U inventoryapi -d inventory -c 'SELECT current_user' | grep -q 'inventoryapi'"

run_test "RBAC database exists" \
    "kubectl exec -n ${NAMESPACE} deployment/acm-kessel-postgres -- psql -U rbacuser -d rbac -c \"SELECT datname FROM pg_database WHERE datname='rbac'\" | grep -q 'rbac'"

run_test "RBAC user can query database" \
    "kubectl exec -n ${NAMESPACE} deployment/acm-kessel-postgres -- psql -U rbacuser -d rbac -c 'SELECT current_user' | grep -q 'rbacuser'"

run_test "RBAC tables exist" \
    "kubectl exec -n ${NAMESPACE} deployment/acm-kessel-postgres -- psql -U rbacuser -d rbac -c '\dt' | grep -q 'api_tenant'"

echo ""

# ============================================================================
# 2. Redis Tests
# ============================================================================
echo -e "${YELLOW}Testing Redis...${NC}"

run_test "Redis pod is running" \
    "kubectl get pod -n ${NAMESPACE} -l app=acm-kessel-rbac-redis -o jsonpath='{.items[0].status.phase}' | grep -q 'Running'"

run_test "Redis is accepting connections" \
    "kubectl exec -n ${NAMESPACE} deployment/acm-kessel-rbac-redis -- redis-cli ping | grep -q 'PONG'"

run_test "Redis can set/get keys" \
    "kubectl exec -n ${NAMESPACE} deployment/acm-kessel-rbac-redis -- sh -c \"redis-cli set smoketest 'ok' && redis-cli get smoketest\" | grep -q 'ok'"

echo ""

# ============================================================================
# 3. SpiceDB Tests
# ============================================================================
echo -e "${YELLOW}Testing SpiceDB...${NC}"

run_test "SpiceDB Operator is running" \
    "kubectl get pod -n ${NAMESPACE} -l app=spicedb-operator -o jsonpath='{.items[0].status.phase}' | grep -q 'Running'"

run_test "SpiceDB pod is running" \
    "kubectl get pod -n ${NAMESPACE} -l app.kubernetes.io/component=spicedb -o jsonpath='{.items[0].status.phase}' | grep -q 'Running'"

echo ""

# ============================================================================
# 4. Relations API Tests
# ============================================================================
echo -e "${YELLOW}Testing Relations API...${NC}"

run_test "Relations API pod is running" \
    "kubectl get pod -n ${NAMESPACE} -l app=acm-kessel-relations-api -o jsonpath='{.items[0].status.phase}' | grep -q 'Running'"

# Test with grpcurl if available
if command -v grpcurl &> /dev/null; then
    echo -e "${BLUE}  Using grpcurl for detailed testing...${NC}"

    # Port forward for grpcurl tests
    kubectl port-forward -n ${NAMESPACE} svc/acm-kessel-relations-api 9000:9000 &
    PF_PID=$!
    sleep 2

    run_test "Relations API lists services" \
        "grpcurl -plaintext localhost:9000 list | grep -q 'kessel.relations'"

    run_test "Relations API health check via gRPC" \
        "grpcurl -plaintext -d '{\"service\":\"\"}' localhost:9000 grpc.health.v1.Health/Check | grep -q 'SERVING'"

    run_test "Relations API exposes KesselTupleService" \
        "grpcurl -plaintext localhost:9000 list | grep -q 'kessel.relations.v1beta1.KesselTupleService'"

    run_test "Relations API exposes KesselCheckService" \
        "grpcurl -plaintext localhost:9000 list | grep -q 'kessel.relations.v1beta1.KesselCheckService'"

    # Cleanup port forward
    kill $PF_PID 2>/dev/null || true
else
    echo -e "${YELLOW}  Skipping detailed gRPC tests (grpcurl not installed)${NC}"
    echo -e "${YELLOW}  Install: brew install grpcurl${NC}"
fi

echo ""

# ============================================================================
# 5. Inventory API Tests
# ============================================================================
echo -e "${YELLOW}Testing Inventory API...${NC}"

run_test "Inventory API pod is running" \
    "kubectl get pod -n ${NAMESPACE} -l app=acm-kessel-inventory-api -o jsonpath='{.items[0].status.phase}' | grep -q 'Running'"

# Test with grpcurl if available
if command -v grpcurl &> /dev/null; then
    echo -e "${BLUE}  Using grpcurl for detailed testing...${NC}"

    # Port forward for grpcurl tests
    kubectl port-forward -n ${NAMESPACE} svc/acm-kessel-inventory-api 9001:9000 &
    PF_PID=$!
    sleep 2

    run_test "Inventory API lists services" \
        "grpcurl -plaintext localhost:9001 list | grep -q 'kessel.inventory'"

    run_test "Inventory API health check via gRPC" \
        "grpcurl -plaintext -d '{\"service\":\"\"}' localhost:9001 grpc.health.v1.Health/Check | grep -q 'SERVING'"

    run_test "Inventory API exposes KesselInventoryService" \
        "grpcurl -plaintext localhost:9001 list | grep -q 'kessel.inventory.v1beta2.KesselInventoryService'"

    # Cleanup port forward
    kill $PF_PID 2>/dev/null || true
else
    echo -e "${YELLOW}  Skipping detailed gRPC tests (grpcurl not installed)${NC}"
fi

echo ""

# ============================================================================
# 6. RBAC API Tests
# ============================================================================
echo -e "${YELLOW}Testing RBAC API...${NC}"

run_test "RBAC API pod is running" \
    "kubectl get pod -n ${NAMESPACE} -l app=acm-kessel-rbac-api -o jsonpath='{.items[0].status.phase}' | grep -q 'Running'"

run_test "RBAC Redis is running" \
    "kubectl get pod -n ${NAMESPACE} -l app=acm-kessel-rbac-redis -o jsonpath='{.items[0].status.phase}' | grep -q 'Running'"

run_test "RBAC API status endpoint responds" \
    "kubectl exec -n ${NAMESPACE} deployment/acm-kessel-rbac-api -- curl -s http://localhost:8080/api/rbac/v1/status/ | grep -q 'api_version'"

run_test "RBAC API returns valid JSON" \
    "kubectl exec -n ${NAMESPACE} deployment/acm-kessel-rbac-api -- sh -c 'curl -s http://localhost:8080/api/rbac/v1/status/ | python3 -m json.tool' &> /dev/null"

# Port forward for external testing
kubectl port-forward -n ${NAMESPACE} svc/acm-kessel-rbac-api 8080:8080 &
PF_PID=$!
sleep 2

run_test "RBAC API accessible via port-forward" \
    "curl -s http://localhost:8080/api/rbac/v1/status/ | grep -q 'api_version'"

# Test OpenAPI schema
run_test "RBAC API OpenAPI schema available" \
    "curl -s http://localhost:8080/api/rbac/v1/openapi.json | grep -q 'openapi'"

# Test with authentication header (development mode)
IDENTITY='{"identity":{"account_number":"12345","org_id":"67890","type":"User","user":{"username":"smoketest","email":"smoketest@example.com","is_org_admin":true}}}'
ENCODED=$(echo -n "$IDENTITY" | base64 -w0 2>/dev/null || echo -n "$IDENTITY" | base64)

run_test "RBAC API accepts authenticated requests" \
    "curl -s -H 'x-rh-identity: $ENCODED' http://localhost:8080/api/rbac/v1/roles/ | grep -q -E 'data|count'"

# Test database connectivity (this will fail if database auth is broken)
run_test "RBAC API can query database (roles endpoint returns JSON)" \
    "curl -s -H 'x-rh-identity: $ENCODED' http://localhost:8080/api/rbac/v1/roles/ | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null"

run_test "RBAC API database has platform roles" \
    "curl -s -H 'x-rh-identity: $ENCODED' http://localhost:8080/api/rbac/v1/roles/ | python3 -c 'import sys,json; d=json.load(sys.stdin); exit(0 if d.get(\"meta\",{}).get(\"count\",0) > 0 else 1)' 2>/dev/null"

# Test workspace CRUD operations (V2 API)
WORKSPACE_NAME="smoketest-workspace-$$"
WORKSPACE_DESC="Smoke test workspace created at $(date)"

run_test "RBAC API can create workspace" \
    "curl -s -X POST -H 'x-rh-identity: $ENCODED' -H 'Content-Type: application/json' -d '{\"name\":\"$WORKSPACE_NAME\",\"description\":\"$WORKSPACE_DESC\"}' http://localhost:8080/api/rbac/v2/workspaces/ | python3 -c 'import sys,json; d=json.load(sys.stdin); exit(0 if \"id\" in d else 1)' 2>/dev/null"

# Get the workspace ID
WORKSPACE_ID=$(curl -s -H "x-rh-identity: $ENCODED" http://localhost:8080/api/rbac/v2/workspaces/ | python3 -c "import sys,json; d=json.load(sys.stdin); ws=[w for w in d.get('data',[]) if w.get('name')=='$WORKSPACE_NAME']; print(ws[0]['id'] if ws else '')" 2>/dev/null)

run_test "RBAC API can query created workspace" \
    "test -n '$WORKSPACE_ID' && curl -s -H 'x-rh-identity: $ENCODED' http://localhost:8080/api/rbac/v2/workspaces/$WORKSPACE_ID/ | python3 -c 'import sys,json; d=json.load(sys.stdin); exit(0 if d.get(\"name\")==\"$WORKSPACE_NAME\" else 1)' 2>/dev/null"

run_test "RBAC API can delete workspace" \
    "test -n '$WORKSPACE_ID' && curl -s -X DELETE -H 'x-rh-identity: $ENCODED' http://localhost:8080/api/rbac/v2/workspaces/$WORKSPACE_ID/ -w '%{http_code}' | grep -q '204'"

run_test "RBAC API workspace is deleted" \
    "test -n '$WORKSPACE_ID' && curl -s -H 'x-rh-identity: $ENCODED' http://localhost:8080/api/rbac/v2/workspaces/$WORKSPACE_ID/ -w '%{http_code}' | grep -q '404'"

# Cleanup port forward
kill $PF_PID 2>/dev/null || true

echo ""

# ============================================================================
# 7. Integration Tests
# ============================================================================
echo -e "${YELLOW}Testing Integration...${NC}"

run_test "All expected pods are running" \
    "test \$(kubectl get pods -n ${NAMESPACE} --field-selector=status.phase=Running --no-headers | wc -l) -ge 7"

run_test "No pods are in CrashLoopBackOff" \
    "test \$(kubectl get pods -n ${NAMESPACE} --field-selector=status.phase=CrashLoopBackOff --no-headers 2>/dev/null | wc -l) -eq 0"

run_test "All deployments are ready" \
    "test \$(kubectl get deployments -n ${NAMESPACE} -o json | jq '[.items[] | select(.status.readyReplicas == .status.replicas)] | length') -eq \$(kubectl get deployments -n ${NAMESPACE} --no-headers | wc -l)"

echo ""

# ============================================================================
# Summary
# ============================================================================
echo -e "${BLUE}=====================================${NC}"
echo -e "${BLUE}  Test Results${NC}"
echo -e "${BLUE}=====================================${NC}"
echo -e "${GREEN}Passed: ${PASSED_TESTS}${NC}"
echo -e "${RED}Failed: ${FAILED_TESTS}${NC}"
echo ""

if [ $FAILED_TESTS -eq 0 ]; then
    echo -e "${GREEN}✓ All smoke tests passed!${NC}"
    exit 0
else
    echo -e "${RED}✗ Some tests failed. Check the output above for details.${NC}"
    exit 1
fi
