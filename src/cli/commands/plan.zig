//! The `ligi plan` command implementation.

const std = @import("std");
const template = @import("../../template/mod.zig");
const core = @import("../../core/mod.zig");

const fs = core.fs;
const paths = core.paths;
const tag_index = core.tag_index;
const workspace = core.workspace;
const epoch = std.time.epoch;

pub const PlanKind = enum {
    day,
    week,
    month,
    quarter,
    feature,
    chore,
    refactor,
    perf,
};

pub const PlanLength = enum {
    long,
    short,
};

pub const PlanOptions = struct {
    kind: PlanKind,
    name: ?[]const u8 = null,
    date_arg: ?[]const u8 = null,
    length: PlanLength = .long,
    inbox: ?bool = null,
    dir_mode: bool = false,
    quiet: bool = false,
};

const Date = struct {
    year: u16,
    month: u8,
    day: u8,
};

const TimeTags = struct {
    date: Date,
    date_short: []const u8,
    date_long: []const u8,
    week_value: []const u8,
    month_value: []const u8,
    quarter_value: []const u8,
    day_tag: []const u8,
    week_tag: []const u8,
    month_tag: []const u8,
    quarter_tag: []const u8,
    prev_day_tag: []const u8,
    prev_week_tag: []const u8,
    prev_month_tag: []const u8,
    prev_quarter_tag: []const u8,
};

pub fn parseKind(input: []const u8) ?PlanKind {
    if (std.mem.eql(u8, input, "day") or std.mem.eql(u8, input, "daily")) return .day;
    if (std.mem.eql(u8, input, "week") or std.mem.eql(u8, input, "weekly")) return .week;
    if (std.mem.eql(u8, input, "month") or std.mem.eql(u8, input, "monthly")) return .month;
    if (std.mem.eql(u8, input, "quarter") or std.mem.eql(u8, input, "quarterly")) return .quarter;
    if (std.mem.eql(u8, input, "feature")) return .feature;
    if (std.mem.eql(u8, input, "chore")) return .chore;
    if (std.mem.eql(u8, input, "refactor")) return .refactor;
    if (std.mem.eql(u8, input, "perf")) return .perf;
    return null;
}

pub fn parseLength(input: []const u8) ?PlanLength {
    if (std.mem.eql(u8, input, "long")) return .long;
    if (std.mem.eql(u8, input, "short")) return .short;
    return null;
}

pub fn run(
    allocator: std.mem.Allocator,
    options: PlanOptions,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const date = if (options.date_arg) |value|
        parseDate(value) catch |err| {
            renderDateError(value, err, stderr) catch {};
            return 1;
        }
    else
        todayDateUtc() catch |err| {
            try stderr.print("error: plan: failed to determine current date: {s}\n", .{@errorName(err)});
            return 1;
        };

    const time_tags = try buildTimeTags(arena_alloc, date);

    const use_inbox = options.inbox orelse defaultInbox(options.kind);

    if (requiresName(options.kind) and options.name == null) {
        try stderr.print("error: plan: {s} requires a file name\n", .{planKindLabel(options.kind)});
        return 1;
    }
    if (requiresName(options.kind)) {
        const raw_name = options.name orelse "";
        const trimmed = std.mem.trim(u8, raw_name, " \t\r\n");
        if (trimmed.len == 0) {
            try stderr.print("error: plan: {s} requires a non-empty file name\n", .{planKindLabel(options.kind)});
            return 1;
        }
    }

    // Resolve art path via workspace detection
    const art_path = try workspace.resolveArtPath(arena_alloc, null, stderr) orelse return 1;

    const target = try resolveTarget(
        arena_alloc,
        options.kind,
        options.length,
        options.name,
        use_inbox,
        options.dir_mode,
        &time_tags,
    );

    const created = try ensurePlanDoc(
        arena_alloc,
        art_path,
        target,
        options.kind,
        options.name,
        &time_tags,
        options.dir_mode,
        options.quiet,
        stdout,
        stderr,
    );

    const tags_to_add = try calendarTagsForKind(arena_alloc, options.kind, &time_tags);

    try updateCalendar(
        arena_alloc,
        art_path,
        tags_to_add,
        options.quiet,
        stdout,
        stderr,
    );

    // Build full output path for display
    const full_output = try std.fs.path.join(arena_alloc, &.{ art_path, target.output_rel });
    if (!options.quiet and !created) {
        try stdout.print("exists: {s}\n", .{full_output});
    }

    return 0;
}

