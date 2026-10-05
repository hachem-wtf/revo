//! salsa-ish query inputs;;; content hashes + revision guard
//!   so inputs are tracked by hash, not version+opts
//!   todo providers still read the legacy caches; queries take over one at a time

const std = @import("std");

const txt = @import("text.zig");

pub const FileId = txt.FileId;
pub const Revision = u64;

/// always xxhash64 at seed 0
/// i only picked xxhash because vite and webpack use it for some reason
pub fn hashText(text: []const u8) u64 {
    return std.hash.XxHash64.hash(0, text);
}

pub const QueryInput = struct {
    hash: u64,
    revision: Revision,
};

/// input table
/// dirty when current hash differs from recorded
pub const QueryDb = struct {
    alloc: std.mem.Allocator,
    revision: Revision = 1,
    inputs: std.AutoHashMap(FileId, QueryInput),

    pub fn init(alloc: std.mem.Allocator) QueryDb {
        return .{ .alloc = alloc, .inputs = std.AutoHashMap(FileId, QueryInput).init(alloc) };
    }

    pub fn deinit(self: *QueryDb) void {
        self.inputs.deinit();
    }

    pub fn bump(self: *QueryDb) Revision {
        self.revision += 1;
        return self.revision;
    }

    /// record current text hash for a file at the current revision
    pub fn track(self: *QueryDb, id: FileId, text: []const u8) !void {
        try self.inputs.put(id, .{ .hash = hashText(text), .revision = self.revision });
    }

    /// forget a closed file
    pub fn evict(self: *QueryDb, id: FileId) void {
        _ = self.inputs.remove(id);
    }

    /// true when the file is untracked or its text hash moved
    pub fn isDirty(self: *const QueryDb, id: FileId, text: []const u8) bool {
        const recorded = self.inputs.get(id) orelse return true;
        return recorded.hash != hashText(text);
    }
};

test "same text hashes stable, edits go dirty" {
    var db = QueryDb.init(std.testing.allocator);
    defer db.deinit();

    const id: FileId = 7;
    try std.testing.expect(db.isDirty(id, "let x = 1"));
    try db.track(id, "let x = 1");
    try std.testing.expect(!db.isDirty(id, "let x = 1"));
    try std.testing.expect(db.isDirty(id, "let x = 2"));

    _ = db.bump();
    // revision bump alone does not dirty clean content
    try std.testing.expect(!db.isDirty(id, "let x = 1"));

    db.evict(id);
    try std.testing.expect(db.isDirty(id, "let x = 1"));
}
