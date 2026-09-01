//! Image listing and compression for the `cmprs` CLI.
const std = @import("std");
const Io = std.Io;
const flate = std.compress.flate;

pub const ImageKind = enum {
    jpeg,
    png,
    webp,
    gif,
    bmp,
    tiff,
    heic,
    avif,

    pub fn fromPath(path: []const u8) ?ImageKind {
        const ext = extension(path) orelse return null;
        if (std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg"))
            return .jpeg;
        if (std.ascii.eqlIgnoreCase(ext, ".png")) return .png;
        if (std.ascii.eqlIgnoreCase(ext, ".webp")) return .webp;
        if (std.ascii.eqlIgnoreCase(ext, ".gif")) return .gif;
        if (std.ascii.eqlIgnoreCase(ext, ".bmp")) return .bmp;
        if (std.ascii.eqlIgnoreCase(ext, ".tif") or std.ascii.eqlIgnoreCase(ext, ".tiff"))
            return .tiff;
        if (std.ascii.eqlIgnoreCase(ext, ".heic") or std.ascii.eqlIgnoreCase(ext, ".heif"))
            return .heic;
        if (std.ascii.eqlIgnoreCase(ext, ".avif")) return .avif;
        return null;
    }

    pub fn label(kind: ImageKind) []const u8 {
        return switch (kind) {
            .jpeg => "JPEG",
            .png => "PNG",
            .webp => "WebP",
            .gif => "GIF",
            .bmp => "BMP",
            .tiff => "TIFF",
            .heic => "HEIC",
            .avif => "AVIF",
        };
    }
};

pub const Image = struct {
    name: []u8,
    size: u64,
    kind: ImageKind,

    pub fn deinit(image: Image, gpa: std.mem.Allocator) void {
        gpa.free(image.name);
    }
};

pub fn extension(path: []const u8) ?[]const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
        if (dot == 0 or dot == base.len - 1) return null;
        return base[dot..];
    }
    return null;
}

pub fn formatSize(n: u64, buf: *[32]u8) []const u8 {
    const f: f64 = @floatFromInt(n);
    if (n < 1024) {
        return std.fmt.bufPrint(buf, "{d} B", .{n}) catch buf;
    } else if (n < 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.1} KB", .{f / 1024.0}) catch buf;
    } else if (n < 1024 * 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.1} MB", .{f / (1024.0 * 1024.0)}) catch buf;
    } else {
        return std.fmt.bufPrint(buf, "{d:.1} GB", .{f / (1024.0 * 1024.0 * 1024.0)}) catch buf;
    }
}

