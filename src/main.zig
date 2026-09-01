const std = @import("std");
const posix = std.posix;
const Io = std.Io;
const cmprs = @import("cmprs");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stdin_buffer: [256]u8 = undefined;
    var stdin_reader: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    const stdin = &stdin_reader.interface;

    const is_tty = try Io.File.stdin().isTty(io);
    if (!is_tty) {
        try stdout.writeAll("Error: cmprs requires an interactive terminal.\n");
        try stdout.flush();
        std.process.exit(1);
    }

    const original_termios = try posix.tcgetattr(posix.STDIN_FILENO);
    defer _ = posix.tcsetattr(posix.STDIN_FILENO, .NOW, original_termios) catch {};

    var raw = original_termios;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    try posix.tcsetattr(posix.STDIN_FILENO, .NOW, raw);

    const dir = try Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    const images = try cmprs.listImages(gpa, io, dir);
    defer {
        for (images) |img| img.deinit(gpa);
        gpa.free(images);
    }

    if (images.len == 0) {
        try writeAll(stdout, "\x1b[1;33mNo images found in the current directory.\x1b[0m\n");
        try stdout.flush();
        return;
    }

    var selected: usize = 0;
    var running = true;
    while (running) {
        try renderList(stdout, images, selected);
        const key = try readKey(stdin);
        switch (key) {
            .up => {
                if (selected > 0) selected -= 1;
            },
            .down => {
                if (selected < images.len - 1) selected += 1;
            },
            .select => {
                try writeAll(stdout, "\n");
                try stdout.flush();
                const quality = try promptQuality(stdout, stdin);
                if (quality) |q| {
                    try writeAll(stdout, "\n");
                    try stdout.flush();
                    try compressSelected(gpa, io, dir, stdout, images[selected], q);
                    refreshSize(io, dir, &images[selected]) catch {};
                    try writeAll(stdout, "\nPress any key to continue...");
                    try stdout.flush();
                    _ = try readKey(stdin);
                }
            },
            .quit => running = false,
            .none => {},
        }
    }

    try writeAll(stdout, "\x1b[2J\x1b[H");
    try stdout.flush();
}

const Key = enum { up, down, select, quit, none };

fn readKey(reader: *Io.Reader) !Key {
    const ch = try reader.takeByte();
    if (ch == 'q' or ch == 0x03) return .quit;
    if (ch == '\n' or ch == '\r') return .select;
    if (ch == 'k') return .up;
    if (ch == 'j') return .down;
    if (ch == 0x1b) {
        if (reader.bufferedLen() >= 2) {
            const seq = try reader.peek(2);
            if (seq[0] == '[') {
                if (seq[1] == 'A') {
                    reader.toss(2);
                    return .up;
                }
                if (seq[1] == 'B') {
                    reader.toss(2);
                    return .down;
                }
            }
        }
        return .quit;
    }
    return .none;
}

fn renderList(writer: *Io.Writer, images: []cmprs.Image, selected: usize) !void {
    try writeAll(writer, "\x1b[2J\x1b[H");
    try writeAll(writer, "\x1b[1;36m");
    try writeAll(writer, "  cmprs - Image Compressor\n");
    try writeAll(writer, "\x1b[0m");
    try writeAll(writer, "  ─────────────────────────────────────\n\n");

    for (images, 0..) |img, i| {
        if (i == selected) {
            try writeAll(writer, "\x1b[1;32m  > ");
        } else {
            try writeAll(writer, "    ");
        }
        var num_buf: [4]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d}.", .{i + 1}) catch "?";
        try writeAll(writer, num_str);
        try writeAll(writer, " ");
        try writeAll(writer, img.name);
        try writeAll(writer, "  \x1b[90m[");
        var size_buf: [32]u8 = undefined;
        try writeAll(writer, cmprs.formatSize(img.size, &size_buf));
        try writeAll(writer, "]\x1b[0m");
        if (i == selected) {
            try writeAll(writer, "\x1b[1;32m  \x1b[0m");
        }
        try writeAll(writer, "\n");
    }

    try writeAll(writer, "\n  ─────────────────────────────────────\n");
    try writeAll(writer, "  \x1b[90m↑↓ Navigate  Enter Select  q Quit\x1b[0m\n");
    try writer.flush();
}

fn promptQuality(writer: *Io.Writer, reader: *Io.Reader) !?u8 {
    try writeAll(writer, "\n  Quality (1-100, default 85): ");
    try writer.flush();
    var buf: [4]u8 = undefined;
    var len: usize = 0;
    while (len < 3) {
        const ch = try reader.takeByte();
        if (ch == '\n' or ch == '\r') break;
        if (ch == 0x1b) return null;
        if (ch == 0x7f and len > 0) {
            len -= 1;
            try writeAll(writer, "\x1b[D \x1b[D");
            try writer.flush();
            continue;
        }
        if (ch >= '0' and ch <= '9') {
            if (len < 3) {
                buf[len] = ch;
                len += 1;
                var single: [1]u8 = .{ch};
                try writeAll(writer, &single);
                try writer.flush();
            }
        }
    }
    if (len == 0) return 85;
    const num = std.fmt.parseInt(u8, buf[0..len], 10) catch 85;
    if (num < 1) return 1;
    if (num > 100) return 100;
    return num;
}

fn compressSelected(
    gpa: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    writer: *Io.Writer,
    image: cmprs.Image,
    quality: u8,
) !void {
    try writeAll(writer, "\n  Compressing ");
    try writeAll(writer, image.name);
    try writeAll(writer, " (quality=");
    var q_buf: [4]u8 = undefined;
    const q_str = std.fmt.bufPrint(&q_buf, "{d}", .{quality}) catch "?";
    try writeAll(writer, q_str);
    try writeAll(writer, ")...\n");
    try writer.flush();

    const result = cmprs.compressImage(gpa, io, dir, image.name, quality) catch |err| {
        try writeAll(writer, "\x1b[1;31m  Compression failed: ");
        try writeAll(writer, @errorName(err));
        try writeAll(writer, "\x1b[0m\n");
        try writer.flush();
        return;
    };

    if (result.replaced) {
        const saved = result.before - result.after;
        const pct: u64 = if (result.before > 0) (saved * 100 / result.before) else 0;
        try writeAll(writer, "\x1b[1;32m  Done! Saved ");
        var saved_buf: [32]u8 = undefined;
        try writeAll(writer, cmprs.formatSize(saved, &saved_buf));
        try writeAll(writer, " (");
        var pct_buf: [8]u8 = undefined;
        const pct_str = std.fmt.bufPrint(&pct_buf, "{d}", .{pct}) catch "?";
        try writeAll(writer, pct_str);
        try writeAll(writer, "%)");
        try writeAll(writer, "\x1b[0m\n");
        try writeAll(writer, "  \x1b[90m");
        var before_buf: [32]u8 = undefined;
        try writeAll(writer, cmprs.formatSize(result.before, &before_buf));
        try writeAll(writer, " -> ");
        var after_buf: [32]u8 = undefined;
        try writeAll(writer, cmprs.formatSize(result.after, &after_buf));
        try writeAll(writer, "\x1b[0m\n");
    } else {
        try writeAll(writer, "  \x1b[90mNo improvement - file unchanged\x1b[0m\n");
    }
    try writer.flush();
}

fn writeAll(writer: *Io.Writer, s: []const u8) !void {
    try writer.writeAll(s);
}

fn refreshSize(io: Io, dir: Io.Dir, image: *cmprs.Image) !void {
    const st = try dir.statFile(io, image.name, .{});
    image.size = st.size;
}
