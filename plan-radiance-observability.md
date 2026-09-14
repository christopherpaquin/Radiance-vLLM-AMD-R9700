# Plan: Radiance vLLM Observability & Downstream-Client Integration

Status: planning document, no implementation yet.
Scope: dashboard adaptation, GPU telemetry, vLLM metrics, backend-aware
normalization, OpenCode/PI/Hermes validation, MemPalace dependency check,
real agentic coding tests, performance comparison, acceptance criteria.
Companion document: `plan-radiance-vllm.md` (primary inference-stack migration
— read first; this plan assumes that migration's architecture, port/naming
decisions, and phase structure).

Same labeling convention as the companion plan: **verified fact** (confirmed
live or from a primary source, cited), **design decision** (a choice made
here and why), **open question** (cannot be resolved from a desk plan).

---

## 1. Executive Summary

scar.lab already runs a purpose-built observability dashboard
(`vLLM-Management-Portal`, container `vllm-llama-cpp-dashboard`, port 8088) that
is — **verified, not assumed** — architecturally backend-agnostic by design,
currently pointed at llama.cpp, with a real (though safety-disabled) vLLM
lifecycle path already partially built and previously live-tested against an
actual running vLLM instance on this exact host in August 2026. This plan is
**adaptation, not a rewrite**: flip `INFERENCE_BACKEND` to `vllm`, extend the
existing vLLM branch of `runtime_discovery.py`/`model_cache.py` to the current
verified vLLM metrics surface (§5), keep GPU telemetry unchanged (it's already
backend-independent, §6), and explicitly avoid re-enabling the dashboard's
disabled lifecycle-control path as part of this migration (out of scope —
flagged, not silently expanded into).

The rest of this plan covers what the primary plan's companion document is
supposed to cover: validating OpenCode, PI, and (non-blocking) Hermes against
the new endpoint with real agentic workflows, confirming MemPalace has no
dependency on the change (already confirmed negative, §11), and defining
concrete acceptance criteria distinct from the primary plan's.

---

## 2. Existing Dashboard Discovery (verified)

`~/Workspace/Git/vLLM-Management-Portal` — FastAPI backend (`backend/`),
static JS/HTML frontend (`frontend/app.js`, `index.html`), SQLite
(`vllm_portal.db`), currently deployed as three containers via `docker compose`
(`vllm-llama-cpp-dashboard`, `-docker-proxy`, both from this repo's
`compose.yaml`).

### 2.1 It was built backend-agnostic from day one — not retrofitted

