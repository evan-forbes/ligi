//! Builtin template registry for fallback template resolution.
//!
//! This module provides access to the default templates that are embedded
//! in the ligi binary. These serve as the final fallback when a template
//! is not found in repo, org, or global template directories.
//!
//! Note: Template constants are defined in cli/commands/init.zig and referenced
//! here. The actual content is imported at compile time.

const std = @import("std");

/// Template entry with name and content
pub const TemplateEntry = struct {
    name: []const u8,
    content: []const u8,
};

// Template content constants are defined here to avoid circular imports.
// These are the same as in init.zig but accessible from core modules.

pub const PLAN_DAY_TEMPLATE =
    \\```toml
    \\date = { type = "string" }
    \\date_long = { type = "string" }
    \\day_tag = { type = "string" }
    \\week_tag = { type = "string" }
    \\prev_day_tag = { type = "string" }
    \\prev_week_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p day`.
    \\```
    \\
    \\# Daily Plan - {{ date_long }}
    \\
    \\[[t/planning]] [[t/{{ day_tag }}]] [[t/{{ week_tag }}]]
    \\
    \\## Review (required)
    \\- Review yesterday: [[t/{{ prev_day_tag }}]]
    \\- Review current week: [[t/{{ week_tag }}]]
    \\- Review open work: `ligi q t TODO | planning`
    \\
    \\## Today
    \\-
    \\
    \\## Commitments
    \\-
    \\
    \\## Notes
    \\-
    \\
;

pub const PLAN_WEEK_TEMPLATE =
    \\```toml
    \\week = { type = "string" }
    \\day_tag = { type = "string" }
    \\week_tag = { type = "string" }
    \\prev_week_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p week`.
    \\```
    \\
    \\# Weekly Plan - {{ week }}
    \\
    \\[[t/planning]] [[t/{{ day_tag }}]] [[t/{{ week_tag }}]]
    \\
    \\## Review (required)
    \\- Review last week: [[t/{{ prev_week_tag }}]]
    \\- Review open work: `ligi q t TODO | planning`
    \\
    \\## Goals
    \\-
    \\
    \\## Scope
    \\- In:
    \\- Out:
    \\
    \\## Risks / Dependencies
    \\-
    \\
;

pub const PLAN_MONTH_TEMPLATE =
    \\```toml
    \\month = { type = "string" }
    \\day_tag = { type = "string" }
    \\week_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p month`.
    \\```
    \\
    \\# Monthly Plan - {{ month }}
    \\
    \\[[t/planning]] [[t/{{ day_tag }}]] [[t/{{ week_tag }}]]
    \\
    \\## Review (required)
    \\- Review open work: `ligi q t TODO | planning`
    \\
    \\## Goals
    \\-
    \\
    \\## Milestones
    \\-
    \\
    \\## Risks / Dependencies
    \\-
    \\
;

pub const PLAN_QUARTER_TEMPLATE =
    \\```toml
    \\quarter = { type = "string" }
    \\day_tag = { type = "string" }
    \\week_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p quarter`.
    \\```
    \\
    \\# Quarterly Plan - {{ quarter }}
    \\
    \\[[t/planning]] [[t/{{ day_tag }}]] [[t/{{ week_tag }}]]
    \\
    \\## Review (required)
    \\- Review open work: `ligi q t TODO | planning`
    \\
    \\## Themes
    \\-
    \\
    \\## Outcomes
    \\-
    \\
    \\## Risks / Dependencies
    \\-
    \\
;

pub const PLAN_DAY_SHORT_TEMPLATE =
    \\```toml
    \\date_long = { type = "string" }
    \\day_tag = { type = "string" }
    \\week_tag = { type = "string" }
    \\prev_day_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p day -l short`.
    \\```
    \\
    \\# Daily Plan - {{ date_long }}
    \\
    \\[[t/planning]] [[t/{{ day_tag }}]] [[t/{{ week_tag }}]]
    \\
    \\## Review
    \\- Yesterday: [[t/{{ prev_day_tag }}]]
    \\- Week: [[t/{{ week_tag }}]]
    \\
    \\## Focus
    \\-
    \\
    \\## Notes
    \\-
    \\
;

pub const PLAN_WEEK_SHORT_TEMPLATE =
    \\```toml
    \\week = { type = "string" }
    \\day_tag = { type = "string" }
    \\week_tag = { type = "string" }
    \\prev_week_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p week -l short`.
    \\```
    \\
    \\# Weekly Plan - {{ week }}
    \\
    \\[[t/planning]] [[t/{{ day_tag }}]] [[t/{{ week_tag }}]]
    \\
    \\## Review
    \\- Last week: [[t/{{ prev_week_tag }}]]
    \\
    \\## Goals
    \\-
    \\
    \\## Notes
    \\-
    \\
