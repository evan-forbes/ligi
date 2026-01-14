```toml
feature_name = { type = "Github Integration" }
feature_description = pulls github issues and PRs as markdown documents. Converts github tags and status etc to local tag format. Keeps comments in the document. Uses the github number to pull from
cli_surface = ligi github p (pull) -r <repo>, ligi github r (refresh) <range> -r <repo>
```

# Document

# Implementation Plan: GitHub Integration

## Executive Summary

This feature pulls GitHub issues and PRs from a repository and converts them to local markdown documents with ligi tags. It uses `std.http.Client` to call the GitHub REST API, handles pagination, and generates markdown files in `art/github/<owner>/<repo>/` with wiki-link tags like `[[t/github/repo/ligi]]`, `[[t/github/user/evan-forbes]]`, and `[[t/github/number/123]]`. Authentication is via a GitHub token stored in config.

---

## Part 1: Motivation

### Problem Statement

Project management context is split between GitHub (issues, PRs, discussions) and local documentation. Users must context-switch to GitHub to reference issues, losing the benefits of local search, tagging, and linking. There's no way to query "all issues tagged `bug` from this quarter" using ligi's tag system.

### User Story

As a developer using ligi for project documentation, I want to pull GitHub issues and PRs as local markdown documents so that I can search, tag, and link them alongside my other documentation using ligi's existing tag and query infrastructure.

---

## Part 2: Design Decisions

| # | Decision | Choice | Alternatives Considered | Rationale |
|---|----------|--------|------------------------|-----------|
| 1 | HTTP Client | `std.http.Client` from stdlib | libcurl, external library | No additional dependencies; sufficient for REST API calls |
| 2 | Authentication | Token from `art/config/github.toml` or `GITHUB_TOKEN` env var | OAuth flow, git credential helper | Simpler; tokens are standard for CLI tools |
| 3 | Document storage location | `art/github/<owner>/<repo>/<type>-<number>.md` | Flat directory, by issue state | Namespaced by repo allows multiple repos; type prefix distinguishes issues/PRs |
| 4 | Tag namespace | `t/github/...` with sub-tags for repo, user, number, state, label | Flat tags, separate namespace per repo | Hierarchical tags allow powerful queries like `ligi q t github/repo/ligi & github/state/open` |
| 5 | Refresh behavior | Re-download specified range, overwrite existing | Merge/diff, append-only | Simple; users can use git to see changes |
| 6 | Pagination | Follow Link header, fetch all matching | Limit to N pages, require explicit pagination args | Complete data is more useful; pagination is transparent |
| 7 | Rate limiting | Respect `X-RateLimit-Remaining` header, warn user | Hard fail, ignore | Graceful degradation; informs user without blocking partial work |
| 8 | Constraints | Requires network; GitHub API v3 only | N/A | GitHub's REST API is stable and well-documented |
| 9 | Backward compatibility | N/A (new feature) | N/A | No existing github command |
| 10 | Dependencies | `std.http.Client`, `std.json` (stdlib) | External JSON lib | Stdlib is sufficient for GitHub's JSON responses |
| 11 | Risks/Mitigations | API rate limits (5000/hr authenticated) | Batch requests; cache responses locally | Sufficient for most use cases |
| 12 | Security/Privacy | Token stored in config file; never logged | N/A | Config file should have appropriate permissions; warn if world-readable |

---

## Part 3: Specification

### Behavior Summary

**Commands**:
- `ligi github pull` / `ligi github p` / `ligi g p`: Pull all issues and PRs from a repository
- `ligi github refresh` / `ligi github r` / `ligi g r`: Re-download specific issue/PR numbers

**Flags (both commands)**:
- `-r, --repo <owner/repo>`: Repository to pull from (default: infer from `git remote get-url origin`)
- `-q, --quiet`: Suppress non-error output

**Pull-specific flags**:
- `--state <open|closed|all>`: Filter by state (default: `all`)
- `--since <date>`: Only issues updated since date (ISO 8601)

**Refresh-specific arguments**:
- `<range>`: Issue/PR numbers to refresh (e.g., `1-10`, `42`, `1,5,10-20`)

- **Command**: `ligi github pull -r evan-forbes/ligi`
- **Input**: Repository identifier, optional filters
- **Output**: Markdown files in `art/github/<owner>/<repo>/`
- **Side effects**: Creates directories; writes/overwrites markdown files; updates `art/github/<owner>/<repo>/index.md`

### Data Structures

```zig
/// Configuration for GitHub API access
pub const GithubConfig = struct {
    /// GitHub personal access token (from config or env)
    token: ?[]const u8,
    /// API base URL (default: https://api.github.com)
    api_base: []const u8 = "https://api.github.com",
};

/// Represents a GitHub issue or PR after parsing
pub const GithubItem = struct {
    /// Issue/PR number
    number: u32,
    /// "issue" or "pull"
    item_type: ItemType,
    /// Issue/PR title
    title: []const u8,
    /// Markdown body content
    body: []const u8,
    /// Current state
    state: State,
    /// Author login
    author: []const u8,
    /// Labels attached to this item
    labels: []const Label,
    /// Assignees
    assignees: []const []const u8,
    /// Creation timestamp (ISO 8601)
    created_at: []const u8,
    /// Last update timestamp (ISO 8601)
    updated_at: []const u8,
    /// Comments on the issue/PR
    comments: []const Comment,
    /// For PRs: base branch
    base_branch: ?[]const u8,
    /// For PRs: head branch
    head_branch: ?[]const u8,
    /// For PRs: merged status
    merged: ?bool,

    pub const ItemType = enum { issue, pull };
    pub const State = enum { open, closed };
    pub const Label = struct { name: []const u8, color: []const u8 };
    pub const Comment = struct {
        author: []const u8,
        body: []const u8,
        created_at: []const u8,
    };
};

/// Parsed repository identifier
pub const RepoId = struct {
    owner: []const u8,
    repo: []const u8,
};
```

**Exit Codes**:
| Code | Meaning | When Returned |
|------|---------|---------------|
| 0 | Success | All requested items fetched and written |
| 1 | Usage error | Invalid arguments, malformed repo identifier |
| 2 | Filesystem error | Cannot create directories or write files |
| 3 | Config error | Missing token when required, invalid config |
| 4 | Network error | API request failed, timeout, rate limited |

**Data Flow (Mermaid)**:

