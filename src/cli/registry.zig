//! CommandRegistry: Command routing using zig-clap for argument parsing.

const std = @import("std");
const clap = @import("clap");
const core = @import("../core/mod.zig");

/// Version string for ligi
pub const VERSION = "0.1.0";

/// Command definition with metadata
pub const CommandDef = struct {
    /// Canonical name (used in help, documentation)
    canonical: []const u8,
    /// All names that invoke this command (including canonical)
    names: []const []const u8,
    /// Short description for help listing
    description: []const u8,
    /// Long description for command-specific help
    long_description: ?[]const u8 = null,
};

/// Registry of all commands
pub const CommandRegistry = struct {
    commands: []const CommandDef,
    version: []const u8,

    const Self = @This();

    /// Find command by any of its names (canonical or alias)
    pub fn findCommand(self: Self, name: []const u8) ?*const CommandDef {
        for (self.commands) |*cmd| {
            for (cmd.names) |cmd_name| {
                if (std.mem.eql(u8, name, cmd_name)) {
                    return cmd;
                }
            }
        }
        return null;
    }

    /// Generate main help text
    pub fn printHelp(self: Self, writer: anytype) !void {
        try writer.print("ligi v{s} - Human and LLM readable project management\n\n", .{self.version});
        try writer.writeAll("Usage: ligi [options] <command> [command-options]\n\n");
        try writer.writeAll("Commands:\n");
        for (self.commands) |cmd| {
            var names_buf: [64]u8 = undefined;
            var names_len: usize = 0;
            for (cmd.names, 0..) |name, idx| {
                if (idx > 0) {
                    names_buf[names_len] = ',';
                    names_buf[names_len + 1] = ' ';
                    names_len += 2;
                }
                @memcpy(names_buf[names_len..][0..name.len], name);
                names_len += name.len;
            }
            try writer.print("  {s:<16} {s}\n", .{ names_buf[0..names_len], cmd.description });
        }
        try writer.writeAll("\nOptions:\n");
        try writer.writeAll("  -h, --help       Show this help message\n");
        try writer.writeAll("  -v, --version    Show version\n");
        try writer.writeAll("  -q, --quiet      Suppress non-error output\n");
    }

    /// Generate command-specific help
    pub fn printCommandHelp(self: Self, cmd: *const CommandDef, writer: anytype) !void {
        _ = self;
        try writer.print("Usage: ligi {s} [options]\n\n", .{cmd.canonical});
        if (cmd.long_description) |desc| {
            try writer.print("{s}\n\n", .{desc});
        } else {
            try writer.print("{s}\n\n", .{cmd.description});
        }
    }
};