fn defaultInbox(kind: PlanKind) bool {
    _ = kind;
    return true;
}

fn requiresName(kind: PlanKind) bool {
    return switch (kind) {
        .feature, .chore, .refactor, .perf => true,
        else => false,
    };
}

fn planKindLabel(kind: PlanKind) []const u8 {
    return switch (kind) {
        .day => "day",
        .week => "week",
        .month => "month",
        .quarter => "quarter",
        .feature => "feature",
        .chore => "chore",
        .refactor => "refactor",
        .perf => "perf",
    };
}

const PlanTarget = struct {
    template_rel: []const u8,
    output_rel: []const u8,
    file_in_art: []const u8,
};

fn resolveTarget(
    allocator: std.mem.Allocator,
    kind: PlanKind,
    length: PlanLength,
    name: ?[]const u8,
    use_inbox: bool,
    dir_mode: bool,
    tags: *const TimeTags,
) !PlanTarget {
    const template_rel = templatePathForKind(kind, length);

    const base_dir = switch (kind) {
        .day, .week, .month, .quarter => "calendar",
        else => if (use_inbox) "inbox" else "plan",
    };
    const kind_dir = switch (kind) {
        .day => "day",
        .week => "week",
        .month => "month",
        .quarter => "quarter",
        .feature => "feature",
        .chore => "chore",
        .refactor => "refactor",
        .perf => "perf",
    };

    const filename = switch (kind) {
        .day => tags.date_short,
        .week => tags.week_value,
        .month => tags.month_value,
        .quarter => tags.quarter_value,
        .feature, .chore, .refactor, .perf => blk: {
            const raw_name = name orelse return error.MissingName;
            break :blk try normalizeItemName(allocator, raw_name);
        },
    };

    const output_rel_base = try std.fs.path.join(allocator, &.{ base_dir, kind_dir, filename });
    const output_rel_md = if (dir_mode)
        try std.fs.path.join(allocator, &.{ output_rel_base, "plan.md" })
    else if (hasMarkdownExtension(output_rel_base))
        output_rel_base
    else
        try std.fmt.allocPrint(allocator, "{s}.md", .{output_rel_base});

    // output_rel_md is now relative to art/ (e.g. "calendar/day/2026-02-03.md")
    return .{
        .template_rel = template_rel,
        .output_rel = output_rel_md,
        .file_in_art = output_rel_md,
    };
}

fn ensurePlanDoc(
    allocator: std.mem.Allocator,
    art_path: []const u8,
    target: PlanTarget,
    kind: PlanKind,
    name: ?[]const u8,
    tags: *const TimeTags,
    dir_mode: bool,
    quiet: bool,
    stdout: anytype,
    stderr: anytype,
) !bool {
    // Build full paths by joining art_path with relative paths
    const full_output = try std.fs.path.join(allocator, &.{ art_path, target.output_rel });
    const full_template = try std.fs.path.join(allocator, &.{ art_path, target.template_rel });

    if (fs.fileExists(full_output)) {
        return false;
    }

    const dir_path = std.fs.path.dirname(full_output) orelse art_path;
    switch (fs.ensureDirRecursive(dir_path)) {
        .ok => {},
        .err => |e| {
            try e.write(stderr);
            return error.DirectoryCreateFailed;
        },
    }

    const rendered = try renderTemplate(allocator, full_template, kind, name, tags, stderr);

    // Inject auto-tags based on workspace context
    var with_auto_tags = try injectAutoTags(allocator, rendered);
    if (dir_mode) {
        with_auto_tags = try appendPlanLinksSection(allocator, with_auto_tags);
    }

    const filled = try tag_index.fillTagLinks(allocator, with_auto_tags, target.file_in_art);

    switch (fs.writeFile(full_output, filled.content)) {
        .ok => {},
        .err => |e| {
            try e.write(stderr);
            return error.WriteFailed;
        },
    }

    if (!quiet) {
        try stdout.print("created: {s}\n", .{full_output});
    }

    return true;
}

fn appendPlanLinksSection(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    const suffix =
        "\n\n## Links\n" ++
        "<!-- Add links like: - [Item](item.md) -->\n";
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ content, suffix });
}