```mermaid
flowchart TD
    A[CLI Args] --> B{Parse Repo}
    B -->|explicit| C[RepoId]
    B -->|infer| D[git remote get-url origin]
    D --> C
    C --> E[Load GithubConfig]
    E --> F[Build API URL]
    F --> G["HTTP GET /repos/:owner/:repo/issues<br/>(returns BOTH issues AND PRs)"]
    G --> H{Response OK?}
    H -->|yes| I[Parse JSON to GithubItem list]
    H -->|no| J[Handle Error]
    I --> K{More pages?<br/>Check Link header}
    K -->|yes| L[Follow 'next' URL]
    L --> G
    K -->|no| M[For each item: fetch comments]
    M --> M2{Comments paginated?}
    M2 -->|yes| M3[Fetch next page of comments]
    M3 --> M2
    M2 -->|no| N[Convert to Markdown]
    N --> O[Write to art/github/owner/repo/]
    O --> P[Update index.md]
    P --> Q[Exit 0]
    J --> R[Print error, Exit 4]
```

**Note**: The `/repos/:owner/:repo/issues` endpoint returns BOTH issues and PRs.
PRs are distinguished by having a non-null `pull_request` field in the response.

### File Formats

**Document format** (`art/github/<owner>/<repo>/issue-42.md`):

```markdown
# #42: Fix memory leak in parser

[[t/github]] [[t/github/repo/<owner>/<repo>]] [[t/github/number/42]] [[t/github/type/issue]]
[[t/github/state/open]] [[t/github/user/<author>]] [[t/github/label/bug]] [[t/github/label/high-priority]]

**Author**: @username
**Created**: 2025-01-10
**Updated**: 2025-01-14
**Assignees**: @dev1, @dev2

---

The parser leaks memory when handling malformed input...

---

## Comments

### @commenter1 (2025-01-11)

I can reproduce this on the latest main branch...

### @commenter2 (2025-01-12)

Here's a minimal reproduction case...
```

**Config format** (`art/config/github.toml`):

```toml
# GitHub API configuration
token = "ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
# api_base = "https://api.github.com"  # Optional, for GitHub Enterprise
```

**Index format** (`art/github/<owner>/<repo>/index.md`):

```markdown
# GitHub: owner/repo

Last synced: 2025-01-14T10:30:00Z

## Issues

- [[issue-42]] #42: Fix memory leak in parser
- [[issue-38]] #38: Add dark mode support

## Pull Requests

- [[pr-45]] #45: Implement caching layer
- [[pr-41]] #41: Refactor auth module
```

### Error Messages

```
error: github: no repository specified and could not infer from git remote
error: github: invalid repository format '<input>' (expected 'owner/repo' or URL)
error: github: token required but not found (set GITHUB_TOKEN or add to art/config/github.toml)
error: github: API request failed: <status_code> <reason>
error: github: rate limit exceeded (resets at <time>)
error: github: failed to create directory '<path>': <reason>
error: github: failed to write file '<path>': <reason>
error: github: invalid range '<input>' (expected N, N-M, or comma-separated)
warning: github: rate limit low (<remaining>/<limit>), may be throttled
warning: github: config file art/config/github.toml is world-readable
```

---

## Part 4: Implementation

### Prerequisites

Before starting implementation, add a `network` error category to `src/core/errors.zig`:

```zig
pub const ErrorCategory = enum(u8) {
    success = 0,
    usage = 1,
    filesystem = 2,
    config = 3,
    network = 4,  // ADD THIS
    internal = 127,
};
```

And add a constructor:

```zig
pub fn network(message: []const u8, cause: ?*const ErrorContext) Self {
    return .{
        .category = .network,
        .context = .{ .message = message, .source = cause },
    };
}
```

### New/Modified Files

| File | Purpose |
|------|---------|
| `src/core/errors.zig` | Add `network` error category (exit code 4) |
| `src/github/mod.zig` | Module root, exports public API |
| `src/github/client.zig` | HTTP client wrapper for GitHub API |
| `src/github/parser.zig` | JSON parsing for issues/PRs/comments |
| `src/github/markdown.zig` | Convert GithubItem to markdown with tags |
| `src/github/config.zig` | Load token from config/env |
| `src/cli/commands/github.zig` | CLI command implementation |
| `src/cli/registry.zig` | Add github command registration |
| `src/cli/commands/mod.zig` | Export github command |
| `src/core/mod.zig` | Export github module |

### Existing Touchpoints

| Touchpoint | Why It Matters |
|------------|----------------|
| `src/cli/registry.zig` | Add CommandDef for "github" with alias "g" |
| `src/cli/commands/mod.zig` | Export the new github command module |
| `src/core/fs.zig` | Reuse `ensureDirRecursive`, `writeFile`, `readFile` |
| `src/core/paths.zig` | Reuse `joinPath`, `getLocalArtPath` |
| `src/core/errors.zig` | Reuse `LigiError`, `Result` pattern |
| `src/core/tag_index.zig` | Reference tag format for consistency |

### Implementation Steps

#### Step 1: Create github module skeleton

**File(s)**: `src/github/mod.zig`, `src/core/mod.zig`

**Tasks**:
- Create `src/github/` directory
- Create `mod.zig` with placeholder exports
- Add `pub const github = @import("../github/mod.zig");` to `src/core/mod.zig`

**Checklist**:
- [ ] `src/github/mod.zig` exists and compiles
- [ ] `src/core/mod.zig` exports github module

**Verification**: `zig build` succeeds
**Tests**: Compile-time only

#### Step 2: Implement config loading

**File(s)**: `src/github/config.zig`

**Tasks**:
- Define `GithubConfig` struct
- Implement `loadConfig(allocator, art_path)` that:
  1. Checks `GITHUB_TOKEN` env var
  2. Falls back to `art/config/github.toml`
  3. Warns if config file is world-readable
- Return `Result(GithubConfig)` using existing error pattern

**Implementation Details**:

```zig
pub fn loadConfig(allocator: std.mem.Allocator, art_path: []const u8) errors.Result(GithubConfig) {
    // 1. Check environment variable first (takes precedence)
    if (std.posix.getenv("GITHUB_TOKEN")) |token| {
        return .{ .ok = .{ .token = token, .api_base = "https://api.github.com" } };
    }

    // 2. Try config file
    const config_path = paths.joinPath(allocator, &.{ art_path, "config", "github.toml" }) catch {
        return .{ .err = errors.LigiError.filesystem("failed to build config path", null) };
    };
    defer allocator.free(config_path);

    // Check if file exists - if not, return null token (not an error)
    if (!fs.fileExists(config_path)) {
        return .{ .ok = .{ .token = null, .api_base = "https://api.github.com" } };
    }

    // 3. Check permissions (warn if world-readable)
    if (isWorldReadable(config_path)) {
        std.io.getStdErr().writer().print(
            "warning: github: config file {s} is world-readable\n", .{config_path}
        ) catch {};
    }

    // 4. Parse TOML - NOTE: token MUST be quoted in TOML file
    const content = switch (fs.readFile(allocator, config_path)) {
        .ok => |c| c,
        .err => |e| return .{ .err = e },
    };
    defer allocator.free(content);

    var toml = toml_parser.parse(allocator, content) catch {
        return .{ .err = errors.LigiError.config("failed to parse github.toml", null) };
    };
    defer { /* cleanup toml */ }

    const token = if (toml.get("token")) |v| switch (v) {
        .string => |s| s,
        else => null,
    } else null;

    return .{ .ok = .{ .token = token, .api_base = "https://api.github.com" } };
}

/// Check if file is world-readable (Unix only)
fn isWorldReadable(path: []const u8) bool {
    const stat = std.fs.cwd().statFile(path) catch return false;
    // Check if "others" have read permission (mode & 0o004)
    return (stat.mode & 0o004) != 0;
}
```

