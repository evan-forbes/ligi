# Implementation Plan: Kokoro Local TTS Provider

Date: 2026-02-03
Owner: TBD
Status: revised draft

## Summary
Add a local text-to-speech provider built on the official `kokoro` Python package from `hexgrad/kokoro`. The provider must handle very large inputs (ebooks), chunk them deterministically, and generate a single audio file. We will integrate via a small Python worker script invoked from Zig. GPU acceleration will use PyTorch ROCm on AMD APU when available; otherwise CPU fallback is used.

## Key Decisions (Made Now)
1. Integration method: **Python worker** that uses `KPipeline` from `kokoro` (no reliance on an external CLI). The worker writes WAV chunks and returns metadata. This is the most stable path given the official API examples. citeturn3view0
2. Output format: **WAV 24 kHz, mono**. Kokoro examples use 24 kHz and `soundfile` to write WAV files; we will standardize on that. citeturn3view0
3. AMD APU (ROCm) support: **Use PyTorch HIP/ROCm via the CUDA interface**. PyTorch ROCm intentionally reuses `torch.cuda` APIs; device type remains `cuda` and `torch.cuda.is_available()` works for HIP. We will set `device="cuda"` when `torch.cuda.is_available()` and `torch.version.hip` is truthy, else CPU. citeturn1search4turn1search5
4. Chunking strategy: **Chapter-first, size-limited fallback**. We split by chapter markers when present, otherwise by size and paragraph boundaries. Each chunk is synthesized separately so we can resume and concatenate reliably.
5. Concatenation: **Use ffmpeg concat demuxer** in v1 (reliable and fast). Document it as a required system tool; optional pure-Zig WAV concat can be added later as a follow-up.

## Required Tools and Libraries (Document in README)
- Python 3.10-3.12 (kokoro requires `>=3.10,<3.13`). citeturn3view0
- `pip` + `venv` (used by `make kokoro-install`).
- `kokoro>=0.9.4` and `soundfile`. citeturn3view0
- `espeak-ng` (required for English OOD fallback and some non-English languages). citeturn3view0
- `ffmpeg` (required for concatenation in v1).
- Optional for non-English voices: `misaki[ja]`, `misaki[zh]`, etc., as described by Kokoro docs. citeturn3view0
- Optional GPU: ROCm + ROCm-enabled PyTorch (AMD). citeturn1search4turn1search5

## Phase 1 - Python Worker (Core Synthesis) (2-3 days)

### Goal
Create a small, deterministic Python worker that can synthesize one text chunk into a WAV file using Kokoro.

### Steps
1. Add `scripts/kokoro_worker.py` with a minimal CLI:
   - Inputs: `--text-file`, `--voice`, `--speed`, `--lang-code`, `--device`, `--split-pattern`, `--out-wav`.
   - Output: WAV file written with `soundfile` at 24 kHz, mono.
2. In the worker:
   - Load text from file.
   - Create `KPipeline(lang_code=...)`.
   - Call `pipeline(text, voice=..., speed=..., split_pattern=...)`.
   - Iterate generator and write each audio segment to the same WAV file (streaming). Example usage shows the generator yields audio segments and `soundfile` writes WAV. citeturn3view0
3. Device selection in the worker:
   - If `--device=cpu`, run CPU.
   - If `--device=cuda`, set device to `cuda` (works for ROCm/HIP as well). citeturn1search4
   - If `--device=auto`, choose `cuda` if `torch.cuda.is_available()` and `torch.version.hip` or `torch.version.cuda` is set; else CPU. citeturn1search4turn1search5
4. Add `scripts/kokoro_worker_schema.json` documenting the CLI flags and expected behavior.

### Tests
- Unit (Python, `pytest`):
  - `test_args_parsing`: invalid flags exit with code 2.
  - `test_split_pattern`: verify that passing `split_pattern` does not crash and writes output.
  - `test_device_auto_cpu`: when `torch.cuda.is_available()` is False, uses CPU path (mocked).
- Integration (Python):
  - `test_synthesize_short_text`: run worker on 1-2 sentences and assert WAV exists and is non-empty.

### Exit Criteria
- Worker can synthesize a short text chunk to WAV on CPU.

## Phase 2 - Zig Provider Interface (2-3 days)

### Goal
Add a Kokoro provider in Zig that calls the Python worker and exposes configuration.

### Steps
1. Define `TtsProvider` interface (if not already existing) with:
   - `synthesizeChunk(text, voice, speed, outPath) -> Result`
   - `maxChunkChars() -> usize`
   - `providerName() -> []const u8`
2. Add a Kokoro provider implementation that:
   - Writes `chunk_NNNN.txt` to a temp dir.
   - Invokes `scripts/kokoro_worker.py` via subprocess.
   - Captures stderr for error reporting.
