//! The allocator every qnnt entry point uses, chosen by build mode.
//!
//! Small, short-lived blocks dominate: heap-owned topic keys, registry reply strings,
//! peer snapshots, frame buffers. `page_allocator` is the worst possible fit for that —
//! it rounds each request up to a page and goes to mmap/munmap for every one, measured
//! here at ~1.1 us per alloc/free pair against 2-3 ns for the allocators below.
//!
//! Debug and ReleaseSafe get `DebugAllocator`: thread-safe by default in a
//! multi-threaded build, and it tracks allocations, so leaks are detectable now that
//! there is a shutdown path able to expose them. Faster modes get `smp_allocator`, a
//! thread-safe process singleton built for this shape of workload.
//!
//! Still a library-wide choice rather than one the host supplies; handing it over
//! belongs with the core C ABI, where a caller has an allocator to pass in.
//!
//! TOLD (deps/told) has its own copy of this policy in `told_alloc.zig`, since the codec is
//! a project of its own and imports nothing from qnnt. Change the choice here and check
//! whether it should follow there; the two do not track each other.

const std = @import("std");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub const allocator: std.mem.Allocator = switch (@import("builtin").mode) {
    .Debug, .ReleaseSafe => debug_allocator.allocator(),
    .ReleaseFast, .ReleaseSmall => std.heap.smp_allocator,
};
