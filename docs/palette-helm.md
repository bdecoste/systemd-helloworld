# Deploying HelloWorld as a Palette Helm chart

After hitting a wall with Palette's Pack OCI sync path (see prior findings in
this repo's history), we pivoted to a Helm chart published as an OCI artifact
in Harbor and registered in Palette under the **Helm** registry sub-type
(which uses the standard Helm-OCI protocol rather than a Spectro-specific
pack manifest).

## Prerequisites

- Harbor already deployed to the EKS cluster (see the ingress-nginx / Harbor
  bits earlier in the repo)
- `spectro-packs` project exists in Harbor (created earlier)
- Helm ≥ 3.8 installed locally (`helm registry` and `helm push` are Helm 3.8+)

## 1. Package the chart

```bash
cd /Users/bill.decoste/claudecode/heart-flow
helm package palette-helm/helloworld
# produces ./helloworld-0.1.0.tgz
```

## 2. Push to Harbor as an OCI Helm chart

```bash
kubectl -n harbor port-forward svc/harbor-core 8080:80 &

helm registry login localhost:8080 -u admin -p Harbor12345 --insecure
helm push helloworld-0.1.0.tgz oci://localhost:8080/spectro-packs --insecure-skip-tls-verify
```

Verify it landed:

```bash
curl -su admin:Harbor12345 \
  "http://localhost:8080/api/v2.0/projects/spectro-packs/repositories/helloworld/artifacts?with_tag=true" \
  | jq '.[] | {digest, tags: [.tags[].name], media_type, artifact_type}'
```

The `media_type` should now be `application/vnd.cncf.helm.chart.content.v1.tar+gzip`
(a real Helm chart) rather than the ad-hoc `spectrocloud.pack.v1+tar` we used before.

## 3. Register Harbor as a Helm registry in Palette

Tenant Settings → Registries → **Add Pack Registry** → the OCI sub-type list
now offers **Helm**. Fill in:

| Field              | Value                                                     |
|--------------------|-----------------------------------------------------------|
| Registry Name      | `Harbor-Helm`                                             |
| Endpoint           | `http://harbor-core.harbor.svc.cluster.local`             |
| Base Context Path  | `spectro-packs`                                           |
| Auth Type          | Basic                                                     |
| Username           | `admin`                                                   |
| Password           | `Harbor12345`                                             |

Sync. Because Helm-OCI is a standard protocol, Palette should enumerate and
index the chart without needing any Spectro-specific manifest artifact.

## 4. Add to a Cluster Profile

Profiles → Add Add-on Profile → Add Pack → Registry: `Harbor-Helm` →
`helloworld @ 0.1.0` should appear. Override the `image.repository` value
to point at the real ECR path for the container image, then attach the
profile to the Palette-managed EKS cluster.