/// Inject auto-tags (org and repo) into document content based on workspace context
fn injectAutoTags(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    // Try to detect workspace context
    const cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch return content;
    defer allocator.free(cwd);

    const ws_result = core.workspace.detectWorkspace(allocator, cwd);
    if (ws_result != .ok) {
        return content;
    }

    var ctx = ws_result.ok;
    defer ctx.deinit();

    // Don't add auto-tags if disabled
    if (!ctx.auto_tags_enabled) {
        return content;
    }

    // Build auto-tags string
    var auto_tags: std.ArrayList(u8) = .empty;
    defer auto_tags.deinit(allocator);

    // Add org tag if we have an org
    if (ctx.org_name) |org_name| {
        try auto_tags.appendSlice(allocator, " [[t/");
        try auto_tags.appendSlice(allocator, org_name);
        try auto_tags.appendSlice(allocator, "]]");
    }

    // Add repo tag (always, since we're in a workspace)
    try auto_tags.appendSlice(allocator, " [[t/");
    try auto_tags.appendSlice(allocator, ctx.name);
    try auto_tags.appendSlice(allocator, "]]");

    if (auto_tags.items.len == 0) {
        return content;
    }

    // Find the first line with tags (starts with [[t/) and append to it
    // Or find the first blank line after a heading and insert there
    var result: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var found_tag_line = false;

    while (lines.next()) |line| {
        try result.appendSlice(allocator, line);

        // Check if this line has existing tags
        if (!found_tag_line and std.mem.indexOf(u8, line, "[[t/") != null) {
            // Append auto-tags to this line (before newline)
            try result.appendSlice(allocator, auto_tags.items);
            found_tag_line = true;
        }

        try result.append(allocator, '\n');
    }

    // Remove trailing newline if original didn't have one
    if (content.len > 0 and content[content.len - 1] != '\n' and result.items.len > 0) {
        _ = result.pop();
    }

    return result.toOwnedSlice(allocator);
}

