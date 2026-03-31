#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="rbac-local"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RBAC_REPO_DIR="${SCRIPT_DIR}/insights-rbac"
RBAC_IMAGE="insights-rbac:local"
RBAC_REPO_URL="https://github.com/RedHatInsights/insights-rbac.git"
RBAC_BRANCH="master"
RBAC_FORK_URL="https://github.com/coderbydesign/insights-rbac.git"
RBAC_CHERRY_PICK_COMMIT="59606004bfe190b3f2ee33a382258ad0b8279877"

# Override variable to skip image loading (set SKIP_IMAGE_LOAD=true to bypass auto-detection)
SKIP_IMAGE_LOAD="${SKIP_IMAGE_LOAD:-false}"

echo -e "${BLUE}=====================================${NC}"
echo -e "${BLUE}  RBAC Local Stack Deployment${NC}"
echo -e "${BLUE}=====================================${NC}"
echo ""
echo -e "${GREEN}Configuration:${NC}"
echo -e "  Namespace: ${YELLOW}${NAMESPACE}${NC}"
echo -e "  RBAC Repository: ${YELLOW}${RBAC_REPO_URL}${NC}"
echo -e "  RBAC Branch: ${YELLOW}${RBAC_BRANCH}${NC}"
echo -e "  Cherry-pick Commit: ${YELLOW}${RBAC_CHERRY_PICK_COMMIT}${NC}"
echo -e "  RBAC Local Dir: ${YELLOW}${RBAC_REPO_DIR}${NC}"
echo -e "  RBAC Image: ${YELLOW}${RBAC_IMAGE}${NC}"
echo ""
echo -e "  Deployment order:"
echo -e "    0. Build and load RBAC Docker image"
echo -e "    1. Namespace"
echo -e "    2. SpiceDB Operator"
echo -e "    3. PostgreSQL (RBAC + Inventory databases)"
echo -e "    4. Kafka + Zookeeper (for Inventory & RBAC CDC)"
echo -e "    5. Debezium (Inventory WAL + RBAC outbox CDC)"
echo -e "    6. SpiceDB"
echo -e "    7. Relations API"
echo -e "    8. Inventory API"
echo -e "    9. RBAC (Redis + API + Kafka Consumer)"
echo -e "   10. Init Job (migrations + seeding + test data)"
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
        kubectl get pods -n ${NAMESPACE} | grep ${deployment} || true
        kubectl logs -n ${NAMESPACE} deployment/${deployment} --tail=50 2>/dev/null || true
        return 1
    }
}

