# Plan: Migrate scar.lab to Radiance vLLM (AMD Radeon AI PRO R9700)

Status: planning document, no implementation yet.
Scope: primary inference-stack migration, container design, installer design, rollback.
Companion document: `plan-radiance-observability.md` (dashboard/metrics/agentic-client validation).

This plan is written so another coding agent can implement the repository from it
without re-deriving the research. Every claim is labeled as a **verified fact**
(confirmed live on scar.lab or from a primary upstream source, with citation),
a **design decision** (a choice this plan makes and why), or an **open question**
(cannot be resolved from a desk plan — implementation must resolve it, and how is
stated explicitly).

---

## 1. Executive Summary

scar.lab (this host) currently serves an OpenAI-compatible LLM API on port 8080
via a containerized llama.cpp (`llamacpp` container), serving a GGUF build of
`Qwen/Qwen3.8-27B`. This plan replaces that stack with a containerized vLLM
deployment ("Radiance vLLM") on the same host's single AMD Radeon AI PRO R9700
(32GB, gfx1201/RDNA4), while:

- preserving the llama.cpp deployment, stopped but fully recoverable (no
  destructive changes to its repo, container, or model files)
- preserving the external endpoint `http://scar.lab:8080/v1` so OpenCode and PI
  on raptor.lab need at most a served-model-name change, not a URL change
- adopting a **stable served model name** (`scar-coder`) so future model swaps
  never require touching downstream client config again
- targeting ~30.5–31GB VRAM in use, 131072-token context, FP8 KV cache (pending
  validation), and Qwen3.8-27B (same model family already running today, quantized)

**Critical framing correction (read before anything else):** "Radiance vLLM" is
**not an AMD-official product**. It is a single-maintainer community project
(`vllm-radiance`, author `StillDeadcode`, hosted on Codeberg) that ships a patched
vLLM + a custom RDNA4 kernel library (`libr4d`, providing the "R4D" attention
backend and "DFlash2" speculative decoding). See §4 for what this means. This
plan originally recommended AMD's official `rocm/vllm` container as a safe
baseline with the Radiance-specific pieces gated behind validation — **when
asked directly, the user chose to go straight for the `vllm-radiance` stack
from day one instead** (§4.1, decision recorded 2026-09-14), accepting that
risk knowingly rather than deferring it. The official `rocm/vllm` image
remains documented as the last-resort fallback (§4.1) if `vllm-radiance`
fails to run at all, not as the primary path.

---

## 2. Current-State Discovery (verified, live on scar.lab)

This host *is* scar.lab (confirmed via `hostname`, `/etc/hosts`). GPU confirmed
present: AMD Radeon AI PRO R9700, gfx1201, via `rocm-smi`/`amd-smi`.

### 2.1 Running containers (`docker ps`, all via Docker — **not Podman**; see §12.1)

| Container | Image | Port | Managed by |
|---|---|---|---|
| `llamacpp` | `ghcr.io/ggml-org/llama.cpp@sha256:96320a5e...` | `8080` (host+container) | `docker compose`, `~/Workspace/Git/Containerized-llamma.ccp-AMD-9700/docker-compose.yaml` |
| `vllm-llama-cpp-dashboard` | `vllm-management-portal:0.1.0` | `8088->8080` | `docker compose`, `~/Workspace/Git/vLLM-Management-Portal/compose.yaml` |
| `vllm-llama-cpp-dashboard-docker-proxy` | `tecnativa/docker-socket-proxy:v0.4.2` | none (internal) | same compose project |
| `hermes`, `hermes-dashboard` | `nousresearch/hermes-agent:v2026.8.13` | none published | `~/Workspace/Git/Containerized-Hermes-AI-llama.ccp-connector` |
| `homeassistant` | — | exited, unrelated | — |

### 2.2 Current llama.cpp configuration (`docker inspect llamacpp`)

- Model: `/models/Qwen3.8-27B-UD-Q6_K.gguf`, bind-mounted from host
  `/var/lib/llamacpp/models` (root-owned system path, **not** `~/.cache/huggingface`)
- Source checkpoint: HF repo `unsloth/Qwen3.8-27B-GGUF`, file
  `Qwen3.8-27B-UD-Q6_K.gguf` (Unsloth Dynamic imatrix Q6_K quant), ~20.5GiB,
  sha256-pinned in the llama.cpp repo's `VERSIONS` file
- `LLAMA_ARG_CTX_SIZE=131072` — confirms 128K context is already the proven,
  working target on this exact host/model family, not aspirational
- `LLAMA_ARG_CACHE_TYPE_K=q8_0`, `LLAMA_ARG_CACHE_TYPE_V=q8_0` — 8-bit KV cache
  already in production use (closest llama.cpp analog to FP8 KV cache)
- `LLAMA_ARG_SPEC_TYPE=draft-mtp`, `LLAMA_ARG_SPEC_DRAFT_N_MAX=2` — self-speculative
  multi-token-prediction already in production use; this is llama.cpp's
  speculative decoding, not portable to vLLM directly (see §8.2)
- `HSA_OVERRIDE_GFX_VERSION=12.0.1`, `HIP_VISIBLE_DEVICES=0`
- `restart: unless-stopped`, `container_name: llamacpp`, devices
  `/dev/kfd`+`/dev/dri`, `group_add: [video, render]` resolved to numeric GIDs
  `44`/`992` by `deploy.sh` (name-based `group_add` is unreliable — the image's
  base OS may not define a `render` group; **verified failure mode**, see §12.4)
- No API key set (`LLAMA_API_KEY=` empty) — LAN-only trust model, bound `0.0.0.0`

### 2.3 Host environment

- OS: Ubuntu 24.04.4 LTS. **No SELinux** (`getenforce`: not found) — AppArmor is
  loaded but no repo on this host customizes an AppArmor profile for Docker; the
  default `docker-default` profile is in use everywhere. The task prompt's
  SELinux caution is moot here; do not introduce AppArmor changes either unless
  a concrete container failure requires it.
- ROCm installed natively at `/opt/rocm-7.2.2` (mounted read-only into the
  dashboard container for `amd-smi`). This is **older** than the version the
  vLLM container track now targets (ROCm 10.0.0, released 2026-08-26 — see
  §5.2); the container brings its own ROCm userspace, so the host ROCm version
  matters only for kernel/driver (`amdgpu`) compatibility with `/dev/kfd`,
  `/dev/dri`, not for what's inside the container.
- Filesystems: `/home` (sda1) 1.3TB free; `/` (sdd1) 786G free; `/var/lib`
  (**sdc1**, a third, separate filesystem) 880G total, 559G free.
- RAM: 94GiB total, 87GiB available, 31GiB swap unused. 12 CPUs.
- Groups: `video` (gid 44), `render` (gid 992); `cpaquin` is in both plus `docker`.
- Docker images already pulled locally (relevant to this migration):
  - `rocm/vllm:rocm7.14.0_rdna_ubuntu24.04_py3.14_pytorch_2.11.0_vllm_0.23.0` — 73.4GB, pulled ~2 months ago
  - `vllm/vllm-openai:latest` — 29.9GB, **unpinned `:latest` tag, origin unaccounted for by any repo on this host** — flag for cleanup, do not build on this image (see §23)
  - `rocm/pytorch:rocm7.2_ubuntu24.04_py3.12_pytorch_release_2.9.1` — 42.4GB
- `~/.cache/huggingface/hub` already contains ~25GB: `Qwen2.5-Coder-14B-Instruct-AWQ`
  and `stelterlab/Qwen3-Coder-30B-A3B-Instruct-AWQ` — leftovers from the abandoned
  vLLM deployment (§2.4), directly reusable if those profiles are kept as
  fallback/comparison profiles.
- No systemd units and no cron/timer entries manage any of these services —
  container `restart:` policy is the *only* lifecycle mechanism in use anywhere
  on this host. Follow that convention; do not introduce a systemd unit.

### 2.4 A working vLLM deployment already existed here — and was deliberately abandoned

