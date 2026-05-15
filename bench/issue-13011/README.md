# Reproduction harness — Traefik issue [#13011](https://github.com/traefik/traefik/issues/13011)

Demonstrates the steady-state CPU regression introduced in Traefik v3.1.0
(EndpointSlice migration in the `kubernetes` provider) and still present
through v3.6.x.

The harness:

1. creates a **multi-node** kind cluster (1 control-plane + 10 workers) and
   installs `metrics-server` (with `--kubelet-insecure-tls`, required on
   kind),
2. installs Traefik (Helm chart `traefik/traefik`) with both `kubernetes`
   (Ingress) and `kubernetescrd` providers enabled, and verifies the flags
   landed on the running pod,
3. deploys 200 `Service`s + 200 `Ingress`es + 200 `IngressRoute`s + 200
   `TraefikService`s, with **3 `Middleware`s shared per route** (600 total),
   all in namespace `bench-workload`. Resources are applied in **two phases**
   — leaves (Services + Middlewares) first, consumers (Ingresses,
   IngressRoutes, TraefikServices) second — so Traefik never sees a router
   referencing a Middleware/Service it hasn't yet ingested. The IngressRoute
   targets the same Service via the TraefikService and reuses the same three
   Middlewares as the Ingress, so both `kubernetes` and `kubernetescrd`
   providers carry equal load,
4. captures Traefik pod CPU/memory every 15 s until 120 samples are
   recorded (~30 min wall-clock), with background **churn** (Node label
   flips + `dummy-backend` scale flips) running for the entire capture so
   Node and EndpointSlice update events flow through Traefik's watch loop
   instead of leaving it idle,
5. upgrades Traefik to the latest **3.1.x**, repeats the capture,
6. upgrades to the latest **3.6.x**, repeats,
7. emits per-version CSVs and a summary table (count, mean, p50, p95, max
   mCPU).

The 21-node setup is intentional: issue #13011 names node-heartbeat churn
(kubelet rewrites `Node.Status` ~every 10 s) as one of the regression's hot
paths, so more nodes drive more events through Traefik's watch loop and make
the regression more visible in the capture.

The workload is created **once** and persists across upgrades — applying the
same load to each version is the whole point.

## Prerequisites

These tools must be on `PATH`:

- `kind`
- `kubectl`
- `helm`
- `jq`
- `awk` (provided by every base distro / macOS)
- a working Docker daemon (for kind)

The default run also captures a **locally-built** image as a 4th comparison
point. Build it first with `make build-image-dirty` from the repo root
(produces `traefik/traefik:latest`), or set `SKIP_LOCAL_CAPTURE=1` to omit
that step. `scripts/run.sh` fails fast at the top if the image is missing
so you don't lose 45+ minutes of capture time.

Before kind-loading, `run.sh` aliases the build artifact as
`traefik/traefik:$VLOCAL` (default `v3.7.1-dev`; override with `VLOCAL`)
because the chart's `role.yaml` parses `image.tag` as SemVer and rejects
`latest`. The alias is refreshed on every run by comparing image IDs, so
a rebuild via `make build-image-dirty` is picked up automatically.

In local-image mode, `install-traefik.sh` also overrides the chart's image
fields to `image.registry=localhost` + `image.repository=traefik/traefik`,
because kind's `ctr images import` (containerd 2.0+ / kind v0.30+) stores
unqualified refs under `localhost/`, not `docker.io/`. Without the
override, the pod looks up `docker.io/traefik/traefik:<tag>` and kubelet
fails with `ErrImageNeverPull` even though the image is on every node.

**Resource cost.** kind runs each node as its own Docker container with
kubelet/containerd/Kubernetes components — budget ~400–500 MB RAM per node,
so the 21-node cluster alone needs **≥12 GB** of free RAM and a few GB of
Docker disk before the workload is even deployed. If your machine is tight,
edit `manifests/kind-config.yaml` to remove some `worker` entries — none of
the scripts hard-code the count.

## Usage

