//! GitHub integration module for ligi.
//! Pulls GitHub issues and PRs as local markdown documents.

pub const client = @import("client.zig");
pub const config = @import("config.zig");
pub const markdown = @import("markdown.zig");
pub const parser = @import("parser.zig");
pub const repo = @import("repo.zig");

pub const GithubClient = client.GithubClient;
pub const GithubConfig = config.GithubConfig;
pub const GithubItem = parser.GithubItem;
pub const RepoId = repo.RepoId;

test {
    _ = client;
    _ = config;
    _ = markdown;
    _ = parser;
    _ = repo;
}