`~/Workspace/Git/Containerized-VLLM-AMD-R9700` is a **previously fully-working**
vLLM-on-R9700 deployment (commits Aug 10–20 2026): three model profiles, all
started, health-checked, benchmarked, and driven through OpenCode with real tool
calls. It was replaced by the current llama.cpp deployment (commits Aug 15–Sep 5)
for three documented reasons (quoted from that repo's own README):

1. llama.cpp's `-ngl` (partial GPU layer offload) vs. vLLM's static, all-or-nothing
   VRAM allocation
2. llama.cpp's mmap'd GGUF loading avoided a host-RAM OOM-kill spike that vLLM hit
3. "vLLM's brittle, layout-sensitive AWQ/Quark loaders" — a real, reproduced bug:
   `AttributeError: 'dict' object has no attribute 'startswith'` in
   `vllm/model_executor/layers/quantization/quark/quark.py` when loading
   `amd/Qwen3.8-27B-Quark-AWQ-INT4-W4A16` on the pinned vLLM build
   (`0.23.1.dev1+g9ddef7117.d20260715`) — a genuine, unfixed-by-flags vLLM bug,
   not a config mistake.

**This plan must not repeat reason 3.** §6.3 below designs the quantization
choice around this exact lesson (bake-off methodology, avoid Quark format,
prefer compressed-tensors-packaged builds that the old repo already proved work).
Reasons 1 and 2 are addressed by the MEM_LIMIT/MEM_RESERVATION cgroup pattern
that repo also developed after a real host lockup (see §10.3) — carry it forward.

That repo's `docs/ROCM.md`, `scripts/preflight.sh`, `scripts/test-tool-calling.sh`,
OpenCode integration scripts, and benchmark tooling are strong, host-validated
prior art. This plan reuses their conventions and patterns extensively rather
than inventing new ones — see §11.

### 2.5 Downstream clients (verified via SSH to raptor.lab)

**OpenCode** (`~/.config/opencode/opencode.json` on raptor.lab) already has four
providers configured against scar.lab, including a stale `scar-vllm` entry
pointing at `http://10.1.10.10:8000/v1` (the old vLLM repo's default port, since
8080 was taken by llama.cpp) with model key `qwen3-coder-30b-a3b`. The
`scar-llamacpp` and `local-lab-llama` providers point at `:8080` with the raw
GGUF file path as the model id (e.g. `/models/Qwen3.8-27B-Q5_K_M.gguf`) — exactly
the "long, ugly identifier" problem the stable-served-name design decision (§14)
solves.

**PI** (`~/.pi/agent/models.json` on raptor.lab) has one provider,
`local-lab-llama`, `baseUrl: http://10.1.10.10:8080/v1`, model id again the raw
GGUF path.

**Critical implementation fact:** both OpenCode's and PI's configurators
(`~/Workspace/Git/Agentic-Tooling-Local-Lab/scripts/configurators/{opencode,pi}.sh`)
fetch the served model id **once, at configure-time**, from `GET /v1/models` —
neither tool re-discovers it at runtime. **Changing the served-model-name always
requires re-running the configurator once**, even with a stable name design; the
payoff of a stable name is that this happens exactly once more, ever, at cutover,
never again on future model swaps.

### 2.6 Hermes and MemPalace — confirmed out of scope

- Hermes (`~/Workspace/Git/Containerized-Hermes-AI-llama.ccp-connector`) talks
  directly to `http://127.0.0.1:8080/v1`, auto-detecting the model from
  `/v1/models`. It is not in the OpenCode/PI path and this plan does not
  route through it. It should keep working unmodified through the migration
  (same port, OpenAI-compatible, auto-detected model) — verify in §17 rather
  than assume.
- MemPalace: **confirmed no direct dependency on llama.cpp.** The Hermes
  `mempalace-remote` plugin talks only to MemPalace's own MCP server
  (`:8765/mcp`) via the `mcp` SDK — no embeddings or completions calls to
  llama.cpp/vLLM anywhere in that plugin, its README, or `plugin.yaml`. No
  MemPalace changes are in scope for this migration.

---

## 3. Architecture

### 3.1 Staged cutover (not a direct swap)

**Correction from implementation, 2026-09-14:** the "zero production risk"
framing below covers the *port* dimension only. Live measurement on
scar.lab found `llamacpp` alone using ~26.4GB of the ~31.9GB usable VRAM
on this single R9700 (via `rocm-smi`), leaving only ~5.4GB free -- not
enough to hold even the smallest real validation deployment resident
alongside it. **A single 32GB GPU cannot run both services' models loaded
simultaneously**, regardless of which port each listens on. In practice,
Phase 0-3 validation required `docker stop llamacpp` (temporary, fully
reversible with `docker start llamacpp`, autostart left enabled
throughout so this is distinct from Phase 4's permanent disable) for the
duration of testing. See `docs/runbook.md`'s "Single-GPU VRAM contention"
entry. This does not change the plan's rollback guarantee (llama.cpp's
config/container/model files are still never modified), but it does mean
"staging" on this hardware is closer to "an early, immediately-reversible
soft cutover" than a fully concurrent side-by-side comparison.

Port 8080 is owned by the live `llamacpp` container. vLLM cannot bind it until
llama.cpp is stopped. A direct "stop llama.cpp, start vLLM on 8080, hope it
works" is unacceptably risky for a stack with the compatibility gaps documented
in §4–§9. Instead:

```
Phase A (staging):  llamacpp :8080 (unchanged, serving) | radiance-vllm :8081 (new, validation only)
Phase B (cutover):  llamacpp :8080 stopped, autostart disabled | radiance-vllm :8080 (recreated with new port binding)
Phase C (rollback, if needed): radiance-vllm stopped | llamacpp :8080 (restarted, unchanged config)
```

- Phase A runs the full validation matrix (§20) and benchmark suite (§21)
  against `radiance-vllm` on a **staging port (8081)** while `llamacpp` keeps
  serving real traffic on 8080 the whole time. Zero production risk during
  validation.
- Phase B is the only point where 8080 changes hands: stop+disable-autostart
  llama.cpp, recreate the `radiance-vllm` container with its port mapping
  changed from `8081:8000` to `8080:8000` (a `docker compose up -d` after
  editing `.env`'s `API_PORT`, or two compose files/profiles — see §11.3).
  This is a short blip (container recreate, not a cold model reload if the
  torch.compile/weights cache is warm — seconds, not minutes).
- Phase C (rollback) is `docker compose down` on `radiance-vllm`,
  `docker compose up -d` (or `docker start`) on `llamacpp` — no llama.cpp
  config was ever touched, so this is guaranteed to reproduce the exact
  pre-migration state.

### 3.2 Container topology

```
                         scar.lab (Docker, host network unchanged)
  ┌──────────────────────────────────────────────────────────────────┐
  │  radiance-vllm container                                         │
  │    image: rocm/vllm:<pinned digest>  (§5)                        │
  │    devices: /dev/kfd, /dev/dri   ipc: host                       │
  │    port: host 8080 -> container 8000  (staging: 8081 -> 8000)    │
  │    mounts: HF cache, vLLM compile cache, logs                    │
  │    mem_limit / mem_reservation (cgroup, host RAM — see §10.3)    │
  │    served-model-name: scar-coder  (§14)                          │
  └──────────────────────────────────────────────────────────────────┘
                    │ OpenAI-compatible API (/v1/*, /metrics)
                    ▼
     scar.lab:8080/v1  ◄──────────────  OpenCode, PI (raptor.lab, unchanged URL)
                    ▲                   Hermes (127.0.0.1:8080, unchanged, unmodified)
                    │
     vLLM-Management-Portal (dashboard, :8088) — see plan-radiance-observability.md
```

`llamacpp` container is unchanged in this diagram during Phase A/rollback; it is
simply not shown running concurrently with `radiance-vllm` on 8080 in Phase B.

### 3.3 Repository role

This repo (`Radiance-vLLM-AMD-R9700`, currently empty, not yet a git repo) becomes
the installer, mirroring the layout and conventions of the two most relevant
sibling repos verified in §2: `Containerized-llamma.ccp-AMD-9700` (rollback/state
patterns, `VERSIONS` pinning, bats tests, pre-commit tooling) and
`Containerized-VLLM-AMD-R9700` (vLLM-specific compose/preflight/OpenCode/
tool-calling/benchmark scripts — largely reusable, not a rewrite). See §11.

---

## 4. What "Radiance vLLM" Actually Is (verified research, Sept 2026)

**Verified from primary source** (Codeberg README, fetched directly):

- "AMD Radiance" as an AMD marketing term refers to unrelated ray-tracing
  hardware (Project Amethyst). It has nothing to do with this deployment — do
  not search for "AMD Radiance vLLM" documentation from AMD; none exists.
- The actual project is **`vllm-radiance`**
  (`codeberg.org/StillDeadcode/vllm-radiance`, companion kernel repo
  `libr4d`), a **single-maintainer community fork**: a pinned vLLM + custom
  HIP kernel library for gfx1201 specifically. Published images:
  `stilldeadcode/vllm-radiance` and `magiccodingman/vllm-radiance` on Docker Hub.
  Its own README states: *"Early development... Experimental... Not affiliated
  with official AMD support... Not production hardened. Use at your own risk."*
- Its most-validated configuration is **2×R9700 (tensor-parallel=2)**. The
  README does not claim single-GPU qualification. **Our target (single R9700) is
  explicitly the least-tested configuration in this whole ecosystem.**
- `libr4d` provides the "R4D" attention backend: hand-written HIP kernels for
  paged attention, fused gated-delta-net prefill/decode, vision flash-attention,
  P2P all-reduce, and MXFP4/DFlash GEMMs — **opt-in**, not the default backend
  even within vllm-radiance itself, and constrained to specific model shapes
  (head_dim=256, paged block size 16, 6 query heads per KV head, causal
  attention, bf16/fp8 KV cache). No AMD-authored documentation of R4D exists
  anywhere; treat it as unverified-for-production, single-maintainer risk.
- "DFlash2" is `vllm-radiance`'s speculative-decoding drafter, related to (but
  distinct from) upstream vLLM's own `DFlash` implementation (a real, current,
  upstream feature — see §8.2). vllm-radiance's own README states DFlash2
  **failed their own strict greedy/tool-call output-equivalence gate**, passing
  only a looser "meaningful output + sampled tool-call" bar.

### 4.1 Design decision (user-confirmed 2026-09-14): go straight for `vllm-radiance`, not the official image

This plan originally recommended AMD's official `rocm/vllm` container as a
safe baseline, with `vllm-radiance`/`libr4d` (R4D attention, DFlash2 spec
decoding) as a gated, optional Phase 5 add-on. **The user explicitly rejected
that framing** when asked directly, choosing instead: *"Go straight for the
Radiance stack (vllm-radiance/libr4d) from day one."* This plan is updated
accordingly. The risk profile from §4 (single-maintainer, experimental, only
2-GPU-validated) stands as written and is accepted, not mitigated by
deferral.

**Resulting design:**

- **Primary deployment image (Phase 1 onward):** `vllm-radiance`
  (`stilldeadcode/vllm-radiance` or `magiccodingman/vllm-radiance` on Docker
  Hub — resolve exact current tag/digest at implementation time, §5), not
  `rocm/vllm`.