**IMPORTANT**: The TOML parser requires quoted strings. Document in help text:
```toml
# CORRECT:
token = "ghp_xxxx"

# WRONG (will error):
token = ghp_xxxx
```

**Checklist**:
- [ ] Loads token from env var
- [ ] Loads token from TOML config
- [ ] Env var takes precedence over file
- [ ] Missing config file returns null token (not error)
- [ ] Warns on insecure file permissions (Unix only)

**Verification**: Unit tests pass
**Tests**:
- `test_config_loads_from_env`
- `test_config_loads_from_file`
- `test_config_env_precedence`
- `test_config_file_not_found_returns_null_token`
- `test_config_unquoted_token_errors`

#### Step 3: Implement HTTP client wrapper

**File(s)**: `src/github/client.zig`

**Tasks**:
- Create `GithubClient` struct wrapping `std.http.Client`
- Implement `init(allocator, config)` and `deinit()`
- Implement `get(path) -> Result(Response)` with:
  - Authorization header from token
  - Accept header for GitHub API v3
  - User-Agent header (required by GitHub)
  - Rate limit header parsing
- Implement `getJson(path, comptime T) -> Result(T)` for typed responses
- Handle pagination via Link header parsing

**Implementation Details**:

```zig
const std = @import("std");

pub const GithubClient = struct {
    allocator: std.mem.Allocator,
    http_client: std.http.Client,
    token: ?[]const u8,
    api_base: []const u8,
    rate_limit_remaining: ?u32 = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: GithubConfig) !Self {
        var http_client = std.http.Client{ .allocator = allocator };

        // IMPORTANT: Set up TLS certificate bundle for HTTPS
        // Without this, HTTPS requests will fail
        http_client.ca_bundle = std.crypto.Certificate.Bundle{};
        try http_client.ca_bundle.?.rescan(allocator);

        return .{
            .allocator = allocator,
            .http_client = http_client,
            .token = config.token,
            .api_base = config.api_base,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.http_client.ca_bundle) |*bundle| {
            bundle.deinit(self.allocator);
        }
        self.http_client.deinit();
    }

    pub fn get(self: *Self, path: []const u8) !Response {
        const uri = try std.Uri.parse(self.api_base);

        var headers = std.http.Headers{ .allocator = self.allocator };
        defer headers.deinit();

        // Required headers for GitHub API
        try headers.append("Accept", "application/vnd.github.v3+json");
        try headers.append("User-Agent", "ligi-cli/1.0");  // GitHub requires User-Agent
        if (self.token) |t| {
            const auth = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{t});
            defer self.allocator.free(auth);
            try headers.append("Authorization", auth);
        }

        var request = try self.http_client.open(.GET, uri, headers, .{});
        defer request.deinit();

        // Set timeouts (30 second read timeout)
        request.transfer_encoding = .chunked;

        try request.send(.{});
        try request.finish();
        try request.wait();

        // Parse rate limit headers
        if (request.response.headers.getFirstValue("X-RateLimit-Remaining")) |remaining| {
            self.rate_limit_remaining = std.fmt.parseInt(u32, remaining, 10) catch null;
            if (self.rate_limit_remaining) |r| {
                if (r < 100) {
                    std.io.getStdErr().writer().print(
                        "warning: github: rate limit low ({d} remaining)\n", .{r}
                    ) catch {};
                }
            }
        }

        // Check for errors
        if (request.response.status != .ok) {
            return error.HttpError;
        }

        // Read body
        const body = try request.reader().readAllAlloc(self.allocator, 10 * 1024 * 1024);

        // Extract Link header for pagination
        const link_header = request.response.headers.getFirstValue("Link");

        return Response{
            .body = body,
            .next_url = if (link_header) |lh| parseLinkHeaderNext(lh) else null,
        };
    }
};

pub const Response = struct {
    body: []const u8,
    next_url: ?[]const u8,
};

/// Parse Link header to extract "next" URL
/// Format: <https://api.github.com/...?page=2>; rel="next", <...>; rel="last"
fn parseLinkHeaderNext(header: []const u8) ?[]const u8 {
    var iter = std.mem.splitSequence(u8, header, ",");
    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ");
        // Check if this part has rel="next"
        if (std.mem.indexOf(u8, trimmed, "rel=\"next\"")) |_| {
            // Extract URL between < and >
            const start = std.mem.indexOf(u8, trimmed, "<") orelse continue;
            const end = std.mem.indexOf(u8, trimmed, ">") orelse continue;
            if (start < end) {
                return trimmed[start + 1 .. end];
            }
        }
    }
    return null;
}
```

**HTTP Status Code Handling**:
| Status | Meaning | Action |
|--------|---------|--------|
| 200 | Success | Parse response |
| 301/302 | Redirect | Follow (automatic) |
| 401 | Unauthorized | Error: "invalid or expired token" |
| 403 | Forbidden | Check if rate limited (X-RateLimit-Remaining: 0) |
| 404 | Not Found | Error: "repository or item not found" |
| 422 | Validation Failed | Error: show message from response |
| 5xx | Server Error | Error: "GitHub API unavailable" |

**Checklist**:
- [ ] Sets required headers (Authorization, Accept, User-Agent)
- [ ] Sets up TLS certificate bundle for HTTPS
- [ ] Parses rate limit headers
- [ ] Warns when rate limit is low (< 100 remaining)
- [ ] Returns appropriate errors for HTTP status codes
- [ ] Extracts `next` URL from Link header
- [ ] Handles 30 second timeout

**Verification**: Integration test against GitHub API (can be skipped in CI)
**Tests**:
- `test_link_header_parsing`
- `test_link_header_no_next`
- `test_link_header_malformed`
- `test_rate_limit_header_parsing`
- `test_rate_limit_zero_remaining`
- `test_error_status_codes`

#### Step 4: Implement JSON parsing for issues/PRs

**File(s)**: `src/github/parser.zig`

