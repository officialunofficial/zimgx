# zimgx

Fast, single-binary image proxy and transformation server written in Zig, using libvips.

## Build & Test

```bash
zig build                              # debug build
zig build -Doptimize=ReleaseSafe       # optimized build
zig build test                         # run all unit tests
zig build bench                        # run pipeline benchmarks
zig fmt src/                           # format (CI enforced)
```

Requires libvips and glib headers (see `addVipsDeps` in build.zig for paths).

## Commit Convention

Use [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>
```

**Types:** `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `perf`, `ci`

**Scopes** (optional, match source modules): `transform`, `cache`, `origin`, `vips`, `server`, `config`, `http`, `s3`, `router`

Examples:
```
feat(transform): add saturation parameter
fix(cache): prevent eviction race on concurrent put
refactor(server): extract route handlers into separate functions
perf(vips): reduce buffer copies in pipeline execution
test(config): cover R2 validation edge cases
ci: add zig fmt lint step
docs: update transform parameter reference
chore: bump minimum zig version to 0.15.0
```

## Code Conventions

### File Structure

Each `.zig` file follows this layout:

1. **Module comment** — plain `//` comment block describing the module's purpose
2. **Imports** — `const std = @import("std");` then project imports
3. **Error sets** — named `pub const FooError = error{ ... };`
4. **Types / structs / enums** — public API types
5. **Public functions** — module-level public API
6. **Private helpers** — internal functions
7. **Tests** — `test "descriptive name" { ... }` blocks at the end

Sections separated by ASCII divider comments:
```zig
// ---------------------------------------------------------------------------
// Section name
// ---------------------------------------------------------------------------
```

### Naming

- `snake_case` for functions, variables, fields
- `PascalCase` for types (structs, enums, error sets)
- `SCREAMING_SNAKE_CASE` for comptime constants only when truly global
- Environment variables use `ZIMGX_` prefix

### Style

- Use `///` doc comments on public types and functions
- Use plain `//` for internal explanations; omit when code is self-evident
- Prefer named error sets over generic `error`
- Use `orelse` / `catch` for inline error handling where concise
- Use `if (opt) |val|` unwrapping pattern for optionals
- Return errors explicitly — avoid `@panic` except for truly unreachable states
- Use `defer` / `errdefer` for cleanup
- Embed tests in source files, not separate test files
- Test names are lowercase descriptive phrases: `test "parse empty string returns default params"`

### Patterns

- **Vtable interfaces**: type-erased interfaces via `VTable` + `*anyopaque` (see `cache/cache.zig`, `cache/memory.zig`)
- **Config loading**: env vars with `ZIMGX_` prefix, struct defaults, validation in separate pass
- **Parsing**: return typed errors with specific variants (e.g. `ParseError.InvalidWidth`), not generic strings
- **`fromString` / `toString`**: enum conversion via explicit string matching, not `@tagName`

### What to Avoid

- Don't use `@tagName` / `@enumFromInt` for user-facing string conversion — use explicit `fromString` / `toString` methods
- Don't use `anyerror` — define named error sets
- Don't allocate where a stack buffer or comptime value suffices
- Don't add comments that restate what the code does
