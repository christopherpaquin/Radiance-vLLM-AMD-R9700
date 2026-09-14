# Tuning notes

Living document -- filled in as Phase 1-3 (plan-radiance-vllm.md) run real
sweeps on scar.lab. Do not trust nominal config values over real
`rocm-smi`/`amd-smi` measurements -- this exact lesson cost the abandoned
`Containerized-VLLM-AMD-R9700` deployment real debugging time (real VRAM
usage ran several GiB over the nominal `GPU_MEMORY_UTILIZATION` percentage
on this same GPU).

## GPU memory utilization sweep

Target per explicit user direction (plan §7.3, §25): start at 0.968 (the
task's literal full-spec target), measure real VRAM usage immediately
after load, back off in small steps only if real headroom is unsafe
(<~0.5-1GB).

| GPU_MEMORY_UTILIZATION | Real VRAM used (rocm-smi) | Headroom | Notes |
|---|---|---|---|
| 0.968 | 30.75 GiB | **1.11 GiB** | qwen38-27b (RedHatAI INT4), 2026-09-14. Passed `validate-model.sh`'s safety-floor check. Right at the task's ~1GB target -- **shipped as-is, no further sweep needed.** |

vLLM's own log also reports the CUDA-graph-memory-profiling-adjusted
equivalent: *"The current --gpu-memory-utilization=0.9680 is equivalent
to --gpu-memory-utilization=0.9597 without CUDA graph memory
profiling."* -- informational, not something this deployment needs to
act on (the real rocm-smi measurement is the ground truth used here, not
vLLM's own nominal-vs-effective estimate).

## KV cache dtype

`fp8` is the target (plan §7.2) -- correctness-gated, not just a
throughput setting. `validate-model.sh`'s known-answer/tool-call checks
must pass at this setting before it ships.

| KV_CACHE_DTYPE | Passed validate-model.sh? | KV cache size (tokens) | Notes |
|---|---|---|---|
| fp8 | **Yes** (2026-09-14) | **302,359** | 2.31x concurrency at the full 131,072-token context target. Checkpoint lacks calibrated q/k/v scale factors (defaults to 1.0, per startup warnings) -- known accuracy caveat, not yet independently verified beyond the known-answer fixtures (which did pass). |

## max_num_seqs (new finding, not anticipated in the original plan)

The hybrid Gated-DeltaNet architecture requires one Mamba cache block per
concurrent decode sequence. vLLM's default `max_num_seqs=256` (built for
multi-user throughput) exceeded the Mamba-cache-block budget derivable
from this deployment's KV budget (194 blocks available at
GPU_MEMORY_UTILIZATION=0.968), causing a hard `ValueError` at startup --
not an OOM, not an architecture-compat failure, just a default tuned for
a different workload shape.

| max_num_seqs | Result | Notes |
|---|---|---|
| 256 (vLLM default) | **FAILS** -- `ValueError: max_num_seqs (256) exceeds available Mamba cache blocks (194)` | Never use this value on this model/image/context combination |
| 32 | **Works** | Chosen value -- this deployment's stated priority is single-user interactive coding (task spec), not multi-user throughput, so 32 is ample headroom under 194 |

Raise only if real usage shows a need for more concurrent sequences, and
never above 194 without also re-tuning GPU_MEMORY_UTILIZATION to grow the
Mamba block budget.

## Speculative decoding (DFlash2)

Armed by default in this image (`RADIANCE_DYNAMIC_DRAFT=ON`). Confirmed
active during the validated deployment (no separate enable flag needed).
**Not yet run through a dedicated strict output-equivalence test** (plan
§8.2) -- nothing observed during manual generation, tool-calling (6/6
scenarios), or the known-answer/determinism validation suite suggested a
correctness problem, but that's circumstantial, not the formal gate the
plan requires before fully trusting it. Treat as an open follow-up task.

| Config | Passed formal equivalence gate? | Acceptance rate | Notes |
|---|---|---|---|
| default (tau=0.28, schedule=1:8,2:7,4:6,8:5,16:4) | Not formally tested | Not measured | Circumstantial evidence (6/6 tool-call scenarios, known-answer fixtures, 4/4 determinism trials) is positive but not a substitute for the dedicated gate |

