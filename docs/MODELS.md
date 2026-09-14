# Model selection notes

## Qwen3.8-27B (primary target)

Real model, `Qwen/Qwen3.8-27B` (HF, Apache 2.0, released Aug 2026).
Architecture: `Qwen3_5ForConditionalGeneration` -- a vision-language model
(has a ViT vision tower) whose language backbone is 64 layers: 48
Gated-DeltaNet (linear attention) + 16 Gated Attention (full attention),
hidden dim 5120, native context 262144. Same model family already running
in production via llama.cpp on this host
(`unsloth/Qwen3.8-27B-GGUF`/`Qwen3.8-27B-UD-Q6_K.gguf`).

`--language-model-only` is required to skip the vision tower for this
text/coding-only deployment.

## Phase 0 architecture smoke test -- result (2026-09-14)

**Verdict: architecture compatibility CONFIRMED. VRAM budget, as expected,
was not sufficient for FP8 at any real context -- this was known going in
(see the decision tree above) and does not block the real deployment.**

- Image: `magiccodingman/vllm-radiance@sha256:83a9dc02a8f8e75...` (see VERSIONS)
- Checkpoint: `Qwen/Qwen3.8-27B-FP8` (upstream's own stated tuning target)
- Architecture resolution: **confirmed** -- vLLM 0.28.0 logged
  `Resolved architecture: Qwen3_5ForConditionalGeneration` without error.
  This directly resolves the plan's §6.2 top risk (hybrid-architecture
  compatibility) in the affirmative for this vLLM/image combination.
- Text-only mode: **confirmed** -- `--language-model-only` correctly
  disabled all multimodal limits ("running in text-only mode"), vision
  tower skipped.
- R4D engagement: `gdn_chunk_scan ENABLED (head_k 128, head_v 128, chunk
  64)` confirmed live for the 48 Gated-DeltaNet layers. Full attention (16
  layers) resolved to `ROCM_AITER_UNIFIED_ATTN` (AITER's unified attention,
  not a distinct "R4D" backend name in vLLM's own backend enum -- R4D
  appears to patch attention modules in-place rather than register as a
  separate selectable backend; see the `[radiance] attn tuned-config
  override installed on 2 module aliases` log line). Whether this counts
  as "R4D engaged" for the full-attention layers specifically is not
  fully disambiguated from logs alone -- revisit if precise attribution
  matters later.
- FP8 KV cache: kernel path confirmed real (`Selected
  TritonFp8BlockScaledMMKernel for Fp8LinearMethod`), not a silent
  fallback. Checkpoint lacks calibrated q/k/v scaling factors
  (`Using KV cache scaling factor 1.0 for fp8_e4m3` /
  `uncalibrated q_scale 1.0` warnings) -- flagged as a real accuracy risk
  to revisit if FP8 KV cache is used on the real INT4 deployment too.
- DFlash2: armed by default (`RADIANCE_DYNAMIC_DRAFT=ON`, tau=0.28,
  schedule=1:8,2:7,4:6,8:5,16:4), no extra flags needed to activate.
- Weight loading: 27.64 GiB, 20.84s (after download). torch.compile:
  120.89s total, single compile range (1,2048), 51 CUDA graph capture
  sizes, artifacts cached to `/root/.cache/vllm/torch_compile_cache` for
  faster subsequent starts.
- **Failure point: CUDA OOM during final KV-cache tensor allocation**,
  even at `MAX_MODEL_LEN=4096` and `GPU_MEMORY_UTILIZATION=0.90`:
  `Tried to allocate 800.00 MiB. GPU has 31.86 GiB total, 472.00 MiB
  free, 30.10 GiB already allocated by PyTorch.` Confirms the plan's
  prediction exactly: FP8 weights (~28GiB real, matching the 30.89GiB
  on-disk estimate) leave essentially no room for KV cache + activation
  overhead on a 32GB card, regardless of how small the context is pushed.
  This is a VRAM-budget failure, not an architecture/compatibility
  failure -- the engine got all the way through weight load, compile, and
  graph capture before hitting it.
- Generation quality/correctness: not reached (OOM occurred before the
  server became ready for requests). Will be validated on the real INT4
  deployment instead (`config/models/qwen38-27b.env`).
- Container was stopped and removed after the OOM (it would otherwise
  loop crash-restart under `restart:unless-stopped`, repeatedly
  re-downloading/reloading the 28GB checkpoint for no benefit).
  `config/models/qwen38-27b-smoketest.env` is kept in the repo for
  reference/reproducibility but is not part of the deployed profile set.

## Phase 1 real deployment -- result (2026-09-14)

**VALIDATED AND WORKING END TO END.** `config/models/qwen38-27b.env`
(`RedHatAI/Qwen3.8-27B-INT4`) deployed successfully with the full
task-spec target: 131072 context, `GPU_MEMORY_UTILIZATION=0.968`,
`KV_CACHE_DTYPE=fp8`, R4D + DFlash2 active, served as `scar-coder`.

- **First attempt failed** with `ValueError: max_num_seqs (256) exceeds
  available Mamba cache blocks (194)` -- a real, fixable concurrency-vs-
  Mamba-cache-budget constraint of the hybrid architecture, not an
  architecture-compat or OOM failure. Fixed by adding `--max-num-seqs 32`
  to `EXTRA_VLLM_ARGS` (appropriate for this deployment's stated
  single-user-interactive priority, well under the 194 ceiling). See
  `config/models/qwen38-27b.env`'s `EXTRA_VLLM_ARGS` comment for the
  full explanation.
