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
echo -e "${BLUE}  Kessel Stack Cleanup${NC}"
echo -e "${BLUE}=====================================${NC}"
echo ""
echo -e "${YELLOW}This will delete all Kessel components from namespace: ${NAMESPACE}${NC}"
echo -e "${RED}WARNING: This action cannot be undone!${NC}"
echo ""
read -p "Are you sure you want to continue? (yes/no): " -r
echo

if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo -e "${GREEN}Cleanup cancelled${NC}"
    exit 0
fi

# Function to print step
print_step() {
    echo -e "\n${GREEN}>>> $1${NC}"
}

# Step 1: Delete RBAC
print_step "Step 1: Deleting RBAC"
cd "${SCRIPT_DIR}/rbac"
kubectl delete -k . --ignore-not-found=true || true

# Step 2: Delete Inventory API
print_step "Step 2: Deleting Inventory API"
cd "${SCRIPT_DIR}/inventory-api"
kubectl delete -f 11-inventory-api-deployment.yaml --ignore-not-found=true || true
kubectl delete -f 12-inventory-api-service.yaml --ignore-not-found=true || true
kubectl delete -f 10-inventory-api-secret-config.yaml --ignore-not-found=true || true
kubectl delete -f 09-inventory-api-configmap-schema-cache.yaml --ignore-not-found=true || true

# Step 3: Delete Relations API
print_step "Step 3: Deleting Relations API"
cd "${SCRIPT_DIR}/relations-api"
kubectl delete -f 06-relations-api-deployment.yaml --ignore-not-found=true || true
kubectl delete -f 07-relations-api-service.yaml --ignore-not-found=true || true
kubectl delete -f 05-relations-api-configmap-config.yaml --ignore-not-found=true || true
kubectl delete -f 04-relations-api-configmap-schema.yaml --ignore-not-found=true || true

# Step 4: Delete SpiceDB instance
print_step "Step 4: Deleting SpiceDB instance"
cd "${SCRIPT_DIR}/spicedb"
kubectl delete -f 03-spicedb-cluster.yaml --ignore-not-found=true || true
kubectl delete -f 02-spicedb-secret.yaml --ignore-not-found=true || true

# Wait a bit for operator to clean up
echo -e "${YELLOW}Waiting for SpiceDB resources to be cleaned up...${NC}"
sleep 5

# Step 5: Delete SpiceDB Operator
print_step "Step 5: Deleting SpiceDB Operator"
cd "${SCRIPT_DIR}/operator"
kubectl delete -f 01-spicedb-operator.yaml --ignore-not-found=true || true

# Step 6: Delete PostgreSQL
print_step "Step 6: Deleting PostgreSQL (development)"
cd "${SCRIPT_DIR}/postgres-dev"
kubectl delete -f 06-postgres-ensure-rbac-job.yaml --ignore-not-found=true || true
kubectl delete -f 03-postgres-dev-deployment.yaml --ignore-not-found=true || true
kubectl delete -f 04-postgres-dev-service.yaml --ignore-not-found=true || true
kubectl delete -f 05-postgres-init-rbac.yaml --ignore-not-found=true || true
kubectl delete -f 02-postgres-dev-pvc.yaml --ignore-not-found=true || true
kubectl delete -f 01-postgres-dev-secret.yaml --ignore-not-found=true || true

# Step 7: Delete namespace (optional)
echo ""
read -p "Do you want to delete the namespace ${NAMESPACE}? (yes/no): " -r
echo

if [[ $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    print_step "Step 7: Deleting namespace ${NAMESPACE}"
    kubectl delete namespace ${NAMESPACE} --ignore-not-found=true || true
    echo -e "${GREEN}Namespace deleted${NC}"
else
    echo -e "${YELLOW}Namespace ${NAMESPACE} kept${NC}"
fi

echo ""
echo -e "${GREEN}=====================================${NC}"
echo -e "${GREEN}  Cleanup Complete!${NC}"
echo -e "${GREEN}=====================================${NC}"
echo ""