;

pub const PLAN_MONTH_SHORT_TEMPLATE =
    \\```toml
    \\month = { type = "string" }
    \\day_tag = { type = "string" }
    \\week_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p month -l short`.
    \\```
    \\
    \\# Monthly Plan - {{ month }}
    \\
    \\[[t/planning]] [[t/{{ day_tag }}]] [[t/{{ week_tag }}]]
    \\
    \\## Review
    \\
    \\## Goals
    \\-
    \\
    \\## Notes
    \\-
    \\
;

pub const PLAN_QUARTER_SHORT_TEMPLATE =
    \\```toml
    \\quarter = { type = "string" }
    \\day_tag = { type = "string" }
    \\week_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p quarter -l short`.
    \\```
    \\
    \\# Quarterly Plan - {{ quarter }}
    \\
    \\[[t/planning]] [[t/{{ day_tag }}]] [[t/{{ week_tag }}]]
    \\
    \\## Review
    \\
    \\## Themes
    \\-
    \\
    \\## Notes
    \\-
    \\
;

pub const PLAN_FEATURE_TEMPLATE =
    \\```toml
    \\item = { type = "string" }
    \\date_long = { type = "string" }
    \\day_tag = { type = "string" }
    \\week_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p feature <name>`.
    \\```
    \\
    \\# Feature Plan - {{ item }}
    \\
    \\Date: {{ date_long }}
    \\
    \\[[t/planning]] [[t/feature]] [[t/{{ day_tag }}]] [[t/{{ week_tag }}]]
    \\
    \\## Summary
    \\-
    \\
    \\## Problem / Opportunity
    \\-
    \\
    \\## Desired Outcome
    \\-
    \\
    \\## Scope
    \\- In:
    \\- Out:
    \\
    \\## Plan
    \\-
    \\
    \\## Risks / Dependencies
    \\-
    \\
    \\## Definition of Done
    \\-
    \\
    \\## Notes
    \\-
    \\
;

pub const PLAN_FEATURE_SHORT_TEMPLATE =
    \\```toml
    \\item = { type = "string" }
    \\date_long = { type = "string" }
    \\day_tag = { type = "string" }
    \\week_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p feature <name> -l short`.
    \\```
    \\
    \\# Feature Plan - {{ item }}
    \\
    \\Date: {{ date_long }}
    \\
    \\[[t/planning]] [[t/feature]] [[t/{{ day_tag }}]] [[t/{{ week_tag }}]]
    \\
    \\## Goal
    \\-
    \\
    \\## Approach
    \\-
    \\
    \\## Done When
    \\-
    \\
;

pub const PLAN_CHORE_TEMPLATE =
    \\```toml
    \\item = { type = "string" }
    \\date_long = { type = "string" }
    \\day_tag = { type = "string" }
    \\week_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p chore <name>`.
    \\```
    \\
    \\# Chore Plan - {{ item }}
    \\
    \\Date: {{ date_long }}
    \\
    \\[[t/planning]] [[t/chore]] [[t/{{ day_tag }}]] [[t/{{ week_tag }}]]
    \\
    \\## Purpose
    \\-
    \\
    \\## Steps
    \\-
    \\
    \\## Checks
    \\-
    \\
    \\## Risks / Dependencies
    \\-
    \\
    \\## Notes
    \\-
    \\
;

pub const PLAN_CHORE_SHORT_TEMPLATE =
    \\```toml
    \\item = { type = "string" }
    \\date_long = { type = "string" }
    \\day_tag = { type = "string" }
    \\week_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p chore <name> -l short`.
    \\```
    \\
    \\# Chore Plan - {{ item }}
    \\
    \\Date: {{ date_long }}
    \\
    \\[[t/planning]] [[t/chore]] [[t/{{ day_tag }}]] [[t/{{ week_tag }}]]
    \\
    \\## Steps
    \\-
    \\
    \\## Done When
    \\-
    \\
