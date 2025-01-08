## dotenv.zig

<img src="./media/logo.svg" alt="dotenv.zig's logo" align="right" width="200" />

dotenv.zig is a "bare-minimun" low-allocation library to load "`.env`" files
into a project's  local environment.

It allows for:

- multiline quoted strings
- escape characters (including hexadecimal bytes)
- trailing newlines
- retrocompatibility with the `std.process.EnvMap` structure

### Usage

Normally, one would use `std.process.getEnvMap` to get a local hashmap of the
current process' environment, this library wraps this structure to simply `put`
the key-value pairs from whatever you specify as path.

Both of these implementations require a comptime-known size for the static
buffer of bytes.

#### loading from a filepath

```zig
fn loadEnv(
    comptime bufsize: usize,
    path: []const u8,
    allocator: std.mem.Allocator) !std.process.EnvMap
```

#### loading from a reader

```zig
pub fn loadEnvReader(
    comptime bufsize: usize,
    reader: *std.io.AnyReader,
    allocator: std.mem.Allocator) !std.process.EnvMap
```

> [!IMPORTANT]
> As of zig master, `GenericReader` is deprecated, use `AnyReader` in your API
> where possible.

A subset of the possible errors this might result with are specified in the
`LoaderError` ErrorSet, like so:

```zig
const LoaderError = error{
    TrailingSpace,
    InvalidHex,
    UnexpectedEOF,
    UnexpectedChars,
    UnexpectedQuote,
    UnexpectedEscape,
};
```

All resulting from parsing errors.

### Limitations

This library allocates a static buffer for each key-value pair to be put on, so it might overflow and then panic if you set up a small buffer size inside `loadEnv`.

### To-Do

- [ ] full function test coverage
- [ ] add tests for utf-8 support
- [ ] heap-allocated version of `loadEnv`
- [X] buffer size specifier for `loadEnv`