- **R4D attention backend:** attempted first. **User-confirmed fallback
  (2026-09-14):** if R4D's constraints (head_dim=256, 6 query-heads-per-KV-head,
  causal-only) don't match Qwen3.8-27B's hybrid Gated-DeltaNet/Gated-Attention
  architecture (open question, §9.3/§24 — likely, given the architecture),
  **stay on the `vllm-radiance` image and fall back to its standard (non-R4D)
  attention path** — do not abandon the Radiance stack or swap models over an
  R4D-specific mismatch. This is still meaningfully "the Radiance vLLM stack"
  (same maintainer's patched vLLM, DFlash2 still evaluated independently) even
  without R4D specifically engaging for this model's layers.
- **DFlash2 speculative decoding:** attempted first (§8.2), evaluated with the
  same strict output-equivalence bar as before — a *correctness* bar, not a
  scope-inclusion bar. If it fails correctness, ship without speculative
  decoding (or `ngram`) — this is not the same decision as the R4D one above;
  DFlash2 failing its own equivalence gate is a documented, known behavior
  (§4), not merely "doesn't apply to this model."
- **Last-resort fallback (not explicitly asked, but implied by keeping
  llama.cpp as the only required rollback target, §19):** if `vllm-radiance`
  fails to load *any* model at all (a harder failure than R4D not engaging —
  e.g. the image itself won't run on this host, §9.3's container-startup
  bug), fall back to the official `rocm/vllm` image so the migration can still
  deliver a working vLLM deployment, rather than being blocked entirely on a
  single community image. Document this explicitly if it happens — it changes
  the "Radiance" framing materially and the user should know.

This is a materially higher-risk path than this plan originally recommended.
The risks in §4, §9, and §23 are not reduced by this decision — they are
knowingly accepted.

---

## 5. Validated Stack & Version Pins

All version strings below were verified from primary sources in September
2026 (Docker Hub tag listings, ROCm release notes, vLLM's own GitHub). **This
software space moves in weeks, not months** — the implementation step MUST
re-verify the exact current tag/digest before pinning (do not blindly copy
these strings if this plan is implemented more than a few weeks after being
written). Every pin below must resolve to an image **digest** (`@sha256:...`),
not a floating tag, mirroring the llama.cpp repo's `VERSIONS` file convention
(§11.2) — and each pin's chosen value must be re-confirmed via `pip show
<package>` *inside the running container* at deploy time, not trusted from docs.

| Component | Pin (verify/update at implementation time) | Why pinned here |
|---|---|---|
| Container image (**primary**, per §4.1) | `stilldeadcode/vllm-radiance:<latest tag>` or `magiccodingman/vllm-radiance:<latest tag>` (Docker Hub) — resolve exact current tag and pin to digest at implementation time; check both publishers' tag lists, they may drift from each other | User-confirmed primary path (§4.1). Single-maintainer/community, no digest known ahead of time — must be resolved live. |
| Container image (**fallback**, only if `vllm-radiance` fails to load any model at all, §4.1) | `rocm/vllm:rocm7.14.1_rdna_ubuntu24.04_py3.14_pytorch_2.11_vllm_0.23.0` (or newer RDNA-tagged release current at implementation time) | Already validated once on this host via the abandoned vLLM repo. Last resort only — using it changes the "Radiance" framing, document if invoked. |
| ROCm (in-container) | Whatever `vllm-radiance`'s pinned base bundles (verify via `cat /opt/rocm*/.info/version` in-container) | Do not attempt to mix a different ROCm userspace into the container. Host ROCm (7.2.2) does not need to match; only the kernel driver (`amdgpu`) does. |
| PyTorch (in-container) | Observed to drift between 2.11.0–2.12 across `vllm-radiance` tags; verify via `python -c "import torch; print(torch.__version__)"` in-container | Volatile even within this one project's own tags — runtime-verify only |
| Triton (in-container) | Observed to drift between 3.6.0–3.7.1 across `vllm-radiance` tags; verify via `pip show triton` in-container | Volatile; runtime-verify only |
| AITER | Bundled; `vllm-radiance` pins AITER 0.1.17–0.1.20 depending on tag. Used for its Triton-kernel FP8 GEMM path (`aiter.ops.triton.*`); its ASM/C++ attention/GEMM kernels are CDNA-only and unsupported on gfx1201 (`ROCm/aiter#3294`) — confirm R4D (not AITER-ASM) or Triton is the effective attention backend actually selected (§8.1). | RDNA4 kernel-support gap is real and documented; misconfiguration causes either a hard failure or (worse) a silent FP32 fallback (§9.2) |
| vLLM (in-container) | `vllm-radiance` pins 0.27.1–0.28.0 depending on tag; verify via `pip show vllm` in-container | Patched on top of an upstream vLLM base by the vllm-radiance maintainer — do not assume it tracks any specific upstream release cleanly |
| `libr4d` (R4D kernel library) | Verify via the running image's asserted `R4D_VERSION` (currently ~0.5.0 upstream at time of writing) | Core to why this stack was chosen (§4.1) — pin explicitly, re-verify at implementation time |
| DFlash2 | Bundled with `vllm-radiance`; version tracks the image tag | Evaluated per §8.2's correctness gate |

**Open question:** exact current `vllm-radiance` tag/digest for both publishers
(`stilldeadcode`, `magiccodingman`) — resolve at implementation time by
listing Docker Hub tags directly; do not assume either is more current than
the other without checking.

### 5.1 Environment variables required for gfx1201 (from verified research + prior art)

```
PYTORCH_ROCM_ARCH=gfx1201
VLLM_ROCM_USE_AITER=1                    # Triton FP8 GEMM path only — verify effective attn backend stays TRITON_ATTN
VLLM_ROCM_USE_AITER_RMSNORM=0
FLASH_ATTENTION_TRITON_AMD_ENABLE=TRUE
ROCBLAS_USE_HIPBLASLT=1
TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1
HIP_VISIBLE_DEVICES=0
```

`HSA_OVERRIDE_GFX_VERSION` is **not** expected to be needed for vLLM (R9700 is
natively detected as gfx1201, unlike some older RDNA cards) — this differs from
the current llama.cpp deployment, which sets `HSA_OVERRIDE_GFX_VERSION=12.0.1`
anyway. Do not carry that override forward by default; keep it as a documented
fallback to try only if gfx-arch detection fails inside the container (§17,
preflight check).

### 5.2 ROCm 10.0.0 note

ROCm 10.0.0 (released 2026-08-26) is the first release whose published hardware
support table explicitly names "AMD Radeon AI PRO R9700/R9700S/R9600D (gfx1201)."
This is a **verified fact** (fetched release notes) but the version-number jump
from the 7.x series to 10.0.0 could not be corroborated against an AMD versioning
changelog — flag as needing a sanity check at implementation time (is this really
the current major version, or a fetch/parsing artifact?).

---

## 6. Model Choice

### 6.1 Verified: "Qwen3.8-27B" is a real, current model

`Qwen/Qwen3.8-27B` (HuggingFace, released August 2026, Apache 2.0) — **this is
the exact model family already running in production on this host via
llama.cpp** (§2.2), which is strong continuity: no new quality/behavior
unknowns from the model itself, only from the serving stack.

- 27B parameters, **dense but architecturally hybrid**: 16 blocks of
  `3×(Gated DeltaNet → FFN) → 1×(Gated Attention → FFN)`, hidden dim 5120, 64
  layers. This is **not** a uniform transformer — most layers are gated linear
  attention (DeltaNet), only every 4th block uses standard gated attention.
- Native context: 262,144 tokens; YaRN-extensible to 1M. 131072 (the task's
  target) is comfortably inside native range, no YaRN needed.
- Benchmarks (per HF card): SWE-bench Pro 61.7, Terminal-Bench 2.1 73.0 — strong
  agentic-coding profile, consistent with why it's already the production choice.
- Sibling model `Qwen/Qwen3.6-27B` also exists (earlier generation, same size
  class) — 3.8 is the newer, better-fit choice; no separate "Coder" variant of
  the 3.8 generation exists.

### 6.2 Critical risk: hybrid Gated-DeltaNet architecture is the actual source of every compatibility bug seen so far on this host

This is the single most important technical risk in this plan and must be
resolved **first**, before investing in FP8 KV cache, speculative decoding, or
R4D tuning:

- The abandoned vLLM repo's rejected `amd/Qwen3.8-27B-Quark-AWQ-INT4-W4A16`
  checkpoint crashed with a real vLLM bug in the Quark quantization loader
  (§2.4) — that repo's own analysis found a *cluster* of open vLLM issues
  across the whole Qwen3.5/3.6/3.8 hybrid-architecture family, "suggesting this
  whole quark+hybrid-attention combination is an immature, actively shifting
  compatibility surface, not one isolated bug."
- llama.cpp's own `docs/known-issues.md` (in the current, working deployment's
  repo) documents an open, unmerged GGUF-conversion bug specifically for the
  `qwen3_5`-family hybrid architecture (llama.cpp#27019).
- R4D's attention-kernel constraints (§4: head_dim=256, 6 query heads per KV
  head, causal-only) are stated in terms of a *uniform* attention layer — it is
  unclear whether/how R4D interacts with DeltaNet layers at all (open question,
  §9.3, §24).

**Design decision:** implementation Phase 0 (§18) is a dedicated smoke test —
load Qwen3.8-27B (any quant) in the chosen vLLM image and confirm it (a) loads
without error, (b) is recognized as a supported architecture
(`Qwen3.5ForConditionalGeneration` or whatever the pinned vLLM version calls
it — verify exact registered name), (c) produces coherent, non-garbage output
for a basic prompt — **before** any further work on quantization tuning, KV
cache, or speculative decoding. If this fails on every quant/image combination
tried, fall back to a known-working profile (§6.4) rather than block the whole
migration.

### 6.3 Quantization: INT4 AutoRound (W4A16) target, verified bake-off methodology required

- BF16: ~56GB — does not fit.
- FP8: ~27GB weights alone, leaving ~5GB for KV+overhead on a 32GB card — too
  tight for 131072 context, and gfx1201's FP8 kernel path has a documented
  silent-fallback trap (§9.2) that must be ruled out before trusting FP8 weight
  throughput numbers at all.
- **INT4 AutoRound (W4A16), target ~20–21GB weights** (a secondary source
  — not HF itself — cites `Qwen3.8-27B-MixedInt4-AutoRound` at ~20.8GB; **the
  exact HF repo id is an open question, §24**, verify it exists and is the
  right quant before pinning). This leaves ~10–11GB for KV cache + activations
  + ROCm overhead inside a 32GB budget, matching the task's rough allocation
  (main model ~18GB, KV cache 8–10GB, runtime 2–3GB, headroom ~1GB).
- AutoRound on gfx1201 reportedly needs a symmetric-GPTQ zero-point kernel fix
  — not confirmed plug-and-play. GPTQ/AWQ-Int4 (compressed-tensors format) are
  more battle-tested on ROCm generally and are exactly the format that worked
  for the abandoned repo's Qwen3.6-27B profile (`cyankiwi/Qwen3.6-27B-AWQ-INT4`,
  compressed-tensors, no loader crash — contrast with the Quark-format
  checkpoint that did crash).

