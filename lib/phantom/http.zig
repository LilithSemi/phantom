//! One HTTP call, `fetch`, behind a vtable, so an application asks the same way
//! on every backend. Native backends run it on `std.http.Client`. The web
//! backend sends it through the page's own `fetch`, because `std.http.Client`
//! does not compile for wasm32-freestanding on Zig 0.17.0. Zig pull request
//! 37156 fixes that. When a Zig release has the fix, the web side can run on
//! `std.http.Client` too.
const std = @import("std");
const builtin = @import("builtin");

/// False where `std.http.Client` does not compile. See the file comment.
pub const std_available = !(builtin.target.cpu.arch.isWasm() and builtin.target.os.tag == .freestanding);

pub const FetchOptions = struct {
    url: []const u8,
    /// Null sends GET, or POST when there is a payload.
    method: ?std.http.Method = null,
    payload: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    extra_headers: []const std.http.Header = &.{},
    /// Receives the response body. Null discards it.
    response_writer: ?*std.Io.Writer = null,
};

pub const FetchResult = struct {
    status: std.http.Status,
};

pub const FetchError = error{
    /// The url does not parse, or it has no host.
    InvalidUrl,
    /// No response arrived: no network, a refused connection, or a failed
    /// TLS handshake.
    NetworkDown,
    /// Something arrived that is not an HTTP response.
    InvalidResponse,
    /// `response_writer` failed.
    WriteFailed,
    OutOfMemory,
};

pub const Client = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        fetch: *const fn (ptr: *anyopaque, options: FetchOptions) FetchError!FetchResult,
    };

    pub fn fetch(c: Client, options: FetchOptions) FetchError!FetchResult {
        return c.vtable.fetch(c.ptr, options);
    }
};

/// A client for a backend with no network. Every fetch is `error.NetworkDown`.
pub const unavailable: Client = .{ .ptr = undefined, .vtable = &.{ .fetch = fetchUnavailable } };

fn fetchUnavailable(_: *anyopaque, _: FetchOptions) FetchError!FetchResult {
    return error.NetworkDown;
}

/// Runs `Client` on a `std.http.Client` that the caller owns. Use it only where
/// `std_available` is true.
pub const Std = struct {
    inner: *std.http.Client,

    pub fn client(self: *Std) Client {
        return .{ .ptr = self, .vtable = &.{ .fetch = fetchStd } };
    }

    fn fetchStd(ptr: *anyopaque, options: FetchOptions) FetchError!FetchResult {
        const self: *Std = @ptrCast(@alignCast(ptr));
        const res = self.inner.fetch(.{
            .location = .{ .url = options.url },
            .method = options.method,
            .payload = options.payload,
            .headers = .{ .content_type = if (options.content_type) |ct| .{ .override = ct } else .default },
            .extra_headers = options.extra_headers,
            .response_writer = options.response_writer,
        }) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.WriteFailed => error.WriteFailed,
            error.UnexpectedCharacter,
            error.InvalidFormat,
            error.InvalidPort,
            error.UnsupportedUriScheme,
            error.UriMissingHost,
            error.InvalidHostName,
            => error.InvalidUrl,
            error.HttpHeadersInvalid,
            error.HttpHeadersOversize,
            error.HttpChunkInvalid,
            error.HttpChunkTruncated,
            error.HttpRequestTruncated,
            error.HttpContentEncodingUnsupported,
            error.UnsupportedCompressionMethod,
            error.HttpRedirectLocationInvalid,
            error.HttpRedirectLocationMissing,
            error.HttpRedirectLocationOversize,
            error.TooManyHttpRedirects,
            => error.InvalidResponse,
            else => error.NetworkDown,
        };
        return .{ .status = res.status };
    }
};

test "the unavailable client reports the network down" {
    try std.testing.expectError(error.NetworkDown, unavailable.fetch(.{ .url = "http://example.com/" }));
}