pub fn listImages(gpa: std.mem.Allocator, io: Io, dir: Io.Dir) ![]Image {
    var list: std.ArrayList(Image) = .empty;
    errdefer {
        for (list.items) |img| img.deinit(gpa);
        list.deinit(gpa);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link and entry.kind != .unknown)
            continue;
        const kind = ImageKind.fromPath(entry.name) orelse continue;
        const st = dir.statFile(io, entry.name, .{}) catch continue;
        if (st.kind == .directory) continue;
        const name = try gpa.dupe(u8, entry.name);
        errdefer gpa.free(name);
        try list.append(gpa, .{
            .name = name,
            .size = st.size,
            .kind = kind,
        });
    }

    const lessThan = struct {
        fn lessThan(_: void, a: Image, b: Image) bool {
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.lessThan;
    std.mem.sort(Image, list.items, {}, lessThan);
    return list.toOwnedSlice(gpa);
}

pub const CompressResult = struct {
    before: u64,
    after: u64,
    /// True when the original file was replaced with a smaller (or equal) result.
    replaced: bool,
};

pub const CompressError = error{
    ToolFailed,
    ToolNotFound,
    Unsupported,
    InvalidPng,
} || std.mem.Allocator.Error || Io.Cancelable || Io.UnexpectedError ||
    Io.Dir.StatFileError || Io.File.OpenError || Io.File.Writer.Error ||
    Io.Writer.Error || std.process.RunError || Io.Dir.RenameError;

pub fn compressImage(
    gpa: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    name: []const u8,
    quality: u8,
) CompressError!CompressResult {
    const q: u8 = @max(1, @min(quality, 100));
    const kind = ImageKind.fromPath(name) orelse return error.Unsupported;
    const before = (try dir.statFile(io, name, .{})).size;

    const tmp_name = try std.fmt.allocPrint(gpa, ".{s}.cmprs.tmp", .{name});
    defer gpa.free(tmp_name);

    const compressed = switch (kind) {
        .png => try compressPng(gpa, io, dir, name, tmp_name, q),
        else => try compressWithTool(gpa, io, name, tmp_name, q, kind),
    };

    if (!compressed) {
        // The tool failed; keep the original and discard any temp file.
        deleteFile(dir, io, tmp_name);
        return .{ .before = before, .after = before, .replaced = false };
    }

    const after = (dir.statFile(io, tmp_name, .{}) catch {
        return .{ .before = before, .after = before, .replaced = false };
    }).size;

    if (after == 0 or after >= before) {
        // Compression produced nothing useful; discard the temp file.
        deleteFile(dir, io, tmp_name);
        return .{ .before = before, .after = before, .replaced = false };
    }

    try dir.rename(tmp_name, dir, name, io);
    return .{ .before = before, .after = after, .replaced = true };
}

fn deleteFile(dir: Io.Dir, io: Io, name: []const u8) void {
    dir.deleteFile(io, name) catch {};
}

fn compressPng(
    gpa: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    src: []const u8,
    dest: []const u8,
    quality: u8,
) CompressError!bool {
    // pngquant: lossy quantization, biggest size reduction
    if (try runPngquant(gpa, io, src, dest, quality)) return true;
    // oxipng: lossless multi-strategy optimization
    if (try runOxipng(gpa, io, src, dest)) return true;
    // native zlib recompression
    if (recompressPngFile(gpa, io, dir, src, dest)) |_| {
        return true;
    } else |_| {}
    // last resort: sips
    return compressWithTool(gpa, io, src, dest, quality, .png);
}

fn readFileAlloc(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, name: []const u8) ![]u8 {
    const file = try dir.openFile(io, name, .{ .mode = .read_only });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader: Io.File.Reader = .init(file, io, &buf);
    return reader.interface.allocRemaining(gpa, .unlimited) catch |err| switch (err) {
        error.ReadFailed => return reader.err orelse error.Unexpected,
        else => |e| return e,
    };
}

fn writeFile(io: Io, dir: Io.Dir, name: []const u8, data: []const u8) !void {
    const file = try dir.createFile(io, name, .{ .truncate = true });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var writer: Io.File.Writer = .init(file, io, &buf);
    try writer.interface.writeAll(data);
    try writer.interface.flush();
}

fn recompressPngFile(
    gpa: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    src: []const u8,
    dest: []const u8,
) !void {
    const bytes = try readFileAlloc(gpa, io, dir, src);
    defer gpa.free(bytes);
    const out = try recompressPng(gpa, bytes);
    defer gpa.free(out);
    try writeFile(io, dir, dest, out);
}

const png_sig = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

pub fn recompressPng(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    if (src.len < 8 or !std.mem.eql(u8, src[0..8], &png_sig))
        return error.InvalidPng;

    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);
    var other: std.ArrayList(u8) = .empty;
    defer other.deinit(gpa);

    var i: usize = 8;
    var saw_idat = false;
    var saw_iend = false;
    while (i + 12 <= src.len) {
        const len = std.mem.readInt(u32, src[i..][0..4], .big);
        const typ = src[i + 4 ..][0..4];
        const data_start = i + 8;
        const data_end = data_start + len;
        const crc_end = data_end + 4;
        if (crc_end > src.len) return error.InvalidPng;
        const data = src[data_start..data_end];

        if (std.mem.eql(u8, typ, "IDAT")) {
            try idat.appendSlice(gpa, data);
            saw_idat = true;
        } else if (std.mem.eql(u8, typ, "IEND")) {
            saw_iend = true;
            break;
        } else {
            try other.appendSlice(gpa, src[i..crc_end]);
        }
        i = crc_end;
    }
    if (!saw_idat or !saw_iend) return error.InvalidPng;

    const raw = try inflateZlib(gpa, idat.items);
    defer gpa.free(raw);
    const packed_idat = try deflateZlib(gpa, raw);
    defer gpa.free(packed_idat);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &png_sig);
    try out.appendSlice(gpa, other.items);
    try writeChunk(&out, gpa, "IDAT", packed_idat);
    try writeChunk(&out, gpa, "IEND", &.{});
    return out.toOwnedSlice(gpa);
}

fn writeChunk(out: *std.ArrayList(u8), gpa: std.mem.Allocator, typ: *const [4]u8, data: []const u8) !void {
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
    try out.appendSlice(gpa, &len_buf);
    try out.appendSlice(gpa, typ);
    try out.appendSlice(gpa, data);
    var crc = std.hash.Crc32.init();
    crc.update(typ);
    crc.update(data);
    var crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_buf, crc.final(), .big);
    try out.appendSlice(gpa, &crc_buf);
}

fn inflateZlib(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    var input = Io.Reader.fixed(src);
    var window: [flate.max_window_len]u8 = undefined;
    var dec = flate.Decompress.init(&input, .zlib, &window);
    return dec.reader.allocRemaining(gpa, .unlimited) catch |err| switch (err) {
        error.ReadFailed => return dec.err orelse error.InvalidPng,
        else => |e| return e,
    };
}

fn deflateZlib(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    errdefer out.deinit();
    var window: [flate.max_window_len]u8 = undefined;
    var enc = try flate.Compress.init(&out.writer, &window, .zlib, .best);
    try enc.writer.writeAll(src);
    try enc.finish();
    return out.toOwnedSlice();
}