**Tasks**:
- Define JSON response structs matching GitHub API schema
- Implement `parseIssue(json) -> GithubItem`
- Implement `parseComment(json) -> Comment`
- Handle null fields gracefully (body can be null)
- Distinguish issues from PRs via `pull_request` field presence

**GitHub API Response Schema** (exact field names):

```zig
/// JSON struct matching GitHub API /repos/:owner/:repo/issues response
/// Use with std.json.parseFromSlice
const GitHubIssueJson = struct {
    number: u32,
    title: []const u8,
    body: ?[]const u8,  // CAN BE NULL - handle this!
    state: []const u8,  // "open" or "closed" - string not enum
    user: struct {
        login: []const u8,
    },
    labels: []const struct {
        name: []const u8,
        color: []const u8,
    },
    assignees: []const struct {
        login: []const u8,
    },
    created_at: []const u8,  // ISO 8601: "2025-01-14T10:30:00Z"
    updated_at: []const u8,
    // If this field exists, it's a PR, not an issue
    pull_request: ?struct {
        url: []const u8,
    } = null,
};

/// JSON struct for /repos/:owner/:repo/issues/:number/comments
const GitHubCommentJson = struct {
    user: struct {
        login: []const u8,
    },
    body: []const u8,
    created_at: []const u8,
};
```

**Sample API Response** (for testing):

```json
{
  "number": 42,
  "title": "Fix memory leak",
  "body": "The parser leaks memory...",
  "state": "open",
  "user": { "login": "evan-forbes" },
  "labels": [
    { "name": "bug", "color": "d73a4a" },
    { "name": "high-priority", "color": "ff0000" }
  ],
  "assignees": [
    { "login": "dev1" },
    { "login": "dev2" }
  ],
  "created_at": "2025-01-10T12:00:00Z",
  "updated_at": "2025-01-14T15:30:00Z"
}
```

**Memory Management**:

```zig
/// Parse issues from JSON response.
/// IMPORTANT: The returned GithubItem structs reference memory owned by the
/// arena allocator. Do NOT free the arena until you're done with all items.
pub fn parseIssues(
    arena: std.mem.Allocator,  // Use arena - lives for entire operation
    json_bytes: []const u8,
) ![]GithubItem {
    const parsed = try std.json.parseFromSlice(
        []GitHubIssueJson,
        arena,
        json_bytes,
        .{ .ignore_unknown_fields = true },  // IMPORTANT: API may add fields
    );
    // NOTE: parsed.value strings point into json_bytes memory managed by arena
    // Do NOT free json_bytes until done with parsed data

    var items = std.ArrayList(GithubItem).init(arena);
    for (parsed.value) |issue_json| {
        try items.append(convertToGithubItem(issue_json));
    }
    return items.toOwnedSlice();
}

fn convertToGithubItem(json: GitHubIssueJson) GithubItem {
    return .{
        .number = json.number,
        .title = json.title,
        .body = json.body orelse "",  // Handle null body
        .state = if (std.mem.eql(u8, json.state, "open")) .open else .closed,
        .author = json.user.login,
        .item_type = if (json.pull_request != null) .pull else .issue,
        // ... map other fields
    };
}
```

**Checklist**:
- [ ] Parses all required fields from issue response
- [ ] Parses all required fields from comment response
- [ ] Handles null body field (converts to empty string)
- [ ] Detects PRs via `pull_request` field presence
- [ ] Extracts labels and assignees arrays
- [ ] Uses `ignore_unknown_fields = true` for forward compatibility
- [ ] Documents memory ownership (arena allocator)

**Verification**: Unit tests with sample JSON
**Tests**:
- `test_parse_issue_minimal` (only required fields)
- `test_parse_issue_full` (all fields populated)
- `test_parse_issue_null_body`
- `test_parse_issue_empty_labels`
- `test_parse_issue_empty_assignees`
- `test_parse_issue_many_labels` (50+ labels)
- `test_parse_pr_detection` (has pull_request field)
- `test_parse_comment`
- `test_parse_issues_array` (multiple issues)

#### Step 5: Implement markdown generation

**File(s)**: `src/github/markdown.zig`

**Tasks**:
- Implement `itemToMarkdown(allocator, item, repo_id) -> []const u8`
- Generate frontmatter tags: `[[t/github]]`, `[[t/github/repo/owner/repo]]`, etc.
- Format metadata section (author, dates, assignees)
- Include body content
- Format comments section with author attribution
- Sanitize label names for tag compatibility
- Escape special characters in titles that would break wiki-links

**Label Sanitization Rules**:

```zig
/// Sanitize a label name for use in tags.
/// Rules:
/// - Replace spaces with `-`
/// - Replace `/` with `-` (would break tag hierarchy)
/// - Replace `[` and `]` with `-` (would break wiki-links)
/// - Lowercase everything
/// - Truncate to 100 chars max
fn sanitizeLabel(allocator: std.mem.Allocator, label: []const u8) ![]const u8 {
    var result = try allocator.alloc(u8, @min(label.len, 100));
    var i: usize = 0;
    for (label) |c| {
        if (i >= 100) break;
        result[i] = switch (c) {
            ' ', '/', '[', ']', '\t', '\n' => '-',
            'A'...'Z' => c + 32,  // lowercase
            else => c,
        };
        i += 1;
    }
    return result[0..i];
}
```

**Title Escaping** (important for wiki-links):

```zig
/// Escape characters in title that would break markdown/wiki-links
/// Specifically: `[[` and `]]` sequences
fn escapeTitle(allocator: std.mem.Allocator, title: []const u8) ![]const u8 {
    // Count occurrences to pre-allocate
    var extra: usize = 0;
    var i: usize = 0;
    while (i < title.len) : (i += 1) {
        if (i + 1 < title.len) {
            if ((title[i] == '[' and title[i + 1] == '[') or
                (title[i] == ']' and title[i + 1] == ']'))
            {
                extra += 1;  // Need to escape one bracket
            }
        }
    }
    if (extra == 0) return title;

    var result = try allocator.alloc(u8, title.len + extra);
    var out_i: usize = 0;
    i = 0;
    while (i < title.len) : (i += 1) {
        if (i + 1 < title.len and title[i] == '[' and title[i + 1] == '[') {
            result[out_i] = '[';
            result[out_i + 1] = '\\';
            result[out_i + 2] = '[';
            out_i += 3;
            i += 1;
        } else if (i + 1 < title.len and title[i] == ']' and title[i + 1] == ']') {
            result[out_i] = ']';
            result[out_i + 1] = '\\';
            result[out_i + 2] = ']';
            out_i += 3;
            i += 1;
        } else {
            result[out_i] = title[i];
            out_i += 1;
        }
    }
    return result[0..out_i];
}
```

