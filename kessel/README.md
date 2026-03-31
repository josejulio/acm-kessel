# Kessel Local Stack Deployment

Deploy a complete Kessel stack with RBAC, Inventory, and Relations APIs for local development and testing.

## Architecture

This deployment provides:
- **RBAC API** - Role management with Kafka consumer for replication events
- **Kessel Inventory API** - Resource inventory with Kafka consumer for resource events
- **Kessel Relations API** - Authorization tuples and permission checks
- **SpiceDB** - Zanzibar-based authorization storage and evaluation engine
- **PostgreSQL** - Database for RBAC and Inventory services
- **Kafka + Debezium** - CDC pipeline from both services to Relations API (simple Zookeeper + Kafka pods in `kafka-dev/`)
- **Redis** - RBAC caching layer

## CDC Pipelines

Both RBAC and Inventory replicate authorization tuples to Kessel Relations API via CDC:

### RBAC → Kessel Relations
```
RBAC API → management_outbox table (PostgreSQL)
  ↓
Debezium RBAC Connector (outbox pattern with EventRouter)
  ↓
Kafka Topics (routed by aggregatetype):
  - outbox.event.relations-replication-event (relations)
  - outbox.event.workspace (workspace events)
  ↓
RBAC Kafka Consumer (consumes relations topic)
  ↓
Kessel Relations API (gRPC)
  ↓
SpiceDB (authorization tuples)
```

**Note**: The Debezium EventRouter transforms outbox messages into topics using the pattern `outbox.event.<aggregatetype>`. Relations events have `aggregatetype=relations-replication-event`, and workspace events have `aggregatetype=workspace`.

### Inventory → Kessel Relations
```
Kessel Inventory API → pg_logical_emit_message (PostgreSQL WAL)
  ↓
Debezium Inventory Connector (WAL messages)
  ↓
Kafka Topic: outbox.event.kessel.tuples
  ↓
Inventory API Consumer
  ↓
Kessel Relations API (gRPC)
  ↓
SpiceDB (authorization tuples)
```

## Prerequisites

- Kubernetes cluster (Minikube, Kind, or other)
- Docker
- kubectl
- git

**Supported Environments:**
- ✅ Minikube (auto-detected via context: `minikube`)
- ✅ Kind (auto-detected via context: `kind-*`)
- ⚠️ Other clusters: Manual image loading required (see below)

## Quick Start

```bash
./deploy-rbac-local.sh
```

The script will:
1. Clone insights-rbac repository (if not present) from official RedHatInsights repository
2. Checkout latest master branch
3. Add fork remote (coderbydesign/insights-rbac) and cherry-pick commit `59606004bfe190b3f2ee33a382258ad0b8279877` on top of master
4. Build RBAC Docker image
5. Auto-detect your Kubernetes environment (Minikube/Kind) and load the image
6. Deploy all components in order
7. Run migrations and seed data
8. Provision test data (3 test organizations)

## Configuration

Edit `deploy-rbac-local.sh` to customize:

```bash
NAMESPACE="rbac-local"
RBAC_REPO_URL="https://github.com/RedHatInsights/insights-rbac.git"
RBAC_BRANCH="master"
RBAC_FORK_URL="https://github.com/coderbydesign/insights-rbac.git"
RBAC_CHERRY_PICK_COMMIT="59606004bfe190b3f2ee33a382258ad0b8279877"
```

**Note**: The fork URL is used to fetch the cherry-pick commit. The script automatically detects whether you're using Minikube or Kind and loads the Docker image accordingly.

### Manual Image Loading (for unsupported clusters)

If the script cannot auto-detect your Kubernetes environment, it will **fail** with instructions. To proceed:

1. Manually load the image into your cluster
2. Re-run with `SKIP_IMAGE_LOAD=true`:

```bash
# Example for unknown cluster type
docker save insights-rbac:local | your-cluster-load-command
SKIP_IMAGE_LOAD=true ./deploy-rbac-local.sh
```

## Test Data

The deployment provisions 3 test organizations:

| Org ID | Account | Users |
|--------|---------|-------|
| test_org_01 | acct_01 | org_admin_test_org_01 (100001), regular_user_test_org_01 (100002), readonly_user_test_org_01 (100003) |
| test_org_02 | acct_02 | org_admin_test_org_02 (100101), regular_user_test_org_02 (100102), readonly_user_test_org_02 (100103) |
| test_org_03 | acct_03 | org_admin_test_org_03 (100201), regular_user_test_org_03 (100202), readonly_user_test_org_03 (100203) |

## Testing

### Port Forward Services

```bash
# RBAC API (role management)
kubectl port-forward svc/rbac-server 8080:8080 -n rbac-local

# Kessel Inventory API (resources and workspaces)
kubectl port-forward svc/acm-kessel-inventory-api 8000:8000 -n rbac-local

# Kessel Relations API (authorization checks)
kubectl port-forward svc/acm-kessel-relations-api 9000:9000 -n rbac-local
```

### Test RBAC API (Dev Mode)

The RBAC API runs in dev mode with header-based authentication:

```bash
# Status check
curl http://localhost:8080/api/rbac/v1/status/

# List roles
curl http://localhost:8080/api/rbac/v1/roles/

# As org admin
curl -H 'X-Dev-Org-Id: test_org_01' \
     -H 'X-Dev-Username: org_admin_test_org_01' \
     http://localhost:8080/api/rbac/v1/roles/

# As non-admin
curl -H 'X-Dev-Org-Id: test_org_02' \
     -H 'X-Dev-Username: regular_user_test_org_02' \
     -H 'X-Dev-Is-Org-Admin: false' \
     http://localhost:8080/api/rbac/v1/access/?application=rbac
```