fn renderTemplate(
    allocator: std.mem.Allocator,
    template_path: []const u8,
    kind: PlanKind,
    name: ?[]const u8,
    tags: *const TimeTags,
    stderr: anytype,
) ![]const u8 {
    // Try to load template from filesystem first
    var content: []const u8 = undefined;
    var content_allocated = false;
    var abs_path: []const u8 = undefined;
    var abs_path_allocated = false;

    defer {
        if (content_allocated) allocator.free(content);
        if (abs_path_allocated) allocator.free(abs_path);
    }

    // First try the direct path
    const resolve_result = std.fs.cwd().realpathAlloc(allocator, template_path);
    if (resolve_result) |path| {
        abs_path = path;
        abs_path_allocated = true;
        const read_result = std.fs.cwd().readFileAlloc(allocator, abs_path, 1024 * 1024);
        if (read_result) |c| {
            content = c;
            content_allocated = true;
        } else |_| {
            // Try builtin fallback
            const template_name = std.fs.path.basename(template_path);
            if (core.getBuiltinTemplate(template_name)) |builtin| {
                content = builtin;
                content_allocated = false;
            } else {
                try stderr.print("error: plan: cannot read template '{s}'\n", .{abs_path});
                return error.TemplateNotFound;
            }
        }
    } else |_| {
        // Path doesn't exist - try builtin fallback
        const template_name = std.fs.path.basename(template_path);
        if (core.getBuiltinTemplate(template_name)) |builtin| {
            content = builtin;
            content_allocated = false;
            abs_path = "builtin";
            abs_path_allocated = false;
        } else {
            try stderr.print("error: plan: cannot resolve template '{s}'\n", .{template_path});
            return error.TemplateNotFound;
        }
    }

    var tmpl = template.parser.parse(allocator, content) catch |err| {
        const msg = switch (err) {
            error.MissingFrontmatterStart => "template missing '# front' marker",
            error.MissingTomlBlock => "template missing ```toml block",
            error.InvalidType => "invalid type in template frontmatter",
            error.InvalidFieldFormat => "invalid field format in template frontmatter",
            else => "invalid template frontmatter",
        };
        try stderr.print("error: plan: {s}\n", .{msg});
        return error.TemplateInvalid;
    };
    defer tmpl.deinit();

    var values = try buildTemplateValues(allocator, kind, name, tags);
    defer values.deinit();

    // Prompt for any missing fields in the template.
    var missing = try std.ArrayList(template.TemplateField).initCapacity(allocator, 0);
    defer missing.deinit(allocator);
    for (tmpl.fields) |field| {
        if (!values.contains(field.name)) {
            try missing.append(allocator, field);
        }
    }

    if (missing.items.len > 0) {
        var stdin_buf: [4096]u8 = undefined;
        var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
        var prompted = template.prompter.prompt(allocator, missing.items, &stdin_reader.interface, stderr) catch |err| {
            try stderr.print("error: plan: prompting failed: {}\n", .{err});
            return error.TemplatePromptFailed;
        };
        defer prompted.deinit();

        var it = prompted.iterator();
        while (it.next()) |entry| {
            try values.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    var output_list: std.ArrayList(u8) = .empty;
    defer output_list.deinit(allocator);

    const template_dir = std.fs.path.dirname(abs_path) orelse ".";

    template.engine.process(.{
        .values = values,
        .allocator = allocator,
        .cwd = template_dir,
    }, tmpl.body, output_list.writer(allocator), 0) catch |err| {
        if (err == error.RecursionLimitExceeded) {
            try stderr.writeAll("error: plan: include recursion limit exceeded\n");
        } else {
            try stderr.print("error: plan: template processing failed: {}\n", .{err});
        }
        return error.TemplateProcessFailed;
    };

    return try allocator.dupe(u8, output_list.items);
}

fn buildTemplateValues(
    allocator: std.mem.Allocator,
    kind: PlanKind,
    name: ?[]const u8,
    tags: *const TimeTags,
) !std.StringHashMap([]const u8) {
    var values = std.StringHashMap([]const u8).init(allocator);
    try values.put("date", tags.date_short);
    try values.put("date_long", tags.date_long);
    try values.put("week", tags.week_value);
    try values.put("month", tags.month_value);
    try values.put("quarter", tags.quarter_value);
    try values.put("day_tag", tags.day_tag);
    try values.put("week_tag", tags.week_tag);
    try values.put("month_tag", tags.month_tag);
    try values.put("quarter_tag", tags.quarter_tag);
    try values.put("prev_day_tag", tags.prev_day_tag);
    try values.put("prev_week_tag", tags.prev_week_tag);
    try values.put("prev_month_tag", tags.prev_month_tag);
    try values.put("prev_quarter_tag", tags.prev_quarter_tag);
    if (name) |item_name| {
        const trimmed = std.mem.trim(u8, item_name, " \t\r\n");
        if (trimmed.len > 0) {
            var display = trimmed;
            if (display.len > 3 and std.ascii.eqlIgnoreCase(display[display.len - 3 ..], ".md")) {
                display = display[0 .. display.len - 3];
            }
            const duped = try allocator.dupe(u8, display);
            try values.put("item", duped);
        }
    }
    try values.put("kind", planKindLabel(kind));
    return values;
}

fn calendarTagsForKind(
    allocator: std.mem.Allocator,
    kind: PlanKind,
    tags: *const TimeTags,
) ![]const []const u8 {
    var list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    _ = kind;
    try list.append(allocator, tags.day_tag);
    try list.append(allocator, tags.week_tag);
    return try list.toOwnedSlice(allocator);
}

const TagEntry = struct {
    tag: []const u8,
    key: u64,
};

const TagBucket = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(TagEntry),
    seen: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) TagBucket {
        return .{
            .allocator = allocator,
            .entries = .empty,
            .seen = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *TagBucket) void {
        self.entries.deinit(self.allocator);
        self.seen.deinit();
    }

    pub fn add(self: *TagBucket, tag: []const u8, key: u64) !void {
        if (self.seen.contains(tag)) return;
        try self.seen.put(tag, {});
        try self.entries.append(self.allocator, .{ .tag = tag, .key = key });
    }

    pub fn sortDesc(self: *TagBucket) void {
        const Ctx = struct {};
        const cmp = struct {
            fn lessThan(_: Ctx, a: TagEntry, b: TagEntry) bool {
                return a.key > b.key;
            }
        };
        std.sort.pdq(TagEntry, self.entries.items, Ctx{}, cmp.lessThan);
    }
};

fn updateCalendar(
    allocator: std.mem.Allocator,
    art_path: []const u8,
    tags_to_add: []const []const u8,
    quiet: bool,
    stdout: anytype,
    stderr: anytype,
) !void {
    const calendar_dir = try std.fs.path.join(allocator, &.{ art_path, "calendar" });
    defer allocator.free(calendar_dir);
    switch (fs.ensureDirRecursive(calendar_dir)) {
        .ok => {},
        .err => |e| {
            try e.write(stderr);
            return error.CalendarWriteFailed;
        },
    }

    const calendar_path = try std.fs.path.join(allocator, &.{ calendar_dir, "index.md" });
    defer allocator.free(calendar_path);
    const legacy_calendar_path = try std.fs.path.join(allocator, &.{ art_path, "calendar.md" });
    defer allocator.free(legacy_calendar_path);

    var existing_content: []const u8 = "";
    var existing_allocated = false;
    if (fs.fileExists(calendar_path)) {
        existing_content = switch (fs.readFile(allocator, calendar_path)) {
            .ok => |c| blk: {
                existing_allocated = true;
                break :blk c;
            },
            .err => |e| {
                try e.write(stderr);
                return error.CalendarReadFailed;
            },
        };
    } else if (fs.fileExists(legacy_calendar_path)) {
        existing_content = switch (fs.readFile(allocator, legacy_calendar_path)) {
            .ok => |c| blk: {
                existing_allocated = true;
                break :blk c;
            },
            .err => |e| {
                try e.write(stderr);
                return error.CalendarReadFailed;
            },
        };
    }

    var day_bucket = TagBucket.init(allocator);
    defer day_bucket.deinit();
    var week_bucket = TagBucket.init(allocator);
    defer week_bucket.deinit();

    if (existing_content.len > 0) {
        const tags = try tag_index.parseTagsFromContent(allocator, existing_content);
        defer tag_index.freeTags(allocator, tags);

        for (tags) |tag| {
            try addTimeTag(&day_bucket, &week_bucket, tag.name);
        }
    }

    const index_tags = try tag_index.loadTagListFromIndex(allocator, art_path, stderr);
    defer tag_index.freeTagList(allocator, index_tags);
    for (index_tags) |tag_name| {
        try addTimeTag(&day_bucket, &week_bucket, tag_name);
    }

    for (tags_to_add) |tag_name| {
        try addTimeTag(&day_bucket, &week_bucket, tag_name);
    }

    day_bucket.sortDesc();
    week_bucket.sortDesc();

    var calendar: std.ArrayList(u8) = .empty;
    defer calendar.deinit(allocator);

    try calendar.writer(allocator).writeAll(
        "# Calendar\n\n" ++
            "This file is auto-maintained by `ligi plan`. Each section is newest-first.\n\n",
    );

    try renderCalendarSection(calendar.writer(allocator), "Days", &day_bucket);
    try renderCalendarSection(calendar.writer(allocator), "Weeks", &week_bucket);

    const filled = try tag_index.fillTagLinks(allocator, calendar.items, "calendar/index.md");

    const existed = fs.fileExists(calendar_path);
    switch (fs.writeFile(calendar_path, filled.content)) {
        .ok => {},
        .err => |e| {
            try e.write(stderr);
            return error.CalendarWriteFailed;
        },
    }

    if (!quiet) {
        const verb = if (existed) "updated" else "created";
        try stdout.print("{s}: {s}\n", .{ verb, calendar_path });
    }

    if (existing_allocated) allocator.free(existing_content);
}

fn renderCalendarSection(
    writer: anytype,
    title: []const u8,
    bucket: *const TagBucket,
) !void {
    try writer.print("## {s}\n", .{title});
    for (bucket.entries.items) |entry| {
        try writer.print("- [[t/{s}]]\n", .{entry.tag});
    }
    try writer.writeByte('\n');
}

/// Get template filename (without path) for a plan kind
fn templateFileNameForKind(kind: PlanKind, length: PlanLength) []const u8 {
    return switch (kind) {
        .day => switch (length) {
            .long => "plan_day.md",
            .short => "plan_day_short.md",
        },
        .week => switch (length) {
            .long => "plan_week.md",
            .short => "plan_week_short.md",
        },
        .month => switch (length) {
            .long => "plan_month.md",
            .short => "plan_month_short.md",
        },
        .quarter => switch (length) {
            .long => "plan_quarter.md",
            .short => "plan_quarter_short.md",
        },
        .feature => switch (length) {
            .long => "plan_feature.md",
            .short => "plan_feature_short.md",
        },
        .chore => switch (length) {
            .long => "plan_chore.md",
            .short => "plan_chore_short.md",
        },
        .refactor => switch (length) {
            .long => "plan_refactor.md",
            .short => "plan_refactor_short.md",
        },
        .perf => switch (length) {
            .long => "plan_perf.md",
            .short => "plan_perf_short.md",
        },
    };
}

/// Get template path relative to art/ directory
fn templatePathForKind(kind: PlanKind, length: PlanLength) []const u8 {
    return switch (kind) {
        .day => switch (length) {
            .long => "template/plan_day.md",
            .short => "template/plan_day_short.md",
        },
        .week => switch (length) {
            .long => "template/plan_week.md",
            .short => "template/plan_week_short.md",
        },
        .month => switch (length) {
            .long => "template/plan_month.md",
            .short => "template/plan_month_short.md",
        },
        .quarter => switch (length) {
            .long => "template/plan_quarter.md",
            .short => "template/plan_quarter_short.md",
        },
        .feature => switch (length) {
            .long => "template/plan_feature.md",
            .short => "template/plan_feature_short.md",
        },
        .chore => switch (length) {
            .long => "template/plan_chore.md",
            .short => "template/plan_chore_short.md",
        },
        .refactor => switch (length) {
            .long => "template/plan_refactor.md",
            .short => "template/plan_refactor_short.md",
        },
        .perf => switch (length) {
            .long => "template/plan_perf.md",
            .short => "template/plan_perf_short.md",
        },
    };
}

fn normalizeItemName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len > 3 and std.ascii.eqlIgnoreCase(trimmed[trimmed.len - 3 ..], ".md")) {
        trimmed = trimmed[0 .. trimmed.len - 3];
    }
    return try allocator.dupe(u8, trimmed);
}