**Design decision (mirrors the abandoned repo's own successful methodology,
`config/models/qwen36-27b.env`'s documented rejection process):** do not
hard-commit to one HF checkpoint id in code before implementation. Instead,
implement a bake-off: download candidate Qwen3.8-27B quantized checkpoints
(AutoRound W4A16 first choice; GPTQ-Int4 and AWQ-Int4/compressed-tensors as
fallbacks), and for each, check `config.json`'s `quantization_config.quant_method`
directly (never infer from the repo name — this exact lesson is already written
down in the sibling repo) and do a real load+generate test. Pick the first that
loads cleanly and passes Phase 0's smoke test. Document the rejected candidates
and why, exactly as `qwen36-27b.env`'s header comment already models.

### 6.4 Fallback / comparison profiles

Keep the two already-proven, already-cached (in `~/.cache/huggingface`, no
re-download needed) profiles from the abandoned vLLM repo available as
`config/models/*.env` profiles in this new repo, unchanged:

- `qwen25-coder-14b` (`Qwen/Qwen2.5-Coder-14B-Instruct-AWQ`) — smaller, known-good,
  useful both as a fast comparison point and as a guaranteed-working fallback if
  Qwen3.8-27B's hybrid architecture turns out to be unsupportable on the chosen
  vLLM pin.
- `qwen3-coder-30b-a3b` (`stelterlab/Qwen3-Coder-30B-A3B-Instruct-AWQ`) —
  MoE, already benchmarked on this host, already has an OpenCode config entry.

These are not the primary target but materially de-risk the plan: if Phase 0
fails for Qwen3.8-27B, the deployment can still ship on a model this exact
container/scripting stack has already proven works.

---

## 7. Context, KV Cache, and GPU Memory Utilization

### 7.1 Context: 131072 tokens (initial target, not maximum)

Matches the already-proven llama.cpp production config (§2.2) and the task's
explicit target. Do not chase Qwen3.8-27B's full 262144 native window (or
1M via YaRN) in the initial deployment — that's an explicit later tuning
exercise (task requirement), not a v1 requirement. Fallback ladder if 131072
doesn't fit the VRAM budget at the chosen quant: 98304, then 65536, then 32768
— same style of ladder the sibling repo used for its own profile.

### 7.2 KV cache: FP8 target, explicitly gated behind validation

FP8 KV cache on gfx1201 is **experimental, not confirmed working in stock vLLM**:
one source states vLLM's FP8-KV code path assumes FlashAttention-3 (Hopper) or
FlashInfer (Blackwell) kernels, neither ported to RDNA4. `vllm-radiance`'s R4D
backend treats FP8 (or bf16) KV cache as a *requirement of using R4D specifically*
— i.e. FP8 KV cache support may currently only exist as a side effect of the
R4D backend (§8.1), not as a standalone vLLM+ROCm feature. Since R4D is now
attempted in Phase 1 (§4.1), this pairs naturally rather than requiring a
separate later phase — but if R4D doesn't engage for this model (§8.1
fallback), FP8 KV cache may not be available either, in which case fall back
to model-default KV cache dtype per the correctness gate below.

**Design decision (user-confirmed 2026-09-14 — target full spec immediately):**
the deployment launches with `KV_CACHE_DTYPE=fp8` from the first real deploy
attempt (Phase 1), not deferred behind a stable-baseline gate. Since the
primary image is now `vllm-radiance` (§4.1), and that project states FP8 (or
bf16) KV cache is a *requirement* of its R4D backend, this pairs naturally
with attempting R4D first. **This does not relax the correctness bar** — FP8
KV cache still gets the same explicit output-quality check (not just a
throughput number) via the same known-answer/tool-call-determinism style
checks ported from the llama.cpp repo's `validate-model.sh` (§11.2), run
*before* Phase 1 is considered done, not as an afterthought. If FP8 KV cache
fails that check on the `vllm-radiance` image, fall back to unset
(model-default) KV cache dtype for the shipped configuration and document why
— this is a correctness gate, not a scope negotiation, and failing it does
not mean retrying with a "safer" deferred-timeline approach.

### 7.3 GPU memory utilization: 0.968 target, empirically tuned, not trusted blindly

The task's ~96.8% target assumes the host is fully headless — verified true
(§2.3: no desktop workload budget needed). But the abandoned repo's own
measurements on this exact GPU found **real VRAM usage running consistently a
few GiB over the nominal `GPU_MEMORY_UTILIZATION` percentage** (0.68 nominal →
23.88GiB real, not the naive 21.76GiB), attributed to graph-capture buffers and
allocator overhead vLLM's own accounting doesn't include.

**Design decision (user-confirmed 2026-09-14 — target full spec immediately):**
start the very first deploy attempt at `GPU_MEMORY_UTILIZATION=0.968`, the
task's literal target, rather than sweeping up from a conservative starting
point. **This does not remove the measurement requirement** — still reuse the
abandoned repo's exact methodology of measuring *real* `rocm-smi`/`amd-smi`
VRAM usage (not vLLM's own log line) immediately after first successful load,
because that repo's own data shows real usage running a few GiB over nominal.
If real usage at 0.968 leaves less than ~1GB headroom (i.e. risks OOM under
load, not just at idle), back off in small steps (0.95, 0.93, ...) until real
measured headroom is safely positive — this is a safety floor, not a
preference, on a single GPU with no multi-GPU fallback. Record whatever value
actually ships, and why, in `docs/TUNING.md`.

### 7.4 Host RAM limit (cgroup) — carry forward, not optional

The abandoned repo hit a **real host lockup**: unconstrained container host-RAM
growth (CPU-staged weights, ROCm/PyTorch host buffers, `ipc: host` shm) fed a
kernel OOM-killer cascade requiring a hard power cycle. `MEM_LIMIT`/
`MEM_RESERVATION` cgroup limits (observed steady-state ~19.8GiB for the 14B
profile, so budget higher for 27B — start at `MEM_LIMIT=32g`,
`MEM_RESERVATION=26g`, tune from real measurement) are a **required** part of
the compose design in this plan, not optional hardening (§10.3).

---

## 8. Attention Backend & Speculative Decoding

### 8.1 Attention backend: Triton (`TRITON_ATTN`/`ROCM_ATTN`), default

Verified: AMD's AITER ASM/C++ attention kernels (`ROCM_AITER_FA`/`ROCM_AITER_MLA`)
target CDNA/datacenter GPUs (MI300X/MI325X/MI355X) and are **not supported on
RDNA**. vLLM's own blog and source describe `TRITON_ATTN`/`ROCM_ATTN` as "useful
for consumer hardware deployments where AITER primitives aren't available" — this
is the closest thing to an official default for gfx1201 in stock vLLM, and
active upstream work (`vllm-project/vllm#54440`) is making backend
auto-selection RDNA-aware. **Design decision:** do not force AITER attention;
verify (via startup logs) that the effective backend selected is
`TRITON_ATTN`, and treat any other auto-selected backend as a bug to
investigate, not a lucky win.

**Updated per §4.1 (user-confirmed 2026-09-14):** R4D is attempted **first**,
in Phase 1, not deferred. Verify Qwen3.8-27B's Gated-Attention sublayers
against R4D's stated constraints (head_dim=256, 6:1 query:kv-head ratio,
causal-only) by inspecting the model's actual `config.json` — do not guess.
If R4D does not engage (constraint mismatch, or no support for the DeltaNet
layers that make up most of this model — open question, §9.3/§24), fall back
to `vllm-radiance`'s standard attention path (Triton, per the general RDNA4
guidance above) while staying on the `vllm-radiance` image — this exact
fallback behavior was user-confirmed (§4.1), not assumed.

### 8.2 Speculative decoding: `ngram` baseline, DFlash/DFlash2 explicitly experimental

Verified: vLLM currently supports `ngram`, `suffix`, `eagle`/`eagle3`, `mtp`
(native + Gemma-4 variant), `draft_model`, `medusa`, `pard`, `mlp`, and
`dflash`/`dspark`. The only methods with *any* AMD-hardware validation (vLLM's
own 2026-08-23 blog, "Exploring Speculative Decoding in vLLM on AMD GPUs") were
tested exclusively on **MI300X/MI355X (CDNA/datacenter)** — zero mention of
RDNA4, gfx1201, or R9700 anywhere in that post. DFlash2 specifically (the
Radiance-branded variant) is documented by its own maintainer as failing strict
greedy/tool-call equivalence.

llama.cpp's current production config uses self-speculative MTP
(`draft-mtp`/`LLAMA_ARG_SPEC_DRAFT_N_MAX=2`) — this is llama.cpp-specific
infrastructure (the model provides its own draft head), **not directly
portable** to vLLM's speculative-decoding config, which expects either a
separate draft model, an n-gram/suffix lookup, or a method-specific integration
(EAGLE/Medusa/MTP-as-vLLM-implements-it, which may or may not be the same MTP
mechanism this checkpoint ships).

