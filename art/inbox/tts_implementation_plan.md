# Feature: TTS (Text-to-Speech) Command

## Summary

Add a `ligi tts` command that reads markdown/text files, sends them to the TTSReader API, and saves the resulting MP3 audio files.

## API Reference

- Endpoint: `POST https://ttsreader.com/api/ttsSync`
- Auth: Bearer token via `TTS_API_KEY` env var
- Request body (JSON):
  ```json
  {"text": "...", "lang": "en-US", "voice": "Nova Premium", "rate": 1, "quality": "48khz_192kbps"}
  ```
- Response: MP3 binary data

## Files to Create

### 1. `src/tts/config.zig`

TTS configuration. Loads the API token from the `TTS_API_KEY` environment variable.

```zig
pub const TtsConfig = struct {
    token: []const u8,
    api_url: []const u8 = "https://ttsreader.com/api/ttsSync",
};
```

Provide a `fromEnv()` function that reads `TTS_API_KEY` from `std.process.getEnvVarOwned`. Error if the key is not set.

### 2. `src/tts/client.zig`

HTTP client for the TTSReader API. Modeled after `src/github/client.zig` but with key differences:

- Uses **POST** instead of GET
- Sends a **JSON body** (constructed via `std.fmt.allocPrint`, no JSON library needed)
- Receives **binary MP3 data** instead of JSON
- Sets `Content-Type: application/json` and `Accept: audio/mpeg` headers

```zig
pub const TtsClient = struct {
    allocator: std.mem.Allocator,
    http_client: std.http.Client,
    token: []const u8,
    api_url: []const u8,

    pub fn init(allocator, cfg: TtsConfig) !Self { ... }
    pub fn deinit(self: *Self) void { ... }
    pub fn synthesize(self: *Self, text: []const u8, voice: []const u8, lang: []const u8, rate: f32, quality: []const u8) ![]const u8 { ... }
};
```

The `synthesize` method:
- Builds the JSON body via `std.fmt.allocPrint`
- Escapes the `text` field (replace `"` with `\"`, `\n` with `\\n`)
- Uses `std.http.Client.fetch` with `.method = .POST` and `.payload = json_body`
- Returns the raw MP3 bytes (caller owns the memory)

### 3. `src/tts/mod.zig`

Module barrel file:
```zig
pub const client = @import("client.zig");
pub const config = @import("config.zig");
pub const TtsClient = client.TtsClient;
pub const TtsConfig = config.TtsConfig;
```

### 4. `src/cli/commands/tts.zig`

Command handler. Follows the pattern in `src/cli/commands/plan.zig`.

Usage: `ligi tts <file> [options]`

Options:
- `--voice` — Voice name (default: `"Nova Premium"`)
- `--lang` — Language code (default: `"en-US"`)
- `--rate` — Speech rate (default: `1`)
- `--quality` — Audio quality (default: `"48khz_192kbps"`)
- `--output` / `-o` — Output file path (default: derive from input filename, e.g. `notes/foo.md` -> `art/tts/foo.mp3`)

The `run()` function:
1. Read the input file via `core.fs.readFile`
2. Load TTS config from env
3. Initialize `TtsClient`
4. If text exceeds ~4000 chars, split on paragraph boundaries (`\n\n`) into chunks
5. For each chunk, call `client.synthesize()` and collect the MP3 bytes
6. If multiple chunks, concatenate the MP3 data (MP3 frames are independently decodable, so simple concatenation works)
7. Write the output MP3 file
8. Print summary to stdout

## Files to Modify

### 5. `src/cli/registry.zig`

Add a new `CommandDef` entry to the `COMMANDS` array:
```zig
.{
    .canonical = "tts",
    .names = &.{"tts"},
    .description = "Convert text files to speech audio",
    .long_description = "Send text files to TTSReader API for text-to-speech conversion. Outputs MP3 files.",
},
```

Add dispatch to the `tts` command handler in the run/dispatch function.

### 6. `src/cli/commands/index.zig`

Add the tts module export:
```zig
pub const tts = @import("tts.zig");
```

## Design Notes

- **No new dependencies**: Uses `std.http.Client` (already used by GitHub integration) and manual JSON formatting via `std.fmt.allocPrint`.
- **No build.zig changes**: Zig's module system auto-discovers `.zig` files via `@import`.
- **Text chunking**: The TTSReader API likely has a text length limit. Split on `\n\n` paragraph boundaries to produce natural-sounding breaks. Each chunk becomes a separate API call; the resulting MP3 segments are concatenated.
- **JSON escaping**: Must escape `"`, `\`, newlines, and tabs in the text field. A small helper function handles this.
- **Output location**: Default to `art/tts/` directory, creating it if needed via `core.fs.ensureDirRecursive`.
- **Error handling**: Follow existing patterns — return `error.X` variants from the client, print user-friendly messages in the command handler.