fn hasMarkdownExtension(path: []const u8) bool {
    if (path.len < 3) return false;
    return std.ascii.eqlIgnoreCase(path[path.len - 3 ..], ".md");
}

fn addTimeTag(
    day_bucket: *TagBucket,
    week_bucket: *TagBucket,
    tag_name: []const u8,
) !void {
    if (std.mem.startsWith(u8, tag_name, "t/d/")) {
        if (keyFromDay(tag_name[4..])) |key| {
            try day_bucket.add(tag_name, key);
        }
        return;
    }
    if (std.mem.startsWith(u8, tag_name, "t/w/")) {
        if (keyFromWeek(tag_name[4..])) |key| {
            try week_bucket.add(tag_name, key);
        }
        return;
    }
}

fn keyFromDay(value: []const u8) ?u64 {
    const date = parseDateShort(value) orelse return null;
    return dateKey(date.year, date.month, date.day);
}

fn keyFromWeek(value: []const u8) ?u64 {
    var it = std.mem.splitScalar(u8, value, '-');
    const year_str = it.next() orelse return null;
    const month_str = it.next() orelse return null;
    const week_str = it.next() orelse return null;
    if (it.next() != null) return null;

    if (year_str.len != 2) return null;

    const year_short = std.fmt.parseInt(u16, year_str, 10) catch return null;
    const month = std.fmt.parseInt(u8, month_str, 10) catch return null;
    const week = std.fmt.parseInt(u8, week_str, 10) catch return null;

    if (month < 1 or month > 12) return null;
    if (week < 1 or week > 5) return null;

    const year: u16 = 2000 + year_short;
    return (@as(u64, year) * 10000) + (@as(u64, month) * 100) + week;
}

