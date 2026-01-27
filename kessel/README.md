# ACM Kessel Deployment for OpenShift

This directory contains Kubernetes manifests for deploying the Kessel stack into an OpenShift cluster for the ACM project.

## Components

The Kessel stack consists of:

1. **Crunchy Data PostgreSQL Operator** - Manages PostgreSQL cluster lifecycle
2. **PostgreSQL Cluster** - Provides the database backend for the Inventory API
3. **SpiceDB Operator** - Manages the SpiceDB cluster lifecycle
4. **SpiceDB Cluster** - Provides the authorization backend for the Relations API
5. **Relations API** - API for managing authorization relationships backed by SpiceDB
6. **Inventory API** - API for managing resource inventory, backed by PostgreSQL

## Prerequisites

- OpenShift cluster (4.12+) with Operator Lifecycle Manager (OLM)
- Access to the OpenShift OperatorHub (for Crunchy PostgreSQL Operator)
- `oc` CLI tool
- Cluster admin privileges (for operator installation)

## Directory Structure

```
acm/
├── 00-namespace.yaml                              # ACM Kessel namespace
├── postgres/                                      # PostgreSQL Operator (Crunchy Data)
│   ├── 01-postgres-operator-namespace.yaml       # Operator namespace
│   ├── 02-postgres-operator-group.yaml           # Operator group
│   ├── 03-postgres-operator-subscription.yaml    # Operator subscription
│   └── 04-postgres-cluster.yaml                  # PostgreSQL cluster instance
├── operator/
│   └── 01-spicedb-operator.yaml                  # SpiceDB operator installation
├── spicedb/
│   ├── 02-spicedb-secret.yaml                    # SpiceDB preshared key (MUST BE CHANGED)
│   └── 03-spicedb-cluster.yaml                   # SpiceDB cluster configuration
├── relations-api/
│   ├── 04-relations-api-configmap-schema.yaml    # SpiceDB authorization schema
│   ├── 05-relations-api-configmap-config.yaml    # Relations API configuration
│   ├── 06-relations-api-deployment.yaml          # Relations API deployment
│   └── 07-relations-api-service.yaml             # Relations API service
├── inventory-api/
│   ├── 09-inventory-api-configmap-schema-cache.yaml  # Schema cache
│   ├── 10-inventory-api-secret-config.yaml           # Inventory API configuration
│   ├── 11-inventory-api-deployment.yaml              # Inventory API deployment
│   └── 12-inventory-api-service.yaml                 # Inventory API service
├── config/                                        # Application configuration files
├── schema/                                        # Schema files
├── kustomization.yaml                             # Kustomize deployment file
└── README.md                                      # This file
```

## Installation

### Step 1: Configure Secrets

Before deploying, you MUST update the **SpiceDB Preshared Key** (`spicedb/02-spicedb-secret.yaml`):

```bash
# Generate a random 32-character key:
openssl rand -base64 32

# Update the preshared_key value in the file
```

**Note:** PostgreSQL credentials are automatically managed by the Crunchy Data Operator. No manual secret configuration is needed for the database.

### Step 2: Deploy the Stack

Deploy the manifests in order:

```bash
# 1. Create namespaces
oc apply -f 00-namespace.yaml
oc apply -f postgres/01-postgres-operator-namespace.yaml

# 2. Deploy PostgreSQL Operator (Crunchy Data)
oc apply -f postgres/02-postgres-operator-group.yaml
oc apply -f postgres/03-postgres-operator-subscription.yaml

# Wait for the PostgreSQL operator to be ready (this may take a few minutes)
oc wait --for=condition=available --timeout=600s deployment/pgo -n pgo

# 3. Deploy PostgreSQL Cluster
oc apply -f postgres/04-postgres-cluster.yaml

# Wait for PostgreSQL to be ready
oc wait --for=condition=PGBackRestRepoHostReady --timeout=600s postgrescluster/acm-kessel-postgres -n acm-kessel

# 4. Deploy SpiceDB operator
oc apply -f operator/01-spicedb-operator.yaml

# Wait for the operator to be ready
oc wait --for=condition=available --timeout=300s deployment/spicedb-operator -n acm-kessel

# 5. Deploy SpiceDB cluster
oc apply -f spicedb/

# Wait for SpiceDB to be ready
oc wait --for=condition=available --timeout=300s deployment/acm-kessel-spicedb-spicedb -n acm-kessel

# 6. Deploy Relations API
oc apply -f relations-api/

# 7. Deploy Inventory API
oc apply -f inventory-api/09-inventory-api-configmap-schema-cache.yaml
oc apply -f inventory-api/10-inventory-api-secret-config.yaml
oc apply -f inventory-api/11-inventory-api-deployment.yaml
oc apply -f inventory-api/12-inventory-api-service.yaml
```