**Checklist**:
- [ ] Generates all required tags
- [ ] Formats metadata correctly
- [ ] Preserves body markdown
- [ ] Formats comments with attribution
- [ ] Sanitizes label names for tags (spaces, slashes, brackets)
- [ ] Escapes `[[` and `]]` in titles to prevent broken wiki-links
- [ ] Truncates very long labels (> 100 chars)

**Verification**: Unit tests
**Tests**:
- `test_markdown_issue_basic`
- `test_markdown_pr_with_branches`
- `test_markdown_with_comments`
- `test_label_sanitization_spaces`
- `test_label_sanitization_slashes`
- `test_label_sanitization_brackets`
- `test_label_sanitization_long`
- `test_title_escaping_wiki_links` (title contains `[[tag]]`)

#### Step 6: Implement repository inference

**File(s)**: `src/github/mod.zig` or `src/github/repo.zig`

**Tasks**:
- Implement `parseRepoId(input) -> Result(RepoId)` for formats:
  - `owner/repo`
  - `https://github.com/owner/repo`
  - `https://github.com/owner/repo.git`
  - `git@github.com:owner/repo.git`
- Implement `inferRepoFromGit(allocator) -> Result(RepoId)`:
  - Run `git remote get-url origin`
  - Parse output with `parseRepoId`

**Implementation Details**:

```zig
pub fn parseRepoId(allocator: std.mem.Allocator, input: []const u8) errors.Result(RepoId) {
    const trimmed = std.mem.trim(u8, input, " \n\r\t");
    if (trimmed.len == 0) {
        return .{ .err = errors.LigiError.usage("empty repository identifier") };
    }

    // Strip trailing slash (common typo)
    const cleaned = if (trimmed[trimmed.len - 1] == '/')
        trimmed[0 .. trimmed.len - 1]
    else
        trimmed;

    // Strip .git suffix
    const without_git = if (std.mem.endsWith(u8, cleaned, ".git"))
        cleaned[0 .. cleaned.len - 4]
    else
        cleaned;

    // Try different formats
    if (std.mem.startsWith(u8, without_git, "https://github.com/")) {
        // HTTPS: https://github.com/owner/repo
        const path = without_git["https://github.com/".len..];
        return parseOwnerRepo(allocator, path);
    } else if (std.mem.startsWith(u8, without_git, "git@github.com:")) {
        // SSH: git@github.com:owner/repo
        const path = without_git["git@github.com:".len..];
        return parseOwnerRepo(allocator, path);
    } else if (std.mem.indexOf(u8, without_git, "/")) |_| {
        // Plain: owner/repo
        return parseOwnerRepo(allocator, without_git);
    }

    return .{ .err = errors.LigiError.usage(
        "invalid repository format (expected 'owner/repo' or URL)"
    ) };
}

fn parseOwnerRepo(allocator: std.mem.Allocator, path: []const u8) errors.Result(RepoId) {
    const slash_idx = std.mem.indexOf(u8, path, "/") orelse {
        return .{ .err = errors.LigiError.usage("invalid repository format (no slash)") };
    };

    const owner = path[0..slash_idx];
    const repo = path[slash_idx + 1 ..];

    // Validate: no more slashes, non-empty parts
    if (owner.len == 0 or repo.len == 0) {
        return .{ .err = errors.LigiError.usage("invalid repository format (empty owner or repo)") };
    }
    if (std.mem.indexOf(u8, repo, "/") != null) {
        return .{ .err = errors.LigiError.usage("invalid repository format (too many slashes)") };
    }

    return .{ .ok = .{
        .owner = owner,  // NOTE: Points into input - caller must manage lifetime
        .repo = repo,
    } };
}

/// Infer repository from git remote.
/// Returns null if not in a git repo or no origin remote.
pub fn inferRepoFromGit(allocator: std.mem.Allocator) ?RepoId {
    // Run: git remote get-url origin
    var child = std.process.Child.init(.{
        .argv = &.{ "git", "remote", "get-url", "origin" },
        .stdout_behavior = .Pipe,
        .stderr_behavior = .Ignore,
    }, allocator);

    child.spawn() catch return null;

    const stdout = child.stdout orelse return null;
    const output = stdout.reader().readAllAlloc(allocator, 1024) catch return null;
    defer allocator.free(output);

    const term = child.wait() catch return null;
    if (term.Exited != 0) return null;

    const trimmed = std.mem.trim(u8, output, " \n\r\t");
    return switch (parseRepoId(allocator, trimmed)) {
        .ok => |repo| repo,
        .err => null,
    };
}
```

**Checklist**:
- [ ] Parses `owner/repo` format
- [ ] Parses HTTPS URLs (`https://github.com/owner/repo`)
- [ ] Parses SSH URLs (`git@github.com:owner/repo`)
- [ ] Strips `.git` suffix
- [ ] Strips trailing slash (common typo)
- [ ] Rejects URLs with too many path segments
- [ ] Runs git command and parses output
- [ ] Returns null (not error) when git inference fails

**Verification**: Unit tests for parsing, manual test for git inference
**Tests**:
- `test_parse_owner_repo`
- `test_parse_https_url`
- `test_parse_https_url_with_git_suffix`
- `test_parse_ssh_url`
- `test_parse_ssh_url_with_git_suffix`
- `test_parse_trailing_slash`
- `test_parse_invalid_empty`
- `test_parse_invalid_no_slash`
- `test_parse_invalid_too_many_slashes`

#### Step 7: Implement CLI command structure

**File(s)**: `src/cli/commands/github.zig`, `src/cli/registry.zig`, `src/cli/commands/mod.zig`

**Tasks**:
- Add CommandDef to registry:
  ```zig
  .{
      .canonical = "github",
      .names = &.{ "github", "g" },
      .description = "Pull GitHub issues and PRs as local documents",
  }
  ```
- Add dispatch in `run()` function
- Create `github.zig` with subcommand parsing:
  - `pull` / `p`: Pull all issues/PRs
  - `refresh` / `r`: Refresh specific numbers
- Wire up clap for argument parsing

**Checklist**:
- [ ] Command registered with alias "g"
- [ ] Subcommands "pull"/"p" and "refresh"/"r" work
- [ ] `--repo` flag parsed
- [ ] `--quiet` flag parsed
- [ ] `--state` flag parsed (pull only)
- [ ] Range argument parsed (refresh only)

**Verification**: `ligi github --help` works
**Tests**: Manual CLI testing

#### Step 8: Implement pull subcommand

**File(s)**: `src/cli/commands/github.zig`

**Tasks**:
- Resolve repo (explicit or inferred)
- Load config
- Initialize GithubClient
- Fetch all issues with pagination
- For each issue, fetch comments (also paginated!)
- Generate markdown
- Write to `art/github/<owner>/<repo>/<type>-<number>.md`
- Generate/update index.md
- Report progress unless quiet