```bash
cd bench/issue-13011

# Full run (~100 min wall-clock). Includes a capture against the
# locally-built image, so build it first:
make -C ../.. build-image-dirty
scripts/run.sh

# Skip the local-image capture (keeps the original 3-version flow).
SKIP_LOCAL_CAPTURE=1 scripts/run.sh

# Smoke test the harness end-to-end with 8-sample captures (~10 min wall-clock).
CAPTURE_SAMPLES=8 scripts/run.sh

# Pin specific patch versions instead of auto-resolving "latest 3.1.x" / "latest 3.6.x".
# The matching Helm chart (whose appVersion equals the image tag) is
# auto-resolved alongside; override with CHART304/CHART31/CHART36 if needed.
V31=v3.1.0 V36=v3.6.0 scripts/run.sh
CHART304=26.0.0 V31=v3.1.0 CHART31=27.0.0 scripts/run.sh

# Tear down when done.
scripts/teardown.sh
```

Results land under `results/` (gitignored):

- `results/v3.0.4.csv`, `results/v3.1.x.csv`, `results/v3.6.x.csv` — raw samples
  (`timestamp,cpu_m,mem_mi,pod_count`).
- `results/summary.txt` — aggregated table; two panels, one for CPU
  (`mean_m / p50_m / p95_m / max_m`) and one for memory (`mean_mi / p50_mi /
  p95_mi / max_mi`), each with a bar chart and per-version sparkline.