**Using Kustomize:**

```bash
oc apply -k kessel/
```

### Step 3: Verify Deployment

Check that all components are running:

```bash
# Check PostgreSQL operator
oc get pods -n pgo

# Check PostgreSQL cluster
oc get postgrescluster -n acm-kessel
oc get pods -n acm-kessel -l postgres-operator.crunchydata.com/cluster=acm-kessel-postgres

# Check all ACM Kessel pods
oc get pods -n acm-kessel

# Check services
oc get svc -n acm-kessel

# Check SpiceDB cluster status
oc get spicedbcluster -n acm-kessel

# Check deployments
oc get deployments -n acm-kessel
```

Expected output should show:
- PostgreSQL operator deployment in `pgo` namespace
- PostgreSQL cluster pods (primary + repo-host)
- SpiceDB operator deployment
- SpiceDB cluster pods
- Relations API deployment
- Inventory API deployment

**Verify PostgreSQL Secret Creation:**

The Crunchy operator automatically creates a secret with database credentials:

```bash
# Check the auto-generated secret
oc get secret acm-kessel-postgres-pguser-inventoryapi -n acm-kessel

# View the connection details (base64 encoded)
oc get secret acm-kessel-postgres-pguser-inventoryapi -n acm-kessel -o yaml
```

### Step 4: Access the APIs

Port-forward to access the APIs locally:

```bash
# Relations API
oc port-forward svc/acm-kessel-relations-api 9200:9000 -n acm-kessel

# Inventory API
oc port-forward svc/acm-kessel-inventory-api 9100:9000 -n acm-kessel
```

## Configuration

### SpiceDB Datastore

By default, SpiceDB is configured to use in-memory storage (`datastoreEngine: memory`). For production use, configure it to use PostgreSQL:

1. Update `spicedb/03-spicedb-cluster.yaml`:
   ```yaml
   spec:
     config:
       datastoreEngine: postgres
   ```

2. Create a secret with PostgreSQL connection details for SpiceDB (separate from the Inventory API database)

### Image Versions

The manifests use the following default images:

- Relations API: `quay.io/redhat-services-prod/project-kessel-tenant/kessel-relations/relations-api:latest`
- Inventory API: `quay.io/redhat-services-prod/project-kessel-tenant/kessel-inventory/inventory-api:f2a8a16`

Update the image tags in the deployment files as needed for your environment.

### Scaling

To scale the APIs, update the `replicas` field in the deployment manifests:

```bash
# Scale Relations API
oc scale deployment acm-kessel-relations-api --replicas=3 -n acm-kessel

# Scale Inventory API
oc scale deployment acm-kessel-inventory-api --replicas=3 -n acm-kessel
```

## PostgreSQL Configuration (Crunchy Data Operator)

The deployment uses the **Crunchy Data PostgreSQL Operator** for database management. The operator is installed via OpenShift OperatorHub and provides enterprise-grade PostgreSQL with high availability, backup/restore, and monitoring capabilities.

### PostgreSQL Cluster Configuration

The PostgreSQL cluster is defined in `postgres/04-postgres-cluster.yaml`. Key configuration options:

