# Migration Status

Last updated: 2026-09-21, by the session integrating the Radlight stack
(branch `feat/radlight-integration`). The 2026-09-14 entry below (Phases
0-4 of `plan-radiance-vllm.md`) is unchanged and still accurate for the
`radiance-baseline` stack.

## Radlight integration: IN PROGRESS (not yet promoted)

Production (`scar.lab:8080/v1`) is still served by the `radiance-baseline`
stack (`radiance-vllm` container, `qwen38-27b` profile) -- **unchanged and
untouched** by this work so far. A second, independently-pinned stack
(`radlight`, see `VERSIONS` and `docs/RADLIGHT-TUNABLES.md`) has been added
to the repo but has not yet run its sequential canary as of this entry.

Completed so far:

- Radlight source graph (top-level commit + both submodules) cloned and
  pin-verified at `/var/lib/radiance-vllm/upstream/vllm-radlight`
  (`scripts/sync-radlight.sh`, idempotent, re-verified on every run).
- Base image digest resolved and pinned:
  `docker.io/rocm/vllm@sha256:b8a082f346d069376d35784250e38b23a043efe979408ae3a33d7c6b62ee3276`.
- Target/drafter model revisions resolved and pinned in `VERSIONS`;
  download+verification in progress via `scripts/sync-radlight-models.sh`
  (LFS sha256 / git-blob sha1 verified per file).
- `compose.radlight.yaml`, five `config/models/qwen38-27b-radlight*.env`
  profiles, and stack-aware updates to `scripts/lib/common.sh`,
  `deploy.sh`, `status.sh`, `benchmark.sh`, `validate-model.sh`,
  `restore-or-shutdown.sh`, `rollback.sh` added -- both `docker compose
  config` renders validate cleanly.
- New orchestration scripts: `canary-radlight.sh`, `promote-radlight.sh`,
  `rollback-radlight.sh` (two-level rollback chain).

Not yet done: the actual sequential canary run (requires stopping
production for the duration -- single-GPU VRAM exclusivity, same
constraint as the original llama.cpp migration), every correctness/
tool-call/DFlash2-equivalence/long-context gate, benchmark comparison, and
promotion. See `docs/runbook.md`'s "Radlight canary" section for the
procedure and `WORKLOG.md` for the detailed narrative.

## Radiance-baseline: LIVE IN PRODUCTION (2026-09-14 entry, unchanged)

`scar.lab:8080/v1` is served by **Radiance vLLM** (`radiance-vllm`
container), not llama.cpp. This is a completed cutover, not a staging
deployment.

| Component | State |
|---|---|
| `radiance-vllm` | Running, healthy, `0.0.0.0:8080->8000/tcp` |
| `llamacpp` | Stopped, restart policy `no` (autostart disabled) -- config/container/model files untouched, rollback-ready |
| Served model | `scar-coder` (stable name) → `RedHatAI/Qwen3.8-27B-INT4` |
| Context | 131072 tokens |
| GPU memory utilization | 0.968 (real VRAM headroom: ~0.9-1.1GiB, tightens under load -- see Known Risks) |
| KV cache | FP8, 302,359 tokens capacity (2.31x concurrency at full context) |
| Attention / speculative decoding | R4D (confirmed for the 48 Gated-DeltaNet layers) + DFlash2 (armed, not formally correctness-gated) |
| `max_num_seqs` | 32 (required fix -- see Known Issues Found) |
| OpenCode (raptor.lab) | Reconfigured, verified end-to-end (`opencode run` returned a correct response) |
| PI (raptor.lab) | Reconfigured (model id updated to `scar-coder`), not yet run end-to-end |
| Hermes | Unmodified, verified working (auto-detects model) |
| Dashboard (`:8088`) | Unmodified -- still `INFERENCE_BACKEND=llama_cpp`, does not yet reflect the new backend (separate scope, see below) |

## What was completed (plan-radiance-vllm.md Phases 0-4)

- Full installer repo built (compose, scripts, config profiles, docs,
  lint config) -- see `README.md`.
