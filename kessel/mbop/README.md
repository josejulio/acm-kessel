# MBOP (Mock BOP) Deployment

MBOP is a mock service that replaces the BOP (Bundle Object Permission) service in ephemeral/development environments. It provides entitlements and permission data for RBAC without requiring a full Keycloak infrastructure.

## What is MBOP?

MBOP (Mock BOP) is designed to:
- Provide entitlements data to the RBAC service
- Run in mock mode using the `ALL_PASS=true` environment variable
- Return fixed mock data instead of querying Keycloak
- Simplify development and testing environments

Source: [GitHub - RedHatInsights/mbop](https://github.com/RedHatInsights/mbop)

## Configuration

### Mock Mode (Default)

In mock mode, MBOP returns fixed mock data without requiring Keycloak:

```yaml
ALL_PASS: "true"              # Mock mode for entitlements
USERS_MODULE: "mock"          # Mock mode for users endpoint
KEYCLOAK_SERVER: "http://localhost:8080"  # Dummy value
KEYCLOAK_USERNAME: "admin"                 # Dummy value
KEYCLOAK_PASSWORD: "admin"                 # Dummy value
```

**Module Configuration:**
- `ALL_PASS=true` - Entitlements endpoint returns fixed JSON
- `USERS_MODULE=mock` - Users endpoint returns mock user data instead of querying Keycloak

### Service Configuration

- **Port**: 8090 (HTTP)
- **Service Name**: `acm-kessel-mbop`
- **Namespace**: `acm-kessel`
- **Cluster DNS**: `acm-kessel-mbop.acm-kessel.svc.cluster.local:8090`

## Integration with RBAC

RBAC is configured to use MBOP via these environment variables (set in `rbac/03-rbac-configmap.yaml`):

```yaml
BYPASS_BOP_VERIFICATION: "true"
PRINCIPAL_PROXY_SERVICE_PATH: "http://acm-kessel-mbop.acm-kessel.svc.cluster.local:8090"
PRINCIPAL_PROXY_SERVICE_SSL_VERIFY: "false"
```

## Deployment

MBOP is deployed automatically by the deployment script:

```bash
cd kessel/
./deploy-vanilla-k8s.sh
```

Or manually:

```bash
kubectl apply -f mbop/01-mbop-configmap.yaml
kubectl apply -f mbop/02-mbop-deployment.yaml
```

## Verification

Check that MBOP is running:

```bash
# Check pod status
kubectl get pods -n acm-kessel -l app=acm-kessel-mbop

# Test the health endpoint
kubectl port-forward -n acm-kessel svc/acm-kessel-mbop 8090:8090 &
curl http://localhost:8090/
# Expected: {"configured_modules":{"users":"mock","mailer":"print","jwt":""}}

# Test the entitlements endpoint
curl http://localhost:8090/v1/users/testuser/entitlements

# Test the users endpoint
curl http://localhost:8090/v3/accounts/12345/users
# Expected: JSON array with mock users
```

## Container Image

MBOP uses the public container image:
- **Image**: `quay.io/cloudservices/mbop:latest`
- **Fallback**: Build from source if image is not available

To build from source:
```bash
git clone https://github.com/RedHatInsights/mbop
cd mbop
podman build -t localhost/mbop:latest .
```

## API Endpoints

MBOP provides the following endpoints:

- `GET /` - Health check (returns configured modules status)
- `GET /v1/users/{username}/entitlements` - Get user entitlements (used by RBAC for authorization)
- `GET /v3/accounts/{orgID}/users` - Get users for an organization (used by RBAC for principals)

## Production Considerations

**Note**: This deployment uses MBOP in mock mode for development/testing only.

For production:
- ❌ Don't use MBOP - use the real BOP service
- ❌ Don't use `ALL_PASS=true` or `USERS_MODULE=mock`
- ✅ Deploy and configure a proper Keycloak instance
- ✅ Set real `KEYCLOAK_SERVER`, `KEYCLOAK_USERNAME`, and `KEYCLOAK_PASSWORD`
- ✅ Remove `USERS_MODULE` (defaults to querying Keycloak)
- ✅ Configure proper authentication and authorization

## Troubleshooting

### MBOP pod not starting

Check logs:
```bash
kubectl logs -n acm-kessel -l app=acm-kessel-mbop
```

### RBAC can't connect to MBOP

Verify the service:
```bash
kubectl get svc -n acm-kessel acm-kessel-mbop
```

Check RBAC logs for connection errors:
```bash
kubectl logs -n acm-kessel -l app=acm-kessel-rbac-api | grep -i mbop
```