**Design decision (user-confirmed 2026-09-14 — target full spec immediately):**
DFlash2 is attempted **first**, in Phase 1, against the same strict
greedy/tool-call output-equivalence bar `vllm-radiance`'s own maintainer
reports it failing (§4). This is a correctness gate, not a timeline gate —
run it early precisely because a failure here is likely (per the maintainer's
own stated results) and needs to be known before Phase 2's validation
matrix, not discovered late. If DFlash2 fails the equivalence check, ship
without speculative decoding, or with `ngram` (zero hardware-specific kernel
dependency) if a quick evaluation shows a real win — document the DFlash2
failure and why in `docs/TUNING.md`, exactly as the abandoned repo documents
its own rejected-checkpoint decisions.

---

## 9. Known Single-R9700/gfx1201 Limitations (verified)

### 9.1 Bimodal decode throughput bug (open, unresolved upstream)

`ROCm/ROCm#6347`: decode throughput on R9700 sticks at either ~33 tok/s or
~26 tok/s, determined randomly at HIP process init, not recoverable without a
full container/process restart; forcing GPU performance-level pinning does not
help. **Operational implication:** any benchmark or health check that measures
throughput must account for this — a single benchmark run reading "slow" could
mean either a real regression or just an unlucky init roll. Design the
benchmark script (§21) to note current throughput against both known bands and
flag (not fail) if within the ~26 tok/s band, with "try restarting the
container" as the first troubleshooting step in the runbook.

### 9.2 FP8 silent-fallback trap

`ROCm/aiter#3294` / `ROCm/TransformerEngine#520`: gfx1201 was, at least at one
point, missing from AITER's architecture table, causing a **silent** FP32
dequantization fallback for FP8 kernels — no error, no warning, just ~2× worse
throughput than expected (18–22 tok/s instead of 35–40 tok/s in one report).
**Any FP8 (weights or KV cache) throughput number must be cross-checked against
this failure mode** — verify the effective kernel path via logs/profiling, not
just "it produced correct output at a plausible-looking speed."

### 9.3 Container startup issues on RDNA4

