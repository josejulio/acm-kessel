# PostgreSQL for Development

This directory contains simple Kubernetes manifests for deploying PostgreSQL for **development and testing only**.

## Quick Start

1. **Update the password** in `01-postgres-dev-secret.yaml`
2. Deploy:
   ```bash
   kubectl apply -f postgres-dev/
   ```

3. Verify:
   ```bash
   kubectl get pods -n acm-kessel -l app=acm-kessel-postgres
   ```

## What Gets Deployed

- **Secret**: Database credentials (compatible with Inventory API)
- **PVC**: 5Gi persistent storage for database data
- **Deployment**: PostgreSQL 16 (Alpine Linux)
- **Service**: ClusterIP service on port 5432

## Connecting

```bash
# Port-forward
kubectl port-forward -n acm-kessel svc/acm-kessel-postgres 5432:5432

# Connect with psql
PGPASSWORD=changeme123 psql -h localhost -U inventoryapi -d inventory
```

## Storage

Data is stored in a PersistentVolumeClaim. To delete all data:

```bash
kubectl delete pvc acm-kessel-postgres-data -n acm-kessel
```
