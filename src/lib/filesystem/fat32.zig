const FAT32 = @This();

const lib = @import("../../lib.zig");
const assert = lib.assert;
const Disk = lib.Disk;
const GPT = lib.PartitionTable.GPT;
const MBR = lib.PartitionTable.MBR;
const kb = lib.kb;
const mb = lib.mb;
const gb = lib.gb;
const log = lib.log.scoped(.FAT32);

pub const count = 2;
pub const volumes_lba = GPT.reserved_partition_size / GPT.max_block_size / 2;
pub const minimum_partition_size = 33 * mb;
pub const maximum_partition_size = 32 * gb;
pub const last_cluster = 0xffff_ffff;
pub const starting_cluster = 2;
pub const default_fs_info_sector = 1;
pub const default_backup_boot_record_sector = 6;
pub const default_reserved_sector_count = 32;

pub const FSInfo = extern struct {
    lead_signature: u32 = 0x41617272,
    reserved: [480]u8 = [1]u8{0} ** 480,
    signature: u32 = 0x61417272,
    free_cluster_count: u32,
    last_allocated_cluster: u32,
    reserved1: [12]u8 = [1]u8{0} ** 12,
    trail_signature: u32 = 0xaa550000,

    /// Returns first cluster to be used
    pub fn allocate_clusters(fs_info: *FSInfo, cluster_count: u32) u32 {
        const result = fs_info.last_allocated_cluster + 1;
        fs_info.last_allocated_cluster += cluster_count;
        fs_info.free_cluster_count -= cluster_count;
        return result;
    }

    pub fn format(fsinfo: *const FSInfo, comptime _: []const u8, _: lib.FormatOptions, writer: anytype) @TypeOf(writer).Error!void {
        try lib.format(writer, "FSInfo:\n", .{});
        try lib.format(writer, "\tLead signature: 0x{x}\n", .{fsinfo.lead_signature});
        try lib.format(writer, "\tOther signature: 0x{x}\n", .{fsinfo.signature});
        try lib.format(writer, "\tFree cluster count: {}\n", .{fsinfo.free_cluster_count});
        try lib.format(writer, "\tLast allocated cluster: {}\n", .{fsinfo.last_allocated_cluster});
        try lib.format(writer, "\tTrail signature: 0x{x}\n", .{fsinfo.trail_signature});
    }
};

pub fn is_filesystem(file: []const u8) bool {
    const magic = "FAT32   ";
    return lib.equal(u8, file[0x52..], magic);
}

pub fn is_boot_record(file: []const u8) bool {
    const magic = [_]u8{ 0x55, 0xAA };
    const magic_alternative = [_]u8{ 'M', 'S', 'W', 'I', 'N', '4', '.', '1' };
    if (!lib.equal(u8, file[0x1fe..], magic)) return false;
    if (!lib.equal(u8, file[0x3fe..], magic)) return false;
    if (!lib.equal(u8, file[0x5fe..], magic)) return false;
    if (!lib.equal(u8, file[0x03..], magic_alternative)) return false;
    return true;
}

pub fn get_cluster_size(size: u64) u16 {
    if (size <= 64 * mb) return 0x200;
    if (size <= 128 * mb) return 1 * kb;
    if (size <= 256 * mb) return 2 * kb;
    if (size <= 8 * gb) return 8 * kb;
    if (size <= 16 * gb) return 16 * kb;

    return 32 * kb;
}

pub const Date = packed struct(u16) {
    day: u5,
    month: u4,
    year: u7,

    pub fn new(day: u5, month: u4, year: u12) Date {
        return Date{
            .day = day,
            .month = month,
            .year = @intCast(u7, year - 1980),
        };
    }
};

pub const Time = packed struct(u16) {
    seconds_2_factor: u5,
    minutes: u6,
    hours: u5,

    pub fn new(seconds: u6, minutes: u6, hours: u5) Time {
        return Time{
            .seconds_2_factor = @intCast(u5, seconds / 2),
            .minutes = minutes,
            .hours = hours,
        };
    }
};

pub const DirectoryEntry = extern struct {
    name: [11]u8,
    attributes: Attributes,
    nt_reserved: u8 = 0,
    creation_time_tenth: u8,
    creation_time: Time,
    creation_date: Date,
    last_access_date: Date,
    first_cluster_high: u16,
    last_write_time: Time,
    last_write_date: Date,
    first_cluster_low: u16,
    file_size: u32,

    pub const Sector = [per_sector]@This();
    pub const per_sector = @divExact(0x200, @sizeOf(@This()));

    pub const Chain = extern struct {
        previous: ?*DirectoryEntry = null,
        next: ?*DirectoryEntry = null,
        current: *DirectoryEntry,
    };

    pub fn format(entry: *const DirectoryEntry, comptime _: []const u8, _: lib.FormatOptions, writer: anytype) @TypeOf(writer).Error!void {
        try lib.format(writer, "Directory entry:\n", .{});
        try lib.format(writer, "\tName: {s}\n", .{entry.name});
        try lib.format(writer, "\tAttributes: {}\n", .{entry.attributes});
        try lib.format(writer, "\tCreation time tenth: {}\n", .{entry.creation_time_tenth});
        try lib.format(writer, "\tCreation time: {}\n", .{entry.creation_time});
        try lib.format(writer, "\tCreation date: {}\n", .{entry.creation_date});
        try lib.format(writer, "\tLast access date: {}\n", .{entry.last_access_date});
        try lib.format(writer, "\tLast write time: {}\n", .{entry.last_write_time});
        try lib.format(writer, "\tLast write date: {}\n", .{entry.last_write_date});
        const first_cluster = @as(u32, entry.first_cluster_high) << 16 | entry.first_cluster_low;
        try lib.format(writer, "\tFirst cluster: 0x{x}\n", .{first_cluster});
        try lib.format(writer, "\tFile size: 0x{x}\n", .{entry.file_size});
    }

    pub fn small_filename_only(entry: DirectoryEntry) bool {
        return !entry.attributes.has_long_name() and entry.name[0] != 0;
    }

    pub fn is_free(entry: DirectoryEntry) bool {
        const first_char = entry.name[0];
        assert(first_char != 0x20);
        return switch (first_char) {
            0, 0xe5, ' ' => true,
            else => false,
        };
    }

    pub fn set_first_cluster(entry: *DirectoryEntry, cluster: u32) void {
        entry.first_cluster_low = @truncate(u16, cluster);
        entry.first_cluster_high = @truncate(u16, cluster >> 16);
    }

    pub fn get_first_cluster(entry: *DirectoryEntry) u32 {
        return @as(u32, entry.first_cluster_high) << 16 | entry.first_cluster_low;
    }

    pub const Attributes = packed struct(u8) {
        read_only: bool,
        hidden: bool,
        system: bool,
        volume_id: bool,
        directory: bool,
        archive: bool,
        reserved: u2 = 0,

        pub fn has_long_name(attributes: Attributes) bool {
            return attributes.read_only and attributes.hidden and attributes.system and attributes.volume_id;
        }
    };

    comptime {
        assert(@sizeOf(@This()) == 32);
    }
};

