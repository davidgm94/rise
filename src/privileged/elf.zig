const lib = @import("lib");
const alignForward = lib.alignForward;
const assert = lib.assert;
const copy = lib.copy;
const ELF = lib.ELF(64);
const isAligned = lib.isAligned;
const log = lib.log.scoped(.ELF);
const string_eq = lib.string_eq;
const valid_page_sizes = lib.arch.valid_page_sizes;

const privileged = @import("privileged");
const Executable = privileged.Executable;
const PhysicalAddressSpace = privileged.PhysicalAddressSpace;
const TODO = privileged.TODO;
const VirtualAddress = privileged.VirtualAddress;
const VirtualAddressSpace = privileged.VirtualAddressSpace;

pub const ELFResult = struct {
    entry_point: u64,
};

const Error = error{
    program_header_not_page_aligned,
    program_header_offset_not_page_aligned,
    no_sections,
};

pub fn load_into_kernel_memory(physical_address_space: *PhysicalAddressSpace, file: []const u8) !Executable.InKernelMemory {
    var parser = try ELF.Parser.init(file);

    // TODO: further checking
    const program_headers = parser.getProgramHeaders();

    var result = Executable.InKernelMemory{
        .entry_point = parser.getEntryPoint(),
    };

    for (program_headers) |*ph| {
        switch (ph.type) {
            .load => {
                if (ph.size_in_memory == 0) continue;

                const page_size = valid_page_sizes[0];
                const misalignment = ph.virtual_address & (page_size - 1);
                const base_virtual_address = VirtualAddress(.local).new(ph.virtual_address - misalignment);
                const segment_size = alignForward(ph.size_in_memory + misalignment, page_size);

                if (misalignment != 0) {
                    return Error.program_header_not_page_aligned;
                }

                if (!isAligned(ph.offset, page_size)) {
                    return Error.program_header_offset_not_page_aligned;
                }

                assert(ph.flags.readable);
                assert(ph.size_in_file <= ph.size_in_memory);
                assert(misalignment == 0);

                const segment_physical_region = try physical_address_space.allocate(segment_size, page_size);
                const segment_virtual_region = segment_physical_region.toHigherHalfVirtualAddress();

                const dst_slice = segment_virtual_region.offset(misalignment).access(u8)[0..ph.size_in_memory];
                const src_slice = @intToPtr([*]const u8, @ptrToInt(file.ptr) + ph.offset)[0..ph.size_in_file];
                assert(dst_slice.len >= src_slice.len);
                copy(u8, dst_slice, src_slice);

                if (result.section_count < result.sections.len) {
                    const section = &result.sections[result.section_count];
                    section.* = Executable.Section{
                        .user_address = base_virtual_address,
                        .kernel_address = segment_virtual_region.address,
                        .size = segment_size,
                        .flags = .{ .execute = ph.flags.executable, .write = ph.flags.writable, .user = true },
                    };

                    log.debug("New section: {}", .{section});

                    result.section_count += 1;
                } else {
                    @panic("Can't load executable because section count exceeds the ones supported");
                }
            },
            else => {
                log.debug("Unhandled PH type: {}", .{ph.type});
            },
        }
    }

    if (result.section_count == 0) {
        return Error.no_sections;
    }

    return result;
}
