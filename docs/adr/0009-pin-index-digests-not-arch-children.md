# ADR 0009: Pin index digests, not architecture children

- Date: 2026-09-04
- Status: accepted
- Reverses a decision recorded only in a comment in `versions.yaml`. No ADR is
  superseded.

## Context

`versions.yaml` states its own pinning rule at lines 201 to 203, read
2026-09-04:

> THE TAG AND THE DIGEST DO NOT NAME THE SAME OBJECT, and that is expected, not
> a mistake. The tag names the multi-architecture index. The digest names that
> index's linux/arm64 child, which is what this repository has always pinned and
> why CI runs on ubuntu-24.04-arm

`grep -cE '^  [a-z_]+: "[^"]*@sha256:' versions.yaml` returns **8** on
2026-09-04. Several entries record the architecture they read from the image's
own config blob, for example at lines 271, 320, and 329, each ending
`architecture: arm64`. A ninth reference, the `kind` node image, lives outside
the `images:` block under `.kubernetes.kind_node` and is pinned the same way.

The same file already anticipated the problem, at lines 222 to 223:

> Pinning the INDEX digest instead, so that tag and digest agree, was considered
> on 2026-08-19 and rejected. It would change what gets pulled and would undo
> the deliberate arm64-only pinning. That is a phase 2 question about amd64 GPU
> nodes, not a readability fix.

Phase 2 is that question. A rented GPU machine is amd64. Every one of those
digests names an arm64 manifest, so every pull fails there, and phase 2's plan
is to install all thirteen layers on that machine.

## What the arm64 digest was actually doing

Two jobs, not one, and separating them is the whole decision.

1. **Pinning.** Fixing exactly what gets pulled.
2. **Guarding the architecture.** Making it impossible to pull an amd64 image
   onto the development M4, where ADR 0005 records that emulation ends in an
   illegal instruction rather than in slow success.

Only the second job is architecture-specific, and a digest is the wrong tool
for it. A test is the right tool.

## Decision

1. `versions.yaml` pins the **index digest** for every image. One value per
   image, correct on both architectures, resolved by the container runtime.
2. The architecture guard moves into the contract suite.
   `tests/lib/helpers.bash` gains `require_arch <ref> <arch>`, and
   `tests/contract/03-images.bats` asserts that every pinned image publishes
   **both** a `linux/arm64` and a `linux/amd64` child.
3. `.kubernetes.kind_node` changes the same way, because the amd64 CI job
   creates a real `kind` cluster and needs an amd64 node image.

Two things that do not change, both checked at their source on 2026-09-04:

- **`policy/disallow-floating-tags.yaml` still passes.** Its pattern is
  `"*@sha256:*"`, for containers and init containers alike. An index digest is
  a digest.
- **`require_arm64` already works against an index digest.** Its comment and
  its `jq` expression handle both shapes: a single manifest exposes a top-level
  `architecture` field, and a multi-platform index returns an object keyed by
  `os/arch`, which it tests with `has("linux/arm64")`. The new `require_arch`
  generalises this function rather than replacing it.

**The negative test must survive.** `tests/contract/03-images.bats` asserts that
`kserve/huggingfaceserver:v0.20.0` is **not** arm64, with the comment "If this
ever fails, the constraint behind ADR 0005 has changed and the ADR needs a
successor." That assertion was re-confirmed on 2026-09-04 against the registry
and against KServe's own build workflow, which reads `platforms: linux/amd64`.
A generalisation that swept every image into "both architectures required"
would destroy this test. It is not one of the pinned images and must stay a
deliberate exception.

## Cost accepted

**The M4 can now pull an amd64 image again.** The digest no longer makes that
impossible, so the protection is a test result rather than a physical property.
A developer who ignores a red contract suite can reach the failure ADR 0005
describes. This is accepted because the replacement assertion is strictly
stronger: today the repository proves its images run on one architecture, and
after this change it proves they run on both.

**Eight digests plus the node image must be re-read, each with its date.** They
are not derivable from the values already present, because an index digest is a
different object from its child.

> **Untried (2026-09-04):** no image in this repository has been pinned by index
> digest and pulled. The change is believed correct from the registry manifests
> and from the two source files quoted above, and nothing has run.

## Evidence

- `versions.yaml` lines 201 to 203 and 222 to 223, read 2026-09-04, quoted
  above.
- `policy/disallow-floating-tags.yaml`, read 2026-09-04: `image: "*@sha256:*"`
  under both `containers` and `=(initContainers)`.
- `tests/lib/helpers.bash` lines 54 to 77, read 2026-09-04: the `require_arm64`
  doc comment and its two-branch `jq` expression.
- `tests/contract/03-images.bats`, read 2026-09-04: the arm64 loop over
  `.images`, the huggingfaceserver negative test, and the two `kind_node` tests.
- KServe build workflow `.github/workflows/huggingface-docker-publish.yml`,
  read 2026-09-04: `platforms: linux/amd64`.