pub const LongNameEntry = extern struct {
    sequence_number: packed struct(u8) {
        number: u5,
        first_physical_entry: u1 = 0,
        last_logical: bool,
        reserved: u1 = 0,
    },
    chars_0_4: [5]u16 align(1),
    attributes: u8,
    type: u8,
    checksum: u8,
    chars_5_10: [6]u16 align(1),
    reserved: [2]u8 = .{ 0, 0 },
    chars_11_12: [2]u16 align(1),

    pub const Sector = [per_sector]@This();
    pub const per_sector = @divExact(0x200, @sizeOf(@This()));

    pub fn is_last(entry: LongNameEntry) bool {
        return entry.sequence_number.last_logical;
    }

    fn get_characters(entry: LongNameEntry) [26]u8 {
        return entry.chars_0_4 ++ entry.chars_5_10 ++ entry.chars_11_12;
    }

    fn is_free(entry: LongNameEntry) bool {
        const first_char = entry.chars_0_4[0];
        assert(first_char != 0x20);
        return switch (first_char) {
            0, 0xe5, ' ' => true,
            else => false,
        };
    }
};

pub const Entry = packed struct(u32) {
    value: u28,
    reserved: u4 = 0,

    pub const Sector = [@divExact(0x200, @sizeOf(FAT32.Entry))]FAT32.Entry;

    pub fn is_free(entry: Entry) bool {
        return entry.value == value_free;
    }

    pub fn is_eof(entry: Entry, max_valid_cluster_number: u32) bool {
        return switch (entry.get_type(max_valid_cluster_number)) {
            .reserved_and_should_not_be_used_eof, .allocated_and_eof => true,
            .bad_cluster, .reserved_and_should_not_be_used, .allocated, .free => false,
        };
    }

    pub fn get_type(entry: Entry, max_valid_cluster_number: u32) Type {
        return switch (entry.value) {
            value_free => .free,
            value_bad_cluster => .bad_cluster,
            value_reserved_and_should_not_be_used_eof_start...value_reserved_and_should_not_be_used_eof_end => .reserved_and_should_not_be_used_eof,
            value_allocated_and_eof => .allocated_and_eof,
            else => if (entry.value >= value_allocated_start and entry.value <= @intCast(u28, max_valid_cluster_number)) .allocated else if (entry.value >= @intCast(u28, max_valid_cluster_number) + 1 and entry.value <= value_reserved_and_should_not_be_used_end) .reserved_and_should_not_be_used else unreachable,
        };
    }

    fn get_entry(t: Type) Entry {
        return Entry{
            .value = switch (t) {
                .free => value_free,
                .allocated => value_allocated_start,
                .reserved_and_should_not_be_used => value_reserved_and_should_not_be_used_end,
                .bad_cluster => value_bad_cluster,
                .reserved_and_should_not_be_used_eof => value_reserved_and_should_not_be_used_eof_start,
                .allocated_and_eof => value_allocated_and_eof,
            },
        };
    }

    pub const free = get_entry(.free);
    pub const allocated = get_entry(.allocated);
    pub const reserved_and_should_not_be_used = get_entry(.reserved_and_should_not_be_used);
    pub const bad_cluster = get_entry(.bad_cluster);
    pub const reserved_and_should_not_be_used_eof = get_entry(.reserved_and_should_not_be_used_eof);
    pub const allocated_and_eof = get_entry(.allocated_and_eof);

    const value_free = 0;
    const value_allocated_start = 2;
    const value_reserved_and_should_not_be_used_end = 0xfff_fff6;
    const value_bad_cluster = 0xfff_fff7;
    const value_reserved_and_should_not_be_used_eof_start = 0xfff_fff8;
    const value_reserved_and_should_not_be_used_eof_end = 0xfff_fffe;
    const value_allocated_and_eof = 0xfff_ffff;

    pub const Type = enum {
        free,
        allocated,
        reserved_and_should_not_be_used,
        bad_cluster,
        reserved_and_should_not_be_used_eof,
        allocated_and_eof,
    };
};

pub fn get_data_sector_count(mbr: *const MBR.Partition) u32 {
    const fat_sector_count = mbr.bpb.fat_sector_count_32;
    const total_sector_count = mbr.bpb.dos3_31.total_sector_count_32;
    const fat_count = mbr.bpb.dos3_31.dos2_0.fat_count;
    const reserved_sectors = mbr.bpb.dos3_31.dos2_0.reserved_sector_count;

    return total_sector_count - (reserved_sectors + (fat_count * fat_sector_count));
}

pub fn get_cluster_count(mbr: *const MBR.Partition) u32 {
    const data_sector_count = get_data_sector_count(mbr);
    const cluster_sector_count = mbr.bpb.dos3_31.dos2_0.cluster_sector_count;

    const cluster_count = @divExact(data_sector_count, cluster_sector_count);
    return cluster_count;
}

pub fn get_maximum_valid_cluster_number(mbr: *const MBR.Partition) u32 {
    return get_cluster_count(mbr) + 1;
}

pub fn get_mbr(disk: *Disk, gpt_partition: *const GPT.Partition) !*MBR.Partition {
    return try disk.read_typed_sectors(MBR.Partition, gpt_partition.first_lba);
}

pub fn get_cluster_entry_lba(gpt_partition: *const GPT.Partition, mbr_partition: *const MBR.Partition) u64 {
    return gpt_partition.first_lba + mbr_partition.bpb.dos3_31.dos2_0.reserved_sector_count;
}