- **Second attempt succeeded completely:**
  - Weight load: 9.57s (warm disk cache)
  - torch.compile: 1.16s (warm AOT cache -- 85s on a cold cache)
  - `RDNAHybridW4A16LinearKernel for CompressedTensorsWNA16` -- confirms
    this image has dedicated RDNA-optimized kernels for this INT4 format,
    not a generic/unsupported fallback.
  - **GPU KV cache size: 302,359 tokens -- 2.31x concurrency at the full
    131,072-token context target.**
  - Real VRAM usage: 30.75GiB / 31.86GiB (**1.11GiB headroom** at
    GPU_MEMORY_UTILIZATION=0.968 -- right at the task's ~1GB target, no
    further tuning needed for the initial deployment).
- **Full validation suite passed** (`scripts/validate-model.sh`):
  VRAM postflight, known-answer arithmetic + code-completion fixtures,
  tool-call determinism across 4 trials including a full container
  restart.
- **All 6 tool-calling scenarios passed** (`scripts/test-tool-calling.sh`):
  single call, call with arguments, sequential calls, multiple calls in
  one turn, call-then-normal-response, streaming tool calls.
- **Real generation verified manually**: correct, well-formed Python
  code (proper edge-case handling) for a code-generation prompt;
  coherent on-topic reasoning content when thinking mode is left on
  (confirms `--reasoning-parser qwen3` extracts `<think>` content
  correctly into the `reasoning` field, separate from `content`).
- **Streaming verified**: token-by-token SSE chunks confirmed for
  `/v1/chat/completions` with `stream:true`.
- **`/metrics` verified live**: `vllm:kv_cache_usage_perc` is the
  current correct metric name for this vLLM version (not
  `gpu_cache_usage_perc` -- resolves an open question from
  `plan-radiance-observability.md`).
- State recorded: `/var/lib/radiance-vllm/state/current-profile` =
  `qwen38-27b`.

**Not yet done as of this entry:** DFlash2's strict output-equivalence
gate (plan §8.2) has not been run as a dedicated test -- it's armed and
active, and nothing observed in generation/tool-calling testing suggests
a problem, but a dedicated correctness comparison (with vs. without
speculative decoding) hasn't been performed. R4D's precise engagement
status for the 16 full-attention layers (vs. just the 48 GDN layers) is
still not disambiguated from logs alone. Benchmark numbers (TTFT,
tokens/sec) vs. the llama.cpp baseline have not yet been collected.
Cutover to port 8080 has not yet happened -- this validated deployment
is still on staging port 8081.

## Quantization bake-off (plan §6.3)

Researched 2026-09-14 -- checkpoint's own `config.json` `quant_method`
verified directly for every candidate below (never inferred from repo
name -- this exact lesson is written down for a sibling model in the
abandoned `Containerized-VLLM-AMD-R9700` repo's `qwen36-27b.env`).

### Avoid

- `amd/Qwen3.8-27B-Quark-AWQ-MXFP4` -- `quant_method: "quark"`. This exact
  format crashed vLLM's loader for a sibling Qwen3.6-27B checkpoint on an
  older vLLM build (`AttributeError: 'dict' object has no attribute
  'startswith'` in `quark.py`). vllm-radiance's vLLM 0.28.0 is materially
  newer, so this MAY be worth retrying later, but do not default to it.

### Real, viable INT4 candidates (compressed-tensors / native formats, ~19-21GB)

| Repo | quant_method | Size | Notes |
|---|---|---|---|
| `RedHatAI/Qwen3.8-27B-INT4` | compressed-tensors, pack-quantized, sym int4 g128 | 19.47GB | **Primary candidate.** Red Hat AI/Neural Magic pedigree; README states FP8 KV cache support. |
| `dbirks/Qwen3.8-27B-W4A16-AutoRound` | compressed-tensors (despite the name) | 19.47GB | Same underlying recipe as above. Second choice. |
| `Vishva007/Qwen3.8-27B-W4A16-AutoRound` | native `auto-round` | 20.04GB | Verify vLLM's AutoRound loader support before using. |
| `Vishva007/Qwen3.8-27B-W4A16-AutoRound-GPTQ` | gptq (AutoRound-exported) | 20.05GB | |
| `cyankiwi/Qwen3.8-27B-AWQ-INT4` | compressed-tensors, true asymmetric AWQ | 21.04GB | Calibrated on a "STEM and Agentic" dataset. |
| `nicosuter/Qwen3.8-27B-AWQ` | compressed-tensors, true AWQ | 21.57GB | Most rigorously documented calibration. |

None of these disclose AMD/ROCm/R9700 testing on their model cards --
this repo is the first to validate any of them on gfx1201.

### FP8 (too large for this deployment's VRAM budget, kept for reference)

- `Qwen/Qwen3.8-27B-FP8` (official Qwen release, 30.89GB, data-free) --
  used for the Phase 0 architecture smoke test only, not the real
  deployment (leaves ~1GB for KV cache+overhead on a 32GB card).

## Tool-call parser

Resolved via `Qwen/Qwen3.8-27B`'s own `tokenizer_config.json`
`chat_template` (fetched directly): XML-style tool calls
(`<tool_call><function=name><parameter=x>value</parameter></function></tool_call>`),
**not** Hermes-style bare JSON. Use `--tool-call-parser qwen3_xml`.

## Reasoning parser

`qwen3` -- verified current name for the whole Qwen3 family in vLLM.
