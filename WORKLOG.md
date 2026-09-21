# Worklog

Append-only. Matches sibling repos' convention on this host.

## 2026-09-21

- Started `feat/radlight-integration`: integrating
  `https://codeberg.org/hifi/vllm-radlight` as a second, independently-
  pinned stack flavor (`radlight`) alongside the existing production
  `radiance-baseline` stack -- NOT replacing it. See the mission spec's
  "Critical compatibility rule": Radlight patches AMD's own vLLM 0.27/
  ROCm 10 image, completely different from this repo's current vLLM
  0.28/ROCm 7.14 (`magiccodingman/vllm-radiance`) image -- treated as two
  complete, independently-pinned stacks throughout.
- Mandatory initial inspection performed before any change: read
  README/STATUS/VERSIONS/WORKLOG/compose.yaml/.env-template/
  qwen38-27b.env/docs/*.md/plan-*.md and every lifecycle script. Recorded
  baseline state: branch `main` clean at `7dec8bb`, production
  `radiance-vllm` healthy on `:8080` (`RedHatAI/Qwen3.8-27B-INT4`,
  `scar-coder`, 131072 ctx), VRAM 33.57/34.21GiB used (nearly full,
  confirming the single-GPU-exclusivity constraint the mission spec
  assumes), `llamacpp` present and stopped (restart policy `no`) as the
  existing rollback target, Docker 29.7.2 / Compose v5.4.0, 498GiB free
  under `/var/lib`, raptor.lab reachable over SSH (OpenCode/PI live
  there), a live `hermes`/`hermes-dashboard` pair already running against
  the production endpoint.
- Cloned Radlight with submodules to
  `/var/lib/radiance-vllm/upstream/vllm-radlight` (outside any Git working
  tree -- it has no top-level LICENSE file, verified by directory listing;
  see `docs/RADLIGHT-TUNABLES.md` "Licensing"). The default clone landed
  exactly on the mission's pinned commits for all three
  (top-level `f93de10c3d47782edd9ec7a0a69afb0974c5fc63`, `libr4d`
  `b9e42ab7202f53a3bc13d415f5d41481f9ca311b`, `radiance-vllm-mxfp4`
  `037e7fc558038fb73fc7fee1fae504026ffc5087`) -- no drift correction
  needed, but `scripts/sync-radlight.sh` verifies all three explicitly
  and fails closed on any future mismatch rather than trusting that this
  stays true.
- Read Radlight's actual `run.sh`/`entrypoint/init.sh`/`README.md` in
  full (not assumed from the mission brief) -- confirmed it has NO build
  step: it patches an on-the-fly-mounted vLLM install inside AMD's own
  `rocm/vllm:rocm10.0.0_..._vllm_0.27.0` image via ~34 source patches
  applied in a fixed order from the `radiance-vllm-mxfp4` submodule, then
  compiles `libr4d.so` and a fork-specific MXFP4xFP8 HIP extension,
  caching both by submodule commit hash. This shaped
  `compose.radlight.yaml`'s design: the Radlight checkout mounts
  read-only at `/opt/repo`, only a compiled-kernel cache directory is
  read-write, matching Radlight's own "no write access outside its cache"
  design intent.
- Resolved and pinned the base image's immutable manifest digest
  (`docker manifest inspect --verbose`, linux/amd64):
  `sha256:b8a082f346d069376d35784250e38b23a043efe979408ae3a33d7c6b62ee3276`.
  Started pulling it in the background (large image, ~similar order of
  magnitude to the sibling `rocm/vllm` 7.14 image already on this host at
  73.4GB).
- Resolved exact HF revisions via the Hub API (never a mutable branch):
  target `amd/Qwen3.8-27B-Quark-AWQ-MXFP4@5233554c5fa56afda40150556b95573c2d7d29c0`
  (19.82GB), drafter
  `tcclaviger/Qwen3.8-27B-DFlash2-FP8@ee0cb26a8279b7910cc28d82a8a3e15e4728d56f`
  (2.12GB). Wrote `scripts/sync-radlight-models.sh` (pure curl/jq/python3,
  no `huggingface_hub` dependency -- not installed on this host) to
  download both into plain local directories under
  `hf-cache/radlight-models/`, verifying every file by LFS sha256 or
  git-blob sha1 after download. Started this in the background too.
- Wrote `compose.radlight.yaml` (translated from Radlight's Podman
  `run.sh` per the mission's compatibility rules: numeric GIDs not
  `keep-groups`, no `-ti`/`--rm`, `restart: unless-stopped`, `seccomp=
  unconfined` not `label=disable`, no privileged mode, no Docker socket,
  models/repo read-only) and five model profiles under `config/models/`
  (`qwen38-27b-radlight` exact-parity, `-balanced`/`-compat` context
  fallbacks, `-nospec` for the DFlash2 equivalence gate, `-template` for
  the chat-template A/B test). Verified both `docker compose config`
  renders cleanly (`compose.yaml` unchanged/still valid,
  `compose.radlight.yaml` new).
- Made the lifecycle scripts stack-aware rather than hardcoding
  `compose.yaml`/`radiance-vllm`: `scripts/lib/common.sh` gained
  `stack_for_profile`/`compose_file_for_stack`/`container_name_for_stack`
  (stack is derived from the profile name, never a separate flag an
  operator could forget) plus a `current-stack` state file alongside the
  existing `current-profile` one. Updated `deploy.sh`, `status.sh`,
  `benchmark.sh`, `validate-model.sh` (previously didn't even source
  `common.sh` -- had its own hardcoded `compose.yaml` `COMPOSE` array),
  `restore-or-shutdown.sh`, `rollback.sh`, `stop.sh` accordingly.
- Extended the automatic-rollback safety net for the specific two-level
  case the mission requires: `restore-or-shutdown.sh` now auto-falls-through
  to `scripts/rollback.sh` (llama.cpp) if a **radlight** deploy fails AND
  restoring the radiance-baseline profile it displaced ALSO fails --
  scoped specifically to `failed_stack == "radlight"` so this doesn't
  change existing behavior for a same-stack (radiance-baseline-to-
  radiance-baseline) profile-switch failure, which still just brings the
  service down for an operator to decide, as before.
- Wrote `scripts/canary-radlight.sh` (captures a machine-readable rollback
  manifest + redacted `.env` snapshot, stops the current production stack
  cleanly, deploys the radlight profile on the canary port, relies on
  `deploy.sh`'s existing health-wait + `validate-model.sh` gate),
  `scripts/promote-radlight.sh` (canary port -> 8080, mirrors the original
  `cutover.sh` pattern), `scripts/rollback-radlight.sh` (manual level-1
  rollback, radlight -> radiance-baseline, independent of the final
  llama.cpp fallback).
- Wrote `docs/RADLIGHT-TUNABLES.md`: the full tunable-by-tunable
  classification (required/adopted, adopted-but-configurable,
  intentionally-disabled, not-applicable-under-Docker, rejected) for
  every environment variable in Radlight's `run.sh`, plus the model/
  image/context-profile/chat-template/speculative-decoding comparison
  tables the mission requires. Flagged the `--kv-cache-memory` flag
  spelling as needing verification against this exact pulled image's
  `vllm serve --help` before the first real deploy (not guessed).
- Ran `shellcheck` against every new/modified script (one SC2155 warning
  fixed in `stop.sh`; everything else clean) and `docker compose config`
  against both compose files (both render without error).
- **Not yet done as of this entry**: the model/base-image downloads were
  still in progress; the actual sequential canary
  (`scripts/canary-radlight.sh`), every correctness/tool-call/DFlash2-
  equivalence/long-context validation gate, benchmark comparison, and
  promotion have not run yet. Production is untouched. See `STATUS.md`.

## 2026-09-14

- Created `plan-radiance-vllm.md` and `plan-radiance-observability.md`
  (full implementation plans, extensive host/repo research, verified
  current Radiance vLLM ecosystem facts).
- User decisions recorded (plan §4.1/§25): go straight for
  `vllm-radiance`/`libr4d` (not the official `rocm/vllm` baseline
  originally recommended); target full spec immediately (0.968 GPU mem
  util, FP8 KV cache, DFlash2/R4D); fully autonomous execution including
  cutover; no API auth; leave the orphan `vllm/vllm-openai:latest` image
  alone; sudo authorized, scoped to `/var/lib/radiance-vllm` only.
- Set up `/var/lib/radiance-vllm/{hf-cache,vllm-cache,state,benchmarks,logs}`
  (sudo, per explicit authorization).
- Scaffolded the full repo: `compose.yaml`, `.env-template`, `VERSIONS`,
  `scripts/{lib/common.sh,preflight.sh,deploy.sh,stop.sh,status.sh,logs.sh,
  validate-model.sh,restore-or-shutdown.sh,cutover.sh,rollback.sh,
  test-tool-calling.sh,benchmark.sh,gpu-info.sh,configure-opencode.sh,
  configure-pi.sh,verify-versions-pin.sh,check-image-pins.sh}`,
  `config/models/{qwen38-27b,qwen38-27b-smoketest,qwen25-coder-14b,
  qwen3-coder-30b-a3b}.env`, `install.sh`, `uninstall.sh`,
  `healthcheck.sh`, lint configs (`.pre-commit-config.yaml`,
  `.shellcheckrc`, `.pymarkdown.json`), `tests/deploy.bats`, `docs/{ROCM,
  MODELS,TUNING,runbook}.md`. Ported directly from proven patterns in
  `Containerized-llamma.ccp-AMD-9700` (rollback/state-file logic) and
  `Containerized-VLLM-AMD-R9700` (compose/preflight/tool-calling/
  benchmark/OpenCode scripts), not written from scratch.
- Resolved image: `magiccodingman/vllm-radiance@sha256:83a9dc02a8f8e75...`
  (tag `1.0.16`) — chosen over the canonical `stilldeadcode/vllm-radiance`
  (stale, ~3 weeks since last push). Pulled successfully (4GB, much
  smaller than expected — no bundled weights).
- **Critical finding from image inspection:** this whole Radiance stack is
  explicitly tuned around `Qwen3.8-27B-FP8`/`Qwen3.6-27B-FP8` specifically
  (upstream's own words). R4D refuses at startup (hard failure, not silent
  fallback) if a model's attention shape doesn't match its constraints.
  Qualified weight formats are native FP8 or AMD Quark MXFP4 — not the
  INT4/compressed-tensors format the VRAM budget actually requires for a
  single 32GB card at full context. Resolved by splitting into a
  throwaway FP8 architecture-smoke-test profile and a real INT4-targeted
  deployment profile — see `config/models/qwen38-27b.env`'s header.
- **Critical finding from quant research:** `Qwen/Qwen3.8-27B`'s
  `tokenizer_config.json` confirms XML-style tool calls
  (`qwen3_xml` parser, not `hermes` as originally guessed). Model is
  actually a vision-language model (`Qwen3_5ForConditionalGeneration`,
  has a ViT tower) — `--language-model-only` required.
- **Ran Phase 0 (architecture smoke test) live.** Had to temporarily stop
  `llamacpp` (`docker stop`, autostart left enabled) — a single 32GB R9700
  cannot hold both llama.cpp's ~26.4GB production model and any real vLLM
  deployment resident simultaneously (see `docs/runbook.md`). Container
  started, args parsed correctly, and **vLLM 0.28.0 logged `Resolved
  architecture: Qwen3_5ForConditionalGeneration` without error** — this
  directly resolves the plan's top risk (hybrid-architecture
  compatibility) in the affirmative. `gdn_chunk_scan ENABLED` confirms R4D
  engaging for the 48 Gated-DeltaNet layers; FP8 KV cache active
  (`Selected TritonFp8BlockScaledMMKernel`, a real kernel, not a
  fallback); DFlash2 armed by default (`RADIANCE_DYNAMIC_DRAFT=ON`);
  text-only mode confirmed (vision tower skipped).
- Weight download (30.89GB, unauthenticated HF Hub, rate-limited) in
  progress as this entry is written. Generation-quality result and full
  Phase 0 verdict to follow in `docs/MODELS.md`.
- **Phase 0 result: FP8 smoke test hit CUDA OOM during final KV-cache
  allocation** (as predicted -- 27.64GiB weights leave essentially no
  room at any context on a 32GB card), but only *after* architecture
  resolution, weight load, torch.compile, and CUDA graph setup all
  succeeded cleanly. Confirms hybrid-architecture compatibility
  affirmatively; the OOM is a VRAM-budget issue, not a compatibility
  one. Smoke-test container stopped/removed (would otherwise
  crash-loop). Full writeup in `docs/MODELS.md`.
- **Deployed the real target (`qwen38-27b`, RedHatAI INT4) at full spec**
  (131072 context, 0.968 util, FP8 KV, R4D+DFlash2). First attempt hit a
  new, unanticipated (by the original plan) failure:
  `max_num_seqs (256) exceeds available Mamba cache blocks (194)` --
  vLLM's multi-user-throughput default doesn't fit this hybrid
  architecture's Mamba-cache budget on a single 32GB card. Fixed by
  adding `--max-num-seqs 32` (appropriate for this deployment's stated
  single-user-interactive priority) to `config/models/qwen38-27b.env`.
- **Second attempt succeeded completely.** Confirmed via
  `docs/MODELS.md`/`docs/TUNING.md` (full detail there): 302,359-token
  KV cache (2.31x concurrency at full 131072 context), 1.11GiB real VRAM
  headroom at 0.968 utilization, `RDNAHybridW4A16LinearKernel` confirms
  dedicated RDNA INT4 kernel support (not a fallback), correct manual
  generation output (code-gen + reasoning), all 6 tool-calling scenarios
  passed, streaming confirmed, `/metrics` confirmed
  (`vllm:kv_cache_usage_perc` is the correct current name).
- Found and fixed two bugs in `scripts/validate-model.sh` while running
  it: (1) unsafely `source`d the model profile file directly, which
  bash mis-parses for multi-word values like `EXTRA_VLLM_ARGS` -- fixed
  by only sourcing `.env`, not the profile; (2) dropped
  `chat_template_kwargs: {enable_thinking: false}` from the
  known-answer arithmetic/code fixtures when porting from the
  llama.cpp repo's version, causing the 16-token arithmetic budget to
  be consumed entirely by reasoning content -- fixed by restoring that
  flag and raising the code fixture's budget for margin. Neither bug
  was a model/deployment defect (the tool-call-determinism check, which
  didn't have this issue, passed cleanly across a real container
  restart on the very first run).
- **Full `validate-model.sh` suite passed** after the fixes: VRAM
  postflight, known-answer fixtures, tool-call determinism across 4
  trials including a real restart. State recorded:
  `/var/lib/radiance-vllm/state/current-profile` = `qwen38-27b`.
- Ran two benchmark points (`scripts/benchmark.sh`): TTFT ~5-42ms
  (excellent), decode throughput ~23-24 tok/s (consistent across both
  runs, no restart between them -- plausibly the "slow band" of the
  documented bimodal decode-throughput bug, `ROCm/ROCm#6347`, not
  distinguished from a genuine INT4-kernel-path throughput ceiling in
  this session). Direct llama.cpp throughput comparison not performed
  live -- existing llama.cpp reports only recorded perplexity/accuracy,
  and the single-GPU VRAM exclusivity would have required an extra
  stop/benchmark/redeploy cycle not done here. Full detail in
  `docs/TUNING.md`.
- **Executed Phase 4 cutover (`scripts/cutover.sh qwen38-27b`).**
  Fixed `scripts/preflight.sh --cutover`'s llama.cpp-state check first
  (it assumed llama.cpp would be actively *running* at cutover time, per
  the plan's original fully-concurrent-staging design; this host's real
  situation -- llama.cpp deliberately stopped for VRAM headroom, restart
  policy still enabled -- needed to be accepted as an equally valid
  pre-cutover state). Cutover then ran cleanly: llama.cpp restart policy
  set to `no` and confirmed stopped; `radiance-vllm` recreated on
  `0.0.0.0:8080->8000`; full `validate-model.sh` re-passed on the
  production port (VRAM 30.75/31.86GiB, arithmetic + code fixtures,
  4/4 tool-call determinism trials including a restart); all 6
  `test-tool-calling.sh` scenarios re-passed on :8080.
  **`scar.lab:8080/v1` is now served by radiance-vllm.**
- Reconfigured OpenCode and PI on raptor.lab (manual `jq` merge over
  SSH, following the same surgical-merge/backup discipline as
  `scripts/configure-opencode.sh`/`configure-pi.sh`): OpenCode's
  existing `scar-vllm` provider repointed from the old experimental
  `:8000` to `scar.lab:8080/v1` with model id `scar-coder`; PI's
  `local-lab-llama` provider's model id changed from the raw GGUF
  filename to `scar-coder` (URL unchanged, already `:8080`). Both
  backed up before editing (`*.bak.<timestamp>`).
- **Verified real end-to-end through the actual downstream client**:
  `ssh raptor.lab 'opencode run --model scar-vllm/scar-coder "..."'`
  returned a correct response, round-tripping raptor.lab → OpenCode →
  `scar.lab:8080/v1` → radiance-vllm → `scar-coder` → back through
  OpenCode. This is real agentic-client validation, not just a
  synthetic API call.
- Verified Hermes needs no reconfiguration (auto-detects model from
  `/v1/models`, already pointed at `127.0.0.1:8080` — confirmed with a
  direct chat-completion request against the new backend, got a correct
  reply).
- **Status at this entry: Phases 0-4 complete** (plan §18). The primary
  migration (`plan-radiance-vllm.md`) is functionally done and
  validated end-to-end through a real downstream client. Not yet done:
  DFlash2's formal output-equivalence gate (circumstantial evidence
  positive, not a dedicated test), a direct live llama.cpp throughput
  comparison, precise R4D engagement disambiguation for the 16
  full-attention layers, and all of `plan-radiance-observability.md`'s
  scope (dashboard `INFERENCE_BACKEND=vllm` switch, metrics wiring --
  separate document, not started in this session).