pub fn get_cluster_entries(disk: *Disk, gpt_partition: *const GPT.Partition, mbr_partition: *const MBR.Partition, lba_offset: u64) ![]FAT32.Entry {
    assert(disk.sector_size == 0x200);
    const cluster_entry_lba = get_cluster_entry_lba(gpt_partition, mbr_partition);
    return try disk.read_typed_sectors(Entry.Sector, cluster_entry_lba + lba_offset);
}

pub fn get_directory_entries(disk: *Disk, gpt_partition: *const GPT.Partition, mbr_partition: *const MBR.Partition, lba_offset: u64) ![]FAT32.DirectoryEntry {
    const cluster_entry_lba = get_cluster_entry_lba(gpt_partition, mbr_partition);
    const cluster_entry_lba_count = mbr_partition.bpb.fat_sector_count_32 * mbr_partition.bpb.dos3_31.dos2_0.fat_count;
    return try disk.read_typed_sectors(DirectoryEntry.Sector, cluster_entry_lba + cluster_entry_lba_count + lba_offset);
}

fn cdiv(a: u32, b: u32) u32 {
    return (a + b - 1) / b;
}

const min_cluster_32 = 65525;
const max_cluster_32 = 268435446;

pub fn format(disk: *Disk, partition_range: Disk.PartitionRange, copy_mbr: ?*const MBR.Partition) !Cache {
    const fat_partition_mbr_lba = partition_range.first_lba;
    const fat_partition_mbr = try disk.read_typed_sectors(MBR.Partition, fat_partition_mbr_lba);

    const sectors_per_track = 32;
    const total_sector_count_32 = @intCast(u32, lib.alignBackward(partition_range.last_lba - partition_range.first_lba, sectors_per_track));
    const fat_count = FAT32.count;

    var cluster_size: u8 = 1;
    const max_cluster_size = 128;
    var fat_data_sector_count: u32 = undefined;
    var fat_length_32: u32 = undefined;
    var cluster_count_32: u32 = undefined;

    while (true) {
        assert(cluster_size > 0);
        fat_data_sector_count = total_sector_count_32 - lib.alignForwardGeneric(u32, FAT32.default_reserved_sector_count, cluster_size);
        cluster_count_32 = (fat_data_sector_count * disk.sector_size + fat_count * 8) / (cluster_size * disk.sector_size + fat_count * 4);
        fat_length_32 = lib.alignForwardGeneric(u32, cdiv((cluster_count_32 + 2) * 4, disk.sector_size), cluster_size);
        cluster_count_32 = (fat_data_sector_count - fat_count * fat_length_32) / cluster_size;
        const max_cluster_size_32 = @min(fat_length_32 * disk.sector_size / 4, max_cluster_32);
        if (cluster_count_32 > max_cluster_size_32) {
            cluster_count_32 = 0;
        }
        if (cluster_count_32 != 0 and cluster_count_32 < min_cluster_32) {
            cluster_count_32 = 0;
        }

        if (cluster_count_32 != 0) break;

        cluster_size <<= 1;

        const keep_going = cluster_size != 0 and cluster_size <= max_cluster_size;
        if (!keep_going) break;
        unreachable;
    }

    var root_directory_entries: u64 = 0;
    _ = root_directory_entries;

    log.debug("Cluster size: {}. FAT data sector count: {}. FAT sector count: {}", .{ cluster_size, fat_data_sector_count, fat_length_32 });
    const reserved_sector_count = lib.alignForwardGeneric(u16, FAT32.default_reserved_sector_count, cluster_size);

    fat_partition_mbr.* = MBR.Partition{
        .bpb = .{
            .dos3_31 = .{
                .dos2_0 = .{
                    .jmp_code = .{ 0xeb, 0x58, 0x90 },
                    .oem_identifier = "mkfs.fat".*,
                    .sector_size = disk.sector_size,
                    .cluster_sector_count = cluster_size,
                    .reserved_sector_count = reserved_sector_count,
                    .fat_count = fat_count,
                    .root_entry_count = 0,
                    .total_sector_count_16 = 0,
                    .media_descriptor = 0xf8,
                    .fat_sector_count_16 = 0,
                },
                .physical_sectors_per_track = sectors_per_track,
                .disk_head_count = 8,
                .hidden_sector_count = @intCast(u32, partition_range.first_lba),
                .total_sector_count_32 = total_sector_count_32,
            },
            .fat_sector_count_32 = fat_length_32,
            .drive_description = 0,
            .version = .{ 0, 0 },
            .root_directory_cluster_offset = FAT32.starting_cluster,
            .fs_info_sector = FAT32.default_fs_info_sector,
            .backup_boot_record_sector = FAT32.default_backup_boot_record_sector,
            .drive_number = 0x80,
            .extended_boot_signature = 0x29,
            .serial_number = if (copy_mbr) |copy_partition_mbr| copy_partition_mbr.bpb.serial_number else unreachable,
            .volume_label = "NO NAME    ".*,
            .filesystem_type = "FAT32   ".*,
        },
        .code = [_]u8{
            0xe, 0x1f, 0xbe, 0x77, 0x7c, 0xac, 0x22, 0xc0, 0x74, 0xb, 0x56, 0xb4, 0xe, 0xbb, 0x7, 0x0, 0xcd, 0x10, 0x5e, 0xeb, 0xf0, 0x32, 0xe4, 0xcd, 0x16, 0xcd, 0x19, 0xeb, 0xfe, 0x54, 0x68, 0x69, 0x73, 0x20, 0x69, 0x73, 0x20, 0x6e, 0x6f, 0x74, 0x20, 0x61, 0x20, 0x62, 0x6f, 0x6f, 0x74, 0x61, 0x62, 0x6c, 0x65, 0x20, 0x64, 0x69, 0x73, 0x6b, 0x2e, 0x20, 0x20, 0x50, 0x6c, 0x65, 0x61, 0x73, 0x65, 0x20, 0x69, 0x6e, 0x73, 0x65, 0x72, 0x74, 0x20, 0x61, 0x20, 0x62, 0x6f, 0x6f, 0x74, 0x61, 0x62, 0x6c, 0x65, 0x20, 0x66, 0x6c, 0x6f, 0x70, 0x70, 0x79, 0x20, 0x61, 0x6e, 0x64, 0xd, 0xa, 0x70, 0x72, 0x65, 0x73, 0x73, 0x20, 0x61, 0x6e, 0x79, 0x20, 0x6b, 0x65, 0x79, 0x20, 0x74, 0x6f, 0x20, 0x74, 0x72, 0x79, 0x20, 0x61, 0x67, 0x61, 0x69, 0x6e, 0x20, 0x2e, 0x2e, 0x2e, 0x20, 0xd, 0xa,
        } ++ [1]u8{0} ** 227,
        // This should be zero
        .partitions = lib.zeroes([4]MBR.LegacyPartition),
    };

    try disk.write_typed_sectors(MBR.Partition, fat_partition_mbr, fat_partition_mbr_lba, false);

    const backup_boot_record_sector = partition_range.first_lba + fat_partition_mbr.bpb.backup_boot_record_sector;
    const backup_boot_record = try disk.read_typed_sectors(MBR.Partition, backup_boot_record_sector);
    backup_boot_record.* = fat_partition_mbr.*;
    try disk.write_typed_sectors(MBR.Partition, backup_boot_record, backup_boot_record_sector, false);

    const fs_info_lba = partition_range.first_lba + fat_partition_mbr.bpb.fs_info_sector;
    const fs_info = try disk.read_typed_sectors(FAT32.FSInfo, fs_info_lba);
    fs_info.* = .{
        .lead_signature = 0x41615252,
        .signature = 0x61417272,
        .free_cluster_count = fat_partition_mbr.bpb.dos3_31.total_sector_count_32 - 2017, // TODO: compute,
        .last_allocated_cluster = fat_partition_mbr.bpb.root_directory_cluster_offset,
        .trail_signature = 0xaa550000,
    };
    try disk.write_typed_sectors(FAT32.FSInfo, fs_info, fs_info_lba, false);

    const backup_fs_info_lba = backup_boot_record_sector + backup_boot_record.bpb.fs_info_sector;
    const backup_fs_info = try disk.read_typed_sectors(FAT32.FSInfo, backup_fs_info_lba);
    backup_fs_info.* = fs_info.*;
    try disk.write_typed_sectors(FAT32.FSInfo, backup_fs_info, backup_fs_info_lba, false);

    try write_fat_entry_slow(disk, fat_partition_mbr, partition_range.first_lba, FAT32.Entry.reserved_and_should_not_be_used_eof, 0);
    try write_fat_entry_slow(disk, fat_partition_mbr, partition_range.first_lba, FAT32.Entry.allocated_and_eof, 1);
    try write_fat_entry_slow(disk, fat_partition_mbr, partition_range.first_lba, FAT32.Entry.reserved_and_should_not_be_used_eof, 2);

    return .{
        .disk = disk,
        .partition_range = partition_range,
        .mbr = fat_partition_mbr,
        .fs_info = fs_info,
    };
}

