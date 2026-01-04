# Importing Zig Libraries

## Quick Reference

```bash
# Always specify a version tag
zig fetch --save git+https://github.com/USER/REPO#VERSION_TAG
```

## Steps

1. **Find the correct version tag** - Go to the repo's releases/tags page and find the tag that matches your Zig version. Master branch often targets Zig nightly/dev.

2. **Fetch with explicit tag** - Never omit the version:
   ```bash
   # Correct
   zig fetch --save git+https://github.com/Hejsil/zig-clap#0.11.0

   # Wrong - grabs master which may target unreleased Zig
   zig fetch --save git+https://github.com/Hejsil/zig-clap
   ```

3. **Wire into build.zig** - Add the dependency and import:
   ```zig
   const dep = b.dependency("dep_name", .{});

   // Add to module imports
   .imports = &.{
       .{ .name = "dep_name", .module = dep.module("module_name") },
   },
   ```

4. **Build and test** - Verify it compiles before writing code that uses it.

## Common Mistakes

| Mistake | Why It Fails |
|---------|--------------|
| Fetching without `#tag` | Master often targets Zig nightly |
| Assuming latest tag == master | They diverge after release |
| Giving up after one failed fetch | Try tagged releases before concluding incompatibility |

## Version Matching

- Check the library's `build.zig.zon` for `minimum_zig_version`
- Release notes often state which Zig version is supported
- If master says `0.16.0-dev`, look for an older tag for stable Zig
