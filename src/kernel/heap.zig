const Heap = @This();

const std = @import("../common/std.zig");

const arch = @import("arch/common.zig");
const crash = @import("crash.zig");
const kernel = @import("kernel.zig");
const VirtualAddress = @import("virtual_address.zig");
const VirtualAddressSpace = @import("virtual_address_space.zig");

const log = std.log.scoped(.Heap);
const Spinlock = @import("spinlock.zig");
const TODO = crash.TODO;

pub const Region = struct {
    virtual: VirtualAddress = VirtualAddress{ .value = 0 },
    size: u64 = 0,
    allocated: u64 = 0,
};

allocator: std.CustomAllocator = undefined,
regions: [region_count]Region = [1]Region{.{}} ** region_count,
lock: Spinlock = .{},

const region_size = 1024 * arch.page_size;
pub const region_count = 0x1000_0000 / region_size;

pub fn new(virtual_address_space: *VirtualAddressSpace) Heap {
    return Heap{
        .allocator = std.CustomAllocator{
            .ptr = virtual_address_space,
            .vtable = &vtable,
        },
        .regions = std.zeroes([region_count]Region),
        .lock = Spinlock{},
    };
}

fn alloc(virtual_address_space: *VirtualAddressSpace, size: usize, ptr_align: u29, len_align: u29, return_address: usize) std.Allocator.Error![]u8 {
    virtual_address_space.heap.lock.acquire();
    defer virtual_address_space.heap.lock.release();
    std.assert(virtual_address_space.lock.status == 0);

    log.debug("Asked allocation: Size: {}. Pointer alignment: {}. Length alignment: {}. Return address: 0x{x}", .{ size, ptr_align, len_align, return_address });

    var alignment: u64 = len_align;
    if (ptr_align > alignment) alignment = ptr_align;

    const flags = VirtualAddressSpace.Flags{
        .write = true,
        .user = virtual_address_space.privilege_level == .user,
    };

    if (flags.user and !virtual_address_space.is_current()) {
        // TODO: currently the Zig allocator somehow dereferences memory so allocating memory for another address space make this not viable
        @panic("trying to allocate stuff for userspace from another address space");
    }

    //// TODO: check if the region has enough available space
    if (size < region_size) {
        const region = blk: {
            for (virtual_address_space.heap.regions) |*region| {
                if (region.size > 0) {
                    const aligned_allocated = region.virtual.offset(region.allocated).aligned_forward(alignment).value - region.virtual.value;
                    if (region.size < aligned_allocated + size) continue;
                    //std.assert((region.size - region.allocated) >= size);
                    region.allocated = aligned_allocated;
                    break :blk region;
                } else {
                    // TODO: revisit arguments @MaybeBug

                    region.* = Region{
                        .virtual = virtual_address_space.allocate(region_size, null, flags) catch |err| {
                            log.err("Error allocating small memory from VAS: {}", .{err});
                            return std.Allocator.Error.OutOfMemory;
                        },
                        .size = region_size,
                        .allocated = 0,
                    };

                    // Avoid footguns
                    std.assert(std.is_aligned(region.virtual.value, alignment));

                    break :blk region;
                }
            }

            @panic("heap out of memory");
        };

        const result_address = region.virtual.value + region.allocated;
        log.debug("Result address: 0x{x}", .{result_address});
        if (kernel.config.safe_slow) {
            std.assert(virtual_address_space.translate_address(VirtualAddress.new(std.align_backward(result_address, 0x1000))) != null);
        }
        region.allocated += size;
        const result = @intToPtr([*]u8, result_address)[0..size];

        return result;
    } else {
        const allocation_size = std.align_forward(size, arch.page_size);
        const virtual_address = virtual_address_space.allocate(allocation_size, null, flags) catch |err| {
            log.err("Error allocating big chunk from VAS: {}", .{err});
            return std.Allocator.Error.OutOfMemory;
        };
        log.debug("Big allocation happened!", .{});
        return virtual_address.access([*]u8)[0..size];
    }
}

fn resize(virtual_address_space: *VirtualAddressSpace, old_mem: []u8, old_align: u29, new_size: usize, len_align: u29, return_address: usize) ?usize {
    _ = virtual_address_space;
    _ = old_mem;
    _ = old_align;
    _ = new_size;
    _ = len_align;
    _ = return_address;
    TODO();
}

fn free(virtual_address_space: *VirtualAddressSpace, old_mem: []u8, old_align: u29, return_address: usize) void {
    _ = virtual_address_space;
    _ = old_mem;
    _ = old_align;
    _ = return_address;
    TODO();
}

const vtable: std.Allocator.VTable = .{
    .alloc = @ptrCast(*const std.AllocatorAllocFunction, &alloc),
    .resize = @ptrCast(*const std.AllocatorResizeFunction, &resize),
    .free = @ptrCast(*const std.AllocatorFreeFunction, &free),
};
