//! Sorts an error from a model-list fetch into a catalog failure. A cut-off
//! answer is malformed and retryable, a broken answer is malformed and not
//! retryable, a cancel is a cancellation, and anything else is a retryable
//! transport failure.
const std = @import("std");
const model_catalog = @import("../core/gateway/model_catalog.zig");

/// An answer cut off before its end. A retry can get the whole answer.
const cut_off_answer_errors = [_]anyerror{
    error.HttpChunkTruncated,
    error.HttpRequestTruncated,
    error.EndOfStream,
    error.HttpBodyCutOff,
};

/// An answer that arrived but cannot be read, other than the std decoder
/// errors. A retry gets the same answer.
const broken_answer_errors = [_]anyerror{
    error.HttpHeadersInvalid,
    error.HttpHeadersOversize,
    error.HttpConnectionHeaderUnsupported,
    error.HttpHeaderContinuationsUnsupported,
    error.HttpTransferEncodingUnsupported,
    error.InvalidContentLength,
    error.HttpContentEncodingUnsupported,
    error.UnsupportedCompressionMethod,
    error.HttpChunkInvalid,
};

/// Decoder errors that do not mean a broken answer: a failed input read, an
/// answer cut off before its end, and fx's own zstd buffer sizes.
const decoder_errors_not_broken = [_][]const u8{
    "ReadFailed",
    "EndOfStream",
    "OutputBufferUndersize",
    "InputBufferUndersize",
};

/// The error sets of the std gzip, deflate, and zstd decoders.
const decoder_error_sets = .{
    std.compress.flate.Decompress.Error,
    std.compress.zstd.Decompress.Error,
};

pub fn classify(err: anyerror) model_catalog.Failure {
    if (err == error.Cancelled) return .{ .category = .cancellation };
    if (isCutOff(err)) return .{ .category = .malformed_response, .retryable = true };
    if (isBroken(err)) return .{ .category = .malformed_response };
    return .{ .category = .transport, .retryable = true };
}

fn isCutOff(err: anyerror) bool {
    for (cut_off_answer_errors) |cut_off| {
        if (err == cut_off) return true;
    }
    return false;
}

fn isBroken(err: anyerror) bool {
    for (broken_answer_errors) |broken| {
        if (err == broken) return true;
    }
    inline for (decoder_error_sets) |Set| {
        inline for (@typeInfo(Set).error_set.error_names.?) |name| {
            if (comptime !isExcludedDecoderError(name)) {
                if (err == @field(Set, name)) return true;
            }
        }
    }
    return false;
}

fn isExcludedDecoderError(comptime name: []const u8) bool {
    inline for (decoder_errors_not_broken) |excluded| {
        if (comptime std.mem.eql(u8, excluded, name)) return true;
    }
    return false;
}

fn expectClassified(err: anyerror, category: model_catalog.FailureCategory, retryable: bool) !void {
    const failure = classify(err);
    try std.testing.expectEqual(category, failure.category);
    try std.testing.expectEqual(retryable, failure.retryable);
}

test "catalog fetch failures split unreadable answers from connection failures" {
    inline for (decoder_error_sets) |Set| {
        inline for (@typeInfo(Set).error_set.error_names.?) |name| {
            const err: anyerror = @field(Set, name);
            if (comptime !std.mem.eql(u8, name, "ReadFailed")) {
                if (err == error.OutputBufferUndersize or err == error.InputBufferUndersize) {
                    try expectClassified(err, .transport, true);
                } else {
                    try expectClassified(err, .malformed_response, isCutOff(err));
                }
            }
        }
    }
    try expectClassified(error.HttpChunkTruncated, .malformed_response, true);
    try expectClassified(error.EndOfStream, .malformed_response, true);
    try expectClassified(error.HttpBodyCutOff, .malformed_response, true);
    try expectClassified(error.HttpRequestTruncated, .malformed_response, true);
    const broken = [_]anyerror{
        error.BadGzipHeader,
        error.WrongGzipChecksum,
        error.HttpChunkInvalid,
        error.HttpHeadersInvalid,
        error.HttpConnectionHeaderUnsupported,
        error.HttpHeaderContinuationsUnsupported,
        error.HttpTransferEncodingUnsupported,
        error.InvalidContentLength,
    };
    for (broken) |err| try expectClassified(err, .malformed_response, false);
    for (broken_answer_errors) |err| try expectClassified(err, .malformed_response, false);
    try expectClassified(error.OutputBufferUndersize, .transport, true);
    try expectClassified(error.InputBufferUndersize, .transport, true);
    try expectClassified(error.ConnectionRefused, .transport, true);
    try expectClassified(error.ReadFailed, .transport, true);
    try expectClassified(error.Cancelled, .cancellation, false);
}