;

pub const PLAN_REFACTOR_TEMPLATE =
    \\```toml
    \\item = { type = "string" }
    \\date_long = { type = "string" }
    \\day_tag = { type = "string" }
    \\week_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p refactor <name>`.
    \\```
    \\
    \\# Refactor Plan - {{ item }}
    \\
    \\Date: {{ date_long }}
    \\
    \\[[t/planning]] [[t/refactor]] [[t/{{ day_tag }}]] [[t/{{ week_tag }}]]
    \\
    \\## Motivation
    \\-
    \\
    \\## Target Areas
    \\-
    \\
    \\## Strategy
    \\-
    \\
    \\## Safety / Rollout
    \\-
    \\
    \\## Risks / Dependencies
    \\-
    \\
    \\## Success Criteria
    \\-
    \\
;

pub const PLAN_REFACTOR_SHORT_TEMPLATE =
    \\```toml
    \\item = { type = "string" }
    \\date_long = { type = "string" }
    \\day_tag = { type = "string" }
    \\week_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p refactor <name> -l short`.
    \\```
    \\
    \\# Refactor Plan - {{ item }}
    \\
    \\Date: {{ date_long }}
    \\
    \\[[t/planning]] [[t/refactor]] [[t/{{ day_tag }}]] [[t/{{ week_tag }}]]
    \\
    \\## Strategy
    \\-
    \\
    \\## Done When
    \\-
    \\
;

pub const PLAN_PERF_TEMPLATE =
    \\```toml
    \\item = { type = "string" }
    \\date_long = { type = "string" }
    \\day_tag = { type = "string" }
    \\week_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p perf <name>`.
    \\```
    \\
    \\# Performance Plan - {{ item }}
    \\
    \\Date: {{ date_long }}
    \\
    \\[[t/planning]] [[t/perf]] [[t/{{ day_tag }}]] [[t/{{ week_tag }}]]
    \\
    \\## Baseline
    \\-
    \\
    \\## Target
    \\-
    \\
    \\## Hypothesis
    \\-
    \\
    \\## Plan
    \\-
    \\
    \\## Validation
    \\-
    \\
    \\## Risks / Dependencies
    \\-
    \\
;

pub const PLAN_PERF_SHORT_TEMPLATE =
    \\```toml
    \\item = { type = "string" }
    \\date_long = { type = "string" }
    \\day_tag = { type = "string" }
    \\week_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p perf <name> -l short`.
    \\```
    \\
    \\# Performance Plan - {{ item }}
    \\
    \\Date: {{ date_long }}
    \\
    \\[[t/planning]] [[t/perf]] [[t/{{ day_tag }}]] [[t/{{ week_tag }}]]
    \\
    \\## Target
    \\-
    \\
    \\## Approach
    \\-
    \\
    \\## Validation
    \\-
    \\
;

pub const EXTENSION_TEMPLATE =
    \\```toml
    \\other_doc_path = { type = "string" }
    \\```
    \\
    \\<!--
    \\AGENT INSTRUCTION:
    \\Do NOT edit this document directly.
    \\Create a new document with the prefix ext_ based on this template by copy-pasting the content and filling in the details.
    \\-->
    \\
    \\# Document
    \\
    \\[[t/extension]]
    \\
    \\[{{ other_doc_path }}]({{ other_doc_path }})
    \\
;

pub const IMPL_PLAN_TEMPLATE =
    \\```toml
    \\feature_name = { type = "string" }
    \\feature_description = { type = "string" }
    \\cli_surface = { type = "string", default = "" }
    \\```
    \\
    \\# Implementation Plan: {{ feature_name }}
    \\
    \\## Summary
    \\{{ feature_description }}
    \\
    \\{{ cli_surface }}
    \\
    \\## Implementation Steps
    \\-
    \\
;