`GOALS.md` (2305 lines — the project's own design spec) explicitly mandates an
adapter architecture: GPU vendor (AMD/NVIDIA), container runtime
(Docker/Podman/Quadlet/systemd), and inference backend are all modeled as
pluggable, discoverable capabilities, quote: *"not assumptions built into the
application."* `INFERENCE_BACKEND` (`vllm` or `llama_cpp`) and
`INFERENCE_BASE_URL` are both `.env`-driven, swappable without a compose edit.

**Naming history clarifies the container names, which look backwards
otherwise:** the container is literally named `vllm-llama-cpp-dashboard`, and
the image `vllm-management-portal:0.1.0` — because it was originally
conceived and first exercised *while vLLM was the running backend* on this
host. `docs/REFERENCE_BASELINE.md`'s live-captured reference data is dated
2026-08-14, which the primary plan's discovery (§2.4 of that document)
confirms sits squarely inside the abandoned vLLM deployment's Aug 10–20
lifespan. **The dashboard's vLLM support was validated live on real vLLM
output before the llama.cpp cutover happened days later** — this is
materially different from "designed for vLLM but never tested," and lowers
the risk of this plan considerably.

### 2.2 Current backend branching (`backend/core/runtime_discovery.py`, `model_cache.py`)

Already implements real per-backend logic, not stubs:

- **vLLM path:** `/health`, `/v1/models`, `/metrics`, startup-log KV parsing,
  HF-snapshot-format cache discovery
- **llama.cpp path:** `/health`, `/v1/models`, `/props`, optional `/metrics`,
  GGUF-file cache discovery

This is the branch point this plan extends (§7), not replaces.

### 2.3 Lifecycle control is real but deliberately disabled — do not re-enable it here

`backend/core/vllm_lifecycle.py` (113 lines): a `DockerComposeLifecycleAdapter`
validates a compose file + service name and exposes read-only `status()` via
`docker compose ps --format json` and a set of `actions()` (up/stop/
restart/ps as literal command lists for the UI to display) — but
`start_vllm()`/`stop_vllm()`/`restart_vllm()`/`apply_profile()` **all
unconditionally raise `LifecycleDisabled`**, with the stated reason:
*"configuration preservation and atomic known-good restore are required"*
first. `IMPLEMENTATION_STATUS.md` confirms this is intentional, in-progress
work (current milestone #6 of 7: *"implement configuration preservation,
validated rendering, atomic restore, and mocked failure recovery before
enabling lifecycle actions"*) — not abandoned, just correctly gated.

**Design decision:** this migration does not touch `vllm_lifecycle.py`'s
safety gate. The primary plan's `scripts/deploy.sh`/`cutover.sh`/
`rollback.sh` (its own §11, §19) are the actual lifecycle mechanism for this
migration — the dashboard remains monitoring-only throughout, exactly as it
is today for llama.cpp. Re-enabling dashboard-driven lifecycle control is a
separate, future workstream (the milestone-#6 work already scoped in that
repo's own `IMPLEMENTATION_STATUS.md`), explicitly out of scope here.

### 2.4 Dead code warning — do not build on this by mistake

`backend/core/capabilities.py` contains a **second, unwired, unsafe-looking**
`VLLMLifecycleProviderImpl` whose `start_vllm()`/`stop_vllm()`/`restart_vllm()`/
`apply_profile()` all just `return True` unconditionally — contradicting
`vllm_lifecycle.py`'s real safety gate. It is not called from
`discover_host_capabilities()` (which always returns `gpus=[]` for this stub
path) and appears to be superseded/abandoned scaffolding. **Flag explicitly
for whoever implements this plan: do not wire UI or automation against
`capabilities.py`'s GPU/lifecycle classes** — the live, correct
implementations are in `gpu_telemetry.py` (§6) and `vllm_lifecycle.py` (§2.3)
respectively. Consider deleting the dead code as a small cleanup task during
implementation (flagged as a suggestion, not a requirement of this plan).

### 2.5 `docs/metrics.md` already anticipates vLLM concepts — verify names, don't assume they're current

The existing doc defines 8 tunable categories (Model, Context & Memory,
Scheduling & Concurrency, Attention & Cache, Speculative Decoding, Sampling,
GPU & Hardware, Performance) and documents **both** llama.cpp env vars
(`LLAMA_ARG_N_GPU_LAYERS`, `_BATCH`, `_UBATCH`, `_CACHE_TYPE_K/V`,
`_CACHE_PROMPT`, `_KV_OFFLOAD`, `_KV_UNIFIED`, `_CACHE_RAM`, `_DRAFT_MAX` +
a Prometheus speculative-acceptance ratio) **and** vLLM equivalents
(`GPU_MEMORY_UTILIZATION`, `MAX_NUM_SEQS`, `MAX_NUM_BATCHED_TOKENS`,
`KV_CACHE_DTYPE`, `TENSOR/PIPELINE/DATA_PARALLEL_SIZE`,
`ENABLE_PREFIX_CACHING`, `ENABLE_CHUNKED_PREFILL`, `ENFORCE_EAGER`,
`CPU_OFFLOAD_GB`, `SWAP_SPACE`) — speculative decoding is already a
first-class concept here, a head start on §8's requirement.

**Verified drift already present, worth fixing while touching this file:**
the doc's llama.cpp field name `LLAMA_ARG_DRAFT_MAX` does not match the
actually-running deployment's real env var, `LLAMA_ARG_SPEC_DRAFT_N_MAX`
(confirmed via `docker inspect llamacpp`, primary plan §2.2). Minor, but a
concrete instance of "verify against the live system, not the doc" that
should be corrected as part of this plan's edits to this file, not left as
technical debt.

### 2.6 GPU telemetry mechanism (`backend/core/gpu_telemetry.py`)

Real, tested, already backend-independent (sits outside the inference
framework entirely, matching the task's own requirement) — nothing to design
here, just confirm it keeps working (§6).

---

## 3. Dashboard Architecture (target state after this plan)

```
                    vLLM-Management-Portal (unchanged container topology)
  ┌──────────────────────────────────────────────────────────────────┐
  │  INFERENCE_BACKEND=vllm            (was: llama_cpp)               │
  │  INFERENCE_BASE_URL=http://host.docker.internal:8080              │
  │       (was: :8080 pointing at llama.cpp — same port, new backend, │
  │        see primary plan §3.1 for the cutover timing)              │
  │  MODEL_CACHE_PATH=/host/model-cache  -> bind-mount now points at  │
  │       /var/lib/radiance-vllm/hf-cache (was /var/lib/llamacpp/     │
  │       models) — see primary plan §13                              │
  │                                                                    │
  │  runtime_discovery.py: vLLM branch (already exists) — extend      │
  │  model_cache.py: HF-snapshot cache discovery (already exists)     │
  │  gpu_telemetry.py: UNCHANGED — already backend-independent        │
  │  vllm_lifecycle.py: UNCHANGED — stays safety-disabled (§2.3)      │
  └──────────────────────────────────────────────────────────────────┘
```

Only three `.env` values change (`INFERENCE_BACKEND`, and the mount source for
`MODEL_CACHE_PATH` per the primary plan's storage relocation) plus the
`docker-socket-proxy`/`docker` bind-mounts stay as-is (still needed for the
read-only `status()`/`ps` path, §2.3) — this is intentionally a small,
low-risk change given how much of the backend-aware plumbing already exists
and was already live-validated once.

---

## 4. llama.cpp-Specific Assumptions To Retire (in dashboard docs/UI, not delete — relabel)

The task is explicit: do not pretend llama.cpp and vLLM expose identical
concepts. Concretely, these llama.cpp fields have **no direct vLLM
equivalent** and any dashboard UI/doc copy implying a 1:1 mapping must be
corrected, not fudged:

| llama.cpp concept | vLLM reality |
|---|---|
| `LLAMA_ARG_N_GPU_LAYERS` (partial GPU offload) | vLLM has no partial-layer-offload concept — it's all-VRAM-resident or `CPU_OFFLOAD_GB` (a different mechanism, whole-tensor CPU offload, not layer count) |
| GGUF quantization level (`Q4_K_M`, `Q6_K`, etc.) | vLLM's quant is a `quantization_config.quant_method` (AWQ/GPTQ/compressed-tensors/AutoRound/FP8/none) — different taxonomy entirely, not a mapping table between GGUF types and vLLM types |
| `LLAMA_ARG_UBATCH` (micro-batch size) | vLLM's batching is governed by `MAX_NUM_SEQS`/`MAX_NUM_BATCHED_TOKENS` and continuous batching — no direct micro-batch-size analog |
| `LLAMA_ARG_CACHE_TYPE_K/V` (`q8_0`, etc.) | vLLM's `KV_CACHE_DTYPE` (`fp8`, `auto`, etc.) — different value space, different underlying mechanism, and (per primary plan §7.2) different maturity level on gfx1201 |
| `LLAMA_ARG_SPEC_TYPE=draft-mtp` (self-speculative MTP baked into the model) | vLLM's speculative-decoding config (`ngram`/`eagle`/`mtp`/`dflash`/etc., primary plan §8.2) — may or may not be the same underlying mechanism even when both say "MTP"; do not assume equivalence without verification |
| `LLAMA_ARG_CACHE_REUSE`/`LLAMA_ARG_CACHE_PROMPT` (prompt caching) | vLLM's `ENABLE_PREFIX_CACHING` — closer conceptually but still a different implementation (radix-tree prefix cache vs. llama.cpp's reuse heuristic); comparable *effect*, not the same *mechanism* |

**Design decision:** the dashboard's model/runtime-metadata panel should
render backend-appropriate fields conditionally (`if INFERENCE_BACKEND ==
"vllm": show quantization_config.quant_method, kv_cache_dtype, ...`), not a
shared field grid with blank cells for the inapplicable backend — the task
explicitly warns against implying equivalence, and a shared-grid UI with
"N/A" in half the cells does exactly that implicitly.

---

## 5. Radiance/vLLM Metrics To Adopt (verified current names — Sept 2026)

Fetched directly from vLLM's own metrics design docs
(`docs.vllm.ai/en/stable/design/metrics/`), organized by the task's requested
categories:

**Requests running/waiting:**
`vllm:num_requests_running` (gauge), `vllm:num_requests_waiting` (gauge),
`vllm:num_requests_swapped` (gauge, legacy — verify still emitted by the
pinned version)

**KV cache utilization:**
`vllm:kv_cache_usage_perc` (gauge) — **verify this exact name against the
deployed version's actual `/metrics` output before wiring the dashboard to
it**; older blog posts/guides consistently use `gpu_cache_usage_perc`
instead, and metric names have changed release-to-release historically. This
is exactly the kind of "do not hardcode obsolete metric names" risk the task
warns about — resolve by curling the running container's `/metrics` endpoint
directly during implementation, not by trusting this document or any
external doc.

**Prompt/generation token throughput:**
`vllm:prompt_tokens_total` (counter), `vllm:generation_tokens_total` (counter)
— dashboard computes rate (tokens/sec) from these via standard Prometheus
`rate()` semantics, same pattern likely already used for llama.cpp's
analogous counters if any exist there.

**TTFT:** `vllm:time_to_first_token_seconds` (histogram)

**Inter-token latency:** `vllm:inter_token_latency_seconds` (histogram)

**End-to-end request latency:** `vllm:e2e_request_latency_seconds` (histogram)

**Prefill / decode latency:**
`vllm:request_prefill_time_seconds` (histogram),
`vllm:request_decode_time_seconds` (histogram)
(also available: `vllm:request_queue_time_seconds` — scheduler queue wait,
useful for the scheduler-state panel, §9)

**Prefix cache activity:**
`vllm:prefix_cache_queries` (counter), `vllm:prefix_cache_hits` (counter) —
dashboard computes hit rate as `hits/queries`; also
`vllm:kv_block_reuse_gap_seconds` (histogram, prefix-cache-adjacent) if the
pinned version emits it

**Speculative decoding effectiveness:**
`vllm:spec_decode_num_accepted_tokens` (counter),
`vllm:spec_decode_num_draft_tokens` (counter),
`vllm:spec_decode_num_emitted_tokens` (counter),
`vllm:spec_decode_draft_acceptance_rate` (gauge),
`vllm:spec_decode_efficiency` (gauge) — **only meaningful if the primary
plan's Phase 5 (§8.2 of that document) actually adopts speculative decoding**;
if the baseline ships without it, this panel should render "speculative
decoding: disabled" rather than zeroes that look like a broken feature

**Also available (not explicitly requested but low-cost to surface):**
`vllm:request_success_total` (labeled by finish reason — useful for an
error-rate panel), `vllm:cache_config_info` (a labels-only gauge exposing the
running KV-cache config as metric labels — a clean source for the
model/runtime metadata panel, §9), `vllm:request_prompt_tokens` /
`vllm:request_generation_tokens` (histograms, request-size distribution).

**Implementation task:** write a small `backend/core/vllm_metrics.py`
(new file, follows the existing `gpu_telemetry.py`/`runtime_discovery.py`
module-per-concern pattern already used in this codebase) that scrapes
`/metrics`, parses the Prometheus text format (a `prometheus_client` parser
or a minimal regex-based one — check what dependency the repo already has
before adding a new one), and exposes a typed summary the frontend consumes —
mirroring the shape `gpu_telemetry.py` already uses for GPU data (never
substitute 0 for missing/unavailable data, return `None` — same convention,
verified in that module).

---

## 6. AMD GPU Telemetry (unchanged, verified backend-independent)

`gpu_telemetry.py`'s `AMDGPUProvider` prefers `amd-smi static/metric/process
--json` (parsing `mem_usage.{total,used,free}_vram`,
`usage.gfx_activity`/`umc_activity`, `temperature.edge`,
`power.socket_power`, clocks, `asic.market_name`, per-PID VRAM via process
matching), falling back to `rocm-smi
--showdriverversion --showproductname --showmeminfo vram --showuse --showtemp
--showpower --showclocks --showuniqueid --json` if `amd-smi` is unavailable or
errors. This already satisfies the task's requirement to keep GPU telemetry
independent from the inference framework — it queries the GPU directly via
ROCm host tooling (mounted read-only from `/opt/rocm-7.2.2`, primary plan §2.3),
not through vLLM or llama.cpp's own APIs at all.

**Design decision:** no changes to this module. The only action item is
**verification**, not modification: confirm `amd-smi`/`rocm-smi` correctly
attribute VRAM/process data to the new `radiance-vllm` container's PID(s)
instead of `llamacpp`'s, since the per-process VRAM matching logic depends on
PID, not container name — this should "just work" given the mechanism is
PID-based and generic, but must be verified live post-cutover, not assumed.

No changes needed to satisfy: GPU utilization, VRAM used/total, temperature,
power, clock rates, GPU health/errors — all already covered, all already
sourced independently of the inference framework.

---

## 7. Backend Detection & Normalization Strategy

`INFERENCE_BACKEND=vllm` in the dashboard's `.env` (currently `llama_cpp`) is
the single switch (§2.1, §3) — already wired to branch `runtime_discovery.py`
and `model_cache.py` correctly per the existing codebase's design. This plan's
implementation work here is:

1. Flip the env var at the same time as the primary plan's cutover (§14 of
   this document ties this to that timing) — not before (the dashboard
   pointed at a `vllm` backend URL that's actually still serving llama.cpp,
   or vice versa, would misreport everything).
2. Extend (not replace) the existing vLLM branch with the metrics module
   (§5) and the KV-cache-dtype/quant-method/attention-backend/spec-decoding
   fields the model/runtime metadata panel needs (§9) — the branch point
   already exists, this is filling in what was stubbed or partial per
   `IMPLEMENTATION_STATUS.md`.
3. Explicit non-equivalence table (§4) becomes both code (conditional field
   rendering) and documentation (`docs/metrics.md` update, correcting the
   `LLAMA_ARG_DRAFT_MAX` drift noted in §2.5 while there).

**Open question:** whether `INFERENCE_BACKEND` needs to become a *live*
per-request-detected value (auto-probe which backend is actually running) or
remains operator-set in `.env` as it is today. Given the primary plan's staged
cutover (staging port 8081 running vLLM while 8080 still runs llama.cpp,
primary plan §3.1), there's a real window where *both* backends are live
simultaneously on different ports — the current single-`INFERENCE_BASE_URL`/
single-`INFERENCE_BACKEND` design can only monitor one at a time. Resolve at
implementation time: either accept the dashboard only monitors the production
port during staging (simplest, matches current single-instance design, just
means the dashboard doesn't show staging-port health during Phase 1–3 of the
primary plan — acceptable, since `curl`/the primary plan's own validation
scripts cover that window) or extend the dashboard to monitor multiple
endpoints (bigger change, likely out of scope for this migration).

---

## 8. Metrics Collection Implementation Tasks

- New `backend/core/vllm_metrics.py` (§5) — Prometheus scrape + parse
- Extend `backend/core/model_cache.py`'s existing vLLM branch to also surface
  `quantization_config.quant_method` (read from the cached checkpoint's
  `config.json`, same "never infer from the repo name" discipline the primary
  plan's model-selection work already established, §6.3 of that document)
- Extend `backend/core/runtime_discovery.py`'s vLLM branch to capture: served
  model name, `max_model_len`, effective attention backend (from startup log
  parsing — vLLM logs which backend it selected, useful given primary plan
  §8.1's requirement to confirm `TRITON_ATTN` was actually selected, not
  silently something else), `gpu_memory_utilization`, prefix-caching
  enabled/disabled, speculative-decoding method (if any)
- `backend/api/v1` route(s): confirm/extend whatever the existing vLLM-branch
  routes return to include the above — check current schema in
  `backend/api/schemas.py` before adding new fields, extend rather than
  duplicate
- Database: check whether `vllm_portal.db`'s schema needs a migration for any
  new persisted fields (e.g. historical metrics for trend charts) —
  `backend/migrations/` exists in the repo; if new columns are needed, add a
  migration following whatever pattern the existing migrations use (not
  inspected in detail during research — **open question**, verify the
  migration pattern at implementation time before writing raw SQL)

---

## 9. Model/Runtime Metadata Panel (target field set for vLLM backend)

Per the task's explicit list, rendered only when `INFERENCE_BACKEND=vllm`
(§4's conditional-rendering design decision):

- Model (served name, e.g. `scar-coder` — plus, expandable/secondary, the
  actual underlying `MODEL_ID` for operators who need it)
- Quantization format (`quantization_config.quant_method`, from `config.json`)
- KV cache dtype (`kv_cache_dtype` — `auto`/`fp8`/etc., from `cache_config_info`
  metric labels or startup-log parsing)
- Maximum model length (`max_model_len`)
- Attention backend (effective, from startup log — see §8)
- GPU memory utilization (`gpu_memory_utilization`, both nominal config value
  and, if obtainable, the real measured VRAM usage per §6's GPU telemetry —
  showing both side by side directly surfaces the primary plan's §7.3 finding
  that real usage runs over nominal)
- Prefix caching (enabled/disabled)
- Speculative decoding (method, or "disabled" — not a blank field, per §5's
  note)
- Scheduler state (`num_requests_running`/`num_requests_waiting` from §5's
  metrics)
- KV cache utilization (`kv_cache_usage_perc`-or-whatever-it's-actually-called,
  §5)
- Request state (in-flight request count/status, derivable from the running/
  waiting gauges plus `request_success_total` by finish reason)

---

## 10. Visualization

`frontend/app.js`/`index.html` changes needed (implementation-level detail,
not fully specified here — the existing frontend structure should be
inspected directly at implementation time rather than guessed at from this
research pass):

- Backend-conditional panel rendering (§4, §9) — the frontend needs to know
  which backend is active (already exposed via the existing
  `INFERENCE_BACKEND`-aware backend API, per §2.1/§7) and choose which field
  set to render, not show a shared grid with blanks
- New panels/charts for: request running/waiting over time, KV cache
  utilization over time, TTFT/ITL/e2e-latency distributions (histograms —
  likely a percentile or sparkline rendering, matching whatever charting
  approach `app.js` already uses elsewhere in the dashboard, not a new
  charting library introduced just for this)
- Prefix-cache hit-rate indicator
- Speculative-decoding acceptance-rate panel, explicitly hidden/labeled
  "disabled" rather than shown as zero when not in use (§5)
- GPU telemetry panels: **unchanged** (§6 — already backend-independent, no
  visualization work needed here beyond confirming the running container's
  process is correctly attributed post-cutover)

---

## 11. Health/Status Reporting

Backend-aware health source, already partially implemented per §2.2:
- vLLM: `/health` + `/v1/models` (+ `/metrics` reachability as a secondary
  signal)
- llama.cpp: `/health` + `/v1/models` + `/props`

No new design needed here — confirm the existing vLLM branch's health check
logic actually gets exercised (it may have been written but only tested
during the Aug 2026 live-vLLM window, then left dormant while llama.cpp ran) —
this is a verification task (§20), not a design task.

---

## 12. OpenCode Validation Plan

Reuses `Containerized-VLLM-AMD-R9700/scripts/configure-opencode.sh`
(primary plan §11.1 already scopes porting this script) — that script already
installs global rules at `<config_dir>/AGENTS.md` inside managed markers, a
compaction-recovery plugin, and merges provider config via `jq` with
timestamped backups and a `--remove` rollback path. Update it for this
migration's specifics:

- Provider entry: rename/repoint the existing stale `scar-vllm` entry
  (currently `baseURL: http://10.1.10.10:8000/v1`, primary plan §2.5) to
  `http://10.1.10.10:8080/v1` (post-cutover) and model key `scar-coder`
  (stable name, primary plan §14) instead of `qwen3-coder-30b-a3b`
- Re-run once, at cutover time (primary plan §3.1 Phase 4) — not before,
  since the staging deployment on 8081 shouldn't be what OpenCode's primary
  config points at
- Validation tasks to run through OpenCode against the live deployment (task
  requirement — benchmarking alone is not sufficient):
  - repository exploration (open this very repo or another real one, ask it
    to summarize structure)
  - large context injection (paste a large file or several files worth of
    context into a session)
  - code generation (write a new small script/function)
  - code modification (edit an existing file via the agent)
  - tool calls (the above naturally exercise this; also explicitly test a
    multi-step tool-call chain — e.g. read a file, then edit it, then run a
    shell command to verify)
  - shell/tool output handling (a command producing substantial output,
    confirm it's handled without truncation issues beyond OpenCode's own
    configured `tool_output.max_lines`/`max_bytes` — verified present in
    raptor.lab's actual `opencode.json`, 300 lines / 16384 bytes)
  - multiple turns, repeated prompts (prefix-caching effectiveness —
    cross-reference with the KV/prefix-cache metrics panel, §9, during the
    session to confirm cache hits actually occur)
  - long conversations (exercise OpenCode's own `compaction.auto`/`prune`
    settings, verified present in the live config)
  - streaming (default OpenCode behavior — confirm visually/via network
    inspection that tokens stream, not buffer-then-dump)

---

## 13. PI Validation Plan

PI's config (`~/.pi/agent/models.json` on raptor.lab, verified simpler than
OpenCode's — single provider, `local-lab-llama`, `api: "openai-completions"`,
`compat.maxTokensField: "max_tokens"`) has **no existing configurator script**
in the abandoned vLLM repo (that repo only shipped `configure-opencode.sh`).
`Agentic-Tooling-Local-Lab/scripts/configurators/pi.sh` exists but targets the
Agentic-Tooling-Local-Lab's own generic multi-tool setup flow, not this repo's
specific profile-driven config — **implementation task:** write
`scripts/configure-pi.sh` in this repo (primary plan §11.1 already scopes this
as new work, not a port), following the same jq-merge-with-backup pattern as
`configure-opencode.sh` for consistency.

Update: provider's model id from the raw GGUF path
(`/models/Qwen3.8-27B-Q5_K_M.gguf`) to `scar-coder`; `baseUrl` stays
`http://10.1.10.10:8080/v1` (unchanged post-cutover, per primary plan's
endpoint-preservation design). `contextWindow`/`maxTokens` fields should be
updated to reflect the new deployment's actual `MAX_MODEL_LEN` (131072) and
output budget, not left at the old llama.cpp profile's values (131072/8192 —
may coincidentally already match, verify rather than assume).

Run the same real-workflow validation list as §12 through PI once
reconfigured.

---

## 14. Optional Hermes Validation (non-blocking)

Per the task's explicit instruction, Hermes is not part of the critical
OpenCode/PI path and must not gate this migration. Verified (primary plan
§2.6): Hermes talks directly to `http://127.0.0.1:8080/v1` and
auto-detects the served model from `/v1/models` — no hardcoded model id to
update. **Validation task (non-blocking, best-effort):** after cutover,
confirm Hermes still functions — a simple chat exchange is sufficient — and
note whether its auto-detected model label updates to `scar-coder`
automatically (expected) or requires a Hermes-side restart to pick up the
change (unverified — Hermes may cache the detected model at its own startup;
check `hermes config` docs/behavior if this doesn't self-resolve). If Hermes
breaks post-cutover, document it and move on — it does not block sign-off on
this migration per the task's explicit scoping.

---

## 15. MemPalace Dependency Check (already resolved — documented here for completeness)

**Confirmed negative, with evidence** (primary plan §2.6, verified during
research): the Hermes `mempalace-remote` plugin
(`~/Workspace/Git/Containerized-Hermes-AI-llama.ccp-connector/plugins/mempalace-remote/`)
talks exclusively to MemPalace's own MCP server (`:8765/mcp`) via the `mcp`
SDK's `streamablehttp_client`/`ClientSession` — `mempalace_search`,
`mempalace_check_duplicate`, `mempalace_add_drawer`, `mempalace_diary_write`.
Nothing in the plugin, its `README.md`, or `plugin.yaml` references llama.cpp,
port 8080, or any inference-server call for embeddings — MemPalace appears to
handle its own embeddings as an independent service. The
Agentic-Tooling-Local-Lab repo's own architecture notes make the same
separation explicit: *"MemPalace is a parallel MCP memory service, not an
inference proxy."`

**No MemPalace changes are in scope for this migration.** No MemPalace skill
is created as part of this work, per the task's explicit instruction. This
section exists only to document that the check was performed and what it
found — not as a to-do list.

---

## 16. Real Agentic Coding Tests (consolidated checklist)

Superset of §12/§13's per-tool lists, run at least once each through both
OpenCode and PI post-cutover, cross-referenced against the dashboard's new
metrics panels (§9) while running so the metrics themselves get validated
against real traffic, not synthetic curl calls:

- [ ] Repository exploration
- [ ] Large context injection
- [ ] Code generation
- [ ] Code modification
- [ ] Tool calls (single, sequential, multiple-in-one-turn)
- [ ] Shell/tool output handling
- [ ] Multiple turns within one session
- [ ] Repeated prompts (prefix caching — confirm via dashboard's prefix-cache
      hit-rate panel, §5/§9/§10, that cache hits are actually occurring, not
      just that the session "feels" faster)
- [ ] Long conversations (compaction behavior)
- [ ] Streaming (both tools' default behavior)

---

## 17. Performance Comparisons

Compare the primary plan's benchmark results (its §21) against:
- llama.cpp's already-recorded baseline reports at
  `Containerized-llamma.ccp-AMD-9700/performance/reports/llamacpp__qwen3.8-27b-*`
  (multiple quant levels already benchmarked: Q4_K_M, Q5_K_M, UD-Q6_K — the
  currently-running config)
- The dashboard's own historical metrics (if the DB migration in §8 adds
  time-series storage) for a live, ongoing comparison view rather than a
  one-time report

This is presentation/comparison work built on top of the primary plan's raw
benchmark data (its §21) — no new benchmarking methodology needed here, just
surfacing the comparison in the dashboard (a new "vLLM vs llama.cpp" summary
view is a reasonable implementation task, not specified in further detail
here since it depends on what the DB migration in §8 ends up supporting).

---

## 18. Acceptance Criteria

Per the task's own integration/observability criteria, restated against this
plan's specifics:

- Dashboard correctly reports `INFERENCE_BACKEND=vllm` state — model name,
  quantization, KV dtype, max model length, attention backend, GPU memory
  utilization (nominal and real), prefix caching state, speculative-decoding
  state — with no llama.cpp-only fields shown as blank/N/A (§4, §9)
- GPU telemetry remains available and correctly attributed to the new
  container's process (§6)
- vLLM request/KV/performance metrics visible in the dashboard, using
  metric names verified against the actually-deployed `/metrics` output
  (§5 — not copied blindly from this document or any external doc)
- OpenCode completes the full real-workflow checklist (§12/§16)
- PI completes the full real-workflow checklist (§13/§16)
- Endpoint changes minimized: URL unchanged (`scar.lab:8080/v1`), only the
  served-model-name and one-time client reconfiguration occurred (§12/§13,
  tied to primary plan §14)
- Model naming stable and intentional (`scar-coder`, primary plan §14)
- Tool calls work reliably through both OpenCode and PI (§12/§13/§16,
  building on primary plan §20's raw API-level validation)
- Long-context requests stable through real client sessions, not just
  synthetic API calls (§16)
- Rollback documented (primary plan §19) **and** this plan's client-config
  reversion step is explicitly included in that rollback checklist (§12 —
  a completed OpenCode/PI reconfiguration needs a matching revert step,
  tracked, not assumed automatic)

---

## 19. Known Risks

1. **Dashboard's vLLM branch was last live-tested in August 2026, before a
   ~5-week dormancy while llama.cpp ran** (§2.1) — code that hasn't executed
   against a real backend in weeks may have silently bit-rotted (dependency
   version drift, an API response shape change in the vLLM version now
   targeted vs. the one tested against then). Treat as needing re-verification,
   not as already-proven-working.
2. **Dead code in `capabilities.py`** (§2.4) could mislead a future
   implementer into wiring against the unsafe stubbed lifecycle methods
   instead of the real, safety-gated ones in `vllm_lifecycle.py` — flagged
   explicitly, cleanup recommended.
3. **Metric name drift risk** (§5, `kv_cache_usage_perc` vs
   `gpu_cache_usage_perc` and similar) — must be verified against the actual
   deployed version's `/metrics` output, not hardcoded from any document
   including this one.
4. **Single-endpoint monitoring design vs. the primary plan's dual-port
   staging window** (§7 open question) — the dashboard cannot currently watch
   both the staging (8081) and production (8080, still-llama.cpp-until-cutover)
   endpoints simultaneously; acceptable gap during Phase 1–3, but should be
   stated explicitly rather than silently leaving staging unmonitored.
5. **Hermes's model-detection caching behavior post-cutover is unverified**
   (§14) — non-blocking, but should be checked, not assumed to self-resolve.
6. **DB migration path for any new persisted metrics fields is unverified**
   (§8) — `backend/migrations/` exists but its pattern wasn't inspected in
   detail; resolve before writing raw schema changes.

---

## 20. Open Questions

1. **Exact current vLLM `/metrics` field names for this specific deployment's
   pinned vLLM version** (§5) — resolve by curling the live `/metrics`
   endpoint during implementation, not by trusting this document.
2. **Whether the dashboard should be extended to monitor dual endpoints
   during the primary plan's staging window, or accept the monitoring gap**
   (§7) — resolve based on how much staging-phase observability is actually
   needed versus the primary plan's own script-level validation covering that
   window adequately already.
3. **`backend/migrations/` pattern** (§8) — inspect directly before adding any
   schema changes.
4. **Hermes model-label refresh behavior** (§14, §19 item 5) — verify live,
   don't assume.
5. **Whether a "vLLM vs llama.cpp" historical comparison view (§17) is worth
   building now versus deferred** — not required by the task's acceptance
   criteria explicitly; treat as a nice-to-have unless the user wants it
   prioritized.