fn write_fat_entry_slow(disk: *Disk, fat_partition_mbr: *MBR.Partition, partition_lba_start: u64, fat_entry: FAT32.Entry, fat_entry_index: usize) !void {
    const fat_entries_lba = partition_lba_start + fat_partition_mbr.bpb.dos3_31.dos2_0.reserved_sector_count;
    const fat_entry_count = fat_partition_mbr.bpb.dos3_31.dos2_0.fat_count;
    const fat_entry_sector_count = fat_partition_mbr.bpb.fat_sector_count_32;
    var fat_index: u8 = 0;

    while (fat_index < fat_entry_count) : (fat_index += 1) {
        const fat_entry_lba = fat_entries_lba + (fat_index * fat_entry_sector_count) + (fat_entry_index * @sizeOf(u32) / disk.sector_size);
        const fat_entry_sector = try disk.read_typed_sectors(FAT32.Entry.Sector, fat_entry_lba);
        const fat_entry_sector_index = fat_entry_index % disk.sector_size;
        fat_entry_sector[fat_entry_sector_index] = fat_entry;
        try disk.write_typed_sectors(FAT32.Entry.Sector, fat_entry_sector, fat_entry_lba, false);
    }
}

const dot_entry_name: [11]u8 = ".".* ++ ([1]u8{' '} ** 10);
const dot_dot_entry_name: [11]u8 = "..".* ++ ([1]u8{' '} ** 9);

fn insert_directory_entry_slow(disk: *Disk, desired_entry: anytype, insert: struct { cluster: u32, root_cluster: u32, cluster_sector_count: u16, root_cluster_sector: u64 }) !EntryResult(@TypeOf(desired_entry)) {
    const EntryType = @TypeOf(desired_entry);
    comptime assert(EntryType == DirectoryEntry or EntryType == LongNameEntry);
    comptime assert(@sizeOf(EntryType) == 32);
    const cluster_dir_lba = (insert.cluster - insert.root_cluster) * insert.cluster_sector_count + insert.root_cluster_sector;
    assert(insert.cluster_sector_count == 1);
    const fat_directory_entries = try disk.read_typed_sectors(EntryType.Sector, cluster_dir_lba);

    for (fat_directory_entries) |*entry, entry_index| {
        //log.debug("Entry: {}", .{entry});
        if (entry.is_free()) {
            //log.debug("Inserting entry {s} in cluster {}. Cluster dir LBA: 0x{x}. Entry index: {}", .{ desired_entry.name, insert.cluster, cluster_dir_lba, entry_index });
            entry.* = desired_entry;
            return EntryResult(EntryType){
                .cluster = insert.cluster,
                .entry_starting_index = @intCast(u32, entry_index),
                .directory_entry = entry,
            };
        }
    }

    unreachable;
}

fn compare_fat_entries(my_fat_entries: []const FAT32.Entry, barebones_fat_entries: []align(1) const FAT32.Entry) void {
    for (my_fat_entries) |fat_entry, fat_entry_index| {
        const barebones_fat_entry = barebones_fat_entries[fat_entry_index];
        if (barebones_fat_entry.value == .free) {
            break;
        }

        log.debug("Barebones[{}] = {}", .{ fat_entry_index, barebones_fat_entry.value });

        if (barebones_fat_entry.value != fat_entry.value) {
            log.debug("Difference at index {}. My FAT entry: {}. Barebones FAT entry: {}", .{ fat_entry_index, fat_entry, barebones_fat_entry });
        }
    }
}

