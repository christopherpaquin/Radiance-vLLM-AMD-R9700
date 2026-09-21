# Migration Status

Last updated: 2026-09-21, by the session that promoted Radlight to
production (branch `feat/radlight-integration`). The 2026-09-14 entry
below (Phases 0-4 of `plan-radiance-vllm.md`) documents the prior
Radiance-baseline cutover and remains accurate as history, but
Radiance-baseline is **no longer the production stack** -- see below.

## Radlight: LIVE IN PRODUCTION (promoted 2026-09-21)

`scar.lab:8080/v1` is served by the **`radlight`** stack (`radlight-vllm`
container, `qwen38-27b-radlight` profile: `amd/Qwen3.8-27B-Quark-AWQ-MXFP4`,
262144 ctx, DFlash2 on) -- see `VERSIONS` and `docs/RADLIGHT-TUNABLES.md`.
`radiance-vllm` (the prior production stack) is preserved stopped, not
removed, as the level-1 rollback target; `llamacpp` remains the untouched
final fallback.

Gates passed before promotion:

- `scripts/validate-model.sh` guardrail suite (VRAM postflight: 1.72-1.73GiB
  headroom across multiple runs; known-answer arithmetic + code fixtures;
  tool-call determinism across 4 trials including a restart) and all 6
  `scripts/test-tool-calling.sh` scenarios -- passed on both the canary
  and, again, on the production port after promotion.
- **Formal DFlash2 output-equivalence gate**
  (`scripts/test-dflash2-equivalence.sh`): 6 deterministic prompts
  (arithmetic, two code-generation, reasoning, JSON, tool-call), DFlash2
  on vs. off, byte-identical normalized output on all 6 -- **PASSED**.
  Full results: `benchmarks/results/dflash2-equivalence-20260921T202835Z/`.
- Kernel/optimization evidence confirmed live: R4D GDN engaged, MXFP4
  304/304 layers on-kernel, FP8 kernels real (not fallback), DFlash2
  genuinely proposing/accepting tokens.
- Full benchmark matrix (concurrency 1/4/8 x prompt ~512/4096/8192,
  256 max tokens, production port) vs. the documented Radiance-baseline
  numbers (`docs/TUNING.md`):

  | Concurrency | Prompt | Radlight tok/s | Baseline tok/s | Ratio |
  |---:|---:|---:|---:|---:|
  | 1 | 509 | 64.72 | 24.18 | 2.68x |
  | 1 | 3653 | 56.53 | 24.05 | 2.35x |
  | 1 | 7277 | 52.39 | 23.41 | 2.24x |
  | 4 | 509 | 103.69 | 74.04 | 1.40x |
  | 4 | 3653 | 102.06 | 74.05 | 1.38x |
  | 4 | 7277 | 92.09 | 68.12 | 1.35x |
  | 8 | 509 | 103.31 | 97.33 | 1.06x |
  | 8 | 3653 | 102.43 | 96.64 | 1.06x |
  | 8 | 7277 | 92.26 | 86.68 | 1.06x |

  Single-stream decode (concurrency 1, this deployment's stated primary
  workload) is 2.2-2.7x faster, well past the 25% promotion threshold.
  The advantage narrows at higher concurrency because this profile's
  `max_num_seqs=2` caps real parallelism, while the baseline's
  `max_num_seqs=32` scales further -- an intentional tradeoff matching
  the stated single-interactive-agent workload priority, not a
  regression. No errors, OOMs, or crashes occurred during the benchmark
  run itself.

**Known risk, not fully resolved:** during today's canary/equivalence
testing (before promotion), the `qwen38-27b-radlight` profile hit
`HSA_STATUS_ERROR_MEMORY_FAULT` on cold start **3 separate times** across
different attempts (different kernels each time), all auto-recovered via
`restart: unless-stopped` on the very next attempt. The promotion
deploy's own cold start had no fault. This is consistent with Radlight's
own README caveat ("first run will crash... run it again") given the
exact-parity profile's very tight VRAM budget, but it is a real,
repeated pattern on cold start, not a single fluke -- worth monitoring;
see `docs/RADLIGHT-TUNABLES.md` "First live canary results" for the
full account. Not yet run: chat-template A/B, the long-context matrix
(8K-262K), and real OpenCode/PI/Hermes agentic-task validation
(connectivity was smoke-tested, not a full agentic workflow).

Also fixed as part of this work: `preflight.sh --cutover`'s llama.cpp
state check only recognized states valid during the *first*
llama.cpp -> radiance-baseline migration, not llama.cpp's stable
long-retired state, which blocked `promote-radlight.sh` with a false
failure.

Completed so far:

- Radlight source graph (top-level commit + both submodules) cloned and
  pin-verified at `/var/lib/radiance-vllm/upstream/vllm-radlight`
  (`scripts/sync-radlight.sh`, idempotent, re-verified on every run).
- Base image digest resolved and pinned:
  `docker.io/rocm/vllm@sha256:b8a082f346d069376d35784250e38b23a043efe979408ae3a33d7c6b62ee3276`.
- Target/drafter model checkpoints downloaded and verified (LFS sha256 /
  git-blob sha1 per file) at pinned HF revisions
  (`scripts/sync-radlight-models.sh`).
- `compose.radlight.yaml`, five `config/models/qwen38-27b-radlight*.env`
  profiles, and stack-aware updates to `scripts/lib/common.sh`,
  `deploy.sh`, `status.sh`, `benchmark.sh`, `validate-model.sh`,
  `restore-or-shutdown.sh`, `rollback.sh`, `preflight.sh` added -- both
  `docker compose config` renders validate cleanly.
- Orchestration scripts: `canary-radlight.sh`, `promote-radlight.sh`,
  `rollback-radlight.sh` (two-level rollback chain),
  `test-dflash2-equivalence.sh`, all exercised live.
- Fixed a separate sibling repo (`vLLM-Management-Portal`, deploys the
  `:8088` dashboard): its live throughput/acceptance-rate telemetry read
  Prometheus metric names vLLM has since removed, so those tiles always
  showed "Idle"/"Unavailable" regardless of real backend or load. Fixed,
  rebuilt, redeployed, and verified live against the running Radlight
  endpoint. See that repo's own WORKLOG.md.

Not yet done: chat-template A/B, the long-context matrix, and full
OpenCode/PI/Hermes agentic-task validation. See `docs/runbook.md`'s
"Radlight canary" section for the procedure and `WORKLOG.md` for the
detailed narrative.

## Radiance-baseline: prior production stack (2026-09-14 entry, historical)

`scar.lab:8080/v1` was served by **Radiance vLLM** (`radiance-vllm`
container) from this cutover until the 2026-09-21 Radlight promotion
above. `radiance-vllm` remains present (stopped) as the current level-1
rollback target.

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
