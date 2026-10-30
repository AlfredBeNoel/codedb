//! A private macOS malloc zone for one bulk-built index. The shared heap keeps
//! freed small blocks of a dead index dirty; destroying its zone returns them.
const std = @import("std");
const builtin = @import("builtin");
const Alignment = std.mem.Alignment;

const supported = builtin.os.tag == .macos and builtin.link_libc;

const Zone = opaque {};
extern "c" fn malloc_create_zone(start_size: usize, flags: c_uint) ?*Zone;
extern "c" fn malloc_destroy_zone(zone: *Zone) void;
extern "c" fn malloc_zone_malloc(zone: *Zone, size: usize) ?*anyopaque;
extern "c" fn malloc_zone_memalign(zone: *Zone, alignment: usize, size: usize) ?*anyopaque;
extern "c" fn malloc_zone_realloc(zone: *Zone, ptr: ?*anyopaque, size: usize) ?*anyopaque;
extern "c" fn malloc_zone_free(zone: *Zone, ptr: ?*anyopaque) void;
extern "c" fn malloc_size(ptr: ?*const anyopaque) usize;

/// A zone-backed allocator when `parent` is libc malloc on macOS, else `parent`.
/// Other parents (test allocators) keep their own leak accounting.
pub fn create(parent: std.mem.Allocator) std.mem.Allocator {
    if (!supported or parent.vtable != std.heap.c_allocator.vtable) return parent;
    const zone = malloc_create_zone(0, 0) orelse return parent;
    return .{ .ptr = zone, .vtable = &vtable };
}

/// Releases the zone and every block still in it; a no-op for other allocators.
pub fn destroy(allocator: std.mem.Allocator) void {
    if (supported and allocator.vtable == &vtable) malloc_destroy_zone(@ptrCast(allocator.ptr));
}

const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
const malloc_align: Alignment = .of(std.c.max_align_t);

fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
    const zone: *Zone = @ptrCast(ctx);
    const ptr = if (alignment.compare(.lte, malloc_align))
        malloc_zone_malloc(zone, @max(len, malloc_align.toByteUnits()))
    else
        malloc_zone_memalign(zone, alignment.toByteUnits(), len);
    return @ptrCast(ptr orelse return null);
}

fn resize(_: *anyopaque, memory: []u8, _: Alignment, new_len: usize, _: usize) bool {
    return new_len <= memory.len or new_len <= malloc_size(memory.ptr);
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    if (resize(ctx, memory, alignment, new_len, ret_addr)) return memory.ptr;
    // realloc only guarantees malloc alignment.
    if (alignment.compare(.gt, malloc_align)) return null;
    const ptr = malloc_zone_realloc(@ptrCast(ctx), memory.ptr, @max(new_len, malloc_align.toByteUnits()));
    return @ptrCast(ptr orelse return null);
}

fn free(ctx: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
    malloc_zone_free(@ptrCast(ctx), memory.ptr);
}

test "isolated heap: allocations survive until destroy" {
    const a = create(std.heap.c_allocator);
    defer destroy(a);
    var list: std.ArrayList(u64) = .empty;
    for (0..10_000) |i| try list.append(a, i);
    try std.testing.expectEqual(@as(u64, 9_999), list.items[9_999]);
    const aligned = try a.alignedAlloc(u8, .@"64", 100);
    try std.testing.expect(std.mem.isAligned(@intFromPtr(aligned.ptr), 64));
    a.free(aligned);
    list.deinit(a);
    try std.testing.expect(create(std.testing.allocator).vtable == std.testing.allocator.vtable);
}
