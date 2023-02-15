pub const BIOS = @import("bootloader/bios.zig");
pub const UEFI = @import("bootloader/uefi.zig");
pub const limine = @import("bootloader/limine/limine.zig");
pub const arch = @import("bootloader/arch.zig");

const lib = @import("lib.zig");
const assert = lib.assert;
const Allocator = lib.Allocator;
pub const Protocol = lib.Bootloader.Protocol;

const privileged = @import("privileged.zig");
const AddressInterface = privileged.Address.Interface(u64);
const PhysicalAddress = AddressInterface.PhysicalAddress;
const VirtualAddress = AddressInterface.VirtualAddress;
const PhysicalMemoryRegion = AddressInterface.PhysicalMemoryRegion;
const VirtualMemoryRegion = AddressInterface.VirtualMemoryRegion;
pub const VirtualAddressSpace = privileged.Address.Interface(u64).VirtualAddressSpace(switch (lib.cpu.arch) {
    .x86 => .x86_64,
    else => lib.cpu.arch,
});

pub const Version = extern struct {
    patch: u8,
    minor: u16,
    major: u8,
};

pub const CompactDate = packed struct(u16) {
    year: u7,
    month: u4,
    day: u5,
};

pub const Information = extern struct {
    entry_point: u64,
    higher_half: u64,
    total_size: u32,
    version: Version,
    protocol: lib.Bootloader.Protocol,
    bootloader: lib.Bootloader,
    page_allocator: Allocator = .{
        .callbacks = .{
            .allocate = pageAllocate,
        },
    },
    configuration: packed struct(u32) {
        memory_map_diff: u8,
        reserved: u24 = 0,
    },
    reserved: u32 = 0,
    heap: Heap,
    cpu_driver_mappings: CPUDriverMappings,
    framebuffer: Framebuffer,
    cpu: CPU.Information = .{},
    virtual_address_space: VirtualAddressSpace,
    architecture: Architecture,
    slices: lib.EnumStruct(Slice.Name, Slice),

    pub const Architecture = switch (lib.cpu.arch) {
        .x86, .x86_64 => extern struct {
            rsdp_address: u64,
            gdt: privileged.arch.x86_64.GDT.Table = .{},
        },
        else => @compileError("Architecture not supported"),
    };

    pub const Slice = extern struct {
        offset: u32 = 0,
        size: u32 = 0,
        len: u32 = 0,
        alignment: u32 = 1,

        pub const Name = enum {
            bootloader_information, // The main struct
            cpu_driver_stack,
            file_contents,
            file_names,
            files,
            memory_map_entries,
            page_counters,
            external_bootloader_page_counters,
            cpus,
        };

        pub const count = lib.enumCount(Name);

        pub const TypeMap = blk: {
            var arr: [Slice.count]type = undefined;
            arr[@enumToInt(Slice.Name.bootloader_information)] = Information;
            arr[@enumToInt(Slice.Name.file_contents)] = u8;
            arr[@enumToInt(Slice.Name.file_names)] = u8;
            arr[@enumToInt(Slice.Name.files)] = File;
            arr[@enumToInt(Slice.Name.cpu_driver_stack)] = u8;
            arr[@enumToInt(Slice.Name.memory_map_entries)] = MemoryMapEntry;
            arr[@enumToInt(Slice.Name.page_counters)] = u32;
            arr[@enumToInt(Slice.Name.external_bootloader_page_counters)] = u32;
            arr[@enumToInt(Slice.Name.cpus)] = CPU;
            break :blk arr;
        };

        pub fn dereference(slice: Slice, comptime slice_name: Slice.Name, bootloader_information: *const Information) []Slice.TypeMap[@enumToInt(slice_name)] {
            return @intToPtr([*]Slice.TypeMap[@enumToInt(slice_name)], @ptrToInt(bootloader_information) + slice.offset)[0..slice.len];
        }
    };

    // TODO:
    const PA = PhysicalAddress(.global);
    const PMR = PhysicalMemoryRegion(.global);

    const Heap = extern struct {
        allocator: Allocator = .{
            .callbacks = .{
                .allocate = heapAllocate,
            },
        },
        regions: [6]PMR = lib.zeroes([6]PMR),
    };

    pub const CPU = extern struct {
        foo: u64 = 0,

        pub const Information = extern struct {
            foo: u64 = 0,
        };
    };

    pub fn getFileContent(information: *Information, index: usize) []const u8 {
        _ = index;
        _ = information;
        @panic("ajsdksa");
    }

    pub fn getFiles(information: *Information) []File {
        const files_slice_struct = information.slices.fields.files;
        const files = @intToPtr([*]File, @ptrToInt(information) + files_slice_struct.offset)[0..files_slice_struct.len];
        return files;
    }

    pub inline fn getSlice(information: *const Information, comptime offset_name: Slice.Name) []Slice.TypeMap[@enumToInt(offset_name)] {
        const slice = information.slices.array.values[@enumToInt(offset_name)];
        return slice.dereference(offset_name, information);
    }

    pub inline fn getStackTop(information: *const Information) u64 {
        const stack_slice = information.getSlice(.cpu_driver_stack);
        return @ptrToInt(stack_slice.ptr) + stack_slice.len;
    }

    pub fn getMemoryMapEntryCount(information: *Information) usize {
        return information.getSlice(.memory_map_entries).len - information.configuration.memory_map_diff;
    }

    pub fn getMemoryMapEntries(information: *Information) []MemoryMapEntry {
        return information.getSlice(.memory_map_entries)[0..information.getMemoryMapEntryCount()];
    }

    pub fn getPageCounters(information: *Information) []u32 {
        return information.getSlice(.page_counters)[0..information.getMemoryMapEntryCount()];
    }

    pub fn getExternalBootloaderPageCounters(information: *Information) []u32 {
        return information.getSlice(.external_bootloader_page_counters)[0..information.getMemoryMapEntryCount()];
    }

    // TODO: further checks
    pub fn isSizeRight(information: *const Information) bool {
        const original_total_size = information.total_size;
        var total_size: u32 = 0;
        inline for (Information.Slice.TypeMap) |T, index| {
            const slice = information.slices.array.values[index];
            if (slice.len * @sizeOf(T) != slice.size) {
                return false;
            }
            total_size = lib.alignForwardGeneric(u32, total_size, slice.alignment);
            total_size += lib.alignForwardGeneric(u32, slice.size, slice.alignment);
        }

        if (total_size != original_total_size) return false;
        // var extra_size: u32 = 0;
        // inline for (Information.Slice.TypeMap) |T, index| {
        //     const slice = information.slices[index];
        //     const slice_size = @sizeOf(T) * slice.len;
        //     if (slice_size != slice.size) return false;
        //     extra_size += slice_size;
        // }
        //
        // const aligned_extra_size = lib.alignForward(extra_size, lib.arch.valid_page_sizes[0]);
        // const total_size = aligned_struct_size + aligned_extra_size;
        // if (struct_size != information.struct_size) return false;
        // if (extra_size != information.extra_size) return false;
        // if (total_size != information.total_size) return false;
        //
        // return true;
        return true;
    }

    var count: usize = 0;
    pub fn pageAllocate(allocator: *Allocator, size: u64, alignment: u64) Allocator.Allocate.Error!Allocator.Allocate.Result {
        count += 1;
        const bootloader_information = @fieldParentPtr(Information, "page_allocator", allocator);

        if (size & lib.arch.page_mask(lib.arch.valid_page_sizes[0]) != 0) return Allocator.Allocate.Error.OutOfMemory;
        if (alignment & lib.arch.page_mask(lib.arch.valid_page_sizes[0]) != 0) return Allocator.Allocate.Error.OutOfMemory;
        const four_kb_pages = @intCast(u32, @divExact(size, lib.arch.valid_page_sizes[0]));

        const entries = bootloader_information.getMemoryMapEntries();
        const page_counters = bootloader_information.getPageCounters();
        const external_bootloader_page_counters = bootloader_information.getExternalBootloaderPageCounters();

        if (external_bootloader_page_counters[0] != 0) {
            if (count > 1) {
                lib.log.debug("Address: 0x{x}", .{@ptrToInt(&external_bootloader_page_counters[0])});
                @panic("WTFASDASD");
            } else {
                @panic("first");
            }
        }

        for (entries) |entry, entry_index| {
            if (external_bootloader_page_counters.len == 0 or external_bootloader_page_counters[entry_index] == 0) {
                const busy_size = page_counters[entry_index] * lib.arch.valid_page_sizes[0];
                const size_left = entry.region.size - busy_size;
                if (entry.type == .usable and size_left > size) {
                    if (entry.region.address.isAligned(alignment)) {
                        const result = Allocator.Allocate.Result{
                            .address = entry.region.address.offset(busy_size).value(),
                            .size = size,
                        };

                        page_counters[entry_index] += four_kb_pages;

                        if (external_bootloader_page_counters[0] != 0) {
                            @panic("realllyyyyyyyyYY");
                        }
                        return result;
                    }
                }
            }
        }

        return Allocator.Allocate.Error.OutOfMemory;
    }

    pub fn heapAllocate(allocator: *Allocator, size: u64, alignment: u64) Allocator.Allocate.Error!Allocator.Allocate.Result {
        const bootloader_information = @fieldParentPtr(Information, "heap", @fieldParentPtr(Heap, "allocator", allocator));
        for (bootloader_information.heap.regions) |*region| {
            if (region.size > size) {
                const result = .{
                    .address = region.address.value(),
                    .size = size,
                };
                region.size -= size;
                region.address.addOffset(size);
                return result;
            }
        }
        const size_to_page_allocate = lib.alignForwardGeneric(u64, size, lib.arch.valid_page_sizes[0]);
        for (bootloader_information.heap.regions) |*region| {
            if (region.size == 0) {
                const allocated_region = try bootloader_information.page_allocator.allocateBytes(size_to_page_allocate, lib.arch.valid_page_sizes[0]);
                region.* = .{
                    .address = PA.new(allocated_region.address),
                    .size = allocated_region.size,
                };
                const result = .{
                    .address = region.address.value(),
                    .size = size,
                };
                region.address.addOffset(size);
                region.size -= size;
                return result;
            }
        }

        _ = alignment;
        @panic("todo: heap allocate");
    }
};

