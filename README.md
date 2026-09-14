# Radiance vLLM on AMD Radeon AI PRO R9700 (scar.lab)

Installer/automation for migrating scar.lab's LLM inference stack from
llama.cpp to a vLLM deployment on the "Radiance" stack
(`vllm-radiance`/`libr4d`, a community project -- see below) running on the
host's single AMD Radeon AI PRO R9700 (32GB, gfx1201/RDNA4).

**Read `plan-radiance-vllm.md` and `plan-radiance-observability.md` first.**
They contain the full design rationale, verified research, and explicit
decisions this implementation follows. This README is an operational
quick-reference, not a substitute for those documents.

## Important framing

"Radiance vLLM" is not an AMD-official product. It's a single-maintainer
community project (`vllm-radiance`, originally by StillDeadcode, this
deployment uses an actively-maintained fork by `magiccodingman`) that ships
a patched vLLM plus a custom RDNA4 kernel library (`libr4d`, providing the
"R4D" attention backend and "DFlash2" speculative decoding). Its primary
qualified environment is 2xR9700 (TP=2) -- single-GPU (this deployment) is
explicitly the least-tested configuration in this ecosystem. See
`plan-radiance-vllm.md` §4 for the full risk framing and why this project
was chosen anyway (explicit user decision, recorded in §4.1/§25).

## Quick start

```sh
cp .env-template .env       # review it -- HUGGING_FACE_HUB_TOKEN, etc.
./install.sh                 # creates /var/lib/radiance-vllm, runs preflight
scripts/deploy.sh qwen38-27b # deploy the primary profile
scripts/status.sh            # check health
scripts/test-tool-calling.sh qwen38-27b
scripts/logs.sh
```

## Model profiles

| Profile | Purpose |
|---|---|
| `qwen38-27b` | Primary target -- see `config/models/qwen38-27b.env` for the full quant/context/spec-decode decision tree |
| `qwen38-27b-smoketest` | Phase 0 architecture validation only -- not a real deployment profile |
| `qwen25-coder-14b` | Proven-working fallback (ported from the abandoned vLLM deployment) |
| `qwen3-coder-30b-a3b` | Proven-working fallback (ported from the abandoned vLLM deployment) |

## Rollback

llama.cpp (`~/Workspace/Git/Containerized-llamma.ccp-AMD-9700`) is never
modified by this repo. To roll back:

```sh
scripts/rollback.sh
```

See `plan-radiance-vllm.md` §19 for the full procedure and what it does
NOT require (no reinstall, no config restore -- llama.cpp's own state was
never touched).

## Scripts

- `install.sh` / `uninstall.sh` -- system directory setup / teardown
- `scripts/preflight.sh [--cutover]` -- read-only host readiness checks
- `scripts/deploy.sh <profile>` -- deploy + validate a model profile
- `scripts/start.sh` / `stop.sh` / `status.sh` / `logs.sh` -- lifecycle
- `scripts/validate-model.sh <profile>` -- guardrail checks (VRAM, known-answer, tool-call determinism)
- `scripts/test-tool-calling.sh <profile>` -- 6-scenario tool-calling validation matrix
- `scripts/cutover.sh <profile>` -- takes over port 8080 from llama.cpp (production-impacting; automatic rollback on failure)
- `scripts/rollback.sh` -- manual rollback to llama.cpp
- `scripts/configure-opencode.sh` / `configure-pi.sh` -- downstream client configuration (run on raptor.lab)
- `scripts/restore-or-shutdown.sh` -- shared failure-recovery logic (ported from the llama.cpp repo)

## Docs

- `docs/ROCM.md` -- gfx1201/vllm-radiance-specific notes, image gotchas, R4D/DFlash2 findings
- `docs/MODELS.md` -- quantization bake-off results, Phase 0 smoke-test outcome
- `docs/TUNING.md` -- GPU memory utilization sweep, KV cache sizing (filled in as Phase 1-3 run)
- `docs/runbook.md` -- operational procedures (rollback, known-issue workarounds)

## Conventions

Docker (not Podman -- verified host convention, see `plan-radiance-vllm.md`
§12.1), `docker compose`, digest-pinned images (`VERSIONS` +
`scripts/verify-versions-pin.sh`), pre-commit (ruff, shellcheck, shfmt,
pymarkdown, detect-secrets) -- matches every sibling repo on this host.