pub const Cache = extern struct {
    disk: *Disk,
    partition_range: Disk.PartitionRange,
    mbr: *MBR.Partition,
    fs_info: *FSInfo,

    pub fn from_gpt_partition_cache(gpt_partition_cache: GPT.Partition.Cache) !FAT32.Cache {
        const partition_range = Disk.PartitionRange{
            .first_lba = gpt_partition_cache.partition.first_lba,
            .last_lba = gpt_partition_cache.partition.last_lba,
        };
        const disk = gpt_partition_cache.gpt.disk;

        const partition_mbr = try disk.read_typed_sectors(MBR.Partition, partition_range.first_lba);
        assert(partition_mbr.bpb.dos3_31.dos2_0.cluster_sector_count == 1);
        const fs_info_sector = partition_range.first_lba + partition_mbr.bpb.fs_info_sector;
        const fs_info = try disk.read_typed_sectors(FAT32.FSInfo, fs_info_sector);

        return .{
            .disk = disk,
            .partition_range = partition_range,
            .mbr = partition_mbr,
            .fs_info = fs_info,
        };
    }

    pub fn mkdir(cache: Cache, absolute_path: []const u8, copy_cache: ?Cache) !void {
        const fat_lba = cache.partition_range.first_lba + cache.mbr.bpb.dos3_31.dos2_0.reserved_sector_count;

        const root_cluster = cache.mbr.bpb.root_directory_cluster_offset;

        const cluster_sector_count = cache.mbr.bpb.dos3_31.dos2_0.cluster_sector_count;
        const data_lba = fat_lba + (cache.mbr.bpb.fat_sector_count_32 * cache.mbr.bpb.dos3_31.dos2_0.fat_count);
        log.debug("Data LBA: 0x{x}", .{data_lba});

        assert(absolute_path[0] == '/');

        const root_cluster_sector = data_lba;
        var upper_cluster = root_cluster;
        var dir_tokenizer = lib.tokenize(u8, absolute_path, "/");

        var directories: u64 = 0;
        while (dir_tokenizer.next()) |entry_name| : (directories += 1) {
            assert(entry_name.len <= 8);
            log.debug("Looking for/creating {s}", .{entry_name});

            //const cluster_sector = root_cluster_sector + cluster_to_sectors(upper_cluster);
            const directory_cluster = try cache.allocate_fat_entry();
            log.debug("Directory cluster: {}", .{directory_cluster});

            const copy_entry: ?*FAT32.DirectoryEntry = blk: {
                if (copy_cache) |cc| {
                    const name = absolute_path[0..dir_tokenizer.index];
                    log.debug("Entry name: {s}", .{name});
                    const entry_result = try cc.get_directory_entry(name, .fail, null);
                    break :blk entry_result.directory_entry;
                } else break :blk null;
            };

            log.debug("Upper cluster: {}", .{upper_cluster});
            const entry = FAT32.DirectoryEntry{
                .name = blk: {
                    var name: [11]u8 = [1]u8{' '} ** 11;
                    lib.copy(u8, &name, entry_name);
                    break :blk name;
                },
                .attributes = .{
                    .read_only = false,
                    .hidden = false,
                    .system = false,
                    .volume_id = false,
                    .directory = true,
                    .archive = false,
                },
                .creation_time_tenth = if (copy_entry) |ce| ce.creation_time_tenth else unreachable,
                .creation_time = if (copy_entry) |ce| ce.creation_time else unreachable,
                .creation_date = if (copy_entry) |ce| ce.creation_date else unreachable,
                .first_cluster_high = @truncate(u16, directory_cluster >> 16),
                .first_cluster_low = @truncate(u16, directory_cluster),
                .last_access_date = if (copy_entry) |ce| ce.last_access_date else unreachable,
                .last_write_time = if (copy_entry) |ce| ce.last_write_time else unreachable,
                .last_write_date = if (copy_entry) |ce| ce.last_write_date else unreachable,
                .file_size = 0,
            };

            var dot_entry = entry;
            dot_entry.name = dot_entry_name;
            var dot_dot_entry = entry;
            dot_dot_entry.name = dot_dot_entry_name;
            dot_dot_entry.set_first_cluster(if (upper_cluster == root_cluster) 0 else upper_cluster);

            _ = try insert_directory_entry_slow(cache.disk, entry, .{
                .cluster = upper_cluster,
                .root_cluster = root_cluster,
                .cluster_sector_count = cluster_sector_count,
                .root_cluster_sector = root_cluster_sector,
            });
            _ = try insert_directory_entry_slow(cache.disk, dot_entry, .{
                .cluster = upper_cluster + 1,
                .root_cluster = root_cluster,
                .cluster_sector_count = cluster_sector_count,
                .root_cluster_sector = root_cluster_sector,
            });
            _ = try insert_directory_entry_slow(cache.disk, dot_dot_entry, .{
                .cluster = upper_cluster + 1,
                .root_cluster = root_cluster,
                .cluster_sector_count = cluster_sector_count,
                .root_cluster_sector = root_cluster_sector,
            });

            upper_cluster = directory_cluster;
        }
    }

    pub fn add_file(cache: Cache, absolute_path: []const u8, file_content: []const u8, entry_copy: ?*FAT32.DirectoryEntry) !void {
        const file_entry = try cache.get_directory_entry(absolute_path, .{ .allocate = .{ .file = .{ .content = file_content } } }, entry_copy);
        log.debug("File entry: {}", .{file_entry});
    }

    pub const GetNotFoundPolicy = union(enum) {
        allocate: union(enum) {
            file: struct {
                content: []const u8,
            },
            directory: void,
        },
        fail: void,
    };

    pub const GetError = error{
        not_found,
    };

    pub fn get_directory_entry(cache: Cache, absolute_path: []const u8, not_found_policy: GetNotFoundPolicy, entry_copy: ?*FAT32.DirectoryEntry) !EntryResult(DirectoryEntry) {
        const fat_lba = cache.partition_range.first_lba + cache.mbr.bpb.dos3_31.dos2_0.reserved_sector_count;
        const root_cluster = cache.mbr.bpb.root_directory_cluster_offset;
        const data_lba = fat_lba + (cache.mbr.bpb.fat_sector_count_32 * cache.mbr.bpb.dos3_31.dos2_0.fat_count);

        assert(absolute_path[0] == '/');

        const root_cluster_sector = data_lba;
        var upper_cluster = root_cluster;
        var dir_tokenizer = lib.tokenize(u8, absolute_path, "/");
        var directories: usize = 0;

        entry_loop: while (dir_tokenizer.next()) |entry_name| : (directories += 1) {
            const is_last = dir_tokenizer.peek() == null;

            const normalized_name = pack_string(entry_name, .{
                .len = 11,
                .fill_with = ' ',
                .upper = true,
            });

            while (true) : (upper_cluster += 1) {
                const cluster_sector_offset = root_cluster_sector + cache.cluster_to_sectors(upper_cluster - root_cluster);
                const directory_entries_in_cluster = try cache.disk.read_typed_sectors(DirectoryEntry.Sector, cluster_sector_offset);

                var entry_index: usize = 0;
                while (entry_index < directory_entries_in_cluster.len) : ({
                    entry_index += 1;
                }) {
                    const directory_entry = &directory_entries_in_cluster[entry_index];
                    const is_empty = directory_entry.name[0] == 0;
                    const is_unused = directory_entry.name[0] == 0xe5;
                    const is_long_name = directory_entry.attributes.has_long_name();

                    if (is_empty) {
                        switch (not_found_policy) {
                            .allocate => |allocate| switch (allocate) {
                                .file => |file| {
                                    const chop_element_count = 26;
                                    const chop_index = entry_name.len / chop_element_count;
                                    const chop_count = chop_index + 1;
                                    const chop_slice = entry_name[chop_element_count * chop_index ..];
                                    //sequence_number: packed struct(u8) {
                                    //number: u5,
                                    //first_physical_entry: u1 = 0,
                                    //last_logical: bool,
                                    //reserved: u1 = 0,
                                    //},
                                    //chars_0_4: [5]u16 align(1),
                                    //attributes: u8,
                                    //type: u8,
                                    //checksum: u8,
                                    //chars_5_10: [6]u16 align(1),
                                    //reserved: [2]u8 = .{ 0, 0 },
                                    //chars_11_12: [2]u16 align(1),

                                    _ = try insert_directory_entry_slow(cache.disk, LongNameEntry{
                                        .sequence_number = .{
                                            .number = @intCast(u5, chop_index) + 1,
                                            .last_logical = true,
                                        },
                                        .chars_0_4 = long_name_chop(chop_slice, 0, 4, .{}),
                                        .attributes = 0xf,
                                        .type = 0,
                                        .checksum = blk: {
                                            var sum: u8 = 0;
                                            for (normalized_name) |character| {
                                                sum = ((sum & 1) << 7) + (sum >> 1) + character;
                                            }
                                            break :blk sum;
                                        },
                                        .chars_5_10 = long_name_chop(chop_slice, 5, 10, .{}),
                                        .chars_11_12 = long_name_chop(chop_slice, 11, 12, .{}),
                                    }, .{
                                        .cluster = upper_cluster,
                                        .root_cluster = root_cluster,
                                        .cluster_sector_count = @intCast(u16, cache.cluster_to_sectors(1)),
                                        .root_cluster_sector = root_cluster_sector,
                                    });

                                    var index: usize = chop_count - 1;
                                    while (index > 0) : (index -= 1) {
                                        unreachable;
                                    }

                                    var entry = try insert_directory_entry_slow(cache.disk, FAT32.DirectoryEntry{
                                        .name = if (entry_name.len < 10) pack_string(entry_name, .{
                                            .len = 11,
                                            .fill_with = ' ',
                                            .upper = true,
                                        }) else unreachable,
                                        .attributes = .{
                                            .read_only = false,
                                            .hidden = false,
                                            .system = false,
                                            .volume_id = false,
                                            .directory = false,
                                            .archive = true,
                                        },
                                        .creation_time_tenth = if (entry_copy) |copy| copy.creation_time_tenth else unreachable,
                                        .creation_time = if (entry_copy) |copy| copy.creation_time else unreachable,
                                        .creation_date = if (entry_copy) |copy| copy.creation_date else unreachable,
                                        .last_access_date = if (entry_copy) |copy| copy.last_access_date else unreachable,
                                        .first_cluster_high = @truncate(u16, upper_cluster >> 16),
                                        .last_write_time = if (entry_copy) |copy| copy.last_write_time else unreachable,
                                        .last_write_date = if (entry_copy) |copy| copy.last_write_date else unreachable,
                                        .first_cluster_low = @truncate(u16, upper_cluster),
                                        .file_size = @intCast(u32, file.content.len),
                                    }, .{
                                        .cluster = upper_cluster,
                                        .root_cluster = root_cluster,
                                        .cluster_sector_count = @intCast(u16, cache.cluster_to_sectors(1)),
                                        .root_cluster_sector = root_cluster_sector,
                                    });

                                    if (is_last) {
                                        const content_cluster = try cache.allocate_file_content(file.content);
                                        entry.directory_entry.set_first_cluster(content_cluster);
                                        return entry;
                                    } else {
                                        unreachable;
                                    }
                                },
                                .directory => unreachable,
                            },
                            .fail => return GetError.not_found,
                        }
                    }

                    if (is_unused) unreachable;

                    if (is_long_name) {
                        const long_name_entry = @ptrCast(*FAT32.LongNameEntry, directory_entry);
                        const original_starting_index = entry_index;
                        if (long_name_entry.is_last()) {
                            entry_index += 1;
                            assert(entry_index < directory_entries_in_cluster.len);
                            const normal_entry = &directory_entries_in_cluster[entry_index];
                            if (lib.equal(u8, &normal_entry.name, &normalized_name)) {
                                if (is_last) {
                                    return .{ .cluster = upper_cluster, .entry_starting_index = @intCast(u32, original_starting_index), .directory_entry = normal_entry };
                                } else {
                                    unreachable;
                                }
                            }
                            unreachable;
                        } else {
                            unreachable;
                        }
                        unreachable;
                    } else {
                        if (lib.equal(u8, &directory_entry.name, &normalized_name)) {
                            if (is_last) {
                                return .{ .cluster = upper_cluster, .entry_starting_index = @intCast(u32, entry_index), .directory_entry = directory_entry };
                            } else {
                                upper_cluster = directory_entry.get_first_cluster();
                                continue :entry_loop;
                            }
                        }
                    }
                }
            }

            switch (not_found_policy) {
                .allocate => {
                    unreachable;
                },
                .fail => return GetError.not_found,
            }
        }

        unreachable;
    }

    pub fn get_fat_lba(cache: Cache) u64 {
        const fat_lba = cache.partition_range.first_lba + cache.mbr.bpb.dos3_31.dos2_0.reserved_sector_count;
        return fat_lba;
    }

    pub fn get_data_lba(cache: Cache) u64 {
        const data_lba = cache.get_fat_lba() + (cache.mbr.bpb.fat_sector_count_32 * cache.mbr.bpb.dos3_31.dos2_0.fat_count);
        return data_lba;
    }

    pub fn get_root_cluster(cache: Cache) u32 {
        const root_cluster = cache.mbr.bpb.root_directory_cluster_offset;
        return root_cluster;
    }

    pub fn allocate_file_content(cache: Cache, file_content: []const u8) !u32 {
        const sector_count = @intCast(u32, @divExact(lib.alignForward(file_content.len, cache.disk.sector_size), cache.disk.sector_size));
        const cluster_count = lib.alignForwardGeneric(u32, sector_count, cache.cluster_to_sectors(1));
        assert(cluster_count == 1);
        const first_cluster = try cache.allocate_fat_entry();
        try cache.write_string_to_cluster_offset(file_content, first_cluster);
        return first_cluster;
    }

    pub fn write_string_to_cluster_offset(cache: Cache, string: []const u8, cluster_offset: u32) !void {
        const data_lba = cache.get_data_lba();
        const root_cluster = cache.get_root_cluster();
        const sector_offset = data_lba + cache.cluster_to_sectors(cluster_offset - root_cluster);
        try cache.disk.write_slice(u8, string, sector_offset, true);
    }

    pub inline fn cluster_to_sectors(cache: Cache, cluster_count: u32) u32 {
        return cache.mbr.bpb.dos3_31.dos2_0.cluster_sector_count * cluster_count;
    }

    pub fn allocate_fat_entry(cache: Cache) !u32 {
        const cluster = cache.fs_info.allocate_clusters(1);
        try write_fat_entry_slow(cache.disk, cache.mbr, cache.partition_range.first_lba, FAT32.Entry.allocated_and_eof, cluster);
        return cluster;
    }
};

