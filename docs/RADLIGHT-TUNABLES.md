# Radlight tunables: comparison, classification, rationale

Living document for the `radlight` stack (`compose.radlight.yaml`,
`config/models/qwen38-27b-radlight*.env`). Companion to `docs/TUNING.md`
(the Radiance-baseline stack) -- do not merge the two, they describe
independently-pinned stacks with different vLLM/ROCm major versions and
different patch anchors (see `VERSIONS` and the "Critical compatibility
rule" in the integration plan).

## Licensing

Radlight (`https://codeberg.org/hifi/vllm-radlight`, pinned commit
`f93de10c3d47782edd9ec7a0a69afb0974c5fc63`) and both its submodules
(`libr4d` at `b9e42ab7202f53a3bc13d415f5d41481f9ca311b`,
`radiance-vllm-mxfp4` at `037e7fc558038fb73fc7fee1fae504026ffc5087`) carry
**no top-level LICENSE or COPYING file**, verified 2026-09-21 by directory
listing at these exact pinned commits (`scripts/sync-radlight.sh` re-checks
this on every sync and warns if that ever changes). Its own README states
"This repository doesn't contain any original work outside the
arrangement" -- i.e. it positions itself as glue/configuration over
upstream AMD/vLLM/community work, not an independently-licensed body of
code.

Consequences for this integration:

- Radlight is **never vendored or copied into this Git repository**.
  `scripts/sync-radlight.sh` clones it to a dedicated host path
  (`/var/lib/radiance-vllm/upstream/vllm-radlight`, outside any Git
  working tree) and pins it by exact commit hash.
- The running container mounts that checkout **read-only** at `/opt/repo`
  -- the same posture Radlight's own `run.sh` uses (`-v ".:/opt/repo:ro"`),
  so nothing about this changes Radlight's own intended usage.
- No claim is made here about what license, if any, actually governs reuse
  of Radlight's own patch/glue code -- this document records the absence
  of a stated license, it does not resolve it. Treat the acquisition as
  "run it from where it lives, pinned," not "incorporate it."

## Base image

| | Radiance baseline (`compose.yaml`) | Radlight (`compose.radlight.yaml`) |
|---|---|---|
| Image | `magiccodingman/vllm-radiance` | `docker.io/rocm/vllm` (AMD's own build) |
| Tag | `1.0.16` | `rocm10.0.0_ubuntu24.04_py3.14_pytorch_2.12.0_vllm_0.27.0` |
| Digest | `sha256:83a9dc02a8f8e75aabe81366d36ebaa2e35fcbe181cacf8e8e0a4cef4ebccbcc` | `sha256:b8a082f346d069376d35784250e38b23a043efe979408ae3a33d7c6b62ee3276` |
| vLLM | 0.28.0 | 0.27.0 |
| ROCm (in-container) | 7.14.0 | 10.0.0 |
| Patch mechanism | Pre-built into the image | Applied on-the-fly at container start (`entrypoint/init.sh`), cached per submodule commit under `/cache` |
| Build step | None (pull and run) | None for the image itself; native kernels (`r4d.so`, `radiance_mxfp4_fp8.so`) compile on first start (a few minutes each), cached thereafter |

Digest resolved via `docker manifest inspect --verbose` (linux/amd64),
2026-09-21 -- immutable, not the floating tag alone.

## Model checkpoints

| | Value | Source of pin |
|---|---|---|
| Target | `amd/Qwen3.8-27B-Quark-AWQ-MXFP4` @ `5233554c5fa56afda40150556b95573c2d7d29c0` | HF Hub API `sha`, resolved 2026-09-21 |
| Drafter (DFlash2) | `tcclaviger/Qwen3.8-27B-DFlash2-FP8` @ `ee0cb26a8279b7910cc28d82a8a3e15e4728d56f` | HF Hub API `sha`, resolved 2026-09-21 |
| Tokenizer/chat-template (vendor) | bundled in the target repo at the same revision | n/a -- same repo |
| Reference only (not deployed) | `Qwen/Qwen3.8-27B` @ `1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0` | HF Hub API `sha` |

`scripts/sync-radlight-models.sh` downloads these into plain local
directories (not the HF hub blob-cache layout) and verifies every file by
LFS sha256 (large files) or git-blob sha1 (small files) after download --
never trusts a partial or previously-cached file by size alone across a
revision change.

**Re-verification note (task requirement):** `docs/MODELS.md` already
flags this exact `quant_method: "quark"` format as "Avoid" for the
Radiance-baseline stack, based on a loader crash
(`AttributeError: 'dict' object has no attribute 'startswith'` in
`quark.py`) on an **older vLLM build** against a **different (Qwen3.6-27B)
checkpoint**. That finding does not carry over to this pinned vLLM
0.27/ROCm 10 stack, which additionally applies Radlight's own
`patch_quark_mxfp4` source patch specifically for this format. Re-verified
independently here (see "Correctness" gates in the canary runbook) rather
than assumed fixed.

The AMD checkpoint has had community-reported MTP-head metadata and
uncalibrated-FP8-KV-scale concerns (the same class of issue
`docs/MODELS.md`/`docs/TUNING.md` already documented for the
Radiance-baseline INT4 checkpoint: KV scale factors defaulting to 1.0
absent calibration). Radlight's `patch_mtp_mm_mask`/`patch_mtp_loopbreak`
patches and its use of an external DFlash2 drafter (rather than an
MTP head baked into the target checkpoint) may address or sidestep
portions of this, but that is a claim about patch *intent*, not a
verified property of this exact pinned stack -- confirm via the
known-answer/tool-call/DFlash2-equivalence gates before trusting it, not
by assumption.

## Compilation config (used verbatim for the parity profile)

```json
{"cudagraph_capture_sizes":[1,2,4,8,16],"pass_config":{"fuse_norm_quant":true,"fuse_act_quant":true}}
```

## Environment variable classification

Every variable in Radlight's own `run.sh`, classified. "Scope" follows the
task's own taxonomy (image, host, GPU, model, KV, scheduler, speculative
decoding, parser, cache, compilation, security, observability).

### Required and adopted (carried into `compose.radlight.yaml` verbatim)

| Variable | Value | Scope | Rationale |
|---|---|---|---|
| `HIP_VISIBLE_DEVICES` | `0` | GPU | Single-GPU host; matches the baseline stack's own convention |
| `GPU_MAX_HW_QUEUES` | `1` | GPU | Radlight's own queue-depth tuning for gfx1201; no evidence yet this host needs otherwise |
| `HSA_ENABLE_INTERRUPT` | `1` | GPU | Interrupt-driven GPU signaling vs. polling; Radlight default |
| `HSA_ENABLE_MWAITX` | `1` | GPU | MWAITX CPU wait instruction for HSA signal polling; Radlight default |
| `VLLM_USE_V2_MODEL_RUNNER` | `1` | model | Required by this vLLM 0.27 build's Radlight-targeted code paths |
| `VLLM_ROCM_USE_AITER` | `1` | GPU | AITER kernel library master switch |
| `VLLM_ROCM_USE_AITER_UNIFIED_ATTENTION` | `1` | GPU/model | Selects `ROCM_AITER_UNIFIED_ATTN`, the attention backend this profile also passes explicitly via `--attention-backend` |
| `RADIANCE_MXFP4` | `1` | model/quant | MXFP4 weight routing -- the entire point of this checkpoint/stack pairing |
| `RADIANCE_MXFP4_W4A8` | `1` | model/quant | W4A8 activation quantization path on top of MXFP4 weights |
| `RADIANCE_GDN_MERGE_INPROJ` | `1` | model | Gated-DeltaNet input-projection fusion |
| `RADIANCE_USE_R4D` | `1` | model/kernel | R4D kernel library engagement (same flag family as the baseline stack, different value surface per stack) |
| `RADIANCE_R4D_REPORT` | `1` | observability | Logs which R4D kernels actually loaded -- required evidence for the "kernel and optimization validation" gate |
| `R4D_ATTN_FP8` | `3` | KV/model | FP8 attention legs added on top of the pinned libr4d by Radlight's own `r4d_radiance_extras_rx9.patch` |
| `RADIANCE_GDN_FUSED_UPDATE` | `1` | model | Fused GDN decode step |
| `RADIANCE_GDN_FUSED_MAX_ITEMS` | `48` | model | Matches this model's 48 Gated-DeltaNet layers exactly -- do not change without re-deriving from the checkpoint's own layer count |
| `RADIANCE_FP8_STREAM` / `RADIANCE_FP8_STREAM_TP1` | `1` / `1` | KV | FP8 streaming path; `_TP1` variant since this deployment is `--tensor-parallel-size 1` |
| `RADIANCE_DYNAMIC_WIDTH` | `1` | model | Dynamic-width kernel dispatch |
| `RADIANCE_PRESHUFFLE` | `1` | model | Weight preshuffling for the MXFP4 GEMM path |
| `RADIANCE_FUSE_RMS_QUANT` / `RADIANCE_RMS_QUANT_FUSION` | `1` / `1` | model | RMSNorm + quantization fusion (two related but distinct flags in Radlight's own surface -- kept as two, not assumed redundant) |
| `RADIANCE_SKINNY_GEMM` | `1` | model | Skinny-GEMM path for low-batch (decode-shaped) matmuls |
| `RADIANCE_TOPK_TRITON_MIN_ROWS` | `1` | model | Top-k Triton kernel row threshold |
| `RADIANCE_KV_GROUP_OPT` | `1` | KV | KV-group optimization |
| `RADIANCE_MXFP4_WPERM` | `1` | model/quant | Weight permutation for the MXFP4 kernel layout |
| `RADIANCE_MXFP4_DECODE_NT` | `1` | model/quant | Decode-path N-T GEMM orientation |
| `RADIANCE_MXFP4_HOIST_QUANT` / `RADIANCE_MXFP4_TRACED_QUANT` | `1` / `1` | model/quant | Hoisted/traced quantization (task-listed tunable, adopted verbatim) |
| `PYTORCH_CUDA_ALLOC_CONF` | `expandable_segments:True` | host/allocator | Reduces CUDA/HIP allocator fragmentation for long-context KV growth |
| `VLLM_CACHE_ROOT`, `TORCHINDUCTOR_CACHE_DIR`, `TRITON_CACHE_DIR`, `AITER_ROOT_DIR` | `/cache/*` | cache | All point inside `RADLIGHT_CACHE_DIR`, the one read-write mount |
| `TRITON_CACHE_AUTOTUNING` | `1` | cache/compilation | Persists autotuning results across restarts alongside the other caches |

### Adopted but configurable (exposed as `RADLIGHT_*` overrides in `.env`)

Every variable above that plausibly needs host-specific tuning is
double-named in `compose.radlight.yaml` as
`${RADLIGHT_<NAME>:-<radlight-default>}` -- e.g. `RADLIGHT_R4D_ATTN_FP8`
overrides `R4D_ATTN_FP8`. This includes the MXFP4 tuning knobs
(`RADIANCE_MXFP4_TN4_MIN_M`, `RADIANCE_MXFP4_DECODE_MAX_M`,
`RADIANCE_MXFP4_A_TILED_MIN_M`) which Radlight's own comments already mark
"upstream default" (i.e. Radlight itself treats them as tunable, not
fixed). None have been swept independently on this host as of this
document's last update -- left at Radlight's own defaults pending real
measurement, not re-derived from first principles.

| Variable | Radlight default | This deployment | Scope | Rationale |
|---|---|---|---|---|
| `RADIANCE_MXFP4_W4A8_MIN_M` | `0` | `0` (unchanged) | model/quant | No sweep performed yet |
| `RADIANCE_MXFP4_TN4_MIN_M` | `2048` | `2048` (unchanged) | model/quant | Radlight's own comment: "upstream default" |
| `RADIANCE_MXFP4_DECODE_MAX_M` | `64` | `64` (unchanged) | model/quant | Radlight's own comment: "upstream default" |
| `RADIANCE_MXFP4_A_TILED_MIN_M` | `513` | `513` (unchanged) | model/quant | Radlight's own comment: "upstream default" |
| `VLLM_ROCM_USE_AITER_RMSNORM` | `0` | `0` (unchanged) | GPU | Matches the Radiance-baseline stack's own default for the same flag name -- NOTE: same env var name across both stacks, but do not assume identical semantics/effect (different vLLM/AITER versions); verified independently as "off, matches Radlight's own tested config" here |

### Intentionally disabled (preserved unless testing proves otherwise)

Per the task's explicit instruction to preserve these unless testing on
this exact pinned stack proves otherwise:

| Variable | Value | What it would enable | Why still disabled |
|---|---|---|---|
| `VLLM_ROCM_USE_AITER_MHA` | `0` | AITER multi-head attention kernel | Radlight's own tested config leaves it off; this profile explicitly selects `ROCM_AITER_UNIFIED_ATTN` via `--attention-backend` instead |
| `VLLM_ROCM_USE_AITER_MLA` | `0` | AITER multi-head latent attention | Not applicable to this architecture (no MLA layers in this checkpoint) |
| `VLLM_ROCM_USE_AITER_MOE` | `0` | AITER mixture-of-experts kernels | Not applicable -- this is a dense model, no MoE layers |
| `VLLM_ROCM_USE_AITER_LINEAR` | `0` | AITER generic linear-layer kernel | Superseded by the MXFP4-specific GEMM path (`RADIANCE_MXFP4*`) for this checkpoint |
| `VLLM_ROCM_USE_AITER_FP8BMM` | `0` | AITER FP8 batched matmul | Superseded by Radlight's own `RADIANCE_FP8_STREAM` path |
| `VLLM_ROCM_USE_AITER_FP4BMM` | `0` | AITER FP4 batched matmul | Superseded by the fork's own MXFP4xFP8 HIP extension (`radiance_mxfp4_fp8.so`) |
| `RADIANCE_FAST_DRAFT` | `0` | Radiance's own lightweight draft-token heuristic | This profile's speculative decoding is DFlash2 via `--speculative-config`, an explicit, inspectable configuration -- not this implicit env-armed path. Do not enable both at once. |
| `RADIANCE_DYNAMIC_DRAFT` | `0` | Radiance's own dynamic-draft speculative path (the SAME flag the Radiance-baseline stack has ON by default -- see `.env-template`'s `RADIANCE_DYNAMIC_DRAFT` comment for that stack) | Superseded here by the explicit external DFlash2 drafter configuration; the task requires the actual speculative configuration to be visible/inspectable, which `--speculative-config` is and an implicit env-armed path is not |
| `RADIANCE_MXFP4_SANITIZE` | `0` | Extra weight-sanitization pass for MXFP4 checkpoints with irregular scale layouts | Radlight's own tested config leaves it off for this exact checkpoint; would only be worth trying if the correctness gates below fail in a way that looks like corrupted/misrouted weights |

### Not applicable under Docker (Podman-specific in `run.sh`, translated or dropped)

| `run.sh` flag/var | Docker translation |
|---|---|
| `--group-add keep-groups` | Numeric `VIDEO_GID`/`RENDER_GID` group_add, same as `compose.yaml` |
| `--security-opt label=disable` | `security_opt: seccomp=unconfined` (Docker/ROCm's actual requirement; `label=disable` is SELinux-specific to Podman) |
| `-ti` | Dropped -- not a terminal-attached one-shot run, this is a long-lived service |
| `--rm` | Dropped -- `restart: unless-stopped`, container persists |
| `-v ".:/opt/repo:ro"` | `${RADLIGHT_LOCAL_PATH}:/opt/repo:ro` (an explicit host path from `scripts/sync-radlight.sh`, not "current directory") |
| `podman run --entrypoint=/opt/repo/entrypoint/init.sh` | `entrypoint: []` + `command: sh -c 'exec /opt/repo/entrypoint/init.sh ...'` (same idiom `compose.yaml` already uses, see its own comment on the exact backslash/newline failure mode this avoids) |
| `--cap-add=SYS_NICE` | Retained as-is -- a scoped capability, not privileged mode, compatible with Docker Compose's `cap_add:` |

### Rejected (with documented reason)

| Variable | Radlight value | Rejected because |
|---|---|---|
| `HF_HUB_OFFLINE=1` (as a *hard-coded, non-overridable* assumption) | `1` | Kept as the **default** (see "adopted but configurable" -- `RADLIGHT_HF_HUB_OFFLINE`), not rejected outright, but explicitly made overridable to `0` for a one-off diagnostic run against a live repo id, which Radlight's own fixed script does not allow |

No variable from `run.sh` was rejected outright (dropped with no
equivalent) -- everything maps to either "adopted," "adopted but
configurable," "intentionally disabled," or "not applicable under Docker."

## KV cache allocation flag name

Radlight's own `run.sh` passes `--kv-cache-memory "$KV_MEM"`. **Verified
against `docker run ... vllm serve --help=all` inside the actual pulled
digest (`sha256:b8a082f346d0...`, 2026-09-21) that this exact build only
accepts `--kv-cache-memory-bytes`** -- `--kv-cache-memory` (without
`-bytes`) is not a recognized flag on this pinned image, so
`compose.radlight.yaml` uses `--kv-cache-memory-bytes` instead of copying
Radlight's own spelling verbatim. (Likely explanation: Radlight's `run.sh`
was written against a slightly different vLLM 0.27 point build where the
flag had the shorter name before an upstream rename -- not chased further
since the pinned image's actual `--help` output is the ground truth here,
per the task's own instruction, not Radlight's script text.) This profile
never combines the explicit KV-bytes flag with `--gpu-memory-utilization`
-- picking exactly one avoids the ambiguity the task explicitly calls out.

## First live canary results (2026-09-21)

Ran the sequential canary (`scripts/canary-radlight.sh qwen38-27b-radlight`)
three times against real production hardware. The first two attempts hit
real bugs (fixed, see WORKLOG.md for the full account): a git "dubious
ownership" crash-loop against the read-only repo mount, and a shell-quoting
bug that corrupted `--speculative-config`'s JSON value. A third attempt's
first boot also hit a `HSA_STATUS_ERROR_MEMORY_FAULT` during engine
initialization -- consistent with Radlight's own README ("First run will
crash... run it again... if your GPU is doing nothing the default should
eventually fit"), not traced to a specific fix; the automatic container
restart (`restart: unless-stopped`) succeeded on the very next attempt with
identical configuration.

The canary then passed `scripts/validate-model.sh`'s full guardrail suite
cleanly:

| Check | Result |
|---|---|
| VRAM postflight | 30.14GiB / 31.86GiB used -- **1.72GiB headroom** (above the 0.5GiB floor and the task's ~0.75-1.0GiB target) |
| Known-answer arithmetic | Correct (47*89=4183) |
| Known-answer code-completion | Passed static AST check |
| Tool-call determinism | Consistent across 4 trials including a full container restart |
| `scripts/test-tool-calling.sh` (6 scenarios) | **6/6 passed** |

Kernel/optimization evidence collected live (not assumed):

- `Resolved architecture: Qwen3_5ForConditionalGeneration` (target) and
  `DFlash2DraftModel` (drafter) -- both resolved without error.
- `[radiance.gdn] gdn_chunk_scan ENABLED` -- R4D engaged for the
  Gated-DeltaNet layers.
- `[radiance.mxfp4] linear layers: 304/304 on our kernel, 0 FORCED ONTO
  AITER` -- full MXFP4 kernel engagement, no fallback.
- `Selected TritonFp8BlockScaledMMKernel for Fp8LinearMethod` -- real FP8
  kernel path for both the target and drafter models.
- `GPU KV cache size: 281,186 tokens` / `Maximum concurrency for 262,144
  tokens per request: 1.07x` -- matches the exact-parity profile's tight,
  by-design VRAM budget.
- `/metrics`: `vllm:spec_decode_num_draft_tokens_total` 1827,
  `vllm:spec_decode_num_accepted_tokens_total` 838 (**~46% acceptance
  rate**), with the expected per-draft-position falloff (227 accepted at
  position 0 down to 49 at position 6) -- DFlash2 is genuinely proposing
  and accepting tokens, not just "on."
- One transparently-logged (non-silent) fallback observed:
  `[radiance.gdn] falling back to FLA for this shape: state dtype
  torch.float16` -- a specific GDN shape variant uses the reference FLA
  kernel rather than R4D's fused path; logged clearly, not hidden.
- A non-fatal optional-module gap, also transparently logged:
  `[radiance.gemm] no gemm_nt kernel for M<=64 bf16 and no paroquant
  fallback (ModuleNotFoundError('radiance_paroquant_kernel')), disabled`.

Informal throughput signal (`scripts/benchmark.sh`, concurrency 1, ~512
prompt tokens, 128 max tokens, single measurement -- not the full matrix):
**61.23 tok/s aggregate**, vs. the Radiance-baseline's established ~23-24
tok/s single-stream figure (`docs/TUNING.md`) -- roughly **2.5x**, well
above the task's 25% promotion threshold. This is one data point, not the
required full apples-to-apples matrix (same prompt/sampling/output-length
methodology across concurrency 1/2, cold/warm TTFT, prefix-cache hit rate,
etc.) -- treat as a strong positive signal, not a promotion-qualifying
result on its own.

**Not yet run** (see STATUS.md/WORKLOG.md for the full list): the formal
DFlash2 output-equivalence gate (with vs. without, deterministic sampling,
`qwen38-27b-radlight-nospec`), chat-template A/B, long-context tests (8K
through 262K), the full benchmark matrix, and real OpenCode/PI/Hermes
agentic-task validation. The canary was intentionally rolled back to the
Radiance-baseline production profile after this first pass (level-1
rollback, `scripts/rollback-radlight.sh`) rather than promoted, since
promotion requires all of the above, not just the guardrail suite.

Also verified present and correctly spelled on this exact image:
`--language-model-only`, `--attention-backend`, `--mamba-cache-mode
{align,all,none}`, `--mamba-cache-dtype`, `--mamba-ssm-cache-dtype`,
`--async-scheduling`/`--no-async-scheduling`, `--compilation-config`,
`--speculative-config`, `--reasoning-parser`, `--tool-call-parser`
(`qwen3_xml` is in its supported-parser list), `--enable-auto-tool-choice`,
`--enable-prefix-caching`, `--chat-template`, `--trust-remote-code`.

## Context/concurrency profiles

| Profile | Context | KV bytes | max_num_seqs | max_num_batched_tokens | Status |
|---|---|---|---|---|---|
| `qwen38-27b-radlight` (exact parity) | 262144 | 10,200,547,328 | 2 | 2560 | First canary target -- Radlight's own published config, unmodified |
| `qwen38-27b-radlight-balanced` | 196608 | 7,650,410,496 (scaled, unverified) | 2 | 2560 | Fallback if parity profile's real VRAM headroom is unsafe |
| `qwen38-27b-radlight-compat` | 131072 | 5,100,273,664 (scaled, unverified) | 2 | 2560 | Fallback matching the Radiance-baseline's own production context, for apples-to-apples benchmarking |

The two fallback profiles' KV byte values are **linear scalings of
Radlight's own pair, not independently measured** -- KV cache scales with
context length but per-request activation/compilation overhead does not,
so treat them as a starting point for `scripts/validate-model.sh`'s VRAM
postflight, not a final answer. Fill in real `rocm-smi`/`amd-smi` headroom
numbers here once each profile has actually been run.

## Chat template

| | Vendor (checkpoint's own) | Radlight's pinned template |
|---|---|---|
| Source | `amd/Qwen3.8-27B-Quark-AWQ-MXFP4`'s own `tokenizer_config.json` | `entrypoint/chat_template.jinja`, vendored by Radlight from `huggingface.co/peculiar-ragdoll/Qwen-Sharp-Chat-Templates` |
| Profile | `qwen38-27b-radlight.env` (`CHAT_TEMPLATE_ARGS=`, empty) | `qwen38-27b-radlight-template.env` (`CHAT_TEMPLATE_ARGS=--chat-template /opt/repo/entrypoint/chat_template.jinja`) |
| Behavior difference | Standard Qwen3 template | Injects terse-answer / reasoning-effort behavior (per Radlight's own README framing) |
| Decision | **Not yet made** -- run `scripts/test-tool-calling.sh` and the correctness suite against both profiles before picking a production default; do not default to Radlight's template on convenience alone |

## Speculative decoding (DFlash2)

| | Value |
|---|---|
| Method | `dflash` |
| Drafter | `/models/drafter` (pinned `tcclaviger/Qwen3.8-27B-DFlash2-FP8`) |
| Speculative tokens | 7 |
| Draft sampling | `probabilistic` |
| Drafter attention backend | `TRITON_ATTN` |
| Clean disable switch | `config/models/qwen38-27b-radlight-nospec.env` (same target model, `SPEC_DECODE_ARGS=` empty) -- for the mandatory output-equivalence gate |

DFlash2 here is an **explicit, inspectable `--speculative-config`
argument**, not an implicit env-armed path (contrast with the
Radiance-baseline stack's `RADIANCE_DYNAMIC_DRAFT=ON`, which activates
with no visible CLI configuration -- see `docs/ROCM.md`). This satisfies
the task's requirement that the actual speculative configuration be
visible and auditable, not just "on by default."

## Cache directories

| Path (host, `RADLIGHT_CACHE_DIR`) | Path (container) | Contents |
|---|---|---|
| `/var/lib/radiance-vllm/radlight-cache/libr4d/<commit>/` | `/cache/libr4d/<commit>/` | Compiled `r4d.so`, keyed by the pinned `libr4d` submodule commit |
| `/var/lib/radiance-vllm/radlight-cache/radiance_mxfp4/<commit>/` | `/cache/radiance_mxfp4/<commit>/` | Compiled `radiance_mxfp4_fp8.so`, keyed by the pinned `radiance-vllm-mxfp4` submodule commit |
| `/var/lib/radiance-vllm/radlight-cache/vllm/` | `/cache/vllm/` (`VLLM_CACHE_ROOT`) | torch.compile / CUDA graph capture cache |
| `/var/lib/radiance-vllm/radlight-cache/inductor/` | `/cache/inductor/` (`TORCHINDUCTOR_CACHE_DIR`) | TorchInductor cache |
| `/var/lib/radiance-vllm/radlight-cache/triton/` | `/cache/triton/` (`TRITON_CACHE_DIR`) | Triton kernel cache |
| `/var/lib/radiance-vllm/radlight-cache/aiter/` | `/cache/aiter/` (`AITER_ROOT_DIR`) | AITER kernel cache |

This is the **only read-write mount**. The repo checkout (`/opt/repo`) and
both model directories (`/models/target`, `/models/drafter`) are read-only,
matching Radlight's own design intent ("the container intentionally runs
without write permissions outside its own cache").

## Security posture (vs. Radlight's own `podman run`)

| | Radlight (`run.sh`, Podman) | This deployment (Docker Compose) |
|---|---|---|
| Rootless/rootful | Rootless Podman, `keep-groups` | Docker with numeric GID `group_add` (matches `compose.yaml`'s existing convention) |
| Privileged mode | No | No |
| Docker/Podman socket mounted | No | No |
| Ephemeral container | Yes (`--rm -ti`) | No -- `restart: unless-stopped`, persistent service with a healthcheck |
| Capabilities added | `SYS_NICE` | `SYS_NICE` only |
| Filesystem | Repo + models read-only, cache read-write | Same |
| SELinux/seccomp | `label=disable` | `seccomp=unconfined` (Docker/ROCm equivalent already used by `compose.yaml`) |

## Observability

`RADIANCE_R4D_REPORT=1` is the load-bearing flag for the "kernel and
optimization validation" gate -- it logs which R4D kernels actually
loaded at startup (mirrors `docs/ROCM.md`'s `gdn_chunk_scan ENABLED`-style
evidence for the baseline stack). `/metrics` metric names must be
re-verified against this exact vLLM 0.27 build -- do not assume they match
the baseline stack's vLLM 0.28 names 1:1 (e.g. `vllm:kv_cache_usage_perc`
was itself a correction from an assumed `gpu_cache_usage_perc` on the
baseline stack; the same category of drift is plausible across a major
vLLM version change here too).