## Custom Roles

The deployment uses custom role definitions instead of built-in ones:

- **ACM Administrator** - Full ACM cluster access
- **User Access administrator** - Full RBAC permissions
- **User Access principal viewer** - Read-only principal access

Role definitions: `rbac/roles-configmap.yaml`
Permission definitions: `rbac/permissions-configmap.yaml`

## Security Notes

All secrets in this deployment use placeholder values (e.g., `CHANGE_ME_REPLACE_WITH_RANDOM_KEY`) suitable for local development only. These are **not** production secrets and are safe to check into version control for local testing.

For production deployments, you must:
- Generate proper random keys: `openssl rand -base64 32`
- Use proper Kubernetes secret management
- Never commit real secrets to version control

## Cleanup

```bash
kubectl delete namespace rbac-local
```

This will remove all deployed resources. The cloned `insights-rbac/` directory will remain (it's in .gitignore) for faster subsequent deployments.

## Troubleshooting

### Check Deployment Status

```bash
kubectl get pods -n rbac-local
kubectl get deployments -n rbac-local
kubectl get jobs -n rbac-local
```

### Common Issues

#### Image Pull Errors
If deployments show `ImagePullBackOff` for the RBAC image, the Docker image was not loaded into your cluster.

**For auto-detected environments (Minikube/Kind):** This shouldn't happen. Check script output for image loading errors.

**For manual environments:**
```bash
# 1. Load the image
minikube image load insights-rbac:local  # or your cluster's command

# 2. Delete the failing pod to retry
kubectl delete pod -n rbac-local <pod-name>
```

#### Init Job Failures
If the init job fails, check the logs for database connection or migration errors:

```bash
kubectl logs -n rbac-local job/rbac-init
```

Common causes:
- PostgreSQL not ready (wait a few seconds and the job will retry)
- Migration conflicts (delete the namespace and redeploy from scratch)

#### Debezium Connector Failures
If Debezium connectors fail to start, check:

```bash
# View Debezium logs
kubectl logs -n rbac-local deployment/acm-kessel-debezium

# Check connector status via API
kubectl port-forward svc/acm-kessel-debezium 8083:8083 -n rbac-local
curl http://localhost:8083/connectors
curl http://localhost:8083/connectors/acm-kessel-inventory/status
curl http://localhost:8083/connectors/rbac-outbox/status
```

### View Logs

```bash
# RBAC API
kubectl logs -n rbac-local deployment/rbac-server

# RBAC Kafka Consumer (RBAC → Relations replication)
kubectl logs -n rbac-local deployment/rbac-kafka-consumer

# Kessel Inventory API
kubectl logs -n rbac-local deployment/acm-kessel-inventory-api

# Kessel Relations API (SpiceDB)
kubectl logs -n rbac-local deployment/acm-kessel-relations-api

# RBAC Init Job (migrations + seeding)
kubectl logs -n rbac-local job/rbac-init
```

### Check Kafka Topics

```bash
kubectl exec -n rbac-local deployment/rbac-local-kafka -- \
  kafka-topics --bootstrap-server localhost:9092 --list

kubectl exec -n rbac-local deployment/rbac-local-kafka -- \
  kafka-consumer-groups --bootstrap-server localhost:9092 --list
```

### Check Consumer Status

```bash
# RBAC consumer
kubectl exec -n rbac-local deployment/rbac-local-kafka -- \
  kafka-consumer-groups --bootstrap-server localhost:9092 \
  --describe --group rbac-consumer-group

# Inventory consumer
kubectl exec -n rbac-local deployment/rbac-local-kafka -- \
  kafka-consumer-groups --bootstrap-server localhost:9092 \
  --describe --group inventory-consumer
```

## Kafka Topics

The deployment uses Debezium's EventRouter transform which routes outbox messages by `aggregatetype`:

### RBAC → Kessel Relations
- `outbox.event.relations-replication-event` - RBAC relations replication events (roles, groups, bindings)
- `outbox.event.workspace` - Workspace lifecycle events (create/update/delete)

### Kessel Inventory → Kessel Relations
- `outbox.event.kessel.tuples` - Resource authorization tuples
- `outbox.event.kessel.resources` - Resource metadata events

### System Topics
- `__debezium-heartbeat.rbac` - Debezium heartbeat for RBAC connector
- `__debezium-heartbeat.kessel-inventory` - Debezium heartbeat for Inventory connector

## Architecture Decisions

1. **Kessel Authorization**: Complete Kessel stack with RBAC and Inventory both replicating to Relations API (SpiceDB) for unified authorization checks based on Google Zanzibar model
2. **EventRouter Topic Pattern**: Debezium EventRouter routes outbox messages to topics using `outbox.event.<aggregatetype>` pattern, allowing multiple event types from the same outbox table to be routed to different Kafka topics
3. **Separate Event Streams**: RBAC relations events and workspace events use different topics (`outbox.event.relations-replication-event` and `outbox.event.workspace`) to enable independent consumption and processing
4. **Dual CDC Patterns**:
   - RBAC uses **outbox pattern** (management_outbox table)
   - Inventory uses **WAL messages** (pg_logical_emit_message)
5. **Custom Role Definitions**: Only ACM and RBAC roles are seeded to avoid unused services
6. **SUPERUSER for CDC**: PostgreSQL users need SUPERUSER to create publications for Debezium
7. **Cherry-picked Commit**: Uses commit `59606004bfe190b3f2ee33a382258ad0b8279877` on top of latest master for group#member tuple generation fix
