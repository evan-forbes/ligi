```toml
feature_name = { type = "string" }
feature_description = { type = "string" }
cli_surface = { type = "string", default = "" }
```

# Document

# Short Implementation Plan: {{ feature_name }}

## Summary

<!--
2-3 sentences: what it does, why it matters, and the approach.
-->

-

---

## Scope & Design Notes

<!--
Keep this compact. Include:
- Constraints (perf/memory/platform)
- Compatibility/backward-compat
- Dependencies/prereqs
- Risks/mitigations (if any)
- Security/privacy (if applicable)
-->

- 

### Non-Goals

-

---

## Specification (Compact)

{{ cli_surface }}

- **Command**:
- **Input**:
- **Output**:
- **Side effects**:

### Types / Messages

<!--
Define only the key structs or message shapes. Include exit codes.
Append brief data flow notes (create/validate/transform/consume).
-->

```zig
pub const Example = struct {
    /// Description of what this field represents and valid values
    field: []const u8,
};
```

**Exit Codes**:
| Code | Meaning | When Returned |
|------|---------|---------------|
| | | |

**Data Flow Notes**:
- 

---

## Implementation Notes

### Touchpoints

<!--
Existing files/modules/commands affected and why.
-->

| Touchpoint | Why It Matters |
|------------|----------------|
| | |

### Steps (High Level)

1.
2.
3.

---

## Testing (Strategy + Essentials)

<!--
1-2 sentences on scope and boundaries. Ensure exit codes + error messages (100% coverage)
and any constraints/compat/deps from Scope & Design Notes are exercised.
-->

- Strategy:
- Unit:
- Integration:
- Smoke:

---

## Examples

```
$ ligi [command]
[expected output]
```

---

*Generated from art/template/impl_short_plan.md*
