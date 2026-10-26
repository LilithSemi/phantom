//! Persistent byte settings serialized as a deterministic ZON document.

const std = @import("std");
const platform = @import("../platform.zig");

pub const Store = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []u8,
    values: std.StringHashMapUnmanaged([]u8) = .empty,

    const Entry = struct { key: []const u8, value: []const u8 };
    const Document = struct { version: u32 = 1, entries: []const Entry = &.{} };
    const max_file_size = 4 * 1024 * 1024;

    pub fn initXdg(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, app_id: []const u8) !Store {
        const base = environ.get("XDG_CONFIG_HOME") orelse blk: {
            const home = environ.get("HOME") orelse return error.NoConfigHome;
            break :blk try std.fs.path.join(gpa, &.{ home, ".config" });
        };
        const owns_base = environ.get("XDG_CONFIG_HOME") == null;
        defer if (owns_base) gpa.free(base);
        const path = try std.fs.path.join(gpa, &.{ base, app_id, "settings.zon" });
        errdefer gpa.free(path);
        return initPathOwned(gpa, io, path);
    }

    pub fn initPath(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Store {
        return initPathOwned(gpa, io, try gpa.dupe(u8, path));
    }

    fn initPathOwned(gpa: std.mem.Allocator, io: std.Io, path: []u8) !Store {
        var self = Store{ .gpa = gpa, .io = io, .path = path };
        errdefer self.deinit();
        try self.load();
        return self;
    }

    pub fn deinit(self: *Store) void {
        var it = self.values.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.*);
        }
        self.values.deinit(self.gpa);
        self.gpa.free(self.path);
        self.* = undefined;
    }

    pub fn read(self: *const Store, key: []const u8, buf: []u8) platform.SettingsError!?[]const u8 {
        if (!platform.validSettingKey(key)) return error.InvalidKey;
        const value = self.values.get(key) orelse return null;
        if (value.len > buf.len) return error.BufferTooSmall;
        @memcpy(buf[0..value.len], value);
        return buf[0..value.len];
    }

    pub fn write(self: *Store, key: []const u8, value: []const u8) platform.SettingsError!void {
        if (!platform.validSettingKey(key)) return error.InvalidKey;
        const owned_value = self.gpa.dupe(u8, value) catch return error.StorageFailure;
        if (self.values.getPtr(key)) |old| {
            const previous = old.*;
            old.* = owned_value;
            self.persist() catch {
                old.* = previous;
                self.gpa.free(owned_value);
                return error.StorageFailure;
            };
            self.gpa.free(previous);
            return;
        }
        const owned_key = self.gpa.dupe(u8, key) catch {
            self.gpa.free(owned_value);
            return error.StorageFailure;
        };
        self.values.put(self.gpa, owned_key, owned_value) catch {
            self.gpa.free(owned_key);
            self.gpa.free(owned_value);
            return error.StorageFailure;
        };
        self.persist() catch {
            const removed = self.values.fetchRemove(key).?;
            self.gpa.free(removed.key);
            self.gpa.free(removed.value);
            return error.StorageFailure;
        };
    }

    pub fn remove(self: *Store, key: []const u8) platform.SettingsError!void {
        if (!platform.validSettingKey(key)) return error.InvalidKey;
        const removed = self.values.fetchRemove(key) orelse return;
        self.persist() catch {
            self.values.put(self.gpa, removed.key, removed.value) catch {};
            return error.StorageFailure;
        };
        self.gpa.free(removed.key);
        self.gpa.free(removed.value);
    }

    fn load(self: *Store) !void {
        const raw = std.Io.Dir.cwd().readFileAllocOptions(self.io, self.path, self.gpa, .limited(max_file_size), .of(u8), 0) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.gpa.free(raw);
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        var diagnostics: std.zon.parse.Diagnostics = undefined;
        const doc = try std.zon.parse.fromSlice(Document, .{
            .gpa = self.gpa,
            .arena = arena_state.allocator(),
            .source = raw,
            .diagnostics = &diagnostics,
        });
        if (doc.version != 1) return error.UnsupportedSettingsVersion;
        for (doc.entries) |entry| {
            if (!platform.validSettingKey(entry.key)) return error.InvalidSettingKey;
            const key = try self.gpa.dupe(u8, entry.key);
            errdefer self.gpa.free(key);
            const value = try self.gpa.dupe(u8, entry.value);
            errdefer self.gpa.free(value);
            if (try self.values.fetchPut(self.gpa, key, value)) |old| {
                self.gpa.free(key);
                self.gpa.free(old.key);
                self.gpa.free(old.value);
            }
        }
    }

    fn persist(self: *Store) !void {
        const entries = try self.gpa.alloc(Entry, self.values.count());
        defer self.gpa.free(entries);
        var it = self.values.iterator();
        var index: usize = 0;
        while (it.next()) |entry| : (index += 1) entries[index] = .{ .key = entry.key_ptr.*, .value = entry.value_ptr.* };
        std.mem.sort(Entry, entries, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                return std.mem.lessThan(u8, a.key, b.key);
            }
        }.less);
        var output: std.Io.Writer.Allocating = .init(self.gpa);
        defer output.deinit();
        try std.zon.stringify.serialize(Document{ .entries = entries }, .{}, &output.writer);
        try output.writer.writeByte('\n');
        const parent = std.fs.path.dirname(self.path) orelse return error.BadPathName;
        if (std.fs.path.isAbsolute(parent)) try makePathAbsolute(self.io, parent) else try std.Io.Dir.cwd().createDirPath(self.io, parent);
        const temporary = try std.fmt.allocPrint(self.gpa, "{s}.tmp", .{self.path});
        defer self.gpa.free(temporary);
        errdefer std.Io.Dir.cwd().deleteFile(self.io, temporary) catch {};
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = temporary, .data = output.written() });
        if (std.fs.path.isAbsolute(self.path))
            try std.Io.Dir.renameAbsolute(temporary, self.path, self.io)
        else
            try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), self.path, self.io);
    }

    fn makePathAbsolute(io: std.Io, path: []const u8) !void {
        if (path.len == 0 or std.mem.eql(u8, path, "/")) return;
        if (std.Io.Dir.createDirAbsolute(io, path, .default_dir)) |_| return else |err| switch (err) {
            error.PathAlreadyExists => return,
            error.FileNotFound => {
                const parent = std.fs.path.dirname(path) orelse return err;
                try makePathAbsolute(io, parent);
                std.Io.Dir.createDirAbsolute(io, path, .default_dir) catch |again| switch (again) {
                    error.PathAlreadyExists => {},
                    else => return again,
                };
            },
            else => return err,
        }
    }
};