const PackStringOptions = packed struct(u64) {
    fill_with: u8,
    len: u8,
    upper: bool,
    reserved: u47 = 0,
};

pub inline fn pack_string(name: []const u8, comptime options: PackStringOptions) [options.len]u8 {
    var result = [1]u8{options.fill_with} ** options.len;
    if (name.len > 0) {
        if (options.upper) {
            _ = lib.upperString(&result, name);
        } else {
            lib.copy(u8, &result, name);
        }
    }

    return result;
}

const ChopStringOptions = packed struct(u8) {
    reserved: u8 = 0,
};

pub inline fn long_name_chop(name: []const u8, comptime start: usize, comptime end: usize, comptime chop_options: ChopStringOptions) [end - start + 1]u16 {
    _ = chop_options;
    const len = end - start + 1;
    const string = if (start > name.len) "" else if (end > name.len) name[start..] else name[start..end];
    var result = [1]u16{lib.maxInt(u16)} ** len;
    if (string.len > 0) {
        for (string) |character, index| {
            const ptr = &result[index];
            ptr.* = @as(u16, character);
        }

        log.debug("Name len: {}. String len: {}. Result len: {}. Start: {}. End: {}", .{ name.len, string.len, result.len, start, end });
        if (string.len < len) {
            log.debug("Zeroing at {}", .{string.len});
            result[string.len] = 0;
        }
    }

    return result;
}

