# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Toolchain

- Go version pinned in `.go-version` (currently `1.25`); module is `github.com/traefik/traefik/v3`.
- A Nix dev shell (`flake.nix`) provides pinned `golangci-lint` and `kubernetes-controller-tools` (used by code-gen).
- WebUI requires Node 22 + Yarn 4 (via corepack). The `Makefile` shells out to a Docker image (`make build-webui-image`) so a local Node toolchain is not strictly required.

## Common commands

Most workflows go through the `Makefile`:

- `make` / `make default` — `go generate` then build the binary into `dist/<os>/<arch>/traefik`. Note this depends on `generate-webui`, which builds the WebUI in Docker and can be slow; for pure-Go iteration prefer `go build ./cmd/traefik`.
- `make binary` — build only (still runs `generate-webui`).
- `make test-unit` — `go test -cover ./pkg/... ./cmd/...`. Pass extra flags via `TESTFLAGS`, e.g. `make test-unit TESTFLAGS="-run TestFoo ./pkg/server/..."`.
- `make test-integration` — runs `./integration` with a 20m timeout. Requires Docker. Run `make pull-images` first to pre-pull container images used by `integration/resources/compose/*.yml`.
- `make test-gateway-api-conformance` / `make test-knative-conformance` — build a dirty Docker image (`build-image-dirty`) and run conformance suites with build tags `gatewayAPIConformance` / `knativeConformance`.
- `make lint` — `golangci-lint run` (config in `.golangci.yml`, `default: all` minus a long deny list).
- `make validate` — `lint` plus `validate-vendor.sh`, `validate-misspell.sh`, `validate-shell-script.sh`. Requires `misspell` and `shellcheck` on PATH.
- `make fmt` — `gofmt -s -w` on tracked `.go` files.
- `make generate` — runs `go generate` (entry: `internal/gendoc.go`), regenerating dynamic/static configuration documentation reference files. Run after touching tagged config structs.
- `make generate-crd` — regenerates Kubernetes CRD clientset and manifests via `script/code-gen.sh` (uses `kubernetes-controller-tools`).
- `make build-image` / `make build-image-dirty` — produce `traefik/traefik:latest` Docker image (the `dirty` variant skips the WebUI rebuild).

Running a single Go test directly (no Makefile needed): `go test -run TestName ./pkg/path/...`. For integration: `go test -run '^TestSimpleSuite$' -testify.m '^TestFoo$' ./integration -tags integration` (suites use `testify/suite`).

## Architecture

Traefik is a single-binary HTTP/TCP/UDP reverse proxy whose configuration is *continuously* derived from external sources. The core flow is:

1. **Static configuration** is loaded once at boot from CLI flags, env vars, or a file via `paerser`. It lives in `pkg/config/static` and is wired up in `cmd/traefik/traefik.go` (`runCmd` → `setupServer`). It declares entry points, providers, ACME, observability, etc., and cannot be changed without restart.
2. **Providers** (`pkg/provider/{docker,kubernetes,file,consul,consulcatalog,ecs,nomad,kv,http,rest,tailscale,acme,traefik,...}`) each watch their source and emit `dynamic.Configuration` messages on a channel. They are combined by `pkg/provider/aggregator` and merged via `pkg/provider/merge.go`.
3. **`pkg/server/configurationwatcher.go`** debounces the merged stream and, on each change, rebuilds the runtime via `pkg/server/routerfactory.go`. The factory composes:
   - HTTP/TCP/UDP routers from `pkg/server/router/*`,
   - middleware chains from `pkg/server/middleware` + `pkg/middlewares/*` (each middleware lives in its own subpackage),
   - services (load balancers, mirroring, failover, weighted) from `pkg/server/service/*`.
4. **Entry points** in `pkg/server/server_entrypoint_{tcp,udp,tcp_http3}.go` accept connections; the `handler_switcher` pattern atomically swaps in the new router on each reload so connections stay up across config changes. Socket activation and platform-specific listen-config live in the `socket_activation_*.go` and `server_entrypoint_listenconfig_*.go` files.
5. **Runtime view** of routers/services/middlewares is in `pkg/config/runtime` and exposed by `pkg/api` (the dashboard backend).

Adjacent subsystems:

- `pkg/tls` — certificate store and resolver (used by ACME and the providers).
- `pkg/muxer/{http,tcp}` and `pkg/rules` — routing rule parsing and matching.
- `pkg/proxy` (+ `pkg/proxy/httputil`, `pkg/proxy/fast`) — HTTP backend transports; `pkg/tcp`, `pkg/udp` — L4 proxying.
- `pkg/observability/{logs,metrics,tracing}` — zerolog logger, OpenTelemetry/Prometheus/Datadog/etc. metrics, OTel tracing. Wired in `cmd/traefik/traefik.go`.
- `pkg/plugins` — Yaegi-based plugin loader for middlewares/providers; orchestration in `cmd/traefik/plugins.go`.
- `pkg/healthcheck`, `cmd/healthcheck` — used both by the `traefik healthcheck` subcommand and by service health checking.

### Config types

There are three config "shapes" — keep them straight when editing:

- `pkg/config/static` — boot-time configuration (entry points, providers, ACME, ping, log, metrics).
- `pkg/config/dynamic` — runtime/hot-reloadable configuration (routers, services, middlewares, TLS). This is what providers emit. Tags on these structs drive label/KV parsing (`pkg/config/label`, `pkg/config/kv`) and the docs generated by `make generate`.
- `pkg/config/runtime` — the materialised view used by the API/dashboard, including status.

After changing tagged fields in `pkg/config/dynamic` or `pkg/config/static`, run `make generate` to regenerate the doc reference files; CI will fail otherwise.

### WebUI

`webui/` is a React + Vite app (see `webui/readme.md`). The built artefacts under `webui/static/` are embedded into the Go binary via `webui/embed.go` and served by `pkg/api`. Frontend dev workflow: `cd webui && corepack enable && yarn install && yarn dev` (uses MSW for mocked data on `http://localhost:3000`).

### Integration tests

`integration/integration_test.go` is the entry point. Tests use `testify/suite` and `testcontainers-go` to spin up Docker Compose stacks from `integration/resources/compose/*.yml` and a real Traefik binary or `traefik/traefik:latest` image. A few suites are gated by build tags (`gatewayAPIConformance`, `knativeConformance`).
