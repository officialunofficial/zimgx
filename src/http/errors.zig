// HTTP error types
//
// Structured error representations for HTTP error responses, with
// predefined constructors for common status codes and JSON
// serialization for the response body.

const std = @import("std");

/// A structured HTTP error that can be serialized to a JSON response body.
pub const HttpError = struct {
    status: u16,
    message: []const u8,
    detail: ?[]const u8 = null,

    /// 400 Bad Request
    pub fn badRequest(detail: ?[]const u8) HttpError {
        return .{ .status = 400, .message = "Bad Request", .detail = detail };
    }

    /// 404 Not Found
    pub fn notFound(detail: ?[]const u8) HttpError {
        return .{ .status = 404, .message = "Not Found", .detail = detail };
    }

    /// 413 Payload Too Large
    pub fn payloadTooLarge(detail: ?[]const u8) HttpError {
        return .{ .status = 413, .message = "Payload Too Large", .detail = detail };
    }

    /// 422 Unprocessable Entity
    pub fn unprocessableEntity(detail: ?[]const u8) HttpError {
        return .{ .status = 422, .message = "Unprocessable Entity", .detail = detail };
    }

    /// 500 Internal Server Error
    pub fn internalError(detail: ?[]const u8) HttpError {
        return .{ .status = 500, .message = "Internal Server Error", .detail = detail };
    }

    /// 502 Bad Gateway
    pub fn badGateway(detail: ?[]const u8) HttpError {
        return .{ .status = 502, .message = "Bad Gateway", .detail = detail };
    }

    /// 504 Gateway Timeout
    pub fn gatewayTimeout(detail: ?[]const u8) HttpError {
        return .{ .status = 504, .message = "Gateway Timeout", .detail = detail };
    }

    /// Serialize this error to a JSON response body written into `buf`.
    ///
    /// Returns a slice of `buf` containing the JSON string, e.g.:
    /// ```json
    /// {"error":{"status":400,"message":"Bad Request","detail":"invalid width"}}
    /// ```
    /// When `detail` is null the field is omitted entirely.
    pub fn toJsonResponse(self: HttpError, buf: []u8) []const u8 {
        if (self.detail) |detail| {
            return std.fmt.bufPrint(buf, "{{\"error\":{{\"status\":{d},\"message\":\"{s}\",\"detail\":\"{s}\"}}}}", .{
                self.status,
                self.message,
                detail,
            }) catch return "{\"error\":{\"status\":500,\"message\":\"Internal Server Error\"}}";
        } else {
            return std.fmt.bufPrint(buf, "{{\"error\":{{\"status\":{d},\"message\":\"{s}\"}}}}", .{
                self.status,
                self.message,
            }) catch return "{\"error\":{\"status\":500,\"message\":\"Internal Server Error\"}}";
        }
    }
};

/// Return the standard HTTP reason phrase for a given status code.
pub fn statusText(code: u16) []const u8 {
    return switch (code) {
        200 => "OK",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        408 => "Request Timeout",
        413 => "Payload Too Large",
        414 => "URI Too Long",
        415 => "Unsupported Media Type",
        422 => "Unprocessable Entity",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        else => "Unknown",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "badRequest has status 400" {
    const err = HttpError.badRequest("invalid width");
    try std.testing.expectEqual(@as(u16, 400), err.status);
    try std.testing.expectEqualStrings("Bad Request", err.message);
    try std.testing.expectEqualStrings("invalid width", err.detail.?);
}

test "notFound has status 404" {
    const err = HttpError.notFound("image not found");
    try std.testing.expectEqual(@as(u16, 404), err.status);
    try std.testing.expectEqualStrings("Not Found", err.message);
}

test "payloadTooLarge has status 413" {
    const err = HttpError.payloadTooLarge("exceeds 10MB limit");
    try std.testing.expectEqual(@as(u16, 413), err.status);
    try std.testing.expectEqualStrings("Payload Too Large", err.message);
}

test "unprocessableEntity has status 422" {
    const err = HttpError.unprocessableEntity("invalid parameters");
    try std.testing.expectEqual(@as(u16, 422), err.status);
    try std.testing.expectEqualStrings("Unprocessable Entity", err.message);
}

test "internalError has status 500" {
    const err = HttpError.internalError("unexpected failure");
    try std.testing.expectEqual(@as(u16, 500), err.status);
    try std.testing.expectEqualStrings("Internal Server Error", err.message);
}

test "badGateway has status 502" {
    const err = HttpError.badGateway("origin unreachable");
    try std.testing.expectEqual(@as(u16, 502), err.status);
    try std.testing.expectEqualStrings("Bad Gateway", err.message);
}

test "gatewayTimeout has status 504" {
    const err = HttpError.gatewayTimeout("origin timed out");
    try std.testing.expectEqual(@as(u16, 504), err.status);
    try std.testing.expectEqualStrings("Gateway Timeout", err.message);
}

test "toJsonResponse with detail" {
    const err = HttpError.badRequest("invalid width");
    var buf: [256]u8 = undefined;
    const json = err.toJsonResponse(&buf);
    try std.testing.expectEqualStrings(
        "{\"error\":{\"status\":400,\"message\":\"Bad Request\",\"detail\":\"invalid width\"}}",
        json,
    );
}

test "toJsonResponse without detail omits detail field" {
    const err = HttpError.notFound(null);
    var buf: [256]u8 = undefined;
    const json = err.toJsonResponse(&buf);
    try std.testing.expectEqualStrings(
        "{\"error\":{\"status\":404,\"message\":\"Not Found\"}}",
        json,
    );
}

test "toJsonResponse for internalError with detail" {
    const err = HttpError.internalError("disk full");
    var buf: [256]u8 = undefined;
    const json = err.toJsonResponse(&buf);
    try std.testing.expectEqualStrings(
        "{\"error\":{\"status\":500,\"message\":\"Internal Server Error\",\"detail\":\"disk full\"}}",
        json,
    );
}

test "statusText maps 400" {
    try std.testing.expectEqualStrings("Bad Request", statusText(400));
}

test "statusText maps 404" {
    try std.testing.expectEqualStrings("Not Found", statusText(404));
}

test "statusText maps 413" {
    try std.testing.expectEqualStrings("Payload Too Large", statusText(413));
}

test "statusText maps 422" {
    try std.testing.expectEqualStrings("Unprocessable Entity", statusText(422));
}

test "statusText maps 500" {
    try std.testing.expectEqualStrings("Internal Server Error", statusText(500));
}

test "statusText maps 502" {
    try std.testing.expectEqualStrings("Bad Gateway", statusText(502));
}

test "statusText maps 504" {
    try std.testing.expectEqualStrings("Gateway Timeout", statusText(504));
}

test "statusText unknown code returns Unknown" {
    try std.testing.expectEqualStrings("Unknown", statusText(999));
}

test "error constructor with null detail" {
    const err = HttpError.badRequest(null);
    try std.testing.expectEqual(@as(u16, 400), err.status);
    try std.testing.expect(err.detail == null);
}
