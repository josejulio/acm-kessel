# RBAC (Role-Based Access Control) for ACM Kessel

Standalone deployment of insights-rbac without Insights/HCC/Console dependencies.

## ✅ Container Image

The official RBAC image is **publicly available** at:
- **`quay.io/cloudservices/rbac:latest`**

No build steps required! The deployment is pre-configured to use this image.

## What's Included

This is a **minimal** RBAC deployment with:
- ✅ RBAC REST API (Django)
- ✅ Redis (for Celery task queue)
- ✅ Separate PostgreSQL database
- ✅ Kessel Relations API integration (enabled)
- ✅ Kessel Inventory API integration (enabled)
- ❌ No Celery Worker (async tasks disabled)
- ❌ No Celery Beat (scheduled tasks disabled)
- ❌ No Principal Proxy Service (Insights dependency removed)
- ❌ No UMB/Kafka (Insights messaging removed)
- ❌ No Clowder configuration

## Prerequisites

1. **PostgreSQL** with `rbac` database
   - Deploy postgres-dev: `kubectl apply -f postgres-dev/`
   - Or use existing PostgreSQL (create `rbac` database and `rbacuser`)

2. **Kessel Relations API** (already deployed)
3. **Kessel Inventory API** (already deployed)

## Quick Start

### Step 1: Generate Django Secret Key

```bash
# Generate a secure random key
openssl rand -base64 32

# Update rbac/02-rbac-secret.yaml with the generated key
vim rbac/02-rbac-secret.yaml
```

Edit this line:
```yaml
django-secret-key: "CHANGE_ME_GENERATE_WITH_openssl_rand_base64_32"
```

### Step 2: Deploy PostgreSQL Database (if using postgres-dev)

```bash
# Deploy PostgreSQL with RBAC database initialization
kubectl apply -f ../postgres-dev/05-postgres-init-rbac.yaml
kubectl apply -f ../postgres-dev/03-postgres-dev-deployment.yaml

# Wait for database to be ready
kubectl wait --for=condition=ready pod -l app=acm-kessel-postgres -n acm-kessel --timeout=60s
```

**Note:** The init script creates:
- Database: `rbac`
- User: `rbacuser`
- Password: `changeme123` (change if you updated postgres-dev password)

### Step 3: Deploy RBAC

**Option A: Using Kustomize (recommended)**
```bash
kubectl apply -k rbac/
```

**Option B: Apply files individually**
```bash
kubectl apply -f rbac/01-redis-deployment.yaml
kubectl apply -f rbac/02-rbac-secret.yaml
kubectl apply -f rbac/03-rbac-configmap.yaml
kubectl apply -f rbac/04-rbac-db-secret.yaml
kubectl apply -f rbac/05-rbac-api-deployment.yaml
```

**Watch deployment:**
```bash
kubectl get pods -n acm-kessel -l app.kubernetes.io/part-of=acm-rbac -w
```

### Step 4: Verify Deployment

```bash
# Check all components are running
kubectl get pods,svc -n acm-kessel -l app.kubernetes.io/part-of=acm-rbac

# Check RBAC API logs
kubectl logs -n acm-kessel deployment/acm-kessel-rbac-api --tail=50

# Test the API
kubectl port-forward svc/acm-kessel-rbac-api 8080:8080 -n acm-kessel

# In another terminal
curl http://localhost:8080/api/rbac/v1/status/
```

Expected response:
```json
{
  "api_version": 1,
  "commit": "...",
  ...
}
```

## API Endpoints

Once deployed, the RBAC API is available at:
- **Base path**: `/api/rbac`
- **V1 API**: `/api/rbac/v1/`
- **V2 API**: `/api/rbac/v2/`
- **Status**: `/api/rbac/v1/status/`
- **OpenAPI docs**: `/api/rbac/v1/openapi.json`

### Example API Calls

```bash
# Port-forward
kubectl port-forward svc/acm-kessel-rbac-api 8080:8080 -n acm-kessel

# Get status
curl http://localhost:8080/api/rbac/v1/status/

# List roles (requires authentication - see Authentication section)
curl -H "x-rh-identity: ..." http://localhost:8080/api/rbac/v1/roles/

# OpenAPI specification
curl http://localhost:8080/api/rbac/v1/openapi.json
```