fn EntryResult(comptime EntryType: type) type {
    return extern struct {
        cluster: u32,
        entry_starting_index: u32,
        directory_entry: *EntryType,
    };
}

// Sadly we have to wrap shell commands into scripts because of shell redirection usages
const LoopbackDevice = struct {
    name: []const u8,
    mount_dir: ?[]const u8 = null,

    fn start(loopback_device: LoopbackDevice, allocator: lib.Allocator, image_path: []const u8) !void {
        try lib.spawnProcess(&.{ "./tools/loopback_start.sh", image_path, loopback_device.name }, allocator);
    }

    fn end(loopback_device: LoopbackDevice, allocator: lib.Allocator) !void {
        assert(loopback_device.mount_dir == null);
        try lib.spawnProcess(&.{ "./tools/loopback_end.sh", loopback_device.name }, allocator);
        try lib.cwd().deleteFile(loopback_device.name);
    }

    fn mount(loopback_device: *LoopbackDevice, allocator: lib.Allocator, mount_dir: []const u8) !MountedPartition {
        try lib.cwd().makePath(mount_dir);
        try lib.spawnProcess(&.{ "./tools/loopback_mount.sh", loopback_device.name, mount_dir }, allocator);
        loopback_device.mount_dir = mount_dir;

        return MountedPartition{
            .loopback_device = loopback_device.*,
        };
    }
};

const MountedPartition = struct {
    loopback_device: LoopbackDevice,

    fn from_loopback(ld: LoopbackDevice, allocator: lib.Allocator, image_path: []const u8, mount_dir: []const u8) !MountedPartition {
        var loopback_device = ld;
        try loopback_device.start(allocator, image_path);
        return try loopback_device.mount(allocator, mount_dir);
    }

    fn mkdir(partition: MountedPartition, allocator: lib.Allocator, dir: []const u8) !void {
        try lib.spawnProcess(&.{ "sudo", "mkdir", "-p", try partition.join_with_root(allocator, dir) }, allocator);
    }

    fn join_with_root(partition: MountedPartition, allocator: lib.Allocator, path: []const u8) ![]const u8 {
        const mount_dir = partition.loopback_device.mount_dir orelse unreachable;
        const join_slice: []const []const u8 = if (path[0] != '/') &.{ mount_dir, "/", path } else &.{ mount_dir, path };
        const joint_path = try lib.concat(allocator, u8, join_slice);
        return joint_path;
    }

    fn copy_files(partition: MountedPartition, allocator: lib.Allocator, dst: []const u8, files: []const []const u8) !void {
        const process_args = try lib.concat(allocator, []const u8, &.{ &.{ "sudo", "cp", "-v" }, files, &.{try partition.join_with_root(allocator, dst)} });
        try lib.spawnProcess(process_args, allocator);
    }

    fn end(partition: *MountedPartition, allocator: lib.Allocator) !void {
        const mount_dir = partition.loopback_device.mount_dir orelse unreachable;
        try lib.spawnProcess(&.{ "sudo", "umount", mount_dir }, allocator);
        partition.loopback_device.mount_dir = null;
        try partition.loopback_device.end(allocator);
        try lib.cwd().deleteTree(mount_dir);
    }
};

