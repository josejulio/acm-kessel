#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="acm-kessel"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${BLUE}=====================================${NC}"
echo -e "${BLUE}  Kessel Stack Deployment (Vanilla K8s)${NC}"
echo -e "${BLUE}=====================================${NC}"
echo ""
echo -e "${GREEN}Configuration:${NC}"
echo -e "  Namespace: ${YELLOW}${NAMESPACE}${NC}"
echo -e "  RBAC Image: ${YELLOW}quay.io/cloudservices/rbac:latest${NC}"
echo ""

# Function to print step
print_step() {
    echo -e "\n${GREEN}>>> $1${NC}"
}

# Function to wait for deployment
wait_for_deployment() {
    local deployment=$1
    local timeout=${2:-120}
    print_step "Waiting for deployment/${deployment} to be ready (timeout: ${timeout}s)"
    kubectl wait --for=condition=available deployment/${deployment} -n ${NAMESPACE} --timeout=${timeout}s || {
        echo -e "${RED}Deployment ${deployment} failed to become ready${NC}"
        kubectl get pods -n ${NAMESPACE} -l app=${deployment}
        kubectl logs -n ${NAMESPACE} deployment/${deployment} --tail=50 || true
        return 1
    }
}

# Function to wait for pod
wait_for_pod() {
    local label=$1
    local timeout=${2:-120}
    print_step "Waiting for pod with label ${label} to be ready (timeout: ${timeout}s)"
    kubectl wait --for=condition=ready pod -l ${label} -n ${NAMESPACE} --timeout=${timeout}s || {
        echo -e "${RED}Pod with label ${label} failed to become ready${NC}"
        kubectl get pods -n ${NAMESPACE} -l ${label}
        return 1
    }
}

# Step 1: Create namespace
print_step "Step 1: Creating namespace ${NAMESPACE}"
cd "${SCRIPT_DIR}"
kubectl apply -f 00-namespace.yaml

# Step 2: Deploy PostgreSQL (development)
print_step "Step 2: Deploying PostgreSQL (development mode)"
cd "${SCRIPT_DIR}/postgres-dev"
kubectl apply -f 01-postgres-dev-secret.yaml
kubectl apply -f 02-postgres-dev-pvc.yaml
kubectl apply -f 05-postgres-init-rbac.yaml
kubectl apply -f 03-postgres-dev-deployment.yaml
kubectl apply -f 04-postgres-dev-service.yaml

wait_for_pod "app=acm-kessel-postgres" 120

# Ensure RBAC user and database exist using a Job
print_step "Ensuring RBAC database and user exist"
# Delete old job if it exists
kubectl delete job postgres-ensure-rbac-user -n ${NAMESPACE} 2>/dev/null || true
kubectl apply -f 06-postgres-ensure-rbac-job.yaml
# Wait for job to complete
kubectl wait --for=condition=complete --timeout=60s job/postgres-ensure-rbac-user -n ${NAMESPACE} || {
    echo -e "${YELLOW}Warning: RBAC user initialization job did not complete in time${NC}"
    kubectl logs -n ${NAMESPACE} job/postgres-ensure-rbac-user --tail=20 || true
}

echo -e "${GREEN}PostgreSQL deployed successfully${NC}"

# Step 3: Deploy SpiceDB Operator
print_step "Step 3: Deploying SpiceDB Operator"
cd "${SCRIPT_DIR}/operator"
kubectl apply -f 01-spicedb-operator.yaml

wait_for_deployment "spicedb-operator" 120

echo -e "${GREEN}SpiceDB Operator deployed successfully${NC}"

# Step 4: Deploy SpiceDB instance
print_step "Step 4: Deploying SpiceDB instance"
cd "${SCRIPT_DIR}/spicedb"
kubectl apply -f 02-spicedb-secret.yaml
kubectl apply -f 03-spicedb-cluster.yaml

# Wait for SpiceDB deployment (created by operator)
# Note: operator creates deployment with pattern: <cluster-name>-spicedb
sleep 10
wait_for_deployment "acm-kessel-spicedb-spicedb" 180

echo -e "${GREEN}SpiceDB deployed successfully${NC}"

# Step 5: Deploy Relations API
print_step "Step 5: Deploying Relations API"
cd "${SCRIPT_DIR}/relations-api"
kubectl apply -f 04-relations-api-configmap-schema.yaml
kubectl apply -f 05-relations-api-configmap-config.yaml
kubectl apply -f 06-relations-api-deployment.yaml
kubectl apply -f 07-relations-api-service.yaml

wait_for_deployment "acm-kessel-relations-api" 120

echo -e "${GREEN}Relations API deployed successfully${NC}"

# Step 6: Deploy Inventory API
print_step "Step 6: Deploying Inventory API"
cd "${SCRIPT_DIR}/inventory-api"
kubectl apply -f 09-inventory-api-configmap-schema-cache.yaml
kubectl apply -f 10-inventory-api-secret-config.yaml
kubectl apply -f 11-inventory-api-deployment.yaml
kubectl apply -f 12-inventory-api-service.yaml

wait_for_deployment "acm-kessel-inventory-api" 120

echo -e "${GREEN}Inventory API deployed successfully${NC}"

# Step 7: Deploy RBAC
print_step "Step 7: Deploying RBAC"
cd "${SCRIPT_DIR}/rbac"
kubectl apply -k .

# Wait for Redis first
wait_for_deployment "acm-kessel-rbac-redis" 120

# Then wait for RBAC API
wait_for_deployment "acm-kessel-rbac-api" 180

echo -e "${GREEN}RBAC deployed successfully${NC}"

# Step 8: Verify deployment
print_step "Step 8: Verifying deployment"
echo ""
echo -e "${BLUE}All Pods:${NC}"
kubectl get pods -n ${NAMESPACE}

echo ""
echo -e "${BLUE}All Services:${NC}"
kubectl get svc -n ${NAMESPACE}

echo ""
echo -e "${GREEN}=====================================${NC}"
echo -e "${GREEN}  Deployment Complete!${NC}"
echo -e "${GREEN}=====================================${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo ""
echo -e "1. Test Relations API:"
echo -e "   ${BLUE}kubectl port-forward svc/acm-kessel-relations-api 9000:9000 -n ${NAMESPACE}${NC}"
echo ""
echo -e "2. Test Inventory API:"
echo -e "   ${BLUE}kubectl port-forward svc/acm-kessel-inventory-api 9001:9000 -n ${NAMESPACE}${NC}"
echo ""
echo -e "3. Test RBAC API:"
echo -e "   ${BLUE}kubectl port-forward svc/acm-kessel-rbac-api 8080:8080 -n ${NAMESPACE}${NC}"
echo -e "   ${BLUE}curl http://localhost:8080/api/rbac/v1/status/${NC}"
echo ""
echo -e "4. Check logs:"
echo -e "   ${BLUE}kubectl logs -n ${NAMESPACE} deployment/acm-kessel-relations-api${NC}"
echo -e "   ${BLUE}kubectl logs -n ${NAMESPACE} deployment/acm-kessel-inventory-api${NC}"
echo -e "   ${BLUE}kubectl logs -n ${NAMESPACE} deployment/acm-kessel-rbac-api${NC}"
echo ""
echo -e "${GREEN}Happy deploying! 🚀${NC}"