`vllm-project/vllm#40081`: reported `amdsmi` init failures inside containers on
gfx1201 (missing sysfs/hwmon paths), cascading into `torch.cuda.device_count()
== 0` — seen under k3s/podman in that report, not confirmed (or ruled out) under
plain `docker compose` (this host's actual runtime). Preflight (§17) and Phase 0
(§18) must explicitly check `torch.cuda.device_count() > 0` (or vLLM's ROCm
equivalent) inside the container as a first-class smoke test, not assume it from
`docker inspect` succeeding.

### 9.4 Single-GPU is the least-validated topology in the ecosystem

Restated from §4: the most actively-tested community stack for this exact GPU
(`vllm-radiance`) only claims qualification for 2×R9700. Budget real
in-house qualification time for single-GPU — do not assume "the community has
already solved this."

---

## 10. Container Design

### 10.1 Compose service (baseline)

Modeled directly on the abandoned repo's already-working `compose.yaml`
(§2.4), with these changes: container/service name `radiance-vllm` (not
`vllm`), port mapping `${API_PORT:-8080}:8000` (was `8000:8000` — internal
port stays 8000, host port becomes 8080 to preserve the external endpoint, per
task requirement), `MEM_LIMIT`/`MEM_RESERVATION` raised for the 27B model class,
gfx1201 env vars from §5.1 added.

```yaml
services:
  radiance-vllm:
    image: ${VLLM_IMAGE}                 # pinned digest, see VERSIONS
    container_name: ${CONTAINER_NAME:-radiance-vllm}
    restart: ${RESTART_POLICY:-unless-stopped}
    devices:
      - /dev/kfd
      - /dev/dri
    group_add:
      - "${VIDEO_GID:-video}"
      - "${RENDER_GID:-render}"          # numeric GID override required — see §12.4 known failure
    security_opt:
      - seccomp=unconfined               # required by ROCm, matches existing convention
    ipc: host
    mem_limit: ${MEM_LIMIT:-32g}
    mem_reservation: ${MEM_RESERVATION:-26g}
    env_file:
      - .env
      - config/models/${MODEL_PROFILE}.env
    environment:
      - HF_HOME=/root/.cache/huggingface
      - PYTORCH_ROCM_ARCH=gfx1201
      - VLLM_ROCM_USE_AITER=1
      - VLLM_ROCM_USE_AITER_RMSNORM=0
      - FLASH_ATTENTION_TRITON_AMD_ENABLE=TRUE
      - ROCBLAS_USE_HIPBLASLT=1
      - TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1
    volumes:
      - ${HF_CACHE_DIR}:/root/.cache/huggingface
      - ${VLLM_CACHE_DIR}:/root/.cache/vllm
    ports:
      - "${API_BIND_ADDRESS:-0.0.0.0}:${API_PORT:-8080}:8000"
    command: >
      sh -c '
        exec vllm serve "$$MODEL_ID" \
          --served-model-name "$$SERVED_MODEL_NAME" \
          --host 0.0.0.0 \
          --port 8000 \
          --max-model-len "$$MAX_MODEL_LEN" \
          --gpu-memory-utilization "$$GPU_MEMORY_UTILIZATION" \
          $${QUANTIZATION:+--quantization "$$QUANTIZATION"} \
          $${KV_CACHE_DTYPE:+--kv-cache-dtype "$$KV_CACHE_DTYPE"} \
          $${TOOL_CALL_PARSER:+--enable-auto-tool-choice --tool-call-parser "$$TOOL_CALL_PARSER"} \
          $${REASONING_PARSER:+--reasoning-parser "$$REASONING_PARSER"} \
          $${SPEC_DECODE_ARGS} \
          --enable-prefix-caching \
          $$EXTRA_VLLM_ARGS
      '
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:8000/v1/models"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 1800s   # 27B cold-load is slower than the 14B's measured 13min; widen further if observed
```

(Same doubled-`$$`/line-continuation-backslash discipline as the abandoned
repo's compose file — that repo documented a real, live-verified failure mode
on scar.lab where dropping the trailing backslash silently truncated the
`vllm serve` command mid-flag-list. Preserve exactly.)

### 10.2 Device/GID handling

Verified failure mode (§2.4 ROCM.md): `group_add: [video, render]` **by name**
fails on this image family — the container's own `/etc/group` doesn't
necessarily define `render`. Resolve `VIDEO_GID`/`RENDER_GID` numerically via
`getent group video render` on the host at deploy time (script responsibility,
not left to the compose file's `:-render` fallback alone) — this repo's
`scripts/deploy.sh` must replicate the llama.cpp repo's `deploy.sh` numeric-GID
resolution logic.

### 10.3 Host memory limit — required, not optional

`MEM_LIMIT`/`MEM_RESERVATION` cgroup values, justified in §7.4. Document the
real lockup incident in the `.env.example` comment, exactly as the abandoned
repo does — this is safety-critical institutional knowledge, not boilerplate.

### 10.4 Mounts

- `HF_CACHE_DIR` → `/root/.cache/huggingface` — see §13 for the storage-location
  design decision (system path vs. reusing existing `~/.cache/huggingface`)
- `VLLM_CACHE_DIR` → `/root/.cache/vllm` — torch.compile/graph-capture cache,
  persisted across restarts (the abandoned repo measured this saves ~1 minute
  of recompile per restart for the 14B profile; expect more for 27B)
- No log-file mount needed initially — `docker logs radiance-vllm` and the
  compose project's log driver are sufficient, matching every other container
  on this host (none of them bind-mount a log directory)

### 10.5 What this design deliberately does NOT do

- No `privileged: true`
- No Docker socket mount (unlike the dashboard, which needs it for lifecycle
  actions — the inference container itself has no need to control other
  containers)
- No AppArmor profile customization (§2.3 — no host precedent, no known need)
- No SELinux changes (not applicable on this host)

---

## 11. Installer Design

### 11.1 Layout (mirrors both sibling repos' proven conventions)

```
Radiance-vLLM-AMD-R9700/
├── install.sh                    # top-level orchestrator: preflight -> deploy
├── uninstall.sh                  # stop + remove container/image, optionally purge cache (guarded)
├── healthcheck.sh                # thin wrapper around scripts/status.sh
├── VERSIONS                      # pinned image digest + rationale, single source of truth
├── .env-template                 # copy to .env; no secrets committed
├── .shellcheckrc
├── .pre-commit-config.yaml       # same hook set as sibling repos (§11.4)
├── .pymarkdown.json
├── .secrets.baseline
├── config/
│   └── models/
│       ├── qwen38-27b.env            # primary target (§6.3)
│       ├── qwen25-coder-14b.env      # fallback, reused from abandoned repo (already cached)
│       └── qwen3-coder-30b-a3b.env   # fallback, reused from abandoned repo (already cached)
├── compose.yaml
├── scripts/
│   ├── lib/common.sh             # ported from abandoned repo's scripts/lib/common.sh
│   ├── preflight.sh              # §17
│   ├── deploy.sh                 # profile resolution, GID resolution, compose up, calls validate-model.sh
│   ├── start.sh / stop.sh / status.sh / logs.sh
│   ├── download-model.sh         # resumable, checksummed — ported pattern from llama.cpp repo (§11.2)
│   ├── validate-model.sh         # postflight guardrails — see §11.2, §18
│   ├── restore-or-shutdown.sh    # ported directly from llama.cpp repo — see §11.2
│   ├── verify-versions-pin.sh    # VERSIONS <-> compose.yaml digest match, pre-commit hook
│   ├── check-image-pins.sh       # reused as-is if possible (shared "coding standards" hook across repos)
│   ├── cutover.sh                # §3.1 Phase B: stop+disable llamacpp, recreate radiance-vllm on :8080
│   ├── rollback.sh                # §19: stop radiance-vllm, restart llamacpp, verify
│   ├── test-tool-calling.sh      # ported from abandoned vLLM repo, extended for streaming (already covers it)
│   ├── benchmark.sh              # ported from abandoned vLLM repo (two-phase TTFT/throughput design)
│   ├── configure-opencode.sh     # ported, updated for stable served-model-name + :8080
│   └── configure-pi.sh           # new — PI has no existing configurator in the abandoned repo, only in Agentic-Tooling-Local-Lab
├── tests/
│   └── deploy.bats               # ported/adapted from llama.cpp repo's bats suite
└── docs/
    ├── ROCM.md                   # ported + updated from abandoned repo, with §4/§9's new findings folded in
    ├── MODELS.md                 # quantization bake-off results (§6.3), once run
    ├── TUNING.md                 # GPU_MEMORY_UTILIZATION sweep results (§7.3), once run
    ├── OPENCODE.md
    └── runbook.md                # rollback procedure (§19), bimodal-throughput workaround (§9.1)
```

### 11.2 Rollback/state pattern — ported directly, not reinvented

The llama.cpp repo's `scripts/restore-or-shutdown.sh` pattern (§2 discovery: a
state file at `$(dirname MODELS_DIR)/state/current-profile`, written only
after `validate-model.sh` passes, with automatic restore-to-last-known-good on
a failed deploy, and `docker compose down` — never a lingering
unhealthy-but-`restart:unless-stopped` container — as the final fallback) is
directly applicable and should be ported with minimal changes: same state-file
location convention (`/var/lib/radiance-vllm/state/current-profile`, §13),
same `DEPLOY_IS_RESTORE=1` recursion guard, same "bring it down rather than
leave it broken" philosophy. This is the single most valuable piece of prior
art in this whole migration for the rollback requirement (§19).

`validate-model.sh` should be adapted (not copied verbatim — the checks
differ): VRAM postflight via `rocm-smi`/`amd-smi` (same idea, vLLM's actual
usage numbers differ from llama.cpp's), and the tool-call-determinism check
(3 trials, prefix-caching on/off, across a restart) ported almost as-is since
it's testing an OpenAI-compatible API surface, not llama.cpp internals — good
overlap with §20's tool-calling validation requirement.

### 11.3 Staging vs. cutover port handling

`scripts/deploy.sh` (Phase A, staging) and `scripts/cutover.sh` (Phase B) share
the same compose file but different `API_PORT` — implement via a `.env`
override the cutover script edits explicitly (with a confirmation prompt/flag,
since this is the action that takes llama.cpp's port away), not two divergent
compose files. `scripts/rollback.sh` is the inverse: stop `radiance-vllm`,
`docker compose up -d` (or `docker start`) `llamacpp` from its own untouched
repo/`.env`, verify `/v1/models` responds on 8080 again.

### 11.4 Lint/test tooling — match host convention exactly

Every sibling repo on this host uses the same stack: pre-commit-hooks
(yaml/json/toml/merge-conflict/large-files/eof/trailing-ws/shebang/private-key),
detect-secrets with `.secrets.baseline`, yamlfmt, ruff+ruff-format (for any
Python — e.g. `benchmark-support.py`-style helper scripts if needed), shellcheck
+ shfmt (`-i 2 -ci -sr`), pymarkdown (excluding `WORKLOG.md`). `.shellcheckrc`
should disable SC1091 (dynamic source paths) and SC2016/SC2031 if bats tests are
used, matching the llama.cpp repo's rationale exactly. Do not introduce a
different toolchain (e.g. no Python linter substitution, no alternate shell
formatter) — this is a hard convention across every repo inspected.

### 11.5 Version pin verification

`scripts/verify-versions-pin.sh`, run as a pre-commit hook scoped to
`^(VERSIONS|compose\.yaml)$`, asserting the digest in `VERSIONS` and the
digest hardcoded in `compose.yaml`'s `image:` line never drift apart — same
mechanism as the llama.cpp repo, same rationale (a reviewed digest should
never silently change). `scripts/check-image-pins.sh` (the more general
floating-tag check shared across repos as a "coding standards" local hook)
should be reused verbatim if its implementation is generic enough, rather than
reimplemented.

---

## 12. Configuration Files

### 12.1 Container runtime: Docker, not Podman

The task prompt suggests "Podman if that matches current host/repo
conventions." **Verified: it does not.** `podman` is not installed on scar.lab;
`docker` is, and every single existing container (llamacpp, dashboard, Hermes,
docker-socket-proxy) runs under Docker via `docker compose`. This plan uses
Docker Compose, matching actual host convention over the task prompt's
suggestion — the task itself says to favor "Podman *if* that matches
current host/repo conventions," and it doesn't.

### 12.2 `.env-template` (top-level, no secrets)

Mirrors the abandoned vLLM repo's `.env.example` structure closely (already a
well-designed template — reuse its comments describing *why* each value is
set, not just restate variable names):

```
DEFAULT_MODEL_PROFILE=qwen38-27b
VLLM_IMAGE=rocm/vllm@sha256:<pinned digest — see VERSIONS>
API_PORT=8081                     # staging default; cutover.sh changes this to 8080
API_BIND_ADDRESS=0.0.0.0
HF_CACHE_DIR=/var/lib/radiance-vllm/hf-cache      # see §13 — system path, not ~/.cache
VLLM_CACHE_DIR=/var/lib/radiance-vllm/vllm-cache
HUGGING_FACE_HUB_TOKEN=
CONTAINER_NAME=radiance-vllm
RESTART_POLICY=unless-stopped
MEM_LIMIT=32g
MEM_RESERVATION=26g
# VIDEO_GID / RENDER_GID resolved automatically by deploy.sh; override here only if resolution fails
```

### 12.3 `config/models/qwen38-27b.env` (shape, values pending bake-off §6.3)

```
MODEL_ID=<pending bake-off — see docs/MODELS.md>
SERVED_MODEL_NAME=scar-coder          # stable name — see §14
MAX_MODEL_LEN=131072                  # fallback ladder: 98304, 65536, 32768 if VRAM doesn't fit
GPU_MEMORY_UTILIZATION=0.92           # starting sweep point — see §7.3, tune from real measurement
QUANTIZATION=                         # leave empty unless bake-off shows the checkpoint needs it forced
KV_CACHE_DTYPE=                       # empty = model default; fp8 is a Phase-5-adjacent tuning experiment, see §7.2
TOOL_CALL_PARSER=hermes               # best-guess default — verify against tokenizer_config.json, see §24
REASONING_PARSER=qwen3                # verified current name for the Qwen3 family
SPEC_DECODE_ARGS=                     # empty baseline; ngram trial values go here if adopted, see §8.2
EXTRA_VLLM_ARGS=--trust-remote-code
```

### 12.4 Known failure mode to preflight/handle explicitly

`group_add` by name (`video`/`render`) is confirmed to fail on this image
family if the container's base OS lacks a `render` group entry — resolve
numeric GIDs on the host and pass them explicitly (§10.2); do not rely on the
compose file's name fallback alone.

---

## 13. Model Acquisition & Storage

**Design decision:** unlike the abandoned vLLM repo (which used
`${HOME}/.cache/huggingface`, appropriate for a workstation-era host), this
plan follows the **current** production convention established by the
llama.cpp deployment: a dedicated system path under `/var/lib/<service-name>/`,
consistent with the host's new "dedicated inference server" role (task
framing) and with `/var/lib/llamacpp/{models,state,benchmarks}`.

- `HF_CACHE_DIR=/var/lib/radiance-vllm/hf-cache` (HF Hub cache-format
  directory — vLLM/`transformers` respect `HF_HOME`/`HF_HUB_CACHE` pointing
  anywhere; no requirement it live under a user's home directory)
- `VLLM_CACHE_DIR=/var/lib/radiance-vllm/vllm-cache`
- `state/` and `benchmarks/` directories alongside, matching the llama.cpp
  layout exactly, for the restore-or-shutdown state file (§11.2) and benchmark
  output (§21)
- Lands on `/var/lib`'s filesystem (`sdc1`, 880G total, 559G free at time of
  writing) — separate from both `/home` and `/`, plenty of headroom for
  several quantized-checkpoint candidates during the bake-off (§6.3)

**Implementation task, not yet done:** the existing ~25GB in
`~/.cache/huggingface/hub` (the 14B and 30B-A3B fallback profiles' weights,
§2.3) should be migrated into the new location (`rsync --remove-source-files`
or a symlink bridge) rather than re-downloaded, since those checkpoints are
kept as fallback profiles (§6.4). Document this as an explicit one-time
migration step in `install.sh`, not silent/automatic (moving files out of a
user's home directory without confirmation is exactly the kind of action that
needs a visible step, even if low-risk).

Disk-space preflight (§17) must check free space on `/var/lib`'s filesystem
specifically (not `/` or `/home`, which are different filesystems on this
host) before any download.

Model downloads: automated via `huggingface_hub`'s snapshot-download
mechanics (vLLM/HF handle this natively given `HF_HOME`/token env vars — no
custom download script needed for HF-hosted checkpoints, unlike llama.cpp's
GGUF single-file `download-model.sh`, which exists because GGUF files aren't
naturally HF-cache-aware). A thin `scripts/download-model.sh` wrapper that
pre-stages the resolved profile's `MODEL_ID` (so the first `docker compose up`
isn't also the first download, keeping `start_period`/healthcheck timing
predictable) is still worth having, mirroring the *purpose* of the llama.cpp
script even though the mechanism differs.

---

## 14. Endpoint Preservation & Stable Served Model Name

- External endpoint stays `http://scar.lab:8080/v1` after cutover (Phase B,
  §3.1) — verified as achievable via container port mapping
  (`${API_PORT:-8080}:8000`), no downstream URL changes required.
- **Design decision:** adopt `scar-coder` as the stable `--served-model-name`,
  independent of whatever the actual underlying HF checkpoint is. Directly
  motivated by the verified §2.5 finding that OpenCode/PI both hardcode the
  model id at configure-time and never re-discover it at runtime — a stable
  name means the *only* time this needs revisiting after this migration is
  never, regardless of future model/quant swaps, as long as the name itself
  doesn't change.