fn compressWithTool(
    gpa: std.mem.Allocator,
    io: Io,
    src: []const u8,
    dest: []const u8,
    quality: u8,
    kind: ImageKind,
) CompressError!bool {
    if (try runSips(gpa, io, src, dest, quality, kind)) return true;
    if (kind == .webp) {
        if (try runCwebp(gpa, io, src, dest, quality)) return true;
    }
    if (try runMagick(gpa, io, src, dest, quality)) return true;
    return error.ToolNotFound;
}

fn runSips(
    gpa: std.mem.Allocator,
    io: Io,
    src: []const u8,
    dest: []const u8,
    quality: u8,
    kind: ImageKind,
) CompressError!bool {
    var qbuf: [8]u8 = undefined;
    const qstr = std.fmt.bufPrint(&qbuf, "{d}", .{quality}) catch unreachable;
    const format = switch (kind) {
        .jpeg => "jpeg",
        .png => "png",
        .gif => "gif",
        .bmp => "bmp",
        .tiff => "tiff",
        .heic => "heic",
        .avif => "avif",
        // sips advertises webp but produces no output; cwebp handles it.
        .webp => return false,
    };
    const argv = [_][]const u8{
        "sips",
        "-s",
        "format",
        format,
        "-s",
        "formatOptions",
        qstr,
        "--out",
        dest,
        src,
    };
    return runOk(gpa, io, &argv);
}

fn runCwebp(
    gpa: std.mem.Allocator,
    io: Io,
    src: []const u8,
    dest: []const u8,
    quality: u8,
) CompressError!bool {
    var qbuf: [8]u8 = undefined;
    const qstr = std.fmt.bufPrint(&qbuf, "{d}", .{quality}) catch unreachable;
    const argv = [_][]const u8{ "cwebp", src, "-q", qstr, "-o", dest };
    return runOk(gpa, io, &argv);
}

fn runPngquant(
    gpa: std.mem.Allocator,
    io: Io,
    src: []const u8,
    dest: []const u8,
    quality: u8,
) CompressError!bool {
    var qbuf: [8]u8 = undefined;
    const qstr = std.fmt.bufPrint(&qbuf, "{d}", .{quality}) catch unreachable;
    const argv = [_][]const u8{ "pngquant", "--quality", qstr, "--force", "--output", dest, src };
    return runOk(gpa, io, &argv);
}

fn runOxipng(
    gpa: std.mem.Allocator,
    io: Io,
    src: []const u8,
    dest: []const u8,
) CompressError!bool {
    const argv = [_][]const u8{ "oxipng", "-o5", "--out", dest, src };
    return runOk(gpa, io, &argv);
}

fn runMagick(
    gpa: std.mem.Allocator,
    io: Io,
    src: []const u8,
    dest: []const u8,
    quality: u8,
) CompressError!bool {
    var qbuf: [8]u8 = undefined;
    const qstr = std.fmt.bufPrint(&qbuf, "{d}", .{quality}) catch unreachable;
    const argv_magick = [_][]const u8{ "magick", src, "-quality", qstr, dest };
    if (try runOk(gpa, io, &argv_magick)) return true;
    const argv_convert = [_][]const u8{ "convert", src, "-quality", qstr, dest };
    return runOk(gpa, io, &argv_convert);
}

fn runOk(gpa: std.mem.Allocator, io: Io, argv: []const []const u8) CompressError!bool {
    const result = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

test "ImageKind.fromPath" {
    try std.testing.expectEqual(ImageKind.jpeg, ImageKind.fromPath("photo.JPG").?);
    try std.testing.expectEqual(ImageKind.png, ImageKind.fromPath("a.b.png").?);
    try std.testing.expectEqual(ImageKind.heic, ImageKind.fromPath("img.heic").?);
    try std.testing.expect(ImageKind.fromPath("notes.txt") == null);
    try std.testing.expect(ImageKind.fromPath(".gitignore") == null);
}

test "formatSize" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("500 B", formatSize(500, &buf));
    try std.testing.expectEqualStrings("1.0 KB", formatSize(1024, &buf));
}

test "recompressPng roundtrip" {
    const gpa = std.testing.allocator;
    // 1x1 red PNG (zlib-compressed IDAT).
    const png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00,
        0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
        0x00, 0x00, 0x03, 0x00, 0x01, 0x18, 0xD8, 0x5E, 0xED, 0x00, 0x00, 0x00,
        0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    };
    const out = try recompressPng(gpa, &png);
    defer gpa.free(out);
    try std.testing.expect(out.len >= 8);
    try std.testing.expectEqualSlices(u8, &png_sig, out[0..8]);
    try std.testing.expectEqualSlices(u8, png[out.len - 12 ..], out[out.len - 12 ..]);
}
