# Radiance vLLM on AMD Radeon AI PRO R9700 (scar.lab)

Production deployment and automation for running a vLLM-compatible inference
service on `scar.lab` using the community Radiance stack
(`vllm-radiance`/`libr4d`) and one AMD Radeon AI PRO R9700 (32 GiB,
gfx1201/RDNA4). This repository replaced the host's previous llama.cpp service
while preserving a tested rollback path.

## Current deployment

| Component | Current value |
|---|---|
| API | `http://scar.lab:8080/v1` |
| Dashboard | `http://scar.lab:8088/` |
| Model | `RedHatAI/Qwen3.8-27B-INT4`, served as `scar-coder` |
| Runtime | Radiance-patched vLLM 0.28.0 on ROCm |
| Context | 131,072 configured tokens; 262,144 native model context |
| KV cache | FP8, approximately 358,958-token capacity |
| Container | `radiance-vllm` |

The deployment is operational and cut over to production. See `STATUS.md` for
the current state and `WORKLOG.md` for the implementation record.

**Read `plan-radiance-vllm.md` and `plan-radiance-observability.md` first.**
They contain the full design rationale, verified research, and explicit
decisions this implementation follows. This README is an operational
quick-reference, not a substitute for those documents.

## Important framing

"Radiance vLLM" is not an AMD-official product. It's a single-maintainer
community project originally maintained by StillDeadcode. This deployment uses
the actively maintained `magiccodingman` fork, which packages patched vLLM with
the `libr4d` RDNA4 kernel library. Radiance provides R4D attention/GDN kernels
and experimental speculative-decoding paths.

The upstream project's primary qualified environment is two R9700 GPUs with
tensor parallelism. This repository's single-GPU, INT4, 131K-context deployment
is outside that primary qualification profile and was therefore validated on
the target host before cutover. See `plan-radiance-vllm.md` §4 for the complete
risk analysis and decision record.

### Upstream projects

- [magiccodingman/vllm-radiance](https://github.com/magiccodingman/vllm-radiance)
  -- source repository for the fork used by this deployment.
- [magiccodingman/vllm-radiance on Docker Hub](https://hub.docker.com/r/magiccodingman/vllm-radiance)
  -- source of the digest-pinned production image.
- [StillDeadcode/vllm-radiance](https://codeberg.org/StillDeadcode/vllm-radiance)
  -- original upstream project.
- [vLLM](https://github.com/vllm-project/vllm) -- inference engine on which
  Radiance is based.

The exact production image digest is recorded in `VERSIONS`; floating image
tags are not used for deployment.

## Requirements

- Linux host with a ROCm-supported AMD Radeon AI PRO R9700 (`gfx1201`)
- Docker Engine with the Compose plugin
- ROCm device nodes `/dev/kfd` and `/dev/dri`
- `curl`, `jq`, and `bc` for validation and benchmark scripts
- Sufficient storage for Hugging Face model and compilation caches under
  `/var/lib/radiance-vllm`

## Quick start

```sh
cp .env-template .env       # review it -- HUGGING_FACE_HUB_TOKEN, etc.
./install.sh                 # creates /var/lib/radiance-vllm, runs preflight
scripts/deploy.sh qwen38-27b # deploy the primary profile
scripts/status.sh            # check health
scripts/test-tool-calling.sh qwen38-27b
scripts/benchmark.sh qwen38-27b
scripts/logs.sh
```

## Model profiles

| Profile | Stack | Purpose |
|---|---|---|
| `qwen38-27b` | radiance-baseline | Primary production profile |
| `qwen38-27b-smoketest` | radiance-baseline | Architecture validation only |
| `qwen25-coder-14b` | radiance-baseline | Proven fallback profile |
| `qwen3-coder-30b-a3b` | radiance-baseline | Proven fallback profile |
| `qwen38-27b-radlight` | radlight | Exact-parity candidate |
| `-balanced` / `-compat` | radlight | Context/concurrency fallbacks |
| `-nospec` / `-template` | radlight | DFlash2-off / template A/B variants |

The profile files under `config/models/` document their quantization, context,
and speculative-decoding decisions. A profile's *name* determines its stack
(`scripts/lib/common.sh:stack_for_profile`) -- any `*radlight*` profile runs
through `compose.radlight.yaml`, everything else through `compose.yaml`.
See `docs/RADLIGHT-TUNABLES.md` and `docs/runbook.md`'s "Radlight canary"
section for the two-stack architecture and promotion/rollback procedure.

## Rollback

llama.cpp (`~/Workspace/Git/Containerized-llamma.ccp-AMD-9700`) is never
modified by this repo. To roll back:

```sh
scripts/rollback.sh
```

See `plan-radiance-vllm.md` §19 for the full procedure and what it does
NOT require (no reinstall, no config restore -- llama.cpp's own state was
never touched).

## Benchmark snapshot

The production concurrency and prompt-size matrix completed 36 of 36 requests
without OOMs or preemptions. Single-request decoding measured approximately
23-24 tokens/s; aggregate generation reached approximately 74 tokens/s at
concurrency 4 and 97 tokens/s at concurrency 8. See `docs/TUNING.md` and the
curated files in `benchmarks/results/` for the complete results and limitations.

## Scripts

- `install.sh` / `uninstall.sh` -- system directory setup / teardown
- `scripts/preflight.sh [--cutover]` -- read-only host readiness checks
- `scripts/deploy.sh <profile>` -- deploy + validate a model profile
- `scripts/start.sh` / `stop.sh` / `status.sh` / `logs.sh` -- lifecycle
- `scripts/validate-model.sh <profile>` -- VRAM and correctness guardrails
- `scripts/test-tool-calling.sh <profile>` -- tool-calling validation matrix
- `scripts/benchmark.sh <profile>` -- repeatable TTFT/throughput measurement
- `scripts/cutover.sh <profile>` -- production cutover with automatic rollback
- `scripts/rollback.sh` -- manual rollback to llama.cpp
- `scripts/configure-opencode.sh` / `configure-pi.sh` -- client configuration
- `scripts/restore-or-shutdown.sh` -- shared failure-recovery logic
- `scripts/sync-radlight.sh` / `sync-radlight-models.sh` -- pinned Radlight
  source/model acquisition
- `scripts/canary-radlight.sh` -- sequential canary (stops production,
  deploys radlight on the canary port)
- `scripts/promote-radlight.sh` -- promotes a validated radlight canary to
  production port 8080
- `scripts/rollback-radlight.sh` -- level-1 rollback (radlight ->
  radiance-baseline)

## Docs

- `docs/ROCM.md` -- gfx1201/Radiance notes and R4D/DFlash2 findings
- `docs/MODELS.md` -- quantization bake-off results, Phase 0 smoke-test outcome
- `docs/TUNING.md` -- GPU memory, KV-cache sizing, and production benchmarks
- `docs/runbook.md` -- operational procedures (rollback, known-issue workarounds)

## Conventions

Docker (not Podman -- verified host convention, see `plan-radiance-vllm.md`
§12.1), `docker compose`, digest-pinned images (`VERSIONS` +
`scripts/verify-versions-pin.sh`), pre-commit (ruff, shellcheck, shfmt,
pymarkdown, detect-secrets) -- matches every sibling repo on this host.
