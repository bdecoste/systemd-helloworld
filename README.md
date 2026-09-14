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

### Exposing the EC2 service over a static AWS IP

Three viable shapes. Pick by fleet size.

#### Recommended for a single VM: Elastic IP on the instance

An Elastic IP (EIP) is free while attached to a running instance. It stays with
the instance across stop/start and reboots.

```bash
# 1. Allocate an EIP
aws ec2 allocate-address \
  --domain vpc \
  --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=helloworld-eip}]'
# note the returned AllocationId (eipalloc-…) and PublicIp

# 2. Associate to the instance
aws ec2 associate-address \
  --instance-id i-0123456789abcdef0 \
  --allocation-id eipalloc-0123456789abcdef0

# 3. Open port 8080 in the instance's security group
aws ec2 authorize-security-group-ingress \
  --group-id sg-0123456789abcdef0 \
  --protocol tcp --port 8080 --cidr 0.0.0.0/0   # narrow the CIDR if you can

# 4. Verify
curl http://<PublicIp>:8080/
curl http://<PublicIp>:8080/healthz
```

#### If you want it on port 80 (no load balancer)

The app runs as the non-root `helloworld` user and can't bind port 80 directly.
Two options that don't touch the app:

**A. Grant the process the bind capability** — add to `helloworld.service`
under `[Service]`:

```ini
AmbientCapabilities=CAP_NET_BIND_SERVICE
```

Set `PORT=80` in `/etc/helloworld/helloworld.env`, then:

```bash
sudo systemctl daemon-reload && sudo systemctl restart helloworld
```

**B. Kernel-level port redirect** (leave the app on 8080):

```bash
sudo iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080
sudo iptables -t nat -A OUTPUT -o lo -p tcp --dport 80 -j REDIRECT --to-port 8080
# Persist across reboots
#   Amazon Linux: sudo dnf install -y iptables-services && sudo service iptables save
#   Ubuntu:       sudo apt-get install -y iptables-persistent
```

Either way, open TCP 80 in the security group and hit `http://<PublicIp>/`.

#### Multi-instance / HA: Network Load Balancer with Elastic IPs

Once there is more than one instance (ASG, multi-AZ), the EIP-on-instance
pattern doesn't stretch. An NLB gives you one fixed public IP per AZ and fronts
the target group:

```bash
# One EIP per AZ subnet
aws ec2 allocate-address --domain vpc     # repeat per AZ

aws elbv2 create-load-balancer \
  --name helloworld-nlb --type network --scheme internet-facing \
  --subnet-mappings SubnetId=subnet-aaaa,AllocationId=eipalloc-aaaa \
                    SubnetId=subnet-bbbb,AllocationId=eipalloc-bbbb

aws elbv2 create-target-group \
  --name helloworld-tg \
  --protocol TCP --port 8080 --vpc-id vpc-xxxx \
  --health-check-protocol HTTP --health-check-path /healthz --health-check-port 8080

aws elbv2 register-targets --target-group-arn <tg-arn> \
  --targets Id=i-0123... Id=i-4567...

aws elbv2 create-listener --load-balancer-arn <lb-arn> \
  --protocol TCP --port 80 --default-actions Type=forward,TargetGroupArn=<tg-arn>
```

Tighten the instance security group to allow TCP 8080 only from the VPC CIDR —
the NLB is the only ingress path.

#### Not a static IP, but usually what people actually want

If the goal is a stable *URL*, put a Route 53 A record on top (pointing at the
EIP, or ALIAS to the NLB/ALB). The IP becomes an implementation detail and you
can re-wire the backend without breaking clients.

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
