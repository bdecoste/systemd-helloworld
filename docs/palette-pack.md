# Deploying HelloWorld as a Palette add-on pack

This walks through publishing the `palette-pack/helloworld/0.1.0` pack to a
custom Spectro Cloud Palette registry, creating a Cluster Profile that
includes it, and attaching that profile to an existing Palette-managed EKS
cluster.

## 0. What's in the pack

```
palette-pack/
  helloworld/
    0.1.0/
      pack.json           # pack metadata (name, version, layer, manifest list)
      values.yaml         # user-facing values, Go-template exposed to manifests
      README.md           # pack-level docs
      manifests/
        configmap.yaml    # PORT / GREETING / ENVIRONMENT
        deployment.yaml   # 2 replicas of the containerized app
        service.yaml      # ClusterIP :80 → pod :8080
        ingress.yaml      # ingressClassName: traefik (overridable)
```

The manifests reference values via `{{ .Values.<path> }}`. Palette renders
them at cluster-apply time using the merged values (pack defaults + any
overrides set on the Cluster Profile layer).

## 1. Push the app image to a registry the cluster can pull from

The pack references `{{ .Values.image.repository }}:{{ .Values.image.tag }}`.
The default is `helloworld:0.1.0`, which won't resolve — push to ECR first:

```bash
docker build -f docker/Dockerfile -t helloworld:0.1.0 .
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=${AWS_REGION:-us-east-1}
REPO="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/helloworld"
aws ecr create-repository --repository-name helloworld || true
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REPO"
docker tag helloworld:0.1.0 "$REPO:0.1.0"
docker push "$REPO:0.1.0"
```

Remember the `$REPO` value — you'll set `image.repository` to it when adding
the pack to a Cluster Profile.

## 2. Publish the pack to a custom registry

Palette needs a **custom pack registry** to serve this pack. Two supported
shapes; pick one.

### Option A — Git-based custom registry (simplest)

Palette syncs pack definitions from a Git repository on a schedule. Point it
at a repo that contains the `palette-pack/` layout at the root (or a
subdirectory you specify when registering the registry).

**One-time registry setup (done in Palette UI or via API):**

- Tenant Settings → Registries → Pack Registries → Add New Pack Registry
- Type: `git`
- Endpoint: your git URL (this repo works if it's reachable from Palette)
- Credentials: PAT / deploy key if the repo is private
- Sync interval: default 10 min (or trigger sync manually)

**Publishing a new version:**

```bash
# From the repo root
git tag helloworld-pack-0.1.0
git push origin main --tags
```

Palette picks up the new pack version on its next sync (or hit "Sync" in the
registry view).

### Option B — OCI custom registry (Harbor / Zot / ECR / Artifactory)

Push the pack as an OCI artifact. Requires an OCI-compatible registry
Palette can pull from (basic-auth or bearer-token).

```bash
# Package the pack directory tree into a tarball
cd palette-pack/helloworld
tar czf /tmp/helloworld-0.1.0.tar.gz 0.1.0

# Push with oras (https://oras.land)
oras push <registry-host>/spectro-packs/helloworld:0.1.0 \
  --artifact-type application/vnd.spectrocloud.pack.v1+tar \
  /tmp/helloworld-0.1.0.tar.gz:application/vnd.spectrocloud.pack.v1+tar
```

**Register the OCI registry in Palette:**

- Tenant Settings → Registries → Pack Registries → Add New Pack Registry
- Type: `oci`
- Endpoint: `<registry-host>`
- Base content path: `spectro-packs` (or wherever you pushed to)
- Credentials: registry auth

Palette will list `helloworld@0.1.0` under the registered registry once the
sync completes.

## 3. Create a Cluster Profile that includes the pack

The choice is between a **full profile** (OS + K8s + CNI + CSI + add-ons —
used when Palette provisions the cluster) and an **add-on profile** (only
add-ons — attaches to an already-provisioned cluster). For dropping this app
onto an existing Palette-managed EKS cluster, use an **add-on profile**.

**Palette UI:**

1. Profiles → Add New Profile
2. Type: `Add-on`
3. Cloud type: `AWS`
4. Add pack → pick your custom registry → `helloworld @ 0.1.0`
5. On the pack's values pane, override at least:
   ```yaml
   image:
     repository: <account>.dkr.ecr.<region>.amazonaws.com/helloworld
     tag: "0.1.0"
   ```
   Override `config.greeting`, `config.environment`, or `replicas` per env
   as needed.
6. Confirm → Create.

**Or via Palette API / Terraform:**

```hcl
resource "spectrocloud_cluster_profile" "helloworld" {
  name    = "helloworld-addon"
  type    = "add-on"
  cloud   = "aws"
  version = "1.0.0"

  pack {
    name         = "helloworld"
    tag          = "0.1.0"
    registry_uid = data.spectrocloud_registry.custom.id
    type         = "manifest"
    values = yamlencode({
      image = {
        repository = "${var.account}.dkr.ecr.${var.region}.amazonaws.com/helloworld"
        tag        = "0.1.0"
      }
      config = {
        greeting    = "Hello from EKS via Palette"
        environment = "prod-eks"
      }
    })
  }
}
```

## 4. Attach the add-on profile to the EKS cluster

**UI:**

1. Clusters → open the target EKS cluster
2. Profile → Attach Add-on Profile → pick `helloworld-addon` → Confirm
3. Palette schedules a cluster update. Progress shows on the cluster page.

**Terraform** (existing cluster resource):

```hcl
resource "spectrocloud_cluster_eks" "example" {
  # …existing config…

  cluster_profile {
    id = spectrocloud_cluster_profile.helloworld.id
  }
}
```

## 5. Verify

```bash
# Kubeconfig for the target cluster (from Palette → cluster → Kubeconfig)
kubectl -n helloworld get deploy,po,svc,ingress
kubectl -n helloworld logs -l app=helloworld -f

# Hit the Ingress. If the Traefik controller has the EIP annotations wired up
# per k8s/traefik-values.yaml, this is the same public IP the EC2
# service used to serve on.
curl -H "Host: $(kubectl -n helloworld get ingress helloworld -o jsonpath='{.spec.rules[0].host}')" \
     http://<EIP>/
curl http://<EIP>/healthz
```

## 6. Updating the pack

Publishing a new version is additive — never overwrite an existing version:

1. Copy `palette-pack/helloworld/0.1.0` → `palette-pack/helloworld/0.2.0`
2. Bump `version` in `pack.json` to `0.2.0`
3. Make the change (new manifest, new default value, etc.)
4. Commit + tag (git registry) or `oras push` (OCI registry)
5. In the Cluster Profile, edit the `helloworld` pack layer → change version
   to `0.2.0` → Save. Palette rolls out the diff to attached clusters.

## Notes

- **Namespace.** Palette creates `pack.namespace` if it doesn't exist. The
  `helloworld-config` ConfigMap and Ingress land there; the Service is
  reachable at `helloworld.helloworld.svc.cluster.local`.
- **Airgap.** `pack.content.images` lists images Palette should mirror into
  the cluster's private registry when the cluster is airgapped. Keep this
  in sync with `image.repository:image.tag`.
- **Ordering.** Add-on packs in a profile apply in list order. This pack has
  no dependencies beyond a running ingress controller (Traefik). If you bundle
  the ingress controller as another add-on pack, put it before `helloworld`
  in the profile.