fn keyFromMonth(value: []const u8) ?u64 {
    var it = std.mem.splitScalar(u8, value, '-');
    const year_str = it.next() orelse return null;
    const month_str = it.next() orelse return null;
    if (it.next() != null) return null;
    if (year_str.len != 2) return null;

    const year_short = std.fmt.parseInt(u16, year_str, 10) catch return null;
    const month = std.fmt.parseInt(u8, month_str, 10) catch return null;
    if (month < 1 or month > 12) return null;

    const year: u16 = 2000 + year_short;
    return (@as(u64, year) * 100) + month;
}

fn keyFromQuarter(value: []const u8) ?u64 {
    var it = std.mem.splitScalar(u8, value, '-');
    const year_str = it.next() orelse return null;
    const quarter_str = it.next() orelse return null;
    if (it.next() != null) return null;
    if (year_str.len != 2) return null;

    const year_short = std.fmt.parseInt(u16, year_str, 10) catch return null;
    const quarter = std.fmt.parseInt(u8, quarter_str, 10) catch return null;
    if (quarter < 1 or quarter > 4) return null;

    const year: u16 = 2000 + year_short;
    return (@as(u64, year) * 10) + quarter;
}

fn dateKey(year: u16, month: u8, day: u8) u64 {
    return (@as(u64, year) * 10000) + (@as(u64, month) * 100) + day;
}