# Function to wait for statefulset
wait_for_statefulset() {
    local sts=$1
    local timeout=${2:-120}
    print_step "Waiting for statefulset/${sts} to be ready (timeout: ${timeout}s)"
    kubectl wait --for=jsonpath='{.status.readyReplicas}'=1 statefulset/${sts} -n ${NAMESPACE} --timeout=${timeout}s || {
        echo -e "${RED}StatefulSet ${sts} failed to become ready${NC}"
        kubectl get pods -n ${NAMESPACE} -l app=${sts}
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

# Function to wait for job
wait_for_job() {
    local job=$1
    local timeout=${2:-60}
    print_step "Waiting for job/${job} to complete (timeout: ${timeout}s)"
    kubectl wait --for=condition=complete --timeout=${timeout}s job/${job} -n ${NAMESPACE} || {
        echo -e "${YELLOW}Warning: Job ${job} did not complete in time${NC}"
        kubectl logs -n ${NAMESPACE} job/${job} --tail=30 2>/dev/null || true
    }
}

# Step 0: Build and load RBAC Docker image
print_step "Step 0: Building and loading RBAC Docker image"

# Clone or update insights-rbac repo
if [ ! -d "${RBAC_REPO_DIR}" ]; then
    echo -e "${YELLOW}Cloning insights-rbac repository...${NC}"
    git clone "${RBAC_REPO_URL}" "${RBAC_REPO_DIR}" || {
        echo -e "${RED}Failed to clone RBAC repository${NC}"
        exit 1
    }
fi

# Ensure we're on the latest master branch
echo -e "${YELLOW}Updating to latest ${RBAC_BRANCH} branch...${NC}"
cd "${RBAC_REPO_DIR}"
git fetch origin || {
    echo -e "${RED}Failed to fetch from remote${NC}"
    exit 1
}
git checkout "${RBAC_BRANCH}" || {
    echo -e "${RED}Failed to checkout branch ${RBAC_BRANCH}${NC}"
    exit 1
}
git pull origin "${RBAC_BRANCH}" || {
    echo -e "${RED}Failed to pull latest changes${NC}"
    exit 1
}

# Add fork as remote if needed and cherry-pick commit
echo -e "${YELLOW}Adding fork remote and cherry-picking commit ${RBAC_CHERRY_PICK_COMMIT}...${NC}"
git remote add fork "${RBAC_FORK_URL}" 2>/dev/null || true
git fetch fork || {
    echo -e "${RED}Failed to fetch from fork${NC}"
    exit 1
}

# Check if we're already on a cherry-picked branch, if so delete it
git branch -D rbac-local-build 2>/dev/null || true

# Create a new branch for our build
git checkout -b rbac-local-build || {
    echo -e "${RED}Failed to create build branch${NC}"
    exit 1
}

# Cherry-pick the commit
git cherry-pick "${RBAC_CHERRY_PICK_COMMIT}" || {
    echo -e "${RED}Failed to cherry-pick commit ${RBAC_CHERRY_PICK_COMMIT}${NC}"
    echo -e "${YELLOW}You may need to resolve conflicts manually in ${RBAC_REPO_DIR}${NC}"
    exit 1
}

echo -e "${GREEN}✓ Successfully applied commit ${RBAC_CHERRY_PICK_COMMIT} on top of ${RBAC_BRANCH}${NC}"
cd "${SCRIPT_DIR}"

# Build the Docker image
echo -e "${YELLOW}Building ${RBAC_IMAGE} from ${RBAC_REPO_DIR}...${NC}"
docker build -t "${RBAC_IMAGE}" "${RBAC_REPO_DIR}" || {
    echo -e "${RED}Failed to build RBAC image${NC}"
    exit 1
}

# Detect Kubernetes environment and load image
if [[ "${SKIP_IMAGE_LOAD}" == "true" ]]; then
    echo -e "${YELLOW}Skipping image load (SKIP_IMAGE_LOAD=true)${NC}"
    echo -e "${YELLOW}Make sure the image is already available in your cluster!${NC}"
else
    echo -e "${YELLOW}Detecting Kubernetes environment...${NC}"
    KUBE_CONTEXT=$(kubectl config current-context)
    if [[ "${KUBE_CONTEXT}" == "minikube" ]]; then
        echo -e "${YELLOW}Detected Minikube - loading image...${NC}"
        minikube image load "${RBAC_IMAGE}" || {
            echo -e "${RED}Failed to load image into Minikube${NC}"
            exit 1
        }
    elif [[ "${KUBE_CONTEXT}" == kind-* ]]; then
        echo -e "${YELLOW}Detected Kind - loading image...${NC}"
        CLUSTER_NAME=$(echo "${KUBE_CONTEXT}" | sed 's/kind-//')
        kind load docker-image "${RBAC_IMAGE}" --name "${CLUSTER_NAME}" || {
            echo -e "${RED}Failed to load image into Kind${NC}"
            exit 1
        }
    else
        echo -e "${RED}════════════════════════════════════════════════════════════${NC}"
        echo -e "${RED}  ERROR: Unable to detect Kubernetes environment${NC}"
        echo -e "${RED}════════════════════════════════════════════════════════════${NC}"
        echo -e ""
        echo -e "Current context: ${YELLOW}${KUBE_CONTEXT}${NC}"
        echo -e ""
        echo -e "${YELLOW}The deployment script cannot automatically load the Docker image.${NC}"
        echo -e "${YELLOW}You must manually load it into your cluster.${NC}"
        echo -e ""
        echo -e "${GREEN}Steps to proceed:${NC}"
        echo -e ""
        echo -e "  ${BLUE}1.${NC} Load the image into your cluster:"
        echo -e ""
        echo -e "     ${BLUE}For Minikube:${NC}"
        echo -e "       minikube image load ${RBAC_IMAGE}"
        echo -e ""
        echo -e "     ${BLUE}For Kind:${NC}"
        echo -e "       kind load docker-image ${RBAC_IMAGE} --name <cluster-name>"
        echo -e ""
        echo -e "     ${BLUE}For other clusters:${NC}"
        echo -e "       Push to a registry accessible by your cluster"
        echo -e ""
        echo -e "  ${BLUE}2.${NC} Re-run the script with SKIP_IMAGE_LOAD=true:"
        echo -e ""
        echo -e "       ${GREEN}SKIP_IMAGE_LOAD=true ./deploy-rbac-local.sh${NC}"
        echo -e ""
        echo -e "${RED}Deployment aborted. Please follow the steps above.${NC}"
        echo -e ""
        exit 1
    fi
fi

echo -e "${GREEN}✓ RBAC Docker image ready${NC}"

# Step 1: Create namespace
print_step "Step 1: Creating namespace ${NAMESPACE}"
kubectl apply -f "${SCRIPT_DIR}/rbac/namespace.yaml"

# Step 2: Deploy SpiceDB Operator (needs to be first for CRDs)
print_step "Step 2: Deploying SpiceDB Operator"
kubectl apply -f "${SCRIPT_DIR}/operator/01-spicedb-operator.yaml"
wait_for_deployment "spicedb-operator" 120
echo -e "${GREEN}✓ SpiceDB Operator deployed${NC}"

# Step 3: Deploy PostgreSQL (shared for RBAC and Inventory)
print_step "Step 3: Deploying PostgreSQL (RBAC + Inventory databases)"
kubectl apply -f "${SCRIPT_DIR}/postgres/02-postgres-init-configmap.yaml"
kubectl apply -f "${SCRIPT_DIR}/postgres/01-postgres-service.yaml"
kubectl apply -f "${SCRIPT_DIR}/postgres/03-postgres-statefulset.yaml"
wait_for_statefulset "rbac-db" 120
echo -e "${GREEN}✓ PostgreSQL deployed (RBAC + Inventory databases)${NC}"

# Step 4: Deploy Kafka Infrastructure (for Inventory consumer)
print_step "Step 4: Deploying Kafka Infrastructure"
kubectl apply -f "${SCRIPT_DIR}/kafka-dev/01-zookeeper.yaml"
wait_for_pod "app=zookeeper" 120

kubectl apply -f "${SCRIPT_DIR}/kafka-dev/02-kafka.yaml"
wait_for_pod "app=kafka" 120

# Create Kafka topics
kubectl delete job kafka-create-topics -n ${NAMESPACE} 2>/dev/null || true
kubectl apply -f "${SCRIPT_DIR}/kafka-dev/03-create-topics.yaml"
wait_for_job "kafka-create-topics" 60
echo -e "${GREEN}✓ Kafka infrastructure deployed${NC}"

# Step 5: Deploy Debezium (Inventory + RBAC CDC)
print_step "Step 5: Deploying Debezium (Inventory + RBAC CDC)"
kubectl apply -f "${SCRIPT_DIR}/debezium/01-debezium-deployment.yaml"
kubectl apply -f "${SCRIPT_DIR}/debezium/02-debezium-service.yaml"
wait_for_deployment "acm-kessel-debezium" 120

# Configure Inventory connector (WAL messages)
kubectl apply -f "${SCRIPT_DIR}/debezium/03-debezium-connector-config.yaml"
kubectl delete job acm-kessel-debezium-setup -n ${NAMESPACE} 2>/dev/null || true
kubectl apply -f "${SCRIPT_DIR}/debezium/04-debezium-connector-setup-job.yaml"
wait_for_job "acm-kessel-debezium-setup" 90

# Configure RBAC connector (outbox table)
kubectl apply -f "${SCRIPT_DIR}/debezium/05-rbac-debezium-connector-config.yaml"
kubectl delete job rbac-debezium-setup -n ${NAMESPACE} 2>/dev/null || true
kubectl apply -f "${SCRIPT_DIR}/debezium/06-rbac-debezium-connector-setup-job.yaml"
wait_for_job "rbac-debezium-setup" 90

echo -e "${GREEN}✓ Debezium deployed (Inventory + RBAC connectors)${NC}"

# Step 6: Deploy SpiceDB
print_step "Step 6: Deploying SpiceDB"
kubectl apply -f "${SCRIPT_DIR}/spicedb/02-spicedb-secret.yaml"
kubectl apply -f "${SCRIPT_DIR}/spicedb/03-spicedb-cluster.yaml"

echo -e "${YELLOW}Waiting for SpiceDB operator to create deployment...${NC}"
sleep 10
wait_for_deployment "acm-kessel-spicedb-spicedb" 180
echo -e "${GREEN}✓ SpiceDB deployed${NC}"

# Step 7: Deploy Relations API
print_step "Step 7: Deploying Relations API"
kubectl apply -f "${SCRIPT_DIR}/relations-api/01-relations-api-configmap-schema.yaml"
kubectl apply -f "${SCRIPT_DIR}/relations-api/02-relations-api-secret-config.yaml"
kubectl apply -f "${SCRIPT_DIR}/relations-api/03-relations-api-deployment.yaml"
kubectl apply -f "${SCRIPT_DIR}/relations-api/04-relations-api-service.yaml"
wait_for_deployment "acm-kessel-relations-api" 120
echo -e "${GREEN}✓ Relations API deployed${NC}"

# Step 8: Deploy Inventory API
print_step "Step 8: Deploying Inventory API"
kubectl apply -f "${SCRIPT_DIR}/inventory-api/01-inventory-api-configmap-schema-cache.yaml"
kubectl apply -f "${SCRIPT_DIR}/inventory-api/02-inventory-api-secret-config.yaml"
kubectl apply -f "${SCRIPT_DIR}/inventory-api/03-inventory-api-deployment.yaml"
kubectl apply -f "${SCRIPT_DIR}/inventory-api/04-inventory-api-service.yaml"
wait_for_deployment "acm-kessel-inventory-api" 120
echo -e "${GREEN}✓ Inventory API deployed${NC}"

# Step 9: Deploy RBAC
print_step "Step 9: Deploying RBAC (Redis + API + Kafka Consumer)"
kubectl apply -f "${SCRIPT_DIR}/rbac/redis.yaml"
kubectl apply -f "${SCRIPT_DIR}/rbac/configmap.yaml"
kubectl apply -f "${SCRIPT_DIR}/rbac/roles-configmap.yaml"
kubectl apply -f "${SCRIPT_DIR}/rbac/permissions-configmap.yaml"
wait_for_pod "app=rbac-redis" 120
kubectl apply -f "${SCRIPT_DIR}/rbac/rbac-server.yaml"
wait_for_deployment "rbac-server" 120

# Deploy Kafka consumer
kubectl apply -f "${SCRIPT_DIR}/rbac/clowder-configmap.yaml"
kubectl apply -f "${SCRIPT_DIR}/rbac/kafka-consumer-deployment.yaml"
wait_for_deployment "rbac-kafka-consumer" 120
echo -e "${GREEN}✓ RBAC deployed (API + Kafka Consumer)${NC}"

# Verification
print_step "Verifying deployment"
echo ""
echo -e "${BLUE}All Pods:${NC}"
kubectl get pods -n ${NAMESPACE}

echo ""
echo -e "${BLUE}All Services:${NC}"
kubectl get svc -n ${NAMESPACE}

echo ""
echo -e "${BLUE}All Deployments:${NC}"
kubectl get deployments -n ${NAMESPACE}

# Step 10: Run Init Job (migrations + seeding + test data)
print_step "Step 10: Running Init Job (migrations + seeding + test data)"
echo -e "${YELLOW}All infrastructure is ready. Running database migrations and seeding...${NC}"
echo -e "${YELLOW}This will take a few minutes...${NC}"

kubectl delete job rbac-init -n ${NAMESPACE} 2>/dev/null || true
kubectl apply -f "${SCRIPT_DIR}/rbac/init-job.yaml"
wait_for_job "rbac-init" 300

# Check init job status
if kubectl get job rbac-init -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' | grep -q "True"; then
    echo -e "${GREEN}✓ Init Job completed successfully${NC}"
    echo ""
    echo -e "${BLUE}Init Job Output (last 30 lines):${NC}"
    kubectl logs -n ${NAMESPACE} job/rbac-init --tail=30
else
    echo -e "${RED}✗ Init Job failed${NC}"
    echo -e "${RED}Check logs with: kubectl logs -n ${NAMESPACE} job/rbac-init${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}=====================================${NC}"
echo -e "${GREEN}  Deployment Complete!${NC}"
echo -e "${GREEN}=====================================${NC}"
echo ""
echo -e "${YELLOW}Deployed Components:${NC}"
echo ""
echo -e "  ${GREEN}✓${NC} RBAC Docker image (insights-rbac:local)"
echo -e "  ${GREEN}✓${NC} SpiceDB Operator + SpiceDB"
echo -e "  ${GREEN}✓${NC} PostgreSQL (RBAC + Inventory databases)"
echo -e "  ${GREEN}✓${NC} Kafka + Zookeeper"
echo -e "  ${GREEN}✓${NC} Debezium CDC (2 connectors: Inventory WAL + RBAC outbox)"
echo -e "  ${GREEN}✓${NC} Relations API"
echo -e "  ${GREEN}✓${NC} Inventory API (with Kafka consumer)"
echo -e "  ${GREEN}✓${NC} RBAC API + Redis + Kafka Consumer"
echo -e "  ${GREEN}✓${NC} Init Job (migrations + seeding + test data)"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo ""
echo -e "1. Port-forward services:"
echo -e "   ${BLUE}kubectl port-forward svc/rbac-server 8080:8080 -n ${NAMESPACE}${NC}"
echo -e "   ${BLUE}kubectl port-forward svc/acm-kessel-inventory-api 8000:8000 -n ${NAMESPACE}${NC}"
echo -e "   ${BLUE}kubectl port-forward svc/acm-kessel-relations-api 9000:9000 -n ${NAMESPACE}${NC}"
echo ""
echo -e "2. Test RBAC API (dev mode enabled - no auth required):"
echo -e "   ${BLUE}curl http://localhost:8080/api/rbac/v1/status/${NC}"
echo -e "   ${BLUE}curl http://localhost:8080/api/rbac/v1/roles/${NC}"
echo ""
echo -e "3. Test with different tenants (dev mode headers):"
echo -e "   ${BLUE}# As org admin in test_org_01${NC}"
echo -e "   ${BLUE}curl -H 'X-Dev-Org-Id: test_org_01' -H 'X-Dev-Username: org_admin_test_org_01' \\${NC}"
echo -e "   ${BLUE}     http://localhost:8080/api/rbac/v1/roles/${NC}"
echo ""
echo -e "   ${BLUE}# As non-admin in test_org_02${NC}"
echo -e "   ${BLUE}curl -H 'X-Dev-Org-Id: test_org_02' -H 'X-Dev-Username: regular_user_test_org_02' \\${NC}"
echo -e "   ${BLUE}     -H 'X-Dev-Is-Org-Admin: false' http://localhost:8080/api/rbac/v1/access/?application=rbac${NC}"
echo ""
echo -e "${YELLOW}Test Data Provisioned:${NC}"
echo -e "  3 test orgs: test_org_01, test_org_02, test_org_03"
echo -e "  Each with 3 users: org_admin_*, regular_user_*, readonly_user_*"
echo -e "  (See init job logs above for details)"
echo ""
echo -e "${GREEN}Happy testing! 🚀${NC}"
