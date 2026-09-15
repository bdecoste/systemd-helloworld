# helloworld Helm chart

Deploys the HelloWorld application (ConfigMap + Deployment + Service + Ingress)
to a Kubernetes cluster. Same app, same containers, same behavior as the
Palette add-on pack at `palette-pack/helloworld/`, but wrapped as a standard
Helm chart so it works with Palette's Helm registry sub-type (which is more
forgiving than the Pack sub-type).

## Package and push (OCI)

```bash
# 1. Package the chart
helm package palette-helm/helloworld
# produces helloworld-0.1.0.tgz

# 2. Port-forward Harbor (if not already up)
kubectl -n harbor port-forward svc/harbor-core 8080:80 &

# 3. Login to Harbor as an OCI registry
helm registry login localhost:8080 -u admin -p Harbor12345 --insecure

# 4. Push to the spectro-packs project
helm push helloworld-0.1.0.tgz oci://localhost:8080/spectro-packs --insecure-skip-tls-verify
```

## Install locally to verify

```bash
kubectl create ns helloworld
helm install helloworld oci://localhost:8080/spectro-packs/helloworld \
  --version 0.1.0 --namespace helloworld --insecure-skip-tls-verify
kubectl -n helloworld get deploy,svc,ingress
```

Uninstall:

```bash
helm uninstall helloworld -n helloworld
```

## Values

| Value                        | Default                            |
|------------------------------|------------------------------------|
| `image.repository`           | `helloworld`                       |
| `image.tag`                  | `0.1.0`                            |
| `replicaCount`               | `2`                                |
| `config.port`                | `"8080"`                           |
| `config.greeting`            | `"Hello from EKS (helm chart)"`    |
| `config.environment`         | `"eks-pod"`                        |
| `service.type`               | `ClusterIP`                        |
| `service.port`               | `80`                               |
| `ingress.enabled`            | `true`                             |
| `ingress.className`          | `traefik`                          |

Override in Palette's Cluster Profile values pane (or with `--set` locally).