**API Endpoints Used**:

```
GET /repos/{owner}/{repo}/issues?state=all&per_page=100
  - Returns both issues AND PRs (not a bug, that's how GitHub API works)
  - Use Link header for pagination
  - Filter PRs via pull_request field presence

GET /repos/{owner}/{repo}/issues/{number}/comments?per_page=100
  - Returns comments for a single issue/PR
  - ALSO PAGINATED - follow Link header
  - Popular issues can have hundreds of comments
```

**Progress Output** (to stderr, so stdout can be piped):

```
Fetching issues from evan-forbes/ligi...
  Fetching page 1 of issues... (30 items)
  Fetching page 2 of issues... (15 items)
  Fetching comments for 45 items...
    issue-42: 5 comments
    pr-45: 12 comments (2 pages)
    ...
  Writing documents...
created: art/github/evan-forbes/ligi/issue-42.md
created: art/github/evan-forbes/ligi/pr-45.md
...
Synced 45 items from evan-forbes/ligi
```

**Index.md Generation**:

The index.md file is **fully rewritten** each sync. Manual edits will be overwritten.
Document this in help text.

```zig
fn generateIndex(allocator: std.mem.Allocator, items: []const GithubItem, repo: RepoId) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.print("# GitHub: {s}/{s}\n\n", .{ repo.owner, repo.repo });
    try writer.print("Last synced: {s}\n\n", .{ timestamp() });

    // Separate issues and PRs
    try writer.writeAll("## Issues\n\n");
    for (items) |item| {
        if (item.item_type == .issue) {
            try writer.print("- [[issue-{d}]] #{d}: {s}\n", .{ item.number, item.number, item.title });
        }
    }

    try writer.writeAll("\n## Pull Requests\n\n");
    for (items) |item| {
        if (item.item_type == .pull) {
            try writer.print("- [[pr-{d}]] #{d}: {s}\n", .{ item.number, item.number, item.title });
        }
    }

    return buf.toOwnedSlice();
}
```

**Checklist**:
- [ ] Creates directory structure (`art/github/<owner>/<repo>/`)
- [ ] Writes all issue files
- [ ] Writes all PR files
- [ ] Fetches comments with pagination (not just first page!)
- [ ] Generates index.md (full rewrite)
- [ ] Respects `--state` filter
- [ ] Respects `--since` filter
- [ ] Shows progress to stderr (unless quiet)
- [ ] Final summary to stdout

**Verification**: Pull from a real repo
**Tests**: Integration test with mock server or recorded responses

#### Step 9: Implement refresh subcommand

**File(s)**: `src/cli/commands/github.zig`

**Tasks**:
- Implement range parsing (`1-10`, `42`, `1,5,10-20`)
- For each number in range:
  - Fetch issue/PR by number
  - Fetch comments
  - Generate markdown
  - Overwrite existing file
- Update index.md

**Range Parsing Implementation**:

```zig
/// Parse a range specification like "1-10", "42", or "1,5,10-20"
/// Returns list of individual numbers.
///
/// Constraints:
/// - Reversed ranges (5-1) are an error
/// - Maximum 1000 total items per command (prevent OOM)
/// - Whitespace around commas is allowed
/// - Duplicates are kept (simpler implementation)
pub fn parseRange(allocator: std.mem.Allocator, input: []const u8) ![]u32 {
    const trimmed = std.mem.trim(u8, input, " \t");
    if (trimmed.len == 0) {
        return error.EmptyRange;
    }

    var result = std.ArrayList(u32).init(allocator);
    errdefer result.deinit();

    // Split by comma
    var parts = std.mem.splitSequence(u8, trimmed, ",");
    while (parts.next()) |part| {
        const p = std.mem.trim(u8, part, " \t");
        if (p.len == 0) continue;

        // Check for range (contains '-')
        if (std.mem.indexOf(u8, p, "-")) |dash_idx| {
            const start_str = std.mem.trim(u8, p[0..dash_idx], " ");
            const end_str = std.mem.trim(u8, p[dash_idx + 1 ..], " ");

            const start = std.fmt.parseInt(u32, start_str, 10) catch {
                return error.InvalidRangeNumber;
            };
            const end = std.fmt.parseInt(u32, end_str, 10) catch {
                return error.InvalidRangeNumber;
            };

            if (start > end) {
                return error.ReversedRange;  // "5-1" is invalid
            }

            // Check total size limit
            if (result.items.len + (end - start + 1) > 1000) {
                return error.RangeTooLarge;
            }

            var i = start;
            while (i <= end) : (i += 1) {
                try result.append(i);
            }
        } else {
            // Single number
            const num = std.fmt.parseInt(u32, p, 10) catch {
                return error.InvalidRangeNumber;
            };
            if (result.items.len >= 1000) {
                return error.RangeTooLarge;
            }
            try result.append(num);
        }
    }

    if (result.items.len == 0) {
        return error.EmptyRange;
    }

    return result.toOwnedSlice();
}
```

**Error Messages for Range Parsing**:
```
error: github: invalid range '' (empty)
error: github: invalid range '5-1' (start must be <= end)
error: github: invalid range 'abc' (not a number)
error: github: range too large (maximum 1000 items per command)
```

**Checklist**:
- [ ] Parses single number (`42`)
- [ ] Parses range (`1-10`)
- [ ] Parses comma-separated list (`1,5,10`)
- [ ] Parses mixed format (`1,3-5,10`)
- [ ] Handles whitespace (`1 , 2 , 3`)
- [ ] Rejects reversed ranges (`5-1`)
- [ ] Rejects non-numbers (`abc`)
- [ ] Limits total items to 1000
- [ ] Fetches each item individually
- [ ] Continues on 404 (item not found), reports at end
- [ ] Updates index.md

**Verification**: Refresh specific issues from a real repo
**Tests**:
- `test_range_parse_single`
- `test_range_parse_range`
- `test_range_parse_mixed`
- `test_range_parse_whitespace`
- `test_range_parse_empty_error`
- `test_range_parse_reversed_error`
- `test_range_parse_non_number_error`
- `test_range_parse_too_large_error`

#### Step 10: Add help text and documentation

**File(s)**: `src/cli/registry.zig`

**Tasks**:
- Add long_description to CommandDef
- Document all flags and subcommands
- Add examples

**Checklist**:
- [ ] `ligi github --help` shows full usage
- [ ] Subcommand help works (`ligi github pull --help`)
- [ ] Examples are accurate

**Verification**: Manual review of help output
**Tests**: N/A

### Integration with Existing Code