fn parseDateShort(value: []const u8) ?Date {
    var it = std.mem.splitScalar(u8, value, '-');
    const year_str = it.next() orelse return null;
    const month_str = it.next() orelse return null;
    const day_str = it.next() orelse return null;
    if (it.next() != null) return null;
    if (year_str.len != 2) return null;

    const year_short = std.fmt.parseInt(u16, year_str, 10) catch return null;
    const month = std.fmt.parseInt(u8, month_str, 10) catch return null;
    const day = std.fmt.parseInt(u8, day_str, 10) catch return null;

    if (month < 1 or month > 12) return null;

    const year: u16 = 2000 + year_short;
    const days_in_month = epoch.getDaysInMonth(year, @enumFromInt(month));
    if (day < 1 or day > days_in_month) return null;

    return .{ .year = year, .month = month, .day = day };
}

fn buildTimeTags(allocator: std.mem.Allocator, date: Date) !TimeTags {
    const date_short = try formatDateShort(allocator, date);
    const date_long = try formatDateLong(allocator, date);
    const week_value = try formatWeekValue(allocator, date);
    const month_value = try formatMonthValue(allocator, date);
    const quarter_value = try formatQuarterValue(allocator, date);

    const day_tag = try std.fmt.allocPrint(allocator, "t/d/{s}", .{date_short});
    const week_tag = try std.fmt.allocPrint(allocator, "t/w/{s}", .{week_value});
    const month_tag = try std.fmt.allocPrint(allocator, "t/m/{s}", .{month_value});
    const quarter_tag = try std.fmt.allocPrint(allocator, "t/q/{s}", .{quarter_value});

    const epoch_day = try epochDayFromDate(date);
    const prev_day = dateFromEpochDay(if (epoch_day > 0) epoch_day - 1 else epoch_day);
    const prev_week = dateFromEpochDay(if (epoch_day >= 7) epoch_day - 7 else epoch_day);

    const prev_day_tag = try std.fmt.allocPrint(allocator, "t/d/{s}", .{try formatDateShort(allocator, prev_day)});
    const prev_week_tag = try std.fmt.allocPrint(allocator, "t/w/{s}", .{try formatWeekValue(allocator, prev_week)});
    const prev_month_tag = try std.fmt.allocPrint(allocator, "t/m/{s}", .{try formatPrevMonthValue(allocator, date)});
    const prev_quarter_tag = try std.fmt.allocPrint(allocator, "t/q/{s}", .{try formatPrevQuarterValue(allocator, date)});

    return .{
        .date = date,
        .date_short = date_short,
        .date_long = date_long,
        .week_value = week_value,
        .month_value = month_value,
        .quarter_value = quarter_value,
        .day_tag = day_tag,
        .week_tag = week_tag,
        .month_tag = month_tag,
        .quarter_tag = quarter_tag,
        .prev_day_tag = prev_day_tag,
        .prev_week_tag = prev_week_tag,
        .prev_month_tag = prev_month_tag,
        .prev_quarter_tag = prev_quarter_tag,
    };
}

fn formatDateShort(allocator: std.mem.Allocator, date: Date) ![]const u8 {
    const year_short: u8 = @intCast(date.year % 100);
    return std.fmt.allocPrint(
        allocator,
        "{d:0>2}-{d:0>2}-{d:0>2}",
        .{ year_short, date.month, date.day },
    );
}

fn formatDateLong(allocator: std.mem.Allocator, date: Date) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}",
        .{ date.year, date.month, date.day },
    );
}

fn formatMonthValue(allocator: std.mem.Allocator, date: Date) ![]const u8 {
    const year_short: u8 = @intCast(date.year % 100);
    return std.fmt.allocPrint(allocator, "{d:0>2}-{d:0>2}", .{ year_short, date.month });
}

fn formatWeekValue(allocator: std.mem.Allocator, date: Date) ![]const u8 {
    const week = weekOfMonth(date.day);
    const month_value = try formatMonthValue(allocator, date);
    return std.fmt.allocPrint(allocator, "{s}-{d}", .{ month_value, week });
}

fn formatQuarterValue(allocator: std.mem.Allocator, date: Date) ![]const u8 {
    const year_short: u8 = @intCast(date.year % 100);
    const quarter = quarterOfMonth(date.month);
    return std.fmt.allocPrint(allocator, "{d:0>2}-{d}", .{ year_short, quarter });
}

fn formatPrevMonthValue(allocator: std.mem.Allocator, date: Date) ![]const u8 {
    var year = date.year;
    var month = date.month;
    if (month == 1) {
        month = 12;
        year -= 1;
    } else {
        month -= 1;
    }
    const year_short: u8 = @intCast(year % 100);
    return std.fmt.allocPrint(allocator, "{d:0>2}-{d:0>2}", .{ year_short, month });
}

