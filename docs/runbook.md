# Runbook

## Rollback to llama.cpp

```sh
scripts/rollback.sh
```

Stops radiance-vllm, re-enables and restarts llamacpp, verifies
`:8080/v1/models` responds. Does not require reinstalling anything --
llama.cpp's config/container/model files are never modified by this repo.

If OpenCode/PI were already reconfigured for radiance-vllm (post-cutover),
revert those manually or re-run their configurators pointed back at the
llama.cpp provider entries (`scar-llamacpp`/`local-lab-llama` on
raptor.lab).

## Bimodal decode-throughput bug (R9700, unresolved upstream -- ROCm/ROCm#6347)

Decode throughput on this GPU can stick at either a fast (~33 tok/s) or
slow (~26 tok/s) band, determined randomly at HIP process init. No fix
available upstream. If a benchmark looks unexpectedly slow:

1. Check whether it's simply in the slow band (compare against a prior
   benchmark run's numbers).
2. Restart the container (`docker compose restart radiance-vllm`) to
   re-roll HIP init.
3. Re-benchmark.

Do not conclude a real regression from a single slow run without ruling
this out first.

## FP8 silent-fallback trap (gfx1201)

If FP8 (weights or KV cache) throughput looks roughly half of what's
expected, gfx1201 may be silently falling back to FP32 dequantization
(missing arch-table entry, `ROCm/aiter#3294`). Check the startup logs for
which kernel path was actually selected (e.g.
`Selected TritonFp8BlockScaledMMKernel for Fp8LinearMethod` -- seen live
in Phase 0, a real FP8 kernel, not a fallback) rather than trusting the
throughput number alone.

## R4D hard-refusal at startup

If a model's attention shape doesn't match R4D's constraints (head_dim
256, paged block 16, 6 query-heads-per-KV-head, causal, bf16/fp8_e4m3 KV),
the container will refuse to start with the reason logged. Fix: set
`RADIANCE_USE_R4D=0` and `RADIANCE_USE_R4D_GDN=0` in `.env` and redeploy
-- this is a confirmed, expected fallback (plan §8.1), not a bug to chase.

## Host RAM (not VRAM) OOM

If the host locks up or the kernel OOM-killer fires, check
`MEM_LIMIT`/`MEM_RESERVATION` in `.env` -- a prior vLLM deployment on this
exact host hit this from unconstrained container host-RAM growth. Raise
both values if real steady-state usage (`docker stats radiance-vllm`)
exceeds the current limit, rather than removing the limit.

## Single-GPU VRAM contention with llama.cpp during validation

This host's single 32GB GPU cannot hold both llama.cpp's production model
and a radiance-vllm validation deployment resident simultaneously (verified
live: llama.cpp alone uses ~26GB, leaving ~5GB free). Real staging
validation requires llama.cpp temporarily stopped (`docker stop llamacpp`,
fully reversible with `docker start llamacpp`) for the duration of testing
-- true zero-impact concurrent staging (as the plan originally envisioned
for the *port* dimension) does not extend to VRAM. See
`plan-radiance-vllm.md`'s implementation notes for how this was handled in
practice.