| Existing Module | Use For |
|----------------|---------|
| `core.fs` | `ensureDirRecursive`, `writeFile`, `readFile` |
| `core.paths` | `joinPath`, `getLocalArtPath` |
| `core.errors` | `LigiError`, `Result`, exit codes |
| `core.tag_index` | Tag format reference (not direct usage) |
| `std.http.Client` | HTTP requests |
| `std.json` | JSON parsing |
| `std.process` | Running git commands |

---

## Part 5: Known Limitations & Non-Goals

### Known Limitations

- Requires network access; no offline mode
- Rate limited to 5000 requests/hour (authenticated) or 60/hour (unauthenticated)
- Does not sync local changes back to GitHub (read-only)
- Comments are fetched individually per issue (slower, but simpler)
- Does not handle GitHub Enterprise with self-signed certificates
- PR review comments (inline code comments) are NOT fetched - only issue-style comments
- index.md is fully rewritten each sync - manual edits will be lost

### Non-Goals

- Bidirectional sync (pushing local changes to GitHub)
- GitHub Actions workflow status
- GitHub Discussions (different API)
- GitHub Projects (different API, complex)
- Real-time webhooks/streaming
- Caching/incremental updates (use git to track changes)
- Issue creation from local markdown
- PR review comments (different API endpoint: `/pulls/:number/comments`)

### Implementation Gotchas for Junior Engineers

1. **TLS Certificate Setup**: `std.http.Client` requires explicit CA bundle setup for HTTPS. Without it, all requests fail with certificate errors.

2. **Memory Ownership with JSON Parsing**: `std.json.parseFromSlice` returns strings that point into the original JSON buffer. If you free the buffer, all strings become dangling pointers. Use an arena allocator.

3. **GitHub API Returns Both Issues and PRs**: The `/repos/:owner/:repo/issues` endpoint returns PRs mixed in. Check the `pull_request` field to distinguish them.

4. **Comments Are Paginated Too**: Don't forget - the comments endpoint also uses pagination. A popular issue can have hundreds of comments across multiple pages.

5. **TOML Strings Must Be Quoted**: The existing TOML parser requires `token = "value"` not `token = value`. Users WILL forget the quotes.

6. **Rate Limit 403 vs 401**: A 403 with `X-RateLimit-Remaining: 0` is rate limiting, not authentication failure. Check the header before showing auth errors.

7. **Git Command May Not Exist**: On some systems, `git` isn't installed. Handle the error gracefully.

8. **Unicode in Filenames**: Issue titles can contain emoji and CJK characters. Most filesystems handle this, but test it.

---

## Part 6: Edge Cases

### Input Edge Cases

| Case | Input | Expected Behavior |
|------|-------|-------------------|
| Empty repo | `-r ""` | Error: "invalid repository format" |
| Malformed repo | `-r "foo"` | Error: "invalid repository format" (no slash) |
| Non-existent repo | `-r owner/nonexistent` | Error from API: "404 Not Found" |
| Private repo without token | `-r owner/private` | Error from API: "404 Not Found" (appears as not found) |
| Repo with many issues | `-r kubernetes/kubernetes` | Handle pagination; may take time |
| Refresh range with gaps | `1-10,20,30-40` | Fetch only specified numbers |
| Refresh non-existent issue | `99999` | Error from API for that number; continue with others |
| Issue with null body | API returns `"body": null` | Generate markdown with empty body section |
| Issue with unicode in title | Emoji, CJK chars | Preserve in title and filename (filesystem allowing) |

### System Edge Cases

| Case | Condition | Expected Behavior |
|------|-----------|-------------------|
| No git repo | Not in git repository | Error: "could not infer from git remote" (when no -r) |
| No origin remote | Git repo but no origin | Error: "could not infer from git remote" |
| No art directory | `art/` doesn't exist | Error: suggest running `ligi init` |
| art/github exists but not writable | Permission denied | Error: "failed to create directory" or "failed to write file" |
| Network timeout | API doesn't respond | Error after timeout; partial results may exist |
| Rate limit exceeded mid-fetch | Hit rate limit while fetching | Warning; save what we have; suggest retry later |
| Disk full | Cannot write | Error: "failed to write file" |
| Very long label name | Label > 255 chars | Truncate tag to valid length |
| Label with special chars | Label contains `/`, `[`, `]` | Sanitize: replace with `-` |

---

## Part 7: Testing

### Testing Strategy

Focus unit tests on pure functions (parsing, markdown generation, repo ID parsing). Integration tests require network or mocking, so provide recorded response files for CI. Manual smoke tests against real repositories for end-to-end validation.

**Not tested**: Actual network calls in CI (flaky, rate limits). Instead, test client logic with mocked responses.

### Unit Tests

| Test | Property Verified |
|------|-------------------|
| **Repo ID Parsing** | |
| `test_parse_repo_id_owner_repo` | Parses "owner/repo" correctly |
| `test_parse_repo_id_https` | Parses HTTPS URL correctly |
| `test_parse_repo_id_https_with_git` | Parses "https://...repo.git" |
| `test_parse_repo_id_ssh` | Parses SSH URL correctly |
| `test_parse_repo_id_ssh_with_git` | Parses "git@...repo.git" |
| `test_parse_repo_id_trailing_slash` | Handles "owner/repo/" typo |
| `test_parse_repo_id_invalid_empty` | Returns error for "" |
| `test_parse_repo_id_invalid_no_slash` | Returns error for "noslash" |
| `test_parse_repo_id_invalid_too_many` | Returns error for "a/b/c" |
| **JSON Parsing** | |
| `test_parse_issue_json` | Parses issue JSON to GithubItem |
| `test_parse_issue_null_body` | Handles `"body": null` gracefully |
| `test_parse_issue_empty_labels` | Handles `"labels": []` |
| `test_parse_issue_empty_assignees` | Handles `"assignees": []` |
| `test_parse_issue_many_labels` | Handles 50+ labels |
| `test_parse_pr_json` | Parses PR JSON (detects pull_request field) |
| `test_parse_comment_json` | Parses comment JSON |
| `test_parse_issues_array` | Parses array of multiple issues |
| **Markdown Generation** | |
| `test_markdown_basic` | Generates valid markdown with tags |
| `test_markdown_with_labels` | Label tags are generated and sanitized |
| `test_markdown_with_comments` | Comments section formatted correctly |
| `test_markdown_escapes_wiki_links` | Title with `[[` doesn't break tags |
| `test_label_sanitization_spaces` | "bug fix" -> "bug-fix" |
| `test_label_sanitization_slashes` | "type/bug" -> "type-bug" |
| `test_label_sanitization_brackets` | "[wip]" -> "-wip-" |
| `test_label_sanitization_long` | 200+ char label truncated to 100 |
| **Range Parsing** | |
| `test_range_single` | "42" -> [42] |
| `test_range_span` | "1-5" -> [1,2,3,4,5] |
| `test_range_mixed` | "1,3-5,10" -> [1,3,4,5,10] |
| `test_range_whitespace` | " 1 , 2 " -> [1,2] |
| `test_range_invalid_empty` | "" -> error |
| `test_range_invalid_reversed` | "5-1" -> error |
| `test_range_invalid_text` | "abc" -> error |
| `test_range_too_large` | "1-2000" -> error (limit 1000) |
| **HTTP Client** | |
| `test_link_header_next` | Extracts next URL from Link header |
| `test_link_header_no_next` | Returns null when no "next" |
| `test_link_header_malformed` | Handles malformed Link gracefully |
| `test_rate_limit_header_parsing` | Parses X-RateLimit-Remaining |
| `test_rate_limit_zero` | Warns when remaining is 0 |
| **Config** | |
| `test_config_env_precedence` | Env var overrides file |
| `test_config_file_not_found` | Returns null token, not error |
| `test_config_file_missing_token` | Handles file without token key |