fn formatPrevQuarterValue(allocator: std.mem.Allocator, date: Date) ![]const u8 {
    var year = date.year;
    var quarter = quarterOfMonth(date.month);
    if (quarter == 1) {
        quarter = 4;
        year -= 1;
    } else {
        quarter -= 1;
    }
    const year_short: u8 = @intCast(year % 100);
    return std.fmt.allocPrint(allocator, "{d:0>2}-{d}", .{ year_short, quarter });
}

fn weekOfMonth(day: u8) u8 {
    return @intCast((day - 1) / 7 + 1);
}

fn quarterOfMonth(month: u8) u8 {
    return @intCast((month - 1) / 3 + 1);
}

fn parseDate(input: []const u8) !Date {
    var it = std.mem.splitScalar(u8, input, '-');
    const year_str = it.next() orelse return error.InvalidDate;
    const month_str = it.next() orelse return error.InvalidDate;
    const day_str = it.next() orelse return error.InvalidDate;
    if (it.next() != null) return error.InvalidDate;

    var year: u16 = 0;
    if (year_str.len == 2) {
        const short = try std.fmt.parseInt(u16, year_str, 10);
        year = 2000 + short;
    } else if (year_str.len == 4) {
        year = try std.fmt.parseInt(u16, year_str, 10);
    } else {
        return error.InvalidDate;
    }

    const month = try std.fmt.parseInt(u8, month_str, 10);
    const day = try std.fmt.parseInt(u8, day_str, 10);

    if (month < 1 or month > 12) return error.InvalidDate;

    const days_in_month = epoch.getDaysInMonth(year, @enumFromInt(month));
    if (day < 1 or day > days_in_month) return error.InvalidDate;

    if (year < 1970) return error.InvalidDate;

    return .{ .year = year, .month = month, .day = day };
}

fn todayDateUtc() !Date {
    const now = std.time.timestamp();
    if (now < 0) return error.InvalidDate;
    const epoch_seconds = epoch.EpochSeconds{ .secs = @intCast(now) };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return .{
        .year = year_day.year,
        .month = @intFromEnum(month_day.month),
        .day = month_day.day_index + 1,
    };
}

fn epochDayFromDate(date: Date) !u64 {
    if (date.year < 1970) return error.InvalidDate;
    var days: u64 = 0;
    var year: u16 = 1970;
    while (year < date.year) : (year += 1) {
        days += epoch.getDaysInYear(year);
    }

    var month: u8 = 1;
    while (month < date.month) : (month += 1) {
        days += epoch.getDaysInMonth(date.year, @enumFromInt(month));
    }

    days += date.day - 1;
    return days;
}

fn dateFromEpochDay(day: u64) Date {
    const epoch_day = epoch.EpochDay{ .day = @intCast(day) };
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return .{
        .year = year_day.year,
        .month = @intFromEnum(month_day.month),
        .day = month_day.day_index + 1,
    };
}

fn renderDateError(value: []const u8, err: anyerror, stderr: anytype) !void {
    if (err == error.InvalidDate) {
        try stderr.print("error: plan: invalid date '{s}' (expected YYYY-MM-DD or YY-MM-DD)\n", .{value});
    } else {
        try stderr.print("error: plan: failed to parse date '{s}': {s}\n", .{ value, @errorName(err) });
    }
}

// ============================================================================
// Tests
// ============================================================================

test "parseDate accepts YYYY-MM-DD" {
    const date = try parseDate("2026-01-14");
    try std.testing.expectEqual(@as(u16, 2026), date.year);
    try std.testing.expectEqual(@as(u8, 1), date.month);
    try std.testing.expectEqual(@as(u8, 14), date.day);
}

test "parseDate accepts YY-MM-DD" {
    const date = try parseDate("26-01-14");
    try std.testing.expectEqual(@as(u16, 2026), date.year);
    try std.testing.expectEqual(@as(u8, 1), date.month);
    try std.testing.expectEqual(@as(u8, 14), date.day);
}

test "formatWeekValue uses week-of-month" {
    const allocator = std.testing.allocator;
    const date = Date{ .year = 2026, .month = 1, .day = 14 };
    const week_value = try formatWeekValue(allocator, date);
    defer allocator.free(week_value);
    try std.testing.expectEqualStrings("26-01-2", week_value);
}
