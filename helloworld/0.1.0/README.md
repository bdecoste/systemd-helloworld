# HelloWorld — Palette add-on pack v0.1.0

Manifest-type add-on pack that deploys the HelloWorld application
(ConfigMap + Deployment + Service + Ingress) into a Palette-managed
Kubernetes cluster.

## What it deploys

| Object      | Purpose                                           |
| ----------- | ------------------------------------------------- |
| ConfigMap   | `PORT`, `GREETING`, `ENVIRONMENT` for the app     |
| Deployment  | 2 replicas of `helloworld` (non-root, hardened)   |
| Service     | ClusterIP on port 80 → pod port 8080              |
| Ingress     | `ingressClassName: nginx`, path `/`               |

## Values

All values are overridable at the Cluster Profile layer.

| Value                    | Default                          |
| ------------------------ | -------------------------------- |
| `pack.namespace`         | `helloworld`                     |
| `image.repository`       | `helloworld`                     |
| `image.tag`              | `0.1.0`                          |
| `replicas`               | `2`                              |
| `config.port`            | `"8080"`                         |
| `config.greeting`        | `"Hello from EKS (container)"`   |
| `config.environment`     | `"eks-pod"`                      |
| `ingress.className`      | `nginx`                          |

## Prerequisites in the cluster

- NGINX Ingress Controller (see `k8s/ingress-nginx-values.yaml` at repo root)
- Image at `image.repository:image.tag` reachable from the cluster
  (typically ECR — replace the default before deploying)

## See also

`docs/palette-pack.md` at repo root — full build, publish, and attach flow.