- Implementation must still re-run `configure-opencode.sh`/`configure-pi.sh`
  exactly once at cutover (§2.5), updating: OpenCode's provider entry (likely
  renaming/repointing the existing `scar-vllm` entry from `:8000` to `:8080`,
  model key from `qwen3-coder-30b-a3b` to `scar-coder`) and PI's
  `models.json` (`local-lab-llama` provider's model id, or a new provider
  entry — decide which at implementation time based on whether keeping the
  llama.cpp-era provider name is confusing once it's actually serving vLLM).
- Hermes needs **no reconfiguration** — it auto-detects the model from
  `/v1/models` and doesn't hardcode an id (verify this behavior explicitly in
  Phase 6/validation, §17, rather than only trust the `.env.example` comment
  claiming it).

---

## 15. Service Lifecycle

- **Start:** `scripts/start.sh [profile]` → `scripts/deploy.sh` → resolves
  profile, resolves numeric GIDs, `docker compose up -d`, waits on healthcheck,
  runs `validate-model.sh`, writes state file on success (§11.2)
- **Stop:** `scripts/stop.sh` → `docker compose stop` (not `down`, unless
  explicitly uninstalling — `stop` preserves the container for a fast restart
  and is sufficient to prevent `restart:unless-stopped` from reactivating it,
  same reasoning as llama.cpp's own rollback design, §19)
- **Status:** `scripts/status.sh` → container health, current profile (state
  file), quick `/v1/models` reachability check
- **Logs:** `scripts/logs.sh` → `docker compose logs -f`, no separate log file
  management (matches host convention, §10.4)
- **Restart policy:** `unless-stopped`, identical semantics to every other
  container on this host — no systemd unit, no cron/timer (§2.3)
- **Healthcheck:** `curl -fsS http://localhost:8000/v1/models` in-container,
  generous `start_period` (§10.1) given a 27B cold load is slower than the
  14B's measured ~13 minutes

---

## 16. Preflight Checks

`scripts/preflight.sh`, extending the abandoned repo's already-solid
`preflight.sh` (§2.4) with migration-specific additions:

Ported as-is (already implemented, already correct for this host):
OS check (warn-only), Docker + `docker compose` plugin present, `/dev/kfd`/
`/dev/dri` presence + `renderD*` node count, device owner:group, `video`/
`render` group existence + current-user membership, `rocminfo` gfx-arch match
against `gfx1201` (hardcoded expected value), `rocm-smi` VRAM query, disk space
at the HF cache path (raise the threshold — 27B-class checkpoints need more
than the original 30GiB warning floor), HF cache dir existence.

New for this migration:
- **Port 8080 owner check:** confirm what currently holds 8080 (`llamacpp`,
  expected) before any cutover action — refuse to proceed with cutover if
  something unexpected is bound there
- **llama.cpp container existence + health check:** confirm `llamacpp`
  container exists and is the expected image/config before disabling it —
  refuse cutover if it's missing entirely (nothing to roll back to)
- **Dashboard reachability check:** confirm `:8088` is up (informational,
  non-blocking — dashboard changes are the companion plan's scope, not this
  one's)
- **`/var/lib` free space check** (distinct filesystem from `/` and `/home` on
  this host — §2.3), not the `/home`-based check the abandoned repo used
- **In-container GPU visibility smoke test** (§9.3): after first container
  start, before declaring preflight/deploy successful, explicitly check
  `torch.cuda.device_count() > 0` (or vLLM's ROCm-equivalent check) inside the
  container — do not assume `docker inspect` health implies GPU visibility
- **Existing model-cache migration check** (§13): detect the ~25GB already in
  `~/.cache/huggingface` and offer (not force) migration into
  `/var/lib/radiance-vllm/hf-cache`

All checks remain **read-only** during preflight itself — no modification
happens until an explicit `deploy`/`cutover` step, matching the abandoned
repo's preflight philosophy exactly.

---

## 17. Security Considerations

- No new attack surface beyond what the existing llama.cpp container already
  exposes: LAN-bound (`0.0.0.0:8080`), no API key today (matches existing
  convention — task doesn't request adding auth, and adding it unilaterally
  would break every existing client silently; treat as an **open question**
  for the user, not a unilateral change, §24)
- Minimal device passthrough (`/dev/kfd`, `/dev/dri` only), no `privileged`,
  no Docker socket in the inference container (unlike the dashboard)
- `seccomp=unconfined` required by ROCm — same as the existing llama.cpp
  container, not a new exposure
- No SELinux on this host (§2.3) — nothing to configure, nothing to disable
- No secrets in any committed file — `HUGGING_FACE_HUB_TOKEN` stays in
  `.env` (gitignored), never logged, matching every sibling repo's stated
  convention
- `detect-secrets` + `.secrets.baseline` in pre-commit, matching host
  convention (§11.4)

---

## 18. Implementation Phases

**Phase 0 — Architecture smoke test (before any other work):** in the
`vllm-radiance` container (§4.1, primary image), load Qwen3.8-27B (any
available quant, doesn't need to be the final bake-off winner) and confirm it
loads, is recognized as a supported architecture, and generates coherent
output. This resolves §6.2's central risk before any further investment. If
it fails across every tried quant on `vllm-radiance` specifically (but the
image itself runs), fall back to §6.4's known-working profiles. If the
`vllm-radiance` image itself fails to run at all on this host (§9.3), fall
back to the official `rocm/vllm` image per §4.1's last-resort clause and
document the change explicitly.

**Phase 1 — Full-spec deployment on staging port:** repo scaffolding (§11),
compose design (§10) targeting `vllm-radiance` with R4D attention attempted
first (§8.1), DFlash2 speculative decoding attempted first (§8.2), FP8 KV
cache (§7.2), and `GPU_MEMORY_UTILIZATION=0.968` (§7.3) — all from the first
deploy attempt, per the user's confirmed rollout posture. Deploy on staging
port 8081 alongside the still-live `llamacpp` on 8080 — the aggressive
config target does not change the staged-cutover safety design (§3.1); it
changes what gets attempted first, not whether production is protected
during validation. No production traffic risk during this phase.

**Phase 2 — Functional + tool-calling validation (§20):** full API surface
test matrix against the staging deployment, including the FP8-KV-cache and
DFlash2 correctness checks (§7.2, §8.2) as hard gates before proceeding.

**Phase 3 — Benchmarking (§21):** compare against llama.cpp's already-recorded
baseline reports (`Containerized-llamma.ccp-AMD-9700/performance/reports/`).

**Phase 4 — Cutover (§3.1 Phase B):** disable llama.cpp autostart, stop it,
recreate `radiance-vllm` on 8080, re-run Phase 2's smoke subset against the
production port, update OpenCode/PI config (§14), verify Hermes still works
unmodified. **Per user direction (2026-09-14), this phase proceeds
autonomously** — see §25 for the exact authorization scope and the
automatic-rollback safety net this plan relies on given no human checkpoint
is required here.

**Phase 5 — Hardening & documentation:** finalize `docs/`, confirm rollback
procedure end-to-end (not just on paper — actually run it once), hand off to
the observability plan's integration work. (What was previously a separate
"optional Radiance layer" phase is now folded into Phase 0–2 above, per §4.1.)

---

## 19. Rollback

**Trigger:** any Phase 2–4 validation failure that can't be quickly fixed, or
a post-cutover production issue.

**Procedure:**
1. `scripts/rollback.sh` (or manual equivalent):
   `docker compose -f <radiance-vllm compose> stop` (container preserved,
   restart policy inert since it was a manual stop — same mechanism the
   llama.cpp repo already relies on, §11.2)
2. `docker compose -f ~/Workspace/Git/Containerized-llamma.ccp-AMD-9700/docker-compose.yaml --env-file <that repo's .env> up -d`
   (or `docker start llamacpp` if the container object still exists and wasn't
   removed) — **zero config changes needed**, since llama.cpp's repo/container
   was never touched by this migration (§2.4's core design constraint)
3. Verify: `curl http://scar.lab:8080/v1/models` returns the llama.cpp model
   entry; confirm OpenCode/PI (if their config was already switched during a
   completed cutover) are pointed back appropriately — note this is the one
   place a completed cutover's client-config change needs a matching rollback
   step, tracked explicitly in `scripts/rollback.sh`'s checklist output, not
   left implicit
4. Document the rollback event (what triggered it) in this repo's `WORKLOG.md`,
   matching sibling-repo convention

**What rollback does NOT require:** reinstalling llama.cpp, restoring from
backup, or any destructive recovery — because nothing about llama.cpp's
config/container/model files was ever modified by this plan (hard requirement,
satisfied by design throughout §3, §10, §19).

---

## 20. Validation

Functional (Phase 2, staging port; re-run subset at Phase 4, production port):

- `GET /v1/models` — returns `scar-coder` (or the pre-cutover served name)
- `POST /v1/chat/completions` — non-streaming, basic correctness
- `POST /v1/completions` — legacy completion endpoint
- `GET /metrics` — Prometheus output present, sane values (feeds the
  observability plan directly)
- **Streaming** — both `/v1/chat/completions` and `/v1/completions` with
  `stream: true`, verify SSE chunk assembly is correct
- **Tool calling**, ported from the abandoned repo's `test-tool-calling.sh`
  (already covers all of this, §2.4): single call, call with specific
  arguments, sequential calls (call → tool-result → follow-up), multiple
  calls in one turn, call-then-normal-response, **streamed tool calls**
  (assemble `tool_calls[].function.arguments` across SSE deltas by index,
  verify `finish_reason == "tool_calls"`, verify concatenated arguments parse
  as JSON) — plus an explicit check that tool-call syntax never leaks into
  `message.content` as plain text (documented real failure mode for some Qwen
  tool-call parsers, §5.1/§24)
- **Long-running agent workflow** — a multi-turn session exercising several
  sequential tool calls plus continued generation after tool results, not
  just isolated single-call tests
- **128K-context stability** — a real long-context prompt (not synthetic
  padding) processed successfully at the configured `MAX_MODEL_LEN`
- **FP8 KV cache correctness** (if adopted per §7.2) — output-quality
  comparison against non-FP8 baseline, not throughput alone

Real coding validation (Phase 4+, via OpenCode and PI on raptor.lab, task
requirement — benchmarking alone is explicitly insufficient):
repository exploration, large context injection, code generation, code
modification, tool calls, shell/tool output round-trips, multiple turns,
repeated prompts (prefix-caching effectiveness), long conversations, streaming
— all through the actual downstream harnesses, not synthetic API calls.

---

## 21. Benchmarks

Reuse the abandoned repo's `scripts/benchmark.sh` methodology directly: two-phase
design (TTFT via streaming + `curl`'s `time_starttransfer`, throughput/latency
via non-streaming using the API's own `usage` field), deliberately separate
wall-clocks per phase (that repo found a shared-clock version silently halved
measured throughput — a real, caught-live bug, not a hypothetical). Output
format: `benchmarks/results/<ts>_<profile>_c<N>_p<N>.json` + `results.csv`,
matching existing convention for cross-run comparability.

Compare directly against llama.cpp's already-recorded baseline reports at
`Containerized-llamma.ccp-AMD-9700/performance/reports/llamacpp__qwen3.8-27b-*`
— same model family, same host, same GPU, making this the most apples-to-apples
comparison available. Metrics: TTFT, prompt processing throughput, decode
tokens/sec, end-to-end latency, VRAM utilization (real, not nominal), KV-cache
utilization, long-context stability, tool-call reliability, speculative
decoding acceptance/effectiveness (if DFlash2 or `ngram` is shipped, §8.2).
Cross-check every
throughput number against the known bimodal-decode-speed bug (§9.1) and the
FP8 silent-fallback trap (§9.2) before treating it as representative.

---

## 22. Acceptance Criteria

Primary deployment considered successful only when **all** of the following
hold (task's own criteria, restated against this plan's specifics):

- `radiance-vllm` starts reliably via `scripts/start.sh` (healthcheck passes
  within `start_period`)
- R9700/gfx1201 correctly detected inside the container (§9.3 smoke test passes)
- Effective attention backend confirmed as `TRITON_ATTN` (or a deliberately
  chosen, validated alternative — not an accidental AITER-ASM selection)
- Qwen3.8-27B (or a documented, justified fallback per §6.4) loads successfully
- Real VRAM usage within the tuned target band (§7.3 — empirically determined,
  not assumed from nominal `GPU_MEMORY_UTILIZATION`)
- 131072-token context works (§20 long-context test)
- FP8 KV cache works *or* is explicitly deferred with documented rationale
  (§7.2 — not silently dropped)
- Speculative decoding works *or* baseline ships without it, documented (§8.2)
- OpenAI-compatible API validated per §20's full matrix
- Streaming validated (both endpoints)
- Tool calling validated per §20 (all 6 scenarios + streaming + leak check)
- `scar.lab:8080/v1` remains the external endpoint post-cutover
- Real coding prompts work through OpenCode and PI (§20)
- llama.cpp remains recoverable — rollback (§19) actually exercised once, not
  just documented

---

## 23. Known Risks

Ranked roughly by severity:

1. **Hybrid Gated-DeltaNet architecture compatibility (§6.2)** — the single
   highest risk; already the proven root cause of multiple real bugs in this
   exact host's history with this exact model family. Mitigated by Phase 0
   gating and §6.4 fallback profiles, not eliminated.
2. **"Radiance" ecosystem is single-maintainer, experimental, and validated
   only for 2-GPU topology (§4, §9.4)** — **user-accepted, not mitigated**
   (§4.1: explicit decision to use `vllm-radiance` as the primary image from
   day one rather than deferring it behind a proven baseline). The last-resort
   fallback to official `rocm/vllm` (§4.1) is the only remaining safety net if
   this risk materializes as a hard failure.
3. **Bimodal decode-throughput bug, unresolved upstream (§9.1)** — no fix
   available; only mitigation is awareness + a documented "restart and
   re-benchmark" runbook step.
4. **FP8 silent-fallback correctness/perf trap (§9.2)** — mitigated by
   explicit kernel-path verification before trusting any FP8 number.
5. **Host RAM OOM precedent (§7.4/§10.3)** — mitigated by carrying forward the
   cgroup limits that already fixed this once on this exact host.
6. **Quantization loader brittleness (§2.4, §6.3)** — mitigated by the
   bake-off methodology and by never trusting a repo name over
   `config.json`'s actual declared `quant_method`.
7. **Unaccounted-for `vllm/vllm-openai:latest` image already on disk (§2.3)**
   — floating tag, violates host pin convention, origin unknown. **Resolved
   (user-confirmed 2026-09-14, §25): leave it untouched.** Do not build on
   it, do not delete it.
8. **Container startup GPU-visibility bug reported on RDNA4 (§9.3)** —
   mitigated by an explicit in-container smoke test rather than trusting
   `docker inspect` health status alone.
9. **Client-config drift risk at cutover (§14, §19)** — OpenCode/PI need a
   one-time reconfiguration exactly at cutover; rollback must explicitly
   remember to reflect this, not assume config reverts itself.

---

## 24. Open Questions (must be resolved during implementation, not guessed)

1. **Exact HF checkpoint id for the INT4 AutoRound quant of Qwen3.8-27B**
   (§6.3) — the ~20.8GB figure came from a secondary source (blog), not
   verified directly against HuggingFace. Resolve via direct HF search +
   `config.json` inspection during the bake-off.
2. **Correct `--tool-call-parser` for Qwen3.8-27B** (§5.1/§12.3) — no
   documentation found naming it specifically; `hermes` is a reasoned guess by
   analogy to other non-Coder Qwen3 dense models, not verified against this
   checkpoint's actual `tokenizer_config.json` chat template. Resolve by
   inspecting the template directly and testing both `hermes` and `qwen3_xml`
   against `test-tool-calling.sh`.
3. **Whether R4D's attention-kernel constraints apply to Qwen3.8-27B's Gated
   Attention sublayers at all, and whether R4D has any support for the
   DeltaNet layers that make up most of the model** (§4, §8.1) — unresolved;
   resolve in Phase 0/1 by inspecting `config.json` directly. If R4D doesn't
   apply, the confirmed fallback (§4.1) is `vllm-radiance`'s standard
   attention path, not blocking the deployment.
4. **Which exact `rocm/vllm` image tag to pin** (§5, §5.2) — RDNA-specific
   vs. generic ROCm-10.0.0 tag tradeoff (older/narrower vs.
   newer/broader-but-unconfirmed-for-RDNA); resolve via Phase 0/1 smoke
   testing both.
5. **Whether FP8 KV cache is achievable at all on the chosen baseline image
   without R4D** (§7.2) — resolve empirically in Phase 3 tuning; if not,
   document and ship without it.
6. **Whether to add API-key authentication to the new endpoint** (§17) — out
   of scope to decide unilaterally; current llama.cpp has none, task doesn't
   request adding it, but a "dedicated inference server" framing might warrant
   revisiting this. Flag for the user, don't silently change the trust model.
7. **Disposition of the unaccounted-for `vllm/vllm-openai:latest` image**
   (§23 item 7) — ask before deleting.
8. **Whether ROCm 10.0.0's hardware-support claim for R9700 needs a host ROCm
   upgrade from 7.2.2, or is irrelevant since the container bundles its own
   ROCm userspace** (§2.3, §5.2) — current understanding is the latter (only
   the `amdgpu` kernel driver needs to be compatible, which it already is,
   since llama.cpp's container works today), but confirm explicitly rather
   than assume, since amdsmi/host-side tooling (used by the dashboard) is
   version-sensitive in a way the inference container itself is not.

**Resolved via direct user confirmation (2026-09-14), no longer open:**
Radiance-stack scope (§4.1 — go straight for `vllm-radiance`), R4D fallback
behavior if inapplicable (§4.1, §8.1), rollout aggressiveness (§7.2, §7.3,
§8.2 — target full spec immediately), execution/checkpoint mode (§25 —
autonomous through cutover), API authentication (§17 — none, matches current
behavior), disposition of the orphan `vllm/vllm-openai:latest` image (§23
item 7 — leave untouched), sudo scope for `/var/lib/radiance-vllm` setup
(§25 — granted, scoped).

---

## 25. Execution Authorization (recorded 2026-09-14)

This section is a record of explicit authorization the user gave when asked
directly, so implementation (and any future reader) doesn't have to guess
scope from conversation history:

- **Execution mode:** fully autonomous through all phases including Phase 4
  cutover (the one step that takes over the live production port from
  llama.cpp). No per-phase check-in is required. This makes the automatic
  rollback design (§11.2, §19 — ported from the llama.cpp repo's
  `restore-or-shutdown.sh` pattern: validate before recording state, restore
  last-known-good or bring the service down on failure, never leave a
  broken/unhealthy container running under `restart:unless-stopped`) load
  bearing, not just good practice — with no human checkpoint at cutover, the
  automatic safety net is what keeps a bad cutover from becoming an extended
  outage. Implementation must not weaken or skip that mechanism to move
  faster.
- **Sudo scope:** non-interactive `sudo` is authorized specifically for
  creating and chowning directories under `/var/lib/radiance-vllm/` (§13) —
  `mkdir`, `chown`, `chmod` scoped to that path only. Not authorized for
  anything else (package installation, system config changes, other paths)
  without a separate explicit ask.
- **Rollout config:** deploy targeting the full task-spec configuration
  (R4D attention, DFlash2 speculative decoding, FP8 KV cache,
  `GPU_MEMORY_UTILIZATION=0.968`) on the **first** deploy attempt, not as a
  later tuning step — see §7.2, §7.3, §8.1, §8.2 for the specific, still-
  mandatory correctness/safety checks this doesn't relax.
- **Orphan image (`vllm/vllm-openai:latest`, §2.3, §23):** leave untouched.
  Do not delete, do not build on it.
- **API authentication:** do not add any — matches current llama.cpp
  behavior, avoids an uncoordinated breaking change to OpenCode/PI/Hermes
  configs.
