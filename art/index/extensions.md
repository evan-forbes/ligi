# Extensions

An **extension** is a lightweight document that references another document to build on it or connect it to something else. Extensions are similar to comments but live as standalone files.

## Usage

Create an extension using:
```bash
ligi t art/template/extension.md
```

Files generated from this template should use the `ext_` prefix.

## Structure

Extensions contain:
1. The `[[t/extension]]` tag
2. A link to the referenced document

That's it. Keep extensions minimal.