pub const CPUDriverMappings = extern struct {
    text: Mapping = .{},
    data: Mapping = .{},
    rodata: Mapping = .{},

    const Mapping = extern struct {
        physical: PhysicalAddress(.local) = PhysicalAddress(.local).invalid(),
        virtual: VirtualAddress(.local) = .null,
        size: u64 = 0,
        flags: privileged.arch.VirtualAddressSpace.Flags = .{},
        reserved: u32 = 0,
    };
};

pub const MemoryMapEntry = extern struct {
    region: PhysicalMemoryRegion(.global),
    type: Type,

    const Type = enum(u64) {
        usable = 0,
        reserved = 1,
        bad_memory = 2,
    };

    comptime {
        assert(@sizeOf(MemoryMapEntry) == @sizeOf(u64) * 3);
    }
};

pub const File = extern struct {
    content_offset: u32,
    content_size: u32,
    path_offset: u32,
    path_size: u32,
    type: Type,
    reserved: u32 = 0,

    pub const Type = enum(u32) {
        cpu_driver,
    };

    pub const Parser = struct {
        text: []const u8,
        index: u32 = 0,

        pub fn init(text: []const u8) File.Parser {
            return .{
                .text = text,
            };
        }

        const Error = error{
            err,
        };

        pub const Unit = struct {
            host_path: []const u8,
            host_base: []const u8,
            suffix_type: SuffixType,
            guest: []const u8,
            type: File.Type,
        };

        pub const SuffixType = enum {
            none,
            arch,
            full,
        };

        pub fn next(parser: *File.Parser) !?Unit {
            // Do this to avoid getting the editor crazy about it
            const left_curly_brace = 0x7b;
            const right_curly_brace = 0x7d;

            while (parser.index < parser.text.len and parser.text[parser.index] != right_curly_brace) {
                try parser.expectChar('.');
                try parser.expectChar(left_curly_brace);

                if (parser.index < parser.text.len and parser.text[parser.index] != right_curly_brace) {
                    const host_path_field = try parser.parseField("host_path");
                    const host_base_field = try parser.parseField("host_base");
                    const suffix_type = lib.stringToEnum(SuffixType, try parser.parseField("suffix_type")) orelse return Error.err;
                    const guest_field = try parser.parseField("guest");
                    const file_type = lib.stringToEnum(File.Type, try parser.parseField("type")) orelse return Error.err;
                    try parser.expectChar(right_curly_brace);
                    parser.maybeExpectChar(',');
                    parser.skipSpace();

                    return .{
                        .host_path = host_path_field,
                        .host_base = host_base_field,
                        .suffix_type = suffix_type,
                        .guest = guest_field,
                        .type = file_type,
                    };
                } else {
                    @panic("WTF");
                }
            }

            return null;
        }

        inline fn consume(parser: *File.Parser) void {
            parser.index += 1;
        }

        fn parseField(parser: *File.Parser, field: []const u8) ![]const u8 {
            try parser.expectChar('.');
            try parser.expectString(field);
            try parser.expectChar('=');
            const field_value = try parser.expectQuotedString();
            parser.maybeExpectChar(',');

            return field_value;
        }

        fn skipSpace(parser: *File.Parser) void {
            while (parser.index < parser.text.len) {
                const char = parser.text[parser.index];
                const is_space = char == ' ' or char == '\n' or char == '\r' or char == '\t';
                if (!is_space) break;
                parser.consume();
            }
        }

        fn maybeExpectChar(parser: *File.Parser, char: u8) void {
            parser.skipSpace();
            if (parser.text[parser.index] == char) {
                parser.consume();
            }
        }

        fn expectChar(parser: *File.Parser, expected_char: u8) !void {
            parser.skipSpace();
            const char = parser.text[parser.index];
            if (char != expected_char) {
                return Error.err;
            }

            parser.consume();
        }

        fn expectString(parser: *File.Parser, string: []const u8) !void {
            parser.skipSpace();
            if (!lib.equal(u8, parser.text[parser.index..][0..string.len], string)) {
                return Error.err;
            }

            for (string) |_, index| {
                _ = index;
                parser.consume();
            }
        }

        fn expectQuotedString(parser: *File.Parser) ![]const u8 {
            parser.skipSpace();
            try parser.expectChar('"');
            const start_index = parser.index;
            while (parser.index < parser.text.len and parser.text[parser.index] != '"') {
                parser.consume();
            }
            const end_index = parser.index;
            try parser.expectChar('"');

            const string = parser.text[start_index..end_index];
            return string;
        }
    };
};

