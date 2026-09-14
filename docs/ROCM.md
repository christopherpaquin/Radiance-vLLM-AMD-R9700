# ROCm / gfx1201 / vllm-radiance notes

Living document -- update as Phase 0-5 (plan-radiance-vllm.md) uncover more.
Everything below is either verified live on scar.lab or sourced from
`magiccodingman/vllm-radiance`'s own `DOCKERHUB.md`/`README.md` (a
community fork of `StillDeadcode/vllm-radiance` -- see plan §4).

## Image

`magiccodingman/vllm-radiance@sha256:83a9dc02a8f8e75aabe81366d36ebaa2e35fcbe181cacf8e8e0a4cef4ebccbcc`
(tag `1.0.16`, resolved 2026-09-14). Chosen over the canonical
`stilldeadcode/vllm-radiance` because that repo's latest tag (0.9.3) was
~3 weeks stale at resolution time; magiccodingman's fork is an
actively-maintained superset (native gfx1201 MXFP4/W4A8, vLLM 0.28 DFlash2,
correctness backports), pushing every 1-4 days. See `VERSIONS` for the full
resolved package version table (vllm 0.28.0, torch 2.12.0+rocm7.14, triton
3.7.1, aiter 0.1.20, in-container ROCm 7.14.0, libr4d 0.5.0).

## Entrypoint gotcha

The image's own `ENTRYPOINT` (`/opt/radiance_entrypoint.sh`) wraps the
`vllm` CLI directly -- it runs a startup banner + `RADIANCE_RUN_BWTEST`
(bandwidth test), then `exec vllm "$@"`. It does **not** accept a shell
command as its argument. `compose.yaml` sets `entrypoint: []` to bypass
this and run our own `sh -c 'exec vllm serve ...'` instead -- confirmed
this doesn't break anything (GPU access, `torch.cuda.device_count()`, all
still work fine without the banner/bandwidth-test).

`/opt/rocm*/.info/version` does **not** resolve inside this image --
`/opt/rocm` is a symlink tree; the actual path is
`/opt/rocm/core-7.14/.info/version`.

## R4D attention backend -- exact constraints (verbatim from upstream)

> head_dim 256, paged block 16, 6 query heads per KV head, causal decoder
> attention, bf16 query, bf16 or fp8_e4m3 KV

Mismatch behavior is a **hard refusal at startup**, not a silent fallback:

> any other shape is refused at startup with the reason, and nothing
> changes unless you ask for it

This means the plan's §8.1 "fall back to standard attention" must be
driven explicitly -- set `RADIANCE_USE_R4D=0` and `RADIANCE_USE_R4D_GDN=0`
in `.env` and redeploy if R4D refuses at startup for a given checkpoint.

**This whole image is explicitly tuned around this exact model family**
(verbatim from `DOCKERHUB.md`): *"Qwen3.8-27B-FP8 / Qwen3.6-27B-FP8 are
what everything here is tuned around: 64 layers, 48 of them linear
attention (GDN) and 16 full attention."* R4D engages for the 16
full-attention (Gated Attention) blocks; `RADIANCE_USE_R4D_GDN` is a
separate switch for the 48 Gated-DeltaNet blocks. Both default to `1`
(on).

**Qualified weight formats are native FP8 or AMD Quark MXFP4 specifically
-- not generic AWQ/GPTQ/compressed-tensors INT4.** This creates a real
tension: FP8 weights (~30.89GB) leave almost no VRAM headroom for KV cache
on a single 32GB card at any real context length. The project's stated
primary qualified environment is **2xR9700 (TP=2)** -- not single-GPU.
See `config/models/qwen38-27b.env` for how this repo resolves that
tension (FP8 smoke test only, INT4 compressed-tensors for the real
deployment, accepting R4D may not engage for INT4 weights).

## DFlash2 (speculative decoding)

Armed by default -- confirmed live in startup logs:

```
[radiance.draft] RADIANCE_DYNAMIC_DRAFT=ON  controller=policy  tau=0.28
  schedule=1:8,2:7,4:6,8:5,16:4  (GPU-resident capture + n-gram matcher;
  per-slot confidence gate short-circuits the forward loop)
```

No separate `--speculative-config` flag was needed -- it activates
automatically based on `RADIANCE_DYNAMIC_DRAFT`/`RADIANCE_DRAFT_SCHEDULE`/
`RADIANCE_DRAFT_TAU` env vars (all left at documented defaults for Phase
0). Still subject to plan §8.2's strict output-equivalence correctness
gate before being trusted for the real deployment -- being "on by default"
is not the same as "validated correct here."

## Env vars beyond the generic ROCm/vLLM set (plan §5.1)

None of `PYTORCH_ROCM_ARCH`/`VLLM_ROCM_USE_AITER`/etc. appear in
vllm-radiance's own documented surface -- `PYTORCH_ROCM_ARCH=gfx1201` is
baked in as a build-time Dockerfile ARG, not a runtime env var for this
image. The image's actual first-class runtime controls are the
`RADIANCE_*` vars (see `.env-template` for the ones currently set/known;
full ~30-var table is in upstream's `DOCKERHUB.md`, not reproduced here in
full -- fetch directly if a var beyond what's in `.env-template` is
needed).

## Known non-fatal warnings

- `Unknown vLLM environment variable detected: VLLM_CACHE_DIR` /
  `VLLM_IMAGE` / `VLLM_IMAGE_FALLBACK` -- these are compose-time vars from
  `.env` leaking into the container's environment (the `env_file:`
  mechanism passes the whole file) and being flagged by vLLM's own arg
  parser since they share the `VLLM_` prefix vLLM scans for its own env
  vars. Harmless, but worth scoping `.env` more tightly later so
  compose-only vars don't reach the container.
- `HSA_STATUS_ERROR_OUT_OF_RESOURCES` from the entrypoint's bandwidth test
  if GPU devices aren't passed through -- not applicable once
  `/dev/kfd`/`/dev/dri` are attached (they always are in this repo's
  compose file).

## Phase 0 result

See `docs/MODELS.md` once Phase 0 completes for the actual outcome
(architecture load success/failure, R4D engagement, generation quality).