**Storage:**
```yaml
dataVolumeClaimSpec:
  resources:
    requests:
      storage: 10Gi  # Adjust for production needs
```

**Replicas (High Availability):**
```yaml
instances:
  - name: instance1
    replicas: 1  # Set to 2 or more for HA
```

**Resource Limits:**
```yaml
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 1000m
    memory: 1Gi
```

**Backups:**
```yaml
backups:
  pgbackrest:
    repos:
    - name: repo1
      volume:
        volumeClaimSpec:
          resources:
            requests:
              storage: 10Gi  # Backup storage size
```

### Connecting to PostgreSQL

The operator automatically creates connection secrets. To connect to the database:

```bash
# Get the database connection details
oc get secret acm-kessel-postgres-pguser-inventoryapi -n acm-kessel -o jsonpath='{.data.host}' | base64 -d
oc get secret acm-kessel-postgres-pguser-inventoryapi -n acm-kessel -o jsonpath='{.data.port}' | base64 -d
oc get secret acm-kessel-postgres-pguser-inventoryapi -n acm-kessel -o jsonpath='{.data.user}' | base64 -d
oc get secret acm-kessel-postgres-pguser-inventoryapi -n acm-kessel -o jsonpath='{.data.password}' | base64 -d

# Or use port-forward to connect directly
oc port-forward -n acm-kessel svc/acm-kessel-postgres-primary 5432:5432

# Then connect with psql
PGPASSWORD=$(oc get secret acm-kessel-postgres-pguser-inventoryapi -n acm-kessel -o jsonpath='{.data.password}' | base64 -d) \
psql -h localhost -U inventoryapi -d inventory
```

### Using External PostgreSQL (Optional)

If you prefer to use an external PostgreSQL database instead of the operator:

1. **Do not** apply the postgres/ manifests
2. Create a secret with your external database credentials:
   ```bash
   oc create secret generic acm-kessel-postgres-credentials -n acm-kessel \
     --from-literal=host=your-postgres-host.example.com \
     --from-literal=port=5432 \
     --from-literal=user=inventoryapi \
     --from-literal=password=YOUR_SECURE_PASSWORD \
     --from-literal=dbname=inventory
   ```
3. In `inventory-api/11-inventory-api-deployment.yaml`, change the secret reference from:
   ```yaml
   name: acm-kessel-postgres-pguser-inventoryapi
   ```
   to:
   ```yaml
   name: acm-kessel-postgres-credentials
   ```
4. Apply the inventory API manifests

## Bootstrap SpiceDB with Initial Data

After deployment, you can bootstrap SpiceDB with initial authorization relationships.