- `results/{heap,goroutine,allocs,profile}-<label>.pb.gz` — optional pprof
  snapshots from `scripts/capture-pprof.sh`. See [Memory
  diagnostics](#memory-diagnostics).

## Layout

```
bench/issue-13011/
├── README.md
├── manifests/
│   ├── kind-config.yaml
│   ├── metrics-server.yaml          # vendored v0.7.2 + --kubelet-insecure-tls
│   ├── backend.yaml                 # shared nginx Deployment
│   ├── workload-1.tmpl.yaml         # phase 1: Service + 3 Middlewares per route
│   └── workload-2.tmpl.yaml         # phase 2: Ingress + TraefikService + IngressRoute
├── scripts/
│   ├── lib.sh                       # shared helpers (sourced)
│   ├── run.sh                       # entry point
│   ├── setup-cluster.sh
│   ├── install-traefik.sh
│   ├── deploy-workload.sh
│   ├── capture-cpu.sh
│   ├── capture-pprof.sh            # optional: heap/goroutine/allocs profiles
│   ├── churn.sh                    # background Node/EndpointSlice churn
│   ├── summarize.sh
│   └── teardown.sh
└── results/                         # CSVs + summary.txt (gitignored)
```

## Individual scripts

Each script is self-contained and idempotent. They can be run independently
(e.g. to re-capture without redeploying the workload):

```bash
scripts/setup-cluster.sh
# install-traefik.sh takes an optional 2nd arg pinning the Helm chart
# version. Required for older image tags (the latest chart floors at
# Traefik v3.6.0+). Omit for the locally-built / current image.
scripts/install-traefik.sh v3.0.4 <chart-version>
scripts/deploy-workload.sh
scripts/capture-cpu.sh v3.0.4 120
scripts/install-traefik.sh v3.1.7 <chart-version>
scripts/capture-cpu.sh v3.1.7 120
# Install a locally-built image (kind-loads it, pins pullPolicy=Never,
# overrides image.repository to the two-segment path it was loaded under).
# `run.sh` aliases the build artifact automatically; standalone callers
# must tag manually so the SemVer tag is present in the Docker daemon.
docker tag traefik/traefik:latest traefik/traefik:v3.7.1-dev
TRAEFIK_LOCAL_IMAGE=1 scripts/install-traefik.sh v3.7.1-dev
scripts/capture-cpu.sh v3.7.1-dev 120
scripts/summarize.sh
```

## Sampling notes

- Sample cadence: 15 s. Source: `kubectl top pod` (metrics-server). The
  capture loop runs until exactly `CAPTURE_SAMPLES` (default 60) successful
  samples are recorded — ~15 min wall-clock at the default cadence — so per-
  version CSVs always have identical `n` and stats are directly comparable.
- 60 s warmup precedes the sample loop so the post-upgrade config-load spike
  doesn't pollute the steady-state mean.
- `cpu_m` is **millicores**; `mem_mi` is **MiB**.

## Churn

Issue #13011 is event-volume-driven. Without external pressure the only
sources of informer traffic during capture are kubelet `Node.Status`
heartbeats (~10 s/node) — too quiet to surface the regression. To fix
this, `capture-cpu.sh` starts `scripts/churn.sh` in the background before
the warmup and tears it down on exit (via `trap`). Churn runs identically
across all per-version captures, so the comparison stays valid.

`churn.sh` runs two independent loops:

- **Node churn** — every `CHURN_NODE_INTERVAL` s (default 5), flip a
  `bench-churn=A|B` label on every worker node. Each flip emits a `Node`
  Update event to all watchers.
- **EndpointSlice churn** — every `CHURN_EPS_INTERVAL` s (default 10),
  scale `dummy-backend` between 2 and 3 replicas. Because all 200 `svc-N`
  Services select `app=dummy-backend`, each scale fans out to 200
  EndpointSlice updates.

Disable churn for an A/B sanity check:

```bash
CHURN_ENABLE=0 scripts/run.sh
```

Tune cadence with `CHURN_NODE_INTERVAL` and `CHURN_EPS_INTERVAL`. On exit
(success or `^C`), churn is stopped, `dummy-backend` is restored to 2
replicas, and `bench-churn` labels are stripped from all nodes.

## What you should see

Per the issue, v3.0.4 should show a noticeably lower mean / p95 CPU than
v3.1.x and v3.6.x on this workload (200 Ingresses × 3 Middlewares = 600
Middleware references; 200 Services ⇒ 200 EndpointSlices). The harness
produces the exact numbers, but the **shape** of the result is what matters:
a clear CPU gap between v3.0.4 and the post-3.1 versions.

Any pre-existing CSVs/`summary.txt` captured before the churn loop was
added are not directly comparable to fresh runs — re-capture from a clean
baseline if you need the gap measurement.

## Tunables

Override via env vars (see `scripts/lib.sh`):

| Var                    | Default          | Meaning                                       |
| ---------------------- | ---------------- | --------------------------------------------- |
| `CLUSTER_NAME`         | `traefik-bench`  | kind cluster name                             |
| `TRAEFIK_NS`           | `traefik`        | Traefik install namespace                     |
| `WORKLOAD_NS`          | `bench-workload` | workload namespace                            |
| `ROUTE_COUNT`          | `200`            | number of Service/Ingress/MW triplets         |
| `TRAEFIK_REPLICAS`     | `1`              | Traefik Deployment replica count              |
| `CAPTURE_SAMPLES`      | `60`             | samples to capture per version (15 s cadence) |
| `CHURN_ENABLE`         | `0`              | run churn loops during capture (0 to disable) |
| `CHURN_NODE_INTERVAL`  | `15`             | seconds between Node label flips              |
| `CHURN_EPS_INTERVAL`   | `30`             | seconds between dummy-backend scale flips     |
| `V304` / `V31` / `V36` | autodetect       | Traefik image tags to install                 |
| `CHART304` / `CHART31` / `CHART36` | autodetect | Helm chart version per image tag (matched on `appVersion`) |
| `VLOCAL`               | `v3.7.0-dev`     | SemVer alias for the locally-built `traefik/traefik:latest` image (loaded into kind as `traefik/traefik:$VLOCAL`; the chart's `role.yaml` rejects non-SemVer tags) |
| `SKIP_LOCAL_CAPTURE`   | (unset)          | Set to `1` to skip the locally-built image capture |
| `INSTALL_TIMEOUT`      | `300s`           | Helm `--wait` / `kubectl rollout` ceiling per install (cold-starting Traefik against the deployed workload routinely needs >3 min) |