test "Basic FAT32 image" {
    lib.testing.log_level = .debug;

    switch (lib.os) {
        .linux => {
            const original_image_path = "barebones.hdd";
            const byte_count = 64 * mb;
            const sector_size = 0x200;

            // Using an arena allocator because it doesn't care about memory leaks
            var arena_allocator = lib.ArenaAllocator.init(lib.page_allocator);
            defer arena_allocator.deinit();

            var allocator = arena_allocator.allocator();

            var disk_image = try Disk.Image.from_zero(byte_count, sector_size);
            defer lib.cwd().deleteFile(original_image_path) catch unreachable;

            const megabytes = @divExact(byte_count, mb);

            // 1. Test GPT creation
            log.info("[TEST #1] Creating GPT", .{});
            var original_disk_image = blk: {
                try lib.spawnProcess(&.{ "dd", "if=/dev/zero", "bs=1M", "count=0", try lib.allocPrint(allocator, "seek={d}", .{megabytes}), try lib.allocPrint(allocator, "of={s}", .{original_image_path}) }, allocator);
                try lib.spawnProcess(&.{ "parted", "-s", original_image_path, "mklabel", "gpt" }, allocator);

                break :blk try Disk.Image.from_file(original_image_path, sector_size, allocator);
            };

            const gpt_cache = try GPT.create(&disk_image.disk, blk: {
                const original_gpt_cache = try GPT.Header.Cache.load(&original_disk_image.disk);
                break :blk original_gpt_cache.header;
            });
            try lib.testing.expectEqualSlices(u8, original_disk_image.get_buffer(), disk_image.get_buffer());

            // 2. Test GPT partition creation
            log.info("[TEST #2] Creating a GPT partition", .{});
            const partition_start_lba = 0x800;
            const partition_name = "ESP";
            const partition_filesystem = lib.Filesystem.Type.fat32;
            original_disk_image = blk: {
                try lib.spawnProcess(&.{ "parted", "-s", original_image_path, "mkpart", partition_name, @tagName(partition_filesystem), try lib.allocPrint(allocator, "{d}s", .{partition_start_lba}), "100%" }, allocator);
                try lib.spawnProcess(&.{ "parted", "-s", original_image_path, "set", "1", "esp", "on" }, allocator);
                break :blk try Disk.Image.from_file(original_image_path, sector_size, allocator);
            };

            const gpt_partition_cache = try gpt_cache.add_partition(partition_filesystem, lib.unicode.utf8ToUtf16LeStringLiteral(partition_name), partition_start_lba, gpt_cache.header.last_usable_lba, blk: {
                const original_gpt_partition_cache = try GPT.Partition.Cache.from_partition_index(&original_disk_image.disk, 0);
                break :blk original_gpt_partition_cache.partition;
            });
            try lib.testing.expectEqualSlices(u8, original_disk_image.get_buffer(), disk_image.get_buffer());

            log.info("[TEST #3] Formatting a partition with FAT32", .{});
            var loopback_device = LoopbackDevice{ .name = "loopback_device" };

            original_disk_image = blk: {
                try loopback_device.start(allocator, original_image_path);
                try lib.spawnProcess(&.{ "./tools/format_loopback_fat32.sh", loopback_device.name }, allocator);
                loopback_device.end(allocator) catch unreachable;
                break :blk try Disk.Image.from_file(original_image_path, sector_size, allocator);
            };

            const fat_partition_cache = try gpt_partition_cache.format(partition_filesystem, blk: {
                break :blk try FAT32.Cache.from_gpt_partition_cache(try GPT.Partition.Cache.from_partition_index(&original_disk_image.disk, 0));
            });
            try lib.testing.expectEqualSlices(u8, original_disk_image.get_buffer(), disk_image.get_buffer());

            log.info("[TEST #4] Making a directory", .{});
            const mount_dir = "image_mount";
            const efi_boot_dir = "/EFI/BOOT";
            original_disk_image = blk: {
                var partition = try MountedPartition.from_loopback(loopback_device, allocator, original_image_path, mount_dir);
                try partition.mkdir(allocator, efi_boot_dir);
                try partition.end(allocator);
                break :blk try Disk.Image.from_file(original_image_path, sector_size, allocator);
            };
            try fat_partition_cache.mkdir(efi_boot_dir, blk: {
                break :blk try FAT32.Cache.from_gpt_partition_cache(try GPT.Partition.Cache.from_partition_index(&original_disk_image.disk, 0));
            });
            try lib.testing.expectEqualSlices(u8, original_disk_image.get_buffer(), disk_image.get_buffer());

            const file_path = "/foo";
            const file_content = "a\n";
            log.info("[TEST #5] Copying a file", .{});
            original_disk_image = blk: {
                var partition = try MountedPartition.from_loopback(loopback_device, allocator, original_image_path, mount_dir);
                try partition.copy_files(allocator, "/", &.{file_path[1..]});
                try partition.end(allocator);
                break :blk try Disk.Image.from_file(original_image_path, sector_size, allocator);
            };
            try fat_partition_cache.add_file(file_path, file_content, blk: {
                const fat_cache = try FAT32.Cache.from_gpt_partition_cache(try GPT.Partition.Cache.from_partition_index(&original_disk_image.disk, 0));
                const entry_result = try fat_cache.get_directory_entry(file_path, .fail, null);
                break :blk entry_result.directory_entry;
            });

            const original_long_name_entry = @ptrCast(*LongNameEntry, original_disk_image.get_buffer()[0x1fc020 .. 0x1fc020 + 0x20]);
            const long_name_entry = @ptrCast(*LongNameEntry, disk_image.get_buffer()[0x1fc020 .. 0x1fc020 + 0x20]);
            log.debug("Original: {}\nMine: {}\n", .{ original_long_name_entry, long_name_entry });

            try lib.diff(original_disk_image.get_buffer(), disk_image.get_buffer());

            try lib.testing.expectEqualSlices(u8, original_disk_image.get_buffer(), disk_image.get_buffer());
        },
        else => log.debug("Skipping for missing `parted` dependency...", .{}),
    }
}