Install [grpcurl](https://github.com/fullstorydev/grpcurl) and run:

```bash
# Port-forward to relations-api
oc port-forward svc/acm-kessel-relations-api 9200:9000 -n acm-kessel

# Create sample relationships
grpcurl -plaintext -d '{
  "upsert": true,
  "tuples": [
    {
      "resource": {
        "type": {"namespace": "rbac", "name": "workspace"},
        "id": "my-workspace"
      },
      "relation": "t_binding",
      "subject": {
        "subject": {
          "type": {"namespace": "rbac", "name": "role_binding"},
          "id": "binding1"
        }
      }
    },
    {
      "resource": {
        "type": {"namespace": "rbac", "name": "role_binding"},
        "id": "binding1"
      },
      "relation": "t_subject",
      "subject": {
        "subject": {
          "type": {"namespace": "rbac", "name": "principal"},
          "id": "redhat/user123"
        }
      }
    },
    {
      "resource": {
        "type": {"namespace": "rbac", "name": "role_binding"},
        "id": "binding1"
      },
      "relation": "t_role",
      "subject": {
        "subject": {
          "type": {"namespace": "rbac", "name": "role"},
          "id": "admin"
        }
      }
    },
    {
      "resource": {
        "type": {"namespace": "rbac", "name": "role"},
        "id": "admin"
      },
      "relation": "t_regional_cluster_cluster_create",
      "subject": {
        "subject": {
          "type": {"namespace": "rbac", "name": "principal"},
          "id": "*"
        }
      }
    }
  ]
}' localhost:9200 kessel.relations.v1beta1.KesselTupleService/CreateTuples

# Verify the permission
grpcurl -plaintext -d '{
  "resource": {
    "type": {"namespace": "rbac", "name": "workspace"},
    "id": "my-workspace"
  },
  "relation": "regional_cluster_cluster_create",
  "subject": {
    "subject": {
      "type": {"namespace": "rbac", "name": "principal"},
      "id": "redhat/user123"
    }
  }
}' localhost:9200 kessel.relations.v1beta1.KesselCheckService/Check
```

## Troubleshooting

### Check Pod Logs

```bash
# PostgreSQL operator logs
oc logs -f deployment/pgo -n pgo

# PostgreSQL cluster logs
oc logs -f -n acm-kessel -l postgres-operator.crunchydata.com/cluster=acm-kessel-postgres

# Relations API logs
oc logs -f deployment/acm-kessel-relations-api -n acm-kessel

# Inventory API logs
oc logs -f deployment/acm-kessel-inventory-api -n acm-kessel

# SpiceDB operator logs
oc logs -f deployment/spicedb-operator -n acm-kessel
```

### Common Issues

1. **PostgreSQL operator not installing**:
   - Check that the operator subscription was created: `oc get subscription -n pgo`
   - Verify OperatorHub is accessible: `oc get catalogsource -n openshift-marketplace`
   - Check install plan: `oc get installplan -n pgo`

2. **PostgreSQL cluster not ready**:
   - Check the cluster status: `oc describe postgrescluster acm-kessel-postgres -n acm-kessel`
   - Verify PVCs are bound: `oc get pvc -n acm-kessel`
   - Check pod events: `oc get events -n acm-kessel --field-selector involvedObject.kind=Pod`

3. **Inventory API fails to start**:
   - Verify PostgreSQL is ready: `oc get postgrescluster -n acm-kessel`
   - Check the auto-generated secret exists: `oc get secret acm-kessel-postgres-pguser-inventoryapi -n acm-kessel`
   - Check migration logs: `oc logs -n acm-kessel -l app=acm-kessel-inventory-api -c migration`

4. **Relations API can't connect to SpiceDB**:
   - Verify SpiceDB cluster is ready: `oc get spicedbcluster -n acm-kessel`
   - Check preshared key matches in secret: `oc get secret acm-kessel-spicedb-config -n acm-kessel`

5. **SpiceDB cluster not starting**:
   - Check operator logs: `oc logs -f deployment/spicedb-operator -n acm-kessel`
   - Ensure CRDs are installed: `oc get crd spicedbclusters.authzed.com`

## Uninstall

To remove the entire stack:

```bash
# Delete ACM Kessel resources
oc delete -f inventory-api/
oc delete -f relations-api/
oc delete -f spicedb/
oc delete -f postgres/04-postgres-cluster.yaml

# Delete the namespace
oc delete namespace acm-kessel

# Optionally, uninstall the operators
oc delete -f postgres/03-postgres-operator-subscription.yaml
oc delete -f postgres/02-postgres-operator-group.yaml
oc delete namespace pgo

oc delete -f operator/01-spicedb-operator.yaml
```

**Note:** Deleting the PostgreSQL cluster will also delete all data. Ensure you have backups if needed.

## Notes

- All "rosa" references from the original deployment have been renamed to "acm"
- The namespace is `acm-kessel` to distinguish it from other Kessel deployments
- All resources are labeled with `app.kubernetes.io/part-of: acm` for easy identification
- PostgreSQL is managed by the **Crunchy Data PostgreSQL Operator** instead of AWS RDS
- The operator automatically manages database credentials, backups, and high availability
- Database credentials are stored in the auto-generated secret: `acm-kessel-postgres-pguser-inventoryapi`

## Support

For issues or questions, refer to the Kessel project documentation or contact the ACM team.