3. Add config keys (examples):
   - `tts.provider = "kokoro"`
   - `tts.kokoro.python = ".venv/kokoro/bin/python"`
   - `tts.kokoro.voice = "af_heart"`
   - `tts.kokoro.lang_code = "a"`
   - `tts.kokoro.device = "auto|cpu|cuda"`
   - `tts.kokoro.split_pattern = "\\n+"`

### Tests
- Unit (Zig):
  - Config parsing for Kokoro fields (defaults and overrides).
  - Command construction string (exact argv list) without execution.
- Integration (Zig):
  - Use a mock worker (simple Python script that writes a tiny WAV) to verify subprocess call and file creation.

### Exit Criteria
- Zig can call the worker to synthesize a single short chunk.

## Phase 3 - Chunking and Job Orchestration (3-5 days)

### Goal
Handle ebook-sized inputs by splitting into chunks, synthesizing them in order, and managing progress.

### Steps
1. Implement a `TextChunker` module (Zig):
   - Normalize newlines and strip BOM.
   - Detect chapter markers with regex: `(?im)^(chapter\b|#|##|part\b)`.
   - Split into chapters when markers exist.
   - If a chapter exceeds `maxChunkChars`, split by paragraphs, then by sentences.
   - Default `maxChunkChars = 20000` (configurable).
2. Create a `SynthesisJob`:
   - Inputs: full text, voice, speed, output path.
   - Outputs: `chunk_0001.wav`, `chunk_0002.wav`, ...
   - Save `job.json` with chunk list and status for resume.
3. Add retries:
   - Retry failed chunk up to 2 times.
   - Persist completed chunks; skip on resume.

### Tests
- Unit (Zig):
  - Chapter split detection for typical headings.
  - Fallback splitting when no chapter markers are present.
  - Enforce `maxChunkChars` (no chunk longer than limit).
- Integration:
  - Run job on a multi-paragraph sample that produces 3+ chunks and confirm all WAVs exist.
  - Simulate failure by deleting one chunk and re-running; verify resume only regenerates missing chunk.

### Exit Criteria
- Long text is chunked deterministically and produces ordered WAV chunks.

## Phase 4 - Concatenation and Output (2-3 days)

### Goal
Combine chunk WAVs into a single output file.

### Steps
1. Use `ffmpeg` concat demuxer:
   - Create `concat.txt` with `file 'chunk_0001.wav'` lines.
   - Run `ffmpeg -f concat -safe 0 -i concat.txt -c copy output.wav`.
2. Validate that all chunks have the same sample rate and channel count before concatenation.
3. Store a final `output.json` with timing and metadata.

### Tests
- Unit:
  - Validate concat list generation.
  - Reject mismatched sample rate/channel metadata.
- Integration:
  - Concatenate 3 chunks and verify output exists and size > sum of headers.

### Exit Criteria
- Single WAV output is produced reliably for large inputs.

## Phase 5 - AMD APU (ROCm) Support (1-2 days)

### Goal
Make GPU usage deterministic and documented for AMD APUs.

### Steps
1. Update README with ROCm guidance:
   - Install ROCm and ROCm-enabled PyTorch.
   - Verify with `python -c 'import torch; print(torch.cuda.is_available())'`.
   - Note that HIP uses `torch.cuda` and device string is `cuda`. citeturn1search4turn1search5
2. In the worker, when `--device=auto`:
   - If `torch.cuda.is_available()` and `torch.version.hip` is truthy, log `device=rocm` and use `cuda` device.
   - If `torch.version.cuda` is set, log `device=cuda`.
   - Otherwise use CPU.

### Tests
- Unit (Python):
  - Mock `torch.version.hip` to verify ROCm path selection.
  - Mock `torch.version.cuda` to verify CUDA path selection.
- Integration (optional):
  - Run a small synthesis on a machine with ROCm; verify logs show `device=rocm`.

### Exit Criteria
- ROCm path is deterministic and documented.

## Phase 6 - Documentation and Tooling (1-2 days)

### Goal
Ensure a junior engineer can install, configure, and run this without external context.

### Steps
1. Update README with:
   - Required tools list.
   - `make kokoro-install` instructions (venv + pip install).
   - Example config and a one-command demo.
2. Add `make kokoro-install` target:
   - Create `./.venv/kokoro`.
   - Install `kokoro>=0.9.4 soundfile`.
3. Add `make kokoro-smoke`:
   - Runs the worker on a tiny sample and produces `out.wav`.

### Tests
- Integration:
  - Run `make kokoro-smoke` and confirm output exists.

### Exit Criteria
- Clear installation path and a working demo.

## Follow-Up (Optimization Only)
- Parallel chunk synthesis (if memory allows).
- Voice cache warming and model persistence.
- Optional pure-Zig WAV concatenation to remove ffmpeg dependency.

## Risks and Mitigations
- Large input size: use chapter-first chunking with size limits and resume support.
- Dependency sprawl: isolate Python venv and document required system tools.
- ROCm fragility: CPU fallback is always available; ROCm is best-effort.

## Decision Log
- 2026-02-03: Choose Python worker + KPipeline integration and ROCm via `torch.cuda`.