pub const Framebuffer = extern struct {
    address: u64,
    pitch: u32,
    width: u32,
    height: u32,
    bpp: u16,
    red_mask: ColorMask,
    green_mask: ColorMask,
    blue_mask: ColorMask,
    memory_model: u8,
    reserved: u8 = 0,

    pub const ColorMask = extern struct {
        size: u8 = 0,
        shift: u8 = 0,
    };

    pub const VideoMode = extern struct {
        foo: u32 = 0,
    };
};

pub const LengthSizeTuples = extern struct {
    tuples: Tuples,
    total_size: u32 = 0,

    const Tuples = lib.EnumStruct(Information.Slice.Name, Tuple);

    const count = Information.Slice.count;

    pub const Tuple = extern struct {
        length: u32,
        alignment: u32,
        size: u32 = 0,
        reserved: u32 = 0,
    };

    pub fn new(fields: Tuples.Struct) LengthSizeTuples {
        var tuples = LengthSizeTuples{
            .tuples = .{
                .fields = fields,
            },
        };

        var total_size: u32 = 0;

        inline for (Information.Slice.TypeMap) |T, index| {
            const tuple = &tuples.tuples.array.values[index];
            const size = tuple.length * @sizeOf(T);
            tuple.alignment = if (tuple.alignment < @alignOf(T)) @alignOf(T) else tuple.alignment;
            total_size = lib.alignForwardGeneric(u32, total_size, tuple.alignment);
            total_size += lib.alignForwardGeneric(u32, size, tuple.alignment);
            tuple.size = size;
        }

        tuples.total_size = total_size;

        return tuples;
    }

    pub fn createSlices(tuples: LengthSizeTuples) lib.EnumStruct(Information.Slice.Name, Information.Slice) {
        var slices = lib.zeroes(lib.EnumStruct(Information.Slice.Name, Information.Slice));
        var allocated_size: u32 = 0;

        for (slices.array.values) |*slice, index| {
            const tuple = tuples.tuples.array.values[index];
            const length = tuple.length;
            const size = lib.alignForwardGeneric(u32, tuple.size, tuple.alignment);

            slice.* = .{
                .offset = allocated_size,
                .len = length,
                .size = tuple.size,
                .alignment = tuple.alignment,
            };

            allocated_size = lib.alignForwardGeneric(u32, allocated_size, tuple.alignment);
            allocated_size += size;
        }

        if (allocated_size != tuples.total_size) @panic("Extra allocation size must match bootloader allocated extra size");

        return slices;
    }
};