## R4D attention engagement

| Layer type | R4D engaged? | Evidence |
|---|---|---|
| Gated-DeltaNet (48 layers) | **Yes** | `gdn_chunk_scan ENABLED (head_k 128, head_v 128, chunk 64)` confirmed live for both the FP8 smoke test and the real INT4 deployment |
| Gated Attention (16 layers) | Ambiguous | Effective attention backend resolves to `ROCM_AITER_UNIFIED_ATTN` (AITER's unified attention), not a distinct "R4D"-named backend in vLLM's backend enum -- `[radiance] attn tuned-config override installed on 2 module aliases` suggests R4D patches into this path rather than registering separately. Not fully disambiguated from logs; low priority to chase further since the deployment works and passes all functional/correctness checks regardless of the precise attribution. |

## Cold-start timing

| Profile | Load stage | Time | Notes |
|---|---|---|---|
| qwen38-27b-smoketest (FP8, no HF token) | Download (30.89GB) | ~9 min | Rate-limited, no HF token. Not representative of a warm-cache redeploy. |
| qwen38-27b (INT4, no HF token) | Download (18.12GB) | ~4 min | Same rate-limiting caveat. |
| qwen38-27b (INT4) | Weight load (warm disk cache) | 9.57s | |
| qwen38-27b (INT4) | torch.compile (cold, no AOT cache) | 84.87s | |
| qwen38-27b (INT4) | torch.compile (warm AOT cache) | **1.16s** | Cache hit confirmed via `Directly load AOT compilation from path` log line -- redeploys after the first successful one are fast. |
| qwen38-27b (INT4) | Full container restart to serving (warm caches) | **~2.5 min** | End-to-end, matches the healthcheck `start_period` design in `compose.yaml` (currently 1800s -- generous, could be tightened once this timing is well-established, not done here). |

**Recommendation for a future HF token**: all cold-start numbers above
are dominated by unauthenticated-HF-Hub rate limiting, not real compute
time. Setting `HUGGING_FACE_HUB_TOKEN` in `.env` would materially speed
up any future fresh download (new model, cache purge, etc.) -- not done
in this session (no token was available), noted here as a low-effort
future improvement.

## Benchmark results (2026-09-14, `scripts/benchmark.sh`, staging port 8081)

| Concurrency | Prompt tokens | Max tokens | TTFT | Decode tok/s | Notes |
|---|---|---|---|---|---|
| 1 | ~509 | 256 | 0.042s | 24.18 | |
| 1 | ~509 | 128 | 0.005s | 23.47 | Consistent with the run above -- no restart-to-restart variance seen across these two runs |

TTFT is excellent (sub-50ms). Decode throughput (~23-24 tok/s) is
**plausibly in the "slow band" of the documented bimodal decode-
throughput bug** (`ROCm/ROCm#6347`, plan §9.1/`docs/runbook.md` --
sticks at ~26 or ~33 tok/s, determined randomly at HIP process init) --
or it may simply be this INT4/W4A16 kernel path's real throughput on
this hardware; the two are not distinguished by two same-session runs
(no container restart between them, so HIP init state didn't re-roll).
**Follow-up task, not done in this session**: restart the container and
re-benchmark to see if throughput jumps to the faster band, per the
runbook's documented troubleshooting step.

**Direct llama.cpp throughput comparison not performed live** -- the
existing llama.cpp benchmark reports
(`Containerized-llamma.ccp-AMD-9700/performance/reports/`) recorded
perplexity/accuracy (WikiText-2, HellaSwag) for this exact model/quant
family but marked throughput fields "not measured." A live head-to-head
would require running both servers, which isn't possible simultaneously
on this single 32GB GPU (see the VRAM-contention note in
`docs/runbook.md`) without an extra stop/benchmark/redeploy cycle not
performed in this session. Flagged as a follow-up, not a blocker --
TTFT and correctness are already strong signals on their own.
