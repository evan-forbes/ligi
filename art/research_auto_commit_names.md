# Research: Auto-Generated Commit Names for Ligi

**Date:** 2026-02-07
**Status:** Draft / Research
**Context:** The `ligi` project is a Zig-based CLI with existing local AI capabilities (Speech-to-Text via `whisper.cpp`). We want to add auto-generated commit messages, ideally maintaining the "fast and local" philosophy.

## Options Analysis

### Option 1: Local LLM (Embedded `llama.cpp`)
**Recommendation Level:** High (Fits project DNA)

This approach mirrors the existing `src/voice/whisper.zig` implementation by vendoring `llama.cpp` and running a small, quantized LLM locally to summarize diffs.

*   **How it works:**
    1.  Vendor `llama.cpp` (similar to `whisper.cpp`).
    2.  Add a `src/ai/llm.zig` wrapper using `@cImport`.
    3.  User downloads a small "coder" model (e.g., `Qwen2.5-Coder-1.5B-Instruct-GGUF` or `Llama-3.2-1B-Instruct-GGUF`, approx 0.5GB - 1GB).
    4.  Command `ligi commit` runs `git diff --staged`, feeds it to the model with a prompt like "Summarize these changes in a conventional commit message...", and pre-fills the commit editor.

*   **Pros:**
    *   **Local & Private:** Code never leaves the machine.
    *   **Offline:** Works without internet.
    *   **Consistent:** Uses the same C-interop pattern as the existing Voice feature.
    *   **Cost:** Free (after hardware).

*   **Cons:**
    *   **Binary Size/Build Time:** Increases compilation time.
    *   **Runtime Resources:** Requires ~1GB RAM and CPU/GPU usage during generation (usually <5s for small models).
    *   **Model Management:** Need to handle model downloading/versioning (just like `voice` models).

### Option 2: Heuristic / Rule-Based
**Recommendation Level:** Medium (Good fallback)

A purely algorithmic approach that parses `git diff` output and constructs messages based on file paths and simple regex patterns.

*   **How it works:**
    1.  Parse changed file paths.
    2.  Detect types: `*.zig` -> `feat/fix/refactor`, `*.md` -> `docs`.
    3.  Detect scopes: `src/voice/` -> `(voice)`, `src/cli/` -> `(cli)`.
    4.  Template: `type(scope): update <filename> [and <N> other files]`

*   **Pros:**
    *   **Instant:** <10ms execution.
    *   **Tiny:** No extra dependencies or models.
    *   **Predictable:** Always gives a standard format.

*   **Cons:**
    *   **"Dumb":** Can't explain *why* a change happened or summarize logic (e.g., "fix off-by-one error" becomes "fix(core): update loop.zig").
    *   **Maintenance:** Heuristics need constant tweaking.

### Option 3: External API (OpenAI / Anthropic / Gemini)
**Recommendation Level:** Low (for this specific project)

Uses a cloud provider to generate the message.

*   **Pros:**
    *   **Intelligence:** SOTA models (GPT-4o, Claude 3.5 Sonnet) write excellent messages.
    *   **Zero Local Load:** No RAM/CPU usage.

*   **Cons:**
    *   **Not Local:** Breaks the core "offline/local" preference.
    *   **Configuration:** Requires API keys and payment.
    *   **Privacy:** Sends code diffs to third-party servers.

### Option 4: `git` Hook Integration
**Recommendation Level:** Supplement

Instead of a `ligi commit` command, `ligi` could install a `prepare-commit-msg` hook that calls `ligi internal generate-message` to populate the message in standard `git commit` flows.

*   **Pros:**
    *   Seamless integration with standard workflows (e.g. `git commit`, VS Code git UI).

## Performance & Footprint Tradeoffs

| Feature | Option 1: Local LLM | Option 2: Heuristics | Option 3: External API |
| :--- | :--- | :--- | :--- |
| **Binary Size** | **Medium impact.** Adds ~5-10MB to the `ligi` binary (or helper binary) for the inference engine. | **Negligible.** Adds <50KB of logic. | **Negligible.** Uses existing HTTP libs. |
| **Disk Usage** | **External.** Requires **0.5GB - 2GB** storage for the GGUF model file, stored in `~/.cache/ligi/llm/`. It is **NOT** embedded in the binary. | **Zero.** | **Zero.** |
| **Boot / Load Time** | **Lazy loading.** `ligi` starts instantly. Model loading (from disk to RAM) takes **0.5s - 3s** and *only* happens when running AI-specific commands. | **Instant.** <10ms. | **Instant.** <10ms. |
| **Execution Time** | **Variable.** **1s - 10s** depending on diff size and CPU/GPU speed. | **Instant.** <50ms. | **Variable.** **2s - 10s** (Network latency + API processing). |
| **Memory (RAM)** | **High.** Requires **~1GB** free RAM to hold the model. | **Minimal.** <10MB. | **Minimal.** <10MB. |

**Analysis:**
*   **Local LLM** imposes a significant "first run" cost (downloading the model) and a noticeable "per run" cost (loading model to RAM), but offers the best balance of privacy and intelligence.
*   **Heuristics** are free but "dumb".
*   **External APIs** are fast enough but introduce latency and dependency on internet/auth.

## Technical Implementation Plan (Option 1 Focus)

1.  **Vendor `llama.cpp`:**
    *   Add `llama.cpp` as a submodule in `vendor/`.
    *   Update `build.zig` to compile `llama.cpp`.

2.  **Zig Wrapper (`src/ai/generator.zig`):**
    *   Implement `generate(diff: []const u8, model_path: []const u8) ![]u8`.
    *   Handle prompt formatting (ChatML/Alpaca depending on model).

3.  **CLI Command (`ligi commit`):**
    *   Check for staged changes.
    *   Load model (prompt to download if missing).
    *   Run generation.
    *   Spawn editor (User's `$EDITOR`) with the generated message for review/editing.
    *   On save/exit, run `git commit -F <msg_file>`.

### Technical Challenges (Crucial)

**Symbol Collision:**
Both `whisper.cpp` (already vendored) and `llama.cpp` use the `ggml` tensor library. They both export C symbols like `ggml_init`, `ggml_new_tensor`, etc.
*   **The Problem:** Statically linking both into `ligi` will cause "duplicate symbol" linker errors.
*   **Solution A (Namespace):** Use a `llama.cpp` build that namespaces its `ggml` (e.g., `llama_ggml_*`), if available, or manually patch it.
*   **Solution B (Separate Binary):** Build a separate helper executable `ligi-llm-helper` that contains `llama.cpp`. The main `ligi` binary calls it via `std.ChildProcess`. This is the safest and cleanest approach for preventing symbol conflicts.
*   **Solution C (Shared Libs):** Build them as dynamic libraries (`.so`/`.dylib`) and load them carefully.

## Recommended Models (GGUF)

For commit generation, we need "Smart enough to summarize" but "Small enough to be fast".

1.  **Qwen2.5-Coder-1.5B-Instruct:** Excellent coding knowledge, very small.
2.  **Llama-3.2-1B-Instruct:** Good general reasoning, widely supported.
3.  **Danube-3-500M:** Extremely small, might be "good enough" for simple commits.