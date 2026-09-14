# HelloWorld: systemd → Kubernetes migration demo

One unmodified application shown running in two deployment models:

- **Current state:** systemd unit on an EC2 VM
- **Future state:** container in EKS

The point of the demo is the **application code never changes** — only the
wrapping around it does. That's what makes lift-and-shift migrations from
VM-based systemd services to Kubernetes tractable without rewrites.

## Repo layout

```
app/                       # The application. Same file in both worlds.
  helloworld.py
systemd/                   # Current-state wrapper (EC2 VM).
  helloworld.service       # systemd unit
  helloworld.env           # EnvironmentFile (config)
  install.sh               # installer / EC2 user-data
docker/                    # Container build.
  Dockerfile               # copies app/helloworld.py in, unmodified
k8s/                       # Future-state wrapper (EKS).
  configmap.yaml           # config (mirrors helloworld.env)
  deployment.yaml          # replaces the systemd unit
  service.yaml             # cluster-internal endpoint
  ingress.yaml             # optional ALB exposure
```

## Why the app is portable without changes

Three properties in `app/helloworld.py`:

1. **Config comes from environment variables.** `PORT`, `GREETING`,
   `ENVIRONMENT`. systemd's `EnvironmentFile=` and K8s's `envFrom:
   configMapRef` both populate the same variables.
2. **Logs go to stdout.** journald collects stdout from systemd services;
   the kubelet collects stdout from containers. Same log path, same shipper
   downstream (CloudWatch Logs, Loki, etc.).
3. **Graceful shutdown on SIGTERM.** systemd sends SIGTERM on `stop`; K8s
   sends SIGTERM before killing a pod. The handler works in both places.

Miss any of these and the migration story gets bumpy. Hit all three and the
app doesn't know or care where it runs.

## Current state — EC2 + systemd

Bake or bootstrap a VM with:

```bash
sudo ./systemd/install.sh
```

Or drop the equivalent into EC2 **user-data** (Amazon Linux 2023 / Ubuntu):

```bash
#!/usr/bin/env bash
set -e
yum install -y git || apt-get update && apt-get install -y git
git clone https://your.git.host/heart-flow.git /tmp/hw
bash /tmp/hw/systemd/install.sh
```

Verify:

```bash
systemctl status helloworld
journalctl -u helloworld -f
curl http://localhost:8080/
curl http://localhost:8080/healthz
```

Typical AWS wiring: an ALB / target group in front of the instance
ASG, health check on `/healthz`.

## Future state — EKS

Build and push the image (no app changes):

```bash
# From repo root — Dockerfile lives in docker/, but build context is repo root
# so it can COPY app/helloworld.py.
docker build -f docker/Dockerfile -t helloworld:0.1.0 .

# ECR
aws ecr create-repository --repository-name helloworld || true
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=${AWS_REGION:-us-east-1}
REPO="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/helloworld"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REPO"
docker tag helloworld:0.1.0 "$REPO:0.1.0"
docker push "$REPO:0.1.0"
```

Update `k8s/deployment.yaml`'s `image:` to `$REPO:0.1.0` and apply:

```bash
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/ingress.yaml     # optional; requires AWS LB Controller
```

Verify:

```bash
kubectl get pods -l app=helloworld
kubectl logs -l app=helloworld -f
kubectl port-forward svc/helloworld 8080:80
curl http://localhost:8080/
```

External exposure options on EKS:

- **Ingress + ALB** (recommended): install the [AWS Load Balancer
  Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/),
  then `k8s/ingress.yaml` provisions an ALB with `/healthz` as the health check.
- **Service type LoadBalancer**: swap `type: ClusterIP` for
  `type: LoadBalancer` in `service.yaml` — provisions an NLB by default.

## The mapping (cheat sheet)

| Concern                   | EC2 + systemd                     | EKS + K8s                                    |
| ------------------------- | --------------------------------- | -------------------------------------------- |
| Where the code lives      | `/opt/helloworld/helloworld.py`   | inside container image at same path          |
| Runtime                   | `python3` from OS package         | `python:3.12-slim` base image                |
| Process supervisor        | systemd (`Restart=on-failure`)    | kubelet (Deployment restart policy)          |
| Config                    | `EnvironmentFile=…/helloworld.env`| `envFrom: configMapRef: helloworld-config`   |
| Secrets                   | file in `/etc/helloworld/` (0600) | `Secret` + `envFrom: secretRef`              |
| Identity                  | `User=helloworld` system account  | `runAsUser: 10001` + IRSA for AWS access     |
| Logs                      | stdout → journald                 | stdout → kubelet → CloudWatch/Loki           |
| Health check              | ALB target group → HTTP `/healthz`| readiness/liveness probes → `/healthz`       |
| Rollout                   | ASG instance refresh / AMI bake   | `kubectl rollout` (RollingUpdate strategy)   |
| Horizontal scale          | ASG desired-count                 | Deployment `replicas` + HPA                  |
| External LB               | ALB in front of ASG               | Ingress (ALB via AWS LB Controller) or NLB   |
| Rollback                  | Previous AMI / launch template    | `kubectl rollout undo`                       |

## What we deliberately did not change

- No framework swap (still stdlib `http.server`).
- No new logging library — stdout is already the right answer for both.
- No baked-in config — env vars work identically under systemd and K8s.
- No sidecars for log shipping or health — the app already speaks HTTP `/healthz`.

If a real app in your fleet violates one of the three portability properties
above, that's the migration work: fix the property in the app once, and the
same wrapping pattern applies. Don't containerize the workaround.
