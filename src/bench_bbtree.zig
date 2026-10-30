//! Paired warm mmap dictionary experiment. No embeddings or network calls.
const std = @import("std");
const cio = @import("cio.zig");
const idx = @import("index.zig");
const bb = @import("bbtree_dictionary.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    cio.setProcessArgs(cio.bootstrapArgs(init.args));
    // Match the CLI's production allocator, including prefix-result allocations.
    const a = std.heap.c_allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const args = try cio.argsAlloc(a);
    defer cio.argsFree(a, args);
    if (args.len < 2) return error.ExpectedSourceFiles;
    var manifest: ?[]u8 = null;
    defer if (manifest) |bytes| a.free(bytes);
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(a);
    if (args.len == 3 and std.mem.eql(u8, args[1], "--manifest")) {
        manifest = try std.Io.Dir.cwd().readFileAlloc(io, args[2], a, .limited(64 * 1024 * 1024));
        var entries = std.mem.splitScalar(u8, manifest.?, 0);
        while (entries.next()) |path| if (path.len > 0) {
            try paths.append(a, path);
        };
    } else try paths.appendSlice(a, args[1..]);
    if (paths.items.len == 0) return error.ExpectedSourceFiles;
    var source_bytes: usize = 0;
    var heap = idx.WordIndex.init(a);
    defer heap.deinit();
    for (paths.items) |path| {
        const content = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 * 1024 * 1024));
        defer a.free(content);
        try heap.indexFile(path, content);
        source_bytes += content.len;
    }
    const dir = try std.fmt.allocPrint(a, ".zig-cache/bbtree-bench-{d}", .{cio.nanoTimestamp()});
    defer a.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try heap.writeToDisk(io, dir, null);
    var baseline = idx.WordIndex.mmapFromDiskWithDictionary(io, dir, a, false) orelse return error.MmapLoadFailed;
    defer baseline.deinit();
    var candidate = idx.WordIndex.mmapFromDiskWithDictionary(io, dir, a, false) orelse return error.MmapLoadFailed;
    defer candidate.deinit();
    const build_start = cio.nanoTimestamp();
    try candidate.enableBBDictionary();
    const build_ns = cio.nanoTimestamp() - build_start;
    const data = baseline.mmap_data.?;
    var queries: std.ArrayList([]const u8) = .empty;
    defer {
        for (queries.items) |q| a.free(q);
        queries.deinit(a);
    }
    // Every real dictionary key, an absent extension, and a prefix (hit or miss).
    for (baseline.word_dir) |off| {
        const key = bb.word(data, off);
        try queries.append(a, try a.dupe(u8, key));
        try queries.append(a, try std.fmt.allocPrint(a, "{s}~absent", .{key}));
        try queries.append(a, try a.dupe(u8, key[0 .. key.len / 2]));
    }
    // Fixed shuffle prevents sorted query locality from flattering either tree.
    var random = std.Random.DefaultPrng.init(0xBB7EE);
    random.random().shuffle([]const u8, queries.items);
    for (queries.items) |q| {
        const expected = (try baseline.search(q, a)).items;
        const actual = (try candidate.search(q, a)).items;
        if (!std.mem.eql(u8, std.mem.sliceAsBytes(expected), std.mem.sliceAsBytes(actual))) return error.ExactParityFailed;
        const rank = candidate.bb_dictionary.?.lowerBound(q);
        var lo: usize = 0;
        var hi = baseline.word_dir.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.order(u8, bb.word(data, baseline.word_dir[mid]), q) == .lt) lo = mid + 1 else hi = mid;
        }
        if (rank != lo) return error.LowerBoundParityFailed;
    }
    const prefix_count = @min(1000, queries.items.len);
    for (queries.items[0..prefix_count]) |q| {
        const expected = try baseline.searchPrefix(q, a, 100);
        defer a.free(expected);
        const actual = try candidate.searchPrefix(q, a, 100);
        defer a.free(actual);
        if (!std.mem.eql(u8, std.mem.sliceAsBytes(expected), std.mem.sliceAsBytes(actual))) return error.PrefixParityFailed;
    }
    std.debug.print("files={d} source_bytes={d} words={d} queries={d} exact/lower-bound parity=all prefix_parity={d} extra_bytes={d} build_ms={d:.3}\n", .{ paths.items.len, source_bytes, baseline.word_dir.len, queries.items.len, prefix_count, candidate.bb_dictionary.?.bytes, @as(f64, @floatFromInt(build_ns)) / 1e6 });
    // Parity walks pre-fault both mappings. Alternate AB/BA over seven rounds.
    var checksum: usize = 0;
    for (0..7) |round| {
        for (0..2) |turn| {
            const is_bb = (round + turn) % 2 != 0;
            const index = if (is_bb) &candidate else &baseline;
            var start = cio.nanoTimestamp();
            for (0..5) |_| for (queries.items) |q| {
                checksum +%= (try index.search(q, a)).items.len;
            };
            const exact = @as(f64, @floatFromInt(cio.nanoTimestamp() - start)) / @as(f64, @floatFromInt(5 * queries.items.len));
            start = cio.nanoTimestamp();
            for (queries.items[0..prefix_count]) |q| {
                const hits = try index.searchPrefix(q, a, 100);
                checksum +%= hits.len;
                a.free(hits);
            }
            const prefix = @as(f64, @floatFromInt(cio.nanoTimestamp() - start)) / @as(f64, @floatFromInt(prefix_count));
            std.debug.print("round={d} implementation={s} exact_ns={d:.2} prefix_ns={d:.2}\n", .{ round, if (is_bb) "bbtree" else "binary", exact, prefix });
        }
    }
    // A write lands in the heap delta: the mmap and dictionary stay, base postings stay borrowed.
    try candidate.indexFile("bbtree-promotion-fixture.zig", "zzbbpromotionfixturezz");
    if (candidate.mmap_data == null or (try candidate.search("zzbbpromotionfixturezz", a)).items.len != 1) return error.OverlayFailed;
    for (baseline.word_dir) |off| {
        const key = bb.word(data, off);
        const expected = try baseline.search(key, a);
        const actual = try candidate.search(key, a);
        if (actual.owned.len != 0 or !std.mem.eql(u8, std.mem.sliceAsBytes(expected.items), std.mem.sliceAsBytes(actual.items))) return error.OverlayParityFailed;
    }
    std.debug.print("overlay_parity=all checksum={d}\n", .{checksum});
}
