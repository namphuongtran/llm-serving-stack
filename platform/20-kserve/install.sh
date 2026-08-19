#!/usr/bin/env bash
# Sync wave 2. KServe v0.17 split the chart; kserve.charts in versions.yaml
# is the ordered install list for phase 1 Standard mode (kserve-crd, then
# kserve-resources) - see the comment there for the install guide this was
# checked against. The rest of the split lives under kserve.charts_available
# and is not installed here.
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION="$(yq -r '.kserve.version' versions.yaml)"

# Portable read loop, not `mapfile`/`readarray`: macOS ships bash 3.2 as
# /bin/bash, which has neither builtin, and this script has no reason to
# require bash 4+.
CHARTS=()
while IFS= read -r c; do CHARTS+=("$c"); done < <(yq -r '.kserve.charts[]' versions.yaml)
[ "${#CHARTS[@]}" -gt 0 ] || { echo "kserve.charts is empty in versions.yaml" >&2; exit 1; }

for chart in "${CHARTS[@]}"; do
  # Each entry is an OCI ref with a trailing ":$VERSION" tag, e.g.
  # oci://ghcr.io/kserve/charts/kserve-resources:v0.20.0. Strip the tag so
  # the ref and --version are not passed redundantly, and so the basename
  # gives the bare chart name instead of "kserve-resources:v0.20.0".
  ref="${chart%":${VERSION}"}"
  name="$(basename "$ref")"
  extra=()
  # kserve-resources is the chart that owns the controller Deployment and
  # the inferenceservice-config ConfigMap; it is the only one
  # values-kserve.yaml's keys (kserve.controller.*) apply to.
  [ "$name" = "kserve-resources" ] && extra=(-f platform/20-kserve/values-kserve.yaml)

  # Assert the tag strip landed. If .kserve.version and the tag inside
  # .kserve.charts[] ever disagree, `ref` equals `chart`, `name` keeps its
  # ":v0.20.0" suffix, the equality test above silently fails, and
  # values-kserve.yaml is never passed - which installs KServe with chart
  # defaults and no error printed. CLAUDE.md records what a wrong value in that
  # file costs: a ConfigMap naming a Gateway this repository never creates, with
  # IngressReady never turning true and a 900 second wait as the only symptom.
  [ "$ref" != "$chart" ] || {
    echo "chart ref $chart does not carry the tag :$VERSION" >&2; exit 1; }

  # ${extra[@]+"${extra[@]}"}, not "${extra[@]}". Under `set -u` bash 3.2 treats
  # an EMPTY array expansion as an unbound variable and aborts:
  #   ./platform/20-kserve/install.sh: line 31: extra[@]: unbound variable
  # That is not hypothetical. It is what this script did on 2026-08-19, on the
  # first real run of the imperative path, and the first chart in the loop
  # (kserve-crd) is exactly the empty case - so the script died before
  # installing anything at all.
  #
  # `/bin/bash -n` cannot see this, because the file parses fine; CLAUDE.md
  # names `bash -n` as the check that stands in for running these scripts, and
  # this is a case that check cannot cover. CI did not catch it either, because
  # GitHub runners have bash 5, where an empty expansion is allowed.
  #
  # The `+` form expands to nothing when the array is unset or empty and to the
  # quoted elements otherwise, which is the portable idiom for both shells. The
  # file's own header already says it "has no reason to require bash 4+".
  helm upgrade --install "$name" "$ref" \
    --namespace kserve --create-namespace \
    --version "$VERSION" ${extra[@]+"${extra[@]}"} \
    --wait --timeout 10m
done

kubectl wait --for=condition=Established crd/inferenceservices.serving.kserve.io --timeout=120s
kubectl -n kserve rollout status deploy --timeout=5m