/// All command definitions
pub const COMMANDS = [_]CommandDef{
    .{
        .canonical = "init",
        .names = &.{"init"},
        .description = "Initialize ligi in current directory or globally",
        .long_description =
        \\Initialize ligi directory structure.
        \\
        \\Creates art/ directory with index/, template/, config/, and archive/
        \\subdirectories. Also creates initial ligi_tags.md index file.
        \\
        \\Use --global to initialize ~/.ligi/ for global artifacts.
        ,
    },
    .{
        .canonical = "index",
        .names = &.{ "index", "i" },
        .description = "Index tags and links in documents",
    },
    .{
        .canonical = "query",
        .names = &.{ "query", "q" },
        .description = "Query documents by tags or links",
    },
    .{
        .canonical = "archive",
        .names = &.{ "archive", "a" },
        .description = "Move document to archive",
    },
    .{
        .canonical = "check",
        .names = &.{"check"},
        .description = "Validate global index and markdown links",
        .long_description =
        \\Validate global index entries and markdown links.
        \\
        \\Checks that all registered repos exist and have valid art/ directories.
        \\Reports OK, BROKEN, or MISSING_ART for each entry.
        ,
    },
    .{
        .canonical = "backup",
        .names = &.{"backup"},
        .description = "Backup global ~/.ligi repo or install cron job",
        .long_description =
        \\Backup the global ~/.ligi git repo, or install a cron job.
        \\
        \\Usage:
        \\  ligi backup              Run backup now
        \\  ligi backup --install    Install cron job (default schedule 0 3 * * *)
        \\  ligi backup --install --schedule "0 */6 * * *"
        ,
    },
    .{
        .canonical = "template",
        .names = &.{ "template", "t" },
        .description = "Fill a template from TOML frontmatter",
        .long_description =
        \\Fill templates with interactive prompts.
        \\
        \\Subcommands:
        \\  fill, f    Fill a template interactively
        \\
        \\Usage: ligi t f [path] [-c|--clipboard]
        \\
        \\If path is omitted, fzf is launched to select a template.
        ,
    },
    .{
        .canonical = "v",
        .names = &.{ "v", "voice" },
        .description = "Record and transcribe audio locally (Linux only)",
        .long_description =
        \\Record audio from the microphone and transcribe locally using whisper.cpp (Linux only).
        \\
        \\Options:
        \\  --timeout <duration>     Max recording time (default: 10m; supports s/m/h)
        \\  --model-size <size>      Model size: tiny|base|small|medium|large
        \\                           or tiny.en|base.en|small.en|medium.en (default: base.en)
        \\  --model <path>           Use explicit model path (overrides --model-size)
        \\  --no-download            Do not download model if missing
        \\  -c, --clipboard          Copy transcript to clipboard
        \\  -h, --help               Show this help
        \\
        \\Controls (Linux): Ctrl+C or Esc to cancel, Space to pause/resume
        ,
    },
    .{
        .canonical = "serve",
        .names = &.{ "serve", "s" },
        .description = "Serve markdown files with GFM + Mermaid rendering",
        .long_description =
        \\Serve markdown files locally with GitHub Flavored Markdown rendering.
        \\
        \\Starts a local HTTP server that renders Markdown files with GFM
        \\features (tables, task lists, strikethrough) and Mermaid diagrams.
        \\All assets are embedded - no CDN dependencies.
        \\
        \\Usage: ligi serve [options]
        \\
        \\Options:
        \\  --root <path>   Base directory to serve (default: ./art or .)
        \\  --host <host>   Host to bind (default: 127.0.0.1)
        \\  --port <port>   Port to bind (default: 8777)
        \\  --open          Open browser after starting server
        \\  --no-index      Disable directory listing
        ,
    },
    .{
        .canonical = "globalize",
        .names = &.{ "globalize", "glob", "g" },
        .description = "Copy local assets to global ~/.ligi directory",
        .long_description =
        \\Copy local ligi assets to the global ~/.ligi directory.
        \\
        \\Makes art documents, templates, data, and media accessible across
        \\all ligi repositories. If a target file already exists, prompts
        \\for confirmation before overwriting.
        \\
        \\Usage: ligi globalize <path>... [-f|--force]
        \\
        \\Options:
        \\  -f, --force    Overwrite existing files without prompting
        \\  -h, --help     Show this help message
        \\
        \\Examples:
        \\  ligi globalize art/template/my_template.md
        \\  ligi glob data/reference.csv media/diagram.png
        \\  ligi g art/template/*.md --force
        ,
    },
};

/// Build the ligi command registry
pub fn buildRegistry() CommandRegistry {
    return .{
        .version = VERSION,
        .commands = &COMMANDS,
    };
}

/// Global options parsed by clap
const GlobalParams = clap.parseParamsComptime(
    \\-h, --help     Show this help message
    \\-v, --version  Show version
    \\-q, --quiet    Suppress non-error output
    \\<str>...
    \\
);

/// Init command options
const InitParams = clap.parseParamsComptime(
    \\-h, --help         Show this help message
    \\-g, --global       Initialize global ~/.ligi instead of local ./art
    \\-r, --root <str>   Override target directory
    \\-q, --quiet        Suppress non-error output
    \\
);

/// Check command options
const CheckParams = clap.parseParamsComptime(
    \\-h, --help         Show this help message
    \\-o, --output <str> Output format: text (default) or json
    \\-r, --root <str>   Limit scope to specific root
    \\-p, --prune        Remove broken entries from indexes
    \\
);

/// Template command options
const TemplateParams = clap.parseParamsComptime(
    \\-h, --help         Show this help message
    \\-c, --clipboard    Copy output to clipboard
    \\<str>...
    \\
);

/// Backup command options
const BackupParams = clap.parseParamsComptime(
    \\-h, --help            Show this help message
    \\-i, --install         Install cron job for global backup
    \\-s, --schedule <str>  Cron schedule (default: "0 3 * * *")
    \\-q, --quiet           Suppress non-error output
    \\
);

/// Index command options
const IndexParams = clap.parseParamsComptime(
    \\-h, --help         Show this help message
    \\-r, --root <str>   Repository root directory
    \\-f, --file <str>   Index single file only
    \\-g, --global       Rebuild global tag indexes from all repos
    \\--no-local         Do not update local tag indexes (with --global)
    \\-q, --quiet        Suppress non-error output
    \\
);

/// Query command options
const QueryParams = clap.parseParamsComptime(
    \\-h, --help         Show this help message
    \\<str>...
    \\
);

/// Serve command options
const ServeParams = clap.parseParamsComptime(
    \\-h, --help           Show this help message
    \\-r, --root <str>     Base directory to serve (default: ./art or .)
    \\-H, --host <str>     Host to bind (default: 127.0.0.1)
    \\-p, --port <u16>     Port to bind (default: 8777)
    \\-o, --open           Open browser after starting server
    \\-n, --no-index       Disable directory listing
    \\
);

/// Voice command options
const VoiceParams = clap.parseParamsComptime(
    \\-h, --help               Show this help message
    \\--timeout <str>          Max recording time (default: 10m; supports s/m/h)
    \\--model-size <str>       Model size: tiny|base|small|medium|large or tiny.en|base.en|small.en|medium.en
    \\--model <str>            Use explicit model path (overrides --model-size)
    \\--no-download            Do not download model if missing
    \\-c, --clipboard          Copy transcript to clipboard
    \\
);

/// Globalize command options
const GlobalizeParams = clap.parseParamsComptime(
    \\-h, --help         Show this help message
    \\-f, --force        Overwrite existing files without prompting
    \\<str>...
    \\
);

/// Run the CLI with the given arguments
pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const registry = buildRegistry();

    // Parse global options first, stopping at first positional (command)
    var diag: clap.Diagnostic = .{};
    var iter = clap.args.SliceIterator{ .args = args };

    var global_res = clap.parseEx(clap.Help, &GlobalParams, clap.parsers.default, &iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
        .terminating_positional = 0, // Stop after command name
    }) catch |err| {
        try diag.report(stderr, err);
        return 1;
    };
    defer global_res.deinit();

    const global_args = global_res.args;
    const positionals = global_res.positionals[0]; // <str>... is first positional

    // Handle --help (no command)
    if (global_args.help != 0) {
        // Check if there's a command for command-specific help
        if (positionals.len > 0) {
            const cmd_name = positionals[0];
            if (registry.findCommand(cmd_name)) |cmd| {
                try registry.printCommandHelp(cmd, stdout);
                return 0;
            }
        }
        try registry.printHelp(stdout);
        return 0;
    }

    // Handle --version
    if (global_args.version != 0) {
        try stdout.print("ligi {s}\n", .{VERSION});
        return 0;
    }

    // No command - show help
    if (positionals.len == 0) {
        try registry.printHelp(stdout);
        return 0;
    }

    const cmd_name = positionals[0];

    // Find command
    const cmd = registry.findCommand(cmd_name) orelse {
        try stderr.print("error: unknown command '{s}'\n\n", .{cmd_name});
        try registry.printHelp(stderr);
        return 1;
    };

    // Get remaining arguments after the command
    const remaining_args = args[iter.index..];

    // Dispatch to command handler
    if (std.mem.eql(u8, cmd.canonical, "init")) {
        return runInitCommand(allocator, remaining_args, global_args.quiet != 0, stdout, stderr);
    } else if (std.mem.eql(u8, cmd.canonical, "index")) {
        return runIndexCommand(allocator, remaining_args, global_args.quiet != 0, stdout, stderr);
    } else if (std.mem.eql(u8, cmd.canonical, "query")) {
        return runQueryCommand(allocator, remaining_args, global_args.quiet != 0, stdout, stderr);
    } else if (std.mem.eql(u8, cmd.canonical, "archive")) {
        try stderr.writeAll("error: 'archive' command not yet implemented\n");
        return 1;
    } else if (std.mem.eql(u8, cmd.canonical, "check")) {
        return runCheckCommand(allocator, remaining_args, stdout, stderr);
    } else if (std.mem.eql(u8, cmd.canonical, "backup")) {
        return runBackupCommand(allocator, remaining_args, global_args.quiet != 0, stdout, stderr);
    } else if (std.mem.eql(u8, cmd.canonical, "template")) {
        return runTemplateCommand(allocator, remaining_args, stdout, stderr);
    } else if (std.mem.eql(u8, cmd.canonical, "v")) {
        return runVoiceCommand(allocator, remaining_args, stdout, stderr);
    } else if (std.mem.eql(u8, cmd.canonical, "serve")) {
        return runServeCommand(allocator, remaining_args, stdout, stderr);
    } else if (std.mem.eql(u8, cmd.canonical, "globalize")) {
        return runGlobalizeCommand(allocator, remaining_args, stdout, stderr);
    }

    try stderr.print("error: command '{s}' has no handler\n", .{cmd.canonical});
    return 127;
}

/// Run the init command with clap parsing
fn runInitCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    global_quiet: bool,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var diag: clap.Diagnostic = .{};
    var iter = clap.args.SliceIterator{ .args = args };

    var res = clap.parseEx(clap.Help, &InitParams, clap.parsers.default, &iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.report(stderr, err);
        return 1;
    };
    defer res.deinit();

    // Handle --help for init
    if (res.args.help != 0) {
        const registry = buildRegistry();
        if (registry.findCommand("init")) |cmd| {
            try registry.printCommandHelp(cmd, stdout);
        }
        return 0;
    }

    const init_cmd = @import("commands/init.zig");
    const quiet = (res.args.quiet != 0) or global_quiet;

    return init_cmd.run(
        allocator,
        res.args.global != 0,
        res.args.root,
        quiet,
        stdout,
        stderr,
    );
}

/// Run the check command with clap parsing
fn runCheckCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var diag: clap.Diagnostic = .{};
    var iter = clap.args.SliceIterator{ .args = args };

    var res = clap.parseEx(clap.Help, &CheckParams, clap.parsers.default, &iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.report(stderr, err);
        return 1;
    };
    defer res.deinit();

    // Handle --help for check
    if (res.args.help != 0) {
        const registry = buildRegistry();
        if (registry.findCommand("check")) |cmd| {
            try registry.printCommandHelp(cmd, stdout);
        }
        try stdout.writeAll("\nOptions:\n");
        try stdout.writeAll("  -o, --output <str>  Output format: text (default) or json\n");
        try stdout.writeAll("  -r, --root <path>   Limit scope to specific root\n");
        try stdout.writeAll("  -p, --prune         Remove broken entries from indexes\n");
        return 0;
    }

    const check_cmd = @import("commands/check.zig");

    // Parse output format
    const output_format: check_cmd.OutputFormat = if (res.args.output) |fmt| blk: {
        if (std.mem.eql(u8, fmt, "json")) {
            break :blk .json;
        } else if (std.mem.eql(u8, fmt, "text")) {
            break :blk .text;
        } else {
            try stderr.print("error: invalid output format '{s}', expected 'text' or 'json'\n", .{fmt});
            return 1;
        }
    } else .text;

    return check_cmd.run(
        allocator,
        output_format,
        res.args.root,
        res.args.prune != 0,
        stdout,
        stderr,
    );
}

/// Run the template command with subcommand parsing
fn runTemplateCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    // Check for subcommand
    if (args.len == 0) {
        try stderr.writeAll("error: missing subcommand\n");
        try stderr.writeAll("usage: ligi t <fill|f> [path] [-c|--clipboard]\n");
        return 1;
    }

    const subcmd = args[0];
    const subcmd_args = args[1..];

    // Handle fill subcommand
    if (std.mem.eql(u8, subcmd, "fill") or std.mem.eql(u8, subcmd, "f")) {
        return runTemplateFillCommand(allocator, subcmd_args, stdout, stderr);
    }

    // Handle --help at template level
    if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        const registry = buildRegistry();
        if (registry.findCommand("template")) |cmd| {
            try registry.printCommandHelp(cmd, stdout);
        }
        return 0;
    }

    try stderr.print("error: unknown subcommand '{s}'\n", .{subcmd});
    try stderr.writeAll("usage: ligi t <fill|f> [path] [-c|--clipboard]\n");
    return 1;
}

/// Run the voice command with clap parsing
fn runVoiceCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var diag: clap.Diagnostic = .{};
    var iter = clap.args.SliceIterator{ .args = args };

    var res = clap.parseEx(clap.Help, &VoiceParams, clap.parsers.default, &iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.report(stderr, err);
        return 1;
    };
    defer res.deinit();

    // Handle --help for voice
    if (res.args.help != 0) {
        const registry = buildRegistry();
        if (registry.findCommand("v")) |cmd| {
            try registry.printCommandHelp(cmd, stdout);
        }
        return 0;
    }

    const voice_cmd = @import("commands/voice.zig");

    return voice_cmd.run(
        allocator,
        res.args.timeout,
        res.args.@"model-size",
        res.args.model,
        res.args.@"no-download" == 0,
        res.args.clipboard != 0,
        stdout,
        stderr,
    );
}

/// Run the backup command with clap parsing
fn runBackupCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    global_quiet: bool,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var diag: clap.Diagnostic = .{};
    var iter = clap.args.SliceIterator{ .args = args };

    var res = clap.parseEx(clap.Help, &BackupParams, clap.parsers.default, &iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.report(stderr, err);
        return 1;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        const registry = buildRegistry();
        if (registry.findCommand("backup")) |cmd| {
            try registry.printCommandHelp(cmd, stdout);
        }
        return 0;
    }

    const backup_cmd = @import("commands/backup.zig");
    const quiet = (res.args.quiet != 0) or global_quiet;

    return backup_cmd.run(
        allocator,
        res.args.install != 0,
        res.args.schedule,
        quiet,
        stdout,
        stderr,
    );
}

/// Run the index command with clap parsing
fn runIndexCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    global_quiet: bool,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var diag: clap.Diagnostic = .{};
    var iter = clap.args.SliceIterator{ .args = args };

    var res = clap.parseEx(clap.Help, &IndexParams, clap.parsers.default, &iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.report(stderr, err);
        return 1;
    };
    defer res.deinit();

    // Handle --help for index
    if (res.args.help != 0) {
        const registry = buildRegistry();
        if (registry.findCommand("index")) |cmd| {
            try registry.printCommandHelp(cmd, stdout);
        }
        try stdout.writeAll("\nOptions:\n");
        try stdout.writeAll("  -r, --root <path>   Repository root directory\n");
        try stdout.writeAll("  -f, --file <path>   Index single file only\n");
        try stdout.writeAll("  -g, --global        Rebuild global tag indexes from all repos\n");
        try stdout.writeAll("  --no-local          Do not update local tag indexes (with --global)\n");
        try stdout.writeAll("  -q, --quiet         Suppress non-error output\n");
        return 0;
    }

    const index_cmd = @import("commands/index.zig");
    const quiet = (res.args.quiet != 0) or global_quiet;

    return index_cmd.run(
        allocator,
        res.args.root,
        res.args.file,
        res.args.global != 0,
        res.args.@"no-local" != 0,
        quiet,
        stdout,
        stderr,
    );
}

/// Run the query command
fn runQueryCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    global_quiet: bool,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    // For query, we pass all remaining args to the command handler
    // since it has subcommands (t/tag) and complex argument structure
    const query_cmd = @import("commands/query.zig");
    return query_cmd.run(allocator, args, stdout, stderr, global_quiet);
}

/// Run the template fill subcommand
fn runTemplateFillCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var diag: clap.Diagnostic = .{};
    var iter = clap.args.SliceIterator{ .args = args };

    var res = clap.parseEx(clap.Help, &TemplateParams, clap.parsers.default, &iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.report(stderr, err);
        return 1;
    };
    defer res.deinit();

    // Handle --help for fill
    if (res.args.help != 0) {
        try stdout.writeAll("Usage: ligi t f [path] [-c|--clipboard]\n\n");
        try stdout.writeAll("Fill a template interactively.\n\n");
        try stdout.writeAll("Arguments:\n");
        try stdout.writeAll("  [path]         Path to template file (launches fzf if omitted)\n\n");
        try stdout.writeAll("Options:\n");
        try stdout.writeAll("  -c, --clipboard  Copy output to clipboard\n");
        try stdout.writeAll("  -h, --help       Show this help\n");
        return 0;
    }

    const template_cmd = @import("commands/template.zig");
    const positionals = res.positionals[0];
    const path: ?[]const u8 = if (positionals.len > 0) positionals[0] else null;

    return template_cmd.runFill(
        allocator,
        path,
        res.args.clipboard != 0,
        stdout,
        stderr,
    );
}

/// Run the serve command with clap parsing
fn runServeCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var diag: clap.Diagnostic = .{};
    var iter = clap.args.SliceIterator{ .args = args };

    var res = clap.parseEx(clap.Help, &ServeParams, clap.parsers.default, &iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.report(stderr, err);
        return 1;
    };
    defer res.deinit();

    // Handle --help for serve
    if (res.args.help != 0) {
        const registry = buildRegistry();
        if (registry.findCommand("serve")) |cmd| {
            try registry.printCommandHelp(cmd, stdout);
        }
        return 0;
    }

    const serve_cmd = @import("commands/serve.zig");

    return serve_cmd.run(
        allocator,
        res.args.root,
        res.args.host,
        res.args.port,
        res.args.open != 0,
        res.args.@"no-index" != 0,
        stdout,
        stderr,
    );
}

/// Run the globalize command with clap parsing
fn runGlobalizeCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var diag: clap.Diagnostic = .{};
    var iter = clap.args.SliceIterator{ .args = args };

    var res = clap.parseEx(clap.Help, &GlobalizeParams, clap.parsers.default, &iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.report(stderr, err);
        return 1;
    };
    defer res.deinit();

    // Handle --help for globalize
    if (res.args.help != 0) {
        const registry = buildRegistry();
        if (registry.findCommand("globalize")) |cmd| {
            try registry.printCommandHelp(cmd, stdout);
        }
        return 0;
    }

    const globalize_cmd = @import("commands/globalize.zig");
    const positionals = res.positionals[0]; // <str>... is first positional

    return globalize_cmd.run(
        allocator,
        positionals,
        res.args.force != 0,
        stdout,
        stderr,
    );
}

// ============================================================================
// Tests
// ============================================================================

test "findCommand returns command for canonical name" {
    const registry = buildRegistry();
    const cmd = registry.findCommand("init");
    try std.testing.expect(cmd != null);
    try std.testing.expectEqualStrings("init", cmd.?.canonical);
}

test "findCommand returns same command for alias" {
    const registry = buildRegistry();
    const cmd_canonical = registry.findCommand("index");
    const cmd_alias = registry.findCommand("i");
    try std.testing.expect(cmd_canonical != null);
    try std.testing.expect(cmd_alias != null);
    try std.testing.expectEqualStrings(cmd_canonical.?.canonical, cmd_alias.?.canonical);
}

test "findCommand returns null for unknown command" {
    const registry = buildRegistry();
    const cmd = registry.findCommand("nonexistent");
    try std.testing.expect(cmd == null);
}

test "printHelp includes all commands" {
    const registry = buildRegistry();
    var buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try registry.printHelp(stream.writer());
    const output = stream.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, output, "init") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "index") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "query") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "archive") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "check") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "backup") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "serve") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "globalize") != null);
}

test "printHelp shows aliases" {
    const registry = buildRegistry();
    var buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try registry.printHelp(stream.writer());
    const output = stream.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, output, "index, i") != null);
}

test "clap module is available" {
    // Verify clap is importable and has expected types
    _ = clap.Diagnostic;
    _ = clap.parseParamsComptime;
}

test "GlobalParams are valid" {
    // Verify global params compile correctly
    _ = GlobalParams;
}

test "InitParams are valid" {
    // Verify init params compile correctly
    _ = InitParams;
}

test "CheckParams are valid" {
    // Verify check params compile correctly
    _ = CheckParams;
}

test "TemplateParams are valid" {
    // Verify template params compile correctly
    _ = TemplateParams;
}

test "BackupParams are valid" {
    // Verify backup params compile correctly
    _ = BackupParams;
}

test "IndexParams are valid" {
    // Verify index params compile correctly
    _ = IndexParams;
}

test "QueryParams are valid" {
    // Verify query params compile correctly
    _ = QueryParams;
}

test "ServeParams are valid" {
    // Verify serve params compile correctly
    _ = ServeParams;
}

test "GlobalizeParams are valid" {
    // Verify globalize params compile correctly
    _ = GlobalizeParams;
}

test "findCommand returns globalize for all aliases" {
    const registry = buildRegistry();
    const cmd_canonical = registry.findCommand("globalize");
    const cmd_glob = registry.findCommand("glob");
    const cmd_g = registry.findCommand("g");

    try std.testing.expect(cmd_canonical != null);
    try std.testing.expect(cmd_glob != null);
    try std.testing.expect(cmd_g != null);
    try std.testing.expectEqualStrings("globalize", cmd_canonical.?.canonical);
    try std.testing.expectEqualStrings("globalize", cmd_glob.?.canonical);
    try std.testing.expectEqualStrings("globalize", cmd_g.?.canonical);
}