- Phase 0: architecture smoke test confirmed the hybrid Gated-DeltaNet
  architecture loads correctly in this vLLM/image combination.
- Phase 1-2: real deployment at full spec, validated (VRAM postflight,
  known-answer fixtures, tool-call determinism across a restart, all 6
  `test-tool-calling.sh` scenarios, streaming, `/metrics`).
- Phase 3: baseline benchmark numbers recorded (TTFT ~5-42ms, decode
  ~23-24 tok/s) -- no direct live llama.cpp comparison (VRAM exclusivity
  on this single GPU prevented running both simultaneously).
- Phase 4: cutover executed, OpenCode/PI reconfigured, Hermes verified,
  end-to-end validated through a real `opencode run` session from
  raptor.lab.

Full narrative detail: `WORKLOG.md`. Per-topic detail:
`docs/MODELS.md` (model/quant decisions, Phase 0/1 results),
`docs/TUNING.md` (VRAM/KV-cache/benchmark numbers), `docs/ROCM.md`
(image/backend notes), `docs/runbook.md` (rollback, known-issue
workarounds).

## Known issues found during implementation (not in the original plan)

1. **`max_num_seqs=256` (vLLM's default) fails outright** on this hybrid
   architecture: `ValueError: max_num_seqs (256) exceeds available Mamba
   cache blocks (194)`. Fixed with `--max-num-seqs 32` in
   `config/models/qwen38-27b.env` (appropriate for this single-user
   deployment; do not raise above 194 without re-tuning
   `GPU_MEMORY_UTILIZATION`).
2. **A single 32GB R9700 cannot hold both llama.cpp and radiance-vllm's
   models resident simultaneously** (llama.cpp alone used ~26GB). This
   meant "staging" during implementation required actually stopping
   llama.cpp, not just running on a different port concurrently, as the
   original plan assumed. Documented in `docs/runbook.md`.
3. Two bugs found and fixed in `scripts/validate-model.sh` itself while
   running it (unsafe `source` of a multi-word profile value; a dropped
   `enable_thinking:false` flag that starved the arithmetic fixture's
   token budget) -- neither was a deployment defect.

## Not yet done

- **DFlash2's formal output-equivalence gate** (plan §8.2) -- armed and
  active, circumstantial evidence is positive (6/6 tool-call scenarios,
  known-answer fixtures, 4/4 determinism trials all passed with it on),
  but no dedicated with/without comparison has been run.
- **Live throughput comparison against llama.cpp** -- existing llama.cpp
  benchmark reports only recorded perplexity/accuracy, not throughput.
  Would require an extra stop/benchmark/redeploy cycle.
- **Precise R4D engagement for the 16 full-attention layers** -- R4D is
  confirmed engaged for the 48 Gated-DeltaNet layers
  (`gdn_chunk_scan ENABLED`); the full-attention layers resolve to
  `ROCM_AITER_UNIFIED_ATTN` in logs, not a distinctly-named R4D backend,
  so exact attribution is ambiguous (functionally irrelevant -- the
  deployment works and passes every check either way).
- **`plan-radiance-observability.md` (the entire companion plan)** --
  dashboard `INFERENCE_BACKEND` switch, vLLM metrics wiring, GPU
  telemetry re-verification, model/runtime metadata panel. Not started.
- **VRAM headroom monitoring** -- 1.11GiB measured immediately
  post-deploy, ~0.9GiB observed ~30 minutes later under light real
  traffic. Worth watching under sustained/heavier load; back off
  `GPU_MEMORY_UTILIZATION` if it trends toward zero (see
  `docs/TUNING.md`).
- **PI has not been exercised end-to-end** the way OpenCode was (only
  config updated + endpoint reachability confirmed from raptor.lab).

## Rollback

Still trivial and untouched by any of the above:

```sh
scripts/rollback.sh
```

Stops `radiance-vllm`, re-enables and restarts `llamacpp`, verifies
`:8080/v1/models` responds again. llama.cpp's own config/container/model
files were never modified.