### Integration Tests

| Test | Scenario |
|------|----------|
| `test_pull_mock_api` | Pull against recorded API responses |
| `test_pull_creates_directory` | Verifies `art/github/<owner>/<repo>/` created |
| `test_pull_idempotent` | Running twice produces same output |
| `test_refresh_mock_api` | Refresh specific items against recorded responses |
| `test_refresh_partial_failure` | Some items 404, others succeed, continues |
| `test_pagination_mock` | Verify pagination following with recorded Link headers |
| `test_comments_pagination_mock` | Verify comment pagination works |

**Recorded Response Files** (for CI):

Store sample API responses in `src/github/testdata/`:
```
src/github/testdata/
├── issues_page1.json      # First page of issues
├── issues_page2.json      # Second page (for pagination test)
├── issue_42.json          # Single issue response
├── issue_42_comments.json # Comments for issue 42
├── pr_45.json             # PR response (has pull_request field)
└── rate_limit.json        # 403 response with rate limit headers
```

### Smoke Tests

```bash
test_github_integration() {
    # Setup
    cd /tmp && mkdir -p test_github && cd test_github
    ligi init
    export GITHUB_TOKEN="$TEST_GITHUB_TOKEN"

    # Execute: Pull a small public repo
    ligi github pull -r octocat/Hello-World

    # Assert: Files created
    [ -d "art/github/octocat/Hello-World" ] || { echo "FAIL: directory not created"; exit 1; }
    [ -f "art/github/octocat/Hello-World/index.md" ] || { echo "FAIL: index.md not created"; exit 1; }
    ls art/github/octocat/Hello-World/*.md | grep -q "issue-" || { echo "FAIL: no issue files"; exit 1; }

    # Assert: Tags present
    grep -q "\[\[t/github\]\]" art/github/octocat/Hello-World/issue-*.md || { echo "FAIL: missing tags"; exit 1; }

    # Cleanup
    cd / && rm -rf /tmp/test_github

    echo "PASS: test_github_integration"
}
```

---

## Part 8: Acceptance Criteria

- [ ] `ligi github pull -r owner/repo` fetches all issues and PRs
- [ ] `ligi github pull` infers repo from git remote
- [ ] `ligi github refresh 1-10 -r owner/repo` refreshes specific items
- [ ] Documents contain correct tags: `[[t/github]]`, `[[t/github/repo/...]]`, etc.
- [ ] Comments are included in documents
- [ ] `ligi q t github/repo/ligi` returns matching documents
- [ ] Rate limiting is handled gracefully with warnings
- [ ] Error messages are clear and actionable
- [ ] All edge cases from Part 6 are handled
- [ ] All unit tests pass
- [ ] Smoke tests pass against a real repository
- [ ] Help text documents all options
- [ ] No regressions in existing tests (`zig build test`)

---

## Part 9: Examples

```
$ ligi github pull -r evan-forbes/ligi
Fetching issues from evan-forbes/ligi...
  [1/3] Fetching page 1 of issues...
  [2/3] Fetching comments...
  [3/3] Writing documents...
created: art/github/evan-forbes/ligi/issue-42.md
created: art/github/evan-forbes/ligi/issue-38.md
created: art/github/evan-forbes/ligi/pr-45.md
created: art/github/evan-forbes/ligi/pr-41.md
created: art/github/evan-forbes/ligi/index.md
Synced 4 items from evan-forbes/ligi

$ ligi github pull
Inferred repository: evan-forbes/ligi (from git remote)
Fetching issues from evan-forbes/ligi...
...

$ ligi github refresh 42,45
Refreshing 2 items from evan-forbes/ligi...
updated: art/github/evan-forbes/ligi/issue-42.md
updated: art/github/evan-forbes/ligi/pr-45.md

$ ligi q t github/repo/evan-forbes/ligi & github/state/open
art/github/evan-forbes/ligi/issue-42.md
art/github/evan-forbes/ligi/pr-45.md

$ ligi github pull -r private/repo
error: github: token required but not found (set GITHUB_TOKEN or add to art/config/github.toml)
```

---

## Appendix A: Open Questions

- [x] ~~Should we support GitHub Enterprise?~~ Not in v1, document as future consideration
- [x] ~~How to handle issue/PR number collisions across repos?~~ Namespaced by repo directory
- [x] ~~Should comments be fetched?~~ Yes, included in document

## Appendix B: Future Considerations

**Near-term (v1.1)**:
- `--dry-run` flag: Show what would be fetched without writing files
- `--limit N` flag: Cap number of issues fetched (useful for testing)
- `--labels` filter: Only fetch issues with specific labels
- PR review comments: Fetch inline code comments via `/pulls/:number/comments`

**Medium-term**:
- GitHub Enterprise support (custom API base URL, certificate handling)
- Incremental sync (only fetch items updated since last sync)
- Better rate limit handling with exponential backoff
- Caching layer to reduce API calls
- Support for filtering by assignee, milestone

**Long-term**:
- GitHub Discussions integration
- GitHub Projects integration
- Push changes back to GitHub (create/update issues)
- Webhook listener for real-time updates

## Appendix C: Implementation Order (Recommended)

1. **Step 1**: Create module skeleton (foundation)
2. **Step 6**: Repository ID parsing (can be tested in isolation)
3. **Step 2**: Config loading (needed for client)
4. **Step 3**: HTTP client wrapper (core networking)
5. **Step 4**: JSON parsing (depends on client for testing)
6. **Step 5**: Markdown generation (pure function, parallelizable)
7. **Step 7**: CLI command structure (ties everything together)
8. **Step 8**: Pull subcommand (main feature)
9. **Step 9**: Refresh subcommand (builds on pull)
10. **Step 10**: Documentation (polish)

---

*Generated from art/template/impl_plan.md*
