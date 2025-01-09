const std = @import("std");

pub const LoaderError = error{
    TrailingSpace,
    InvalidHex,
    UnexpectedEOF,
    UnexpectedChars,
    UnexpectedQuote,
    UnexpectedEscape,
};

fn nextHex(reader: *std.io.AnyReader) !u8 {
    var accum: u8 = 0;
    inline for (0..2) |position| {
        const hex_char = reader.readByte() catch |err| switch (err) {
            error.EndOfStream => return LoaderError.UnexpectedEOF,
            else => return err,
        };

        if (position == 1) {
            accum *= 16;
        }

        if (std.ascii.isDigit(hex_char)) {
            accum += hex_char - '0';
        } else if (std.ascii.isHex(hex_char)) {
            accum += hex_char - 'a' + 10;
        } else {
            return LoaderError.InvalidHex;
        }
    }

    return accum;
}

fn nextEscaped(reader: *std.io.AnyReader) !u8 {
    const escaped_char = reader.readByte() catch |err| switch (err) {
        error.EndOfStream => return LoaderError.UnexpectedEOF,
        else => return err,
    };

    return switch (escaped_char) {
        'x' => nextHex(reader),
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        '\\' => '\\',
        '"' => '"',
        else => LoaderError.UnexpectedEscape,
    };
}

fn nextKey(reader: *std.io.AnyReader, buffer: []u8) !usize {
    var index: usize = 0;

    while (true) {
        const new_byte = try reader.readByte();

        if (new_byte == '\n' and index == 0) {
            return 0;
        }

        if (std.ascii.isWhitespace(new_byte)) {
            return LoaderError.TrailingSpace;
        }


        if (new_byte == '=') {
            break;
        }
        buffer[index] = new_byte;
        index += 1;
    }

    return index;
}

fn nextString(reader: *std.io.AnyReader, buffer: []u8) !usize {
    var index: usize = 0;
    var should_close: bool = false;

    loop: {
        while (true) {
            const new_byte = reader.readByte() catch |err| switch (err) {
                error.EndOfStream => {
                    if (should_close) {
                        break :loop;
                    }

                    return LoaderError.UnexpectedEOF;
                },

                else => return err,
            };

            if (should_close) {
                if (new_byte != '\n') {
                    return LoaderError.UnexpectedChars;
                }

                break;
            }

            if (new_byte == '"') {
                should_close = true;
                continue;
            }

            if (new_byte == '\\') {
                buffer[index] = try nextEscaped(reader);
                index += 1;
                continue;
            }

            buffer[index] = new_byte;
            index += 1;
        }
    }

    return index;
}

fn nextValue(reader: *std.io.AnyReader, buffer: []u8) !usize {
    var index: usize = 0;

    loop: {
        while (true) {
            const new_byte = reader.readByte() catch |err| switch (err) {
                error.EndOfStream => break :loop,
                else => return err,
            };

            if (new_byte == '"') {
                if (index == 0) {
                    return nextString(reader, buffer);
                }

                return LoaderError.UnexpectedQuote;
            }

            if (new_byte == '\n')
                break;

            if (std.ascii.isWhitespace(new_byte))
                return LoaderError.TrailingSpace;

            buffer[index] = new_byte;
            index += 1;
        }
    }

    return index;
}

test "nextValue_unquoted" {
    const test_env =
        \\alo
    ;

    var buf_stream = std.io.fixedBufferStream(test_env);
    var buf_reader = buf_stream.reader().any();

    var b: [3]u8 = undefined;

    const len = try nextValue(&buf_reader, b[0..]);
    try std.testing.expect(len == 3);
    try std.testing.expect(std.mem.eql(u8, &b, "alo"));
}

test "nextValue_quoted" {
    const test_env =
        \\"alo"
    ;

    var buf_stream = std.io.fixedBufferStream(test_env);
    var buf_reader = buf_stream.reader().any();

    var b: [3]u8 = undefined;

    const len = try nextValue(&buf_reader, b[0..]);
    try std.testing.expect(len == 3);
    try std.testing.expect(std.mem.eql(u8, &b, "alo"));
}


fn nextPair(reader: *std.io.AnyReader, key_buffer: []u8, val_buffer: []u8) ![2]usize {
    var lens = [2]usize{ 0, 0 };

    lens[0] = try nextKey(reader, key_buffer);
    if (lens[0] == 0) {
        return lens;
    }

    lens[1] = try nextValue(reader, val_buffer);

    return lens;
}

pub fn loadEnvReader(
    comptime bufsize: usize,
    reader: *std.io.AnyReader,
    allocator: std.mem.Allocator
) !std.process.EnvMap {
    var env_map = try std.process.getEnvMap(allocator);
    errdefer env_map.deinit();

    var raw_buffer: [bufsize]u8 = undefined;

    const slice_size = bufsize / 2;
    while (nextPair(reader, raw_buffer[0..slice_size], raw_buffer[slice_size..])) |*pair| {
        if (pair[0] == 0)
            continue;

        try env_map.put(
            raw_buffer[0..pair[0]],
            raw_buffer[slice_size..slice_size+pair[1]]);
    } else |err| {
        switch (err) {
            error.EndOfStream => {},
            else => {
                return err;
            },
        }
    }

    return env_map;
}

pub fn loadEnv(comptime bufsize: usize, path: []const u8, allocator: std.mem.Allocator) !std.process.EnvMap {
    const file = try std.fs.cwd().openFile(path, std.fs.File.OpenFlags{
        .mode = .read_only,
    });

    defer file.close();

    var buf_file = std.io.bufferedReader(file.reader().any());
    var buf_reader = buf_file.reader().any();

    return loadEnvReader(bufsize, &buf_reader, allocator);
}


test "loadEnv_correct" {
    const test_env =
        \\
        \\ws_server_port=9777
        \\serial_device_path="/dev/ttyUSB0"
        \\
        \\
        \\
        \\a=bbb
        \\
        \\
    ;

    var buf_stream = std.io.fixedBufferStream(test_env);
    var buf_reader = buf_stream.reader().any();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var env_map = try loadEnvReader(512, &buf_reader, allocator);
    defer env_map.deinit();

    try std.testing.expect(std.mem.eql(u8, env_map.get("ws_server_port").?, "9777"));
    try std.testing.expect(std.mem.eql(u8, env_map.get("serial_device_path").?, "/dev/ttyUSB0"));
    try std.testing.expect(std.mem.eql(u8, env_map.get("a").?, "bbb"));
}

test "loadEnv_trailing" {
    const test_env =
        \\
        \\ ws_server_port=9777
        \\serial_device_path="/dev/ttyUSB0"
    ;

    var buf_stream = std.io.fixedBufferStream(test_env);
    var buf_reader = buf_stream.reader().any();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    _ = loadEnvReader(512, &buf_reader, allocator) catch |err| {
        return try std.testing.expect(err == LoaderError.TrailingSpace);
    };
}