## Configuration

### Environment Variables (03-rbac-configmap.yaml)

Key configurations:
- `API_PATH_PREFIX`: `/api/rbac` (base path for all endpoints)
- `REPLICATION_TO_RELATION_ENABLED`: `true` (sync to Kessel Relations)
- `RELATION_API_SERVER`: Points to acm-kessel-relations-api
- `INVENTORY_API_SERVER`: Points to acm-kessel-inventory-api
- `V2_APIS_ENABLED`: `true` (enables modern V2 APIs)

### Database Configuration (04-rbac-db-secret.yaml)

If using external PostgreSQL:
1. Create database: `CREATE DATABASE rbac;`
2. Create user: `CREATE USER rbacuser WITH PASSWORD 'yourpassword';`
3. Grant privileges: `GRANT ALL PRIVILEGES ON DATABASE rbac TO rbacuser;`
4. Update `04-rbac-db-secret.yaml` with your credentials

## Authentication

RBAC expects authentication via headers. For development/testing without Insights:

**Option 1: Disable authentication** (development only)
Edit `03-rbac-configmap.yaml`:
```yaml
AUTHENTICATE_WITH_ORG_ID: "false"
DEVELOPMENT: "true"
```

**Option 2: Use mock identity header**
```bash
# Base64-encoded mock identity
IDENTITY='{"identity":{"account_number":"12345","org_id":"67890","type":"User","user":{"username":"testuser","email":"test@example.com","is_org_admin":true}}}'
ENCODED=$(echo -n "$IDENTITY" | base64 -w0)

curl -H "x-rh-identity: $ENCODED" http://localhost:8080/api/rbac/v1/roles/
```

## Scaling Up (Optional)

To add async task processing and scheduled jobs:

### Deploy Celery Worker

```bash
# Create rbac/06-rbac-worker-deployment.yaml
# (Worker processes background tasks)
```

### Deploy Celery Beat

```bash
# Create rbac/07-rbac-beat-deployment.yaml
# (Scheduler for periodic cleanup jobs)
```

Both services will use the same Redis and database configuration.

## Troubleshooting

### Database Connection Issues

```bash
# Test database connectivity from RBAC pod
kubectl exec -it deployment/acm-kessel-rbac-api -n acm-kessel -- \
  psql -h acm-kessel-postgres -U rbacuser -d rbac -c "SELECT version();"
```

### Migration Issues

```bash
# Check if migrations ran
kubectl logs -n acm-kessel deployment/acm-kessel-rbac-api | grep migration

# Manually run migrations
kubectl exec -it deployment/acm-kessel-rbac-api -n acm-kessel -- \
  python manage.py migrate
```

### Redis Connection Issues

```bash
# Test Redis connectivity
kubectl exec -it deployment/acm-kessel-rbac-redis -n acm-kessel -- \
  redis-cli ping
```

Should return: `PONG`

## Components

| Component | Purpose | Port |
|-----------|---------|------|
| acm-kessel-rbac-api | REST API for roles, groups, permissions | 8080 |
| acm-kessel-rbac-redis | Celery broker and caching | 6379 |
| PostgreSQL (rbac database) | Data storage | 5432 |

## Next Steps

1. **Set up authentication** - Configure proper identity headers or integrate with your auth system
2. **Add Celery Worker** - For async task processing
3. **Add Celery Beat** - For scheduled cleanup jobs
4. **Configure permissions** - Define custom roles and permissions
5. **Integrate with Kessel** - Verify Relations/Inventory API integration

## References

- [RBAC GitHub Repository](https://github.com/redHatInsights/insights-rbac)
- [RBAC API Documentation](https://github.com/redHatInsights/insights-rbac/tree/master/docs)
- Kessel Relations API: `http://acm-kessel-relations-api:9000`
- Kessel Inventory API: `http://acm-kessel-inventory-api:9000`