pub const IMPL_SHORT_PLAN_TEMPLATE =
    \\```toml
    \\feature_name = { type = "string" }
    \\feature_description = { type = "string" }
    \\```
    \\
    \\# Short Implementation Plan: {{ feature_name }}
    \\
    \\{{ feature_description }}
    \\
    \\## Steps
    \\-
    \\
;

/// All builtin templates available for fallback
pub const BUILTIN_TEMPLATES = [_]TemplateEntry{
    .{ .name = "extension.md", .content = EXTENSION_TEMPLATE },
    .{ .name = "impl_plan.md", .content = IMPL_PLAN_TEMPLATE },
    .{ .name = "impl_short_plan.md", .content = IMPL_SHORT_PLAN_TEMPLATE },
    .{ .name = "plan_day.md", .content = PLAN_DAY_TEMPLATE },
    .{ .name = "plan_week.md", .content = PLAN_WEEK_TEMPLATE },
    .{ .name = "plan_month.md", .content = PLAN_MONTH_TEMPLATE },
    .{ .name = "plan_quarter.md", .content = PLAN_QUARTER_TEMPLATE },
    .{ .name = "plan_day_short.md", .content = PLAN_DAY_SHORT_TEMPLATE },
    .{ .name = "plan_week_short.md", .content = PLAN_WEEK_SHORT_TEMPLATE },
    .{ .name = "plan_month_short.md", .content = PLAN_MONTH_SHORT_TEMPLATE },
    .{ .name = "plan_quarter_short.md", .content = PLAN_QUARTER_SHORT_TEMPLATE },
    .{ .name = "plan_feature.md", .content = PLAN_FEATURE_TEMPLATE },
    .{ .name = "plan_feature_short.md", .content = PLAN_FEATURE_SHORT_TEMPLATE },
    .{ .name = "plan_chore.md", .content = PLAN_CHORE_TEMPLATE },
    .{ .name = "plan_chore_short.md", .content = PLAN_CHORE_SHORT_TEMPLATE },
    .{ .name = "plan_refactor.md", .content = PLAN_REFACTOR_TEMPLATE },
    .{ .name = "plan_refactor_short.md", .content = PLAN_REFACTOR_SHORT_TEMPLATE },
    .{ .name = "plan_perf.md", .content = PLAN_PERF_TEMPLATE },
    .{ .name = "plan_perf_short.md", .content = PLAN_PERF_SHORT_TEMPLATE },
};

/// Get a builtin template by name.
/// Returns the template content if found, null otherwise.
pub fn getBuiltinTemplate(name: []const u8) ?[]const u8 {
    for (BUILTIN_TEMPLATES) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            return entry.content;
        }
    }
    return null;
}

/// Check if a template name is a known builtin template.
pub fn isBuiltinTemplate(name: []const u8) bool {
    return getBuiltinTemplate(name) != null;
}

/// Get a list of all builtin template names.
pub fn getBuiltinTemplateNames() []const []const u8 {
    comptime {
        var names: [BUILTIN_TEMPLATES.len][]const u8 = undefined;
        for (BUILTIN_TEMPLATES, 0..) |entry, i| {
            names[i] = entry.name;
        }
        return &names;
    }
}

// ============================================================================
// Tests
// ============================================================================

test "getBuiltinTemplate returns known template" {
    const content = getBuiltinTemplate("plan_day.md");
    try std.testing.expect(content != null);
    try std.testing.expect(std.mem.indexOf(u8, content.?, "Daily Plan") != null);
}

test "getBuiltinTemplate returns null for unknown template" {
    const content = getBuiltinTemplate("nonexistent.md");
    try std.testing.expect(content == null);
}

test "isBuiltinTemplate returns true for known template" {
    try std.testing.expect(isBuiltinTemplate("impl_plan.md"));
    try std.testing.expect(isBuiltinTemplate("plan_week.md"));
}

test "isBuiltinTemplate returns false for unknown template" {
    try std.testing.expect(!isBuiltinTemplate("custom_template.md"));
}

test "BUILTIN_TEMPLATES contains expected templates" {
    try std.testing.expect(BUILTIN_TEMPLATES.len >= 19);
}
