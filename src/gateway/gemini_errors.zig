const std = @import("std");

pub const Classification = union(enum) {
    rate_limited: struct { retry_after_s: u32 },
    daily_limit: struct { model: ?[]const u8, reset_after_s: ?u32 },
    model_unavailable: struct { model: ?[]const u8 },
    not_entitled: struct { upgrade_url: []const u8 },
    api_key_invalid,
    scope_missing,
    client_not_authorized,
    plan_setup_pending,
    service_disabled,
    project_not_allowlisted,
    unsupported_location,
    stateless_required,
    unauthenticated,
    server_error,
    other: struct { status: u16 },
};

const body_max_bytes: usize = 8 * 1024;
const parse_buffer_bytes: usize = 32 * 1024;
const json_max_nesting_levels: usize = 32;
const default_retry_after_s: u32 = 15;
const max_wait_s: u32 = std.math.maxInt(u32);

const status_bad_request: u16 = 400;
const status_unauthorized: u16 = 401;
const status_payment_required: u16 = 402;
const status_forbidden: u16 = 403;
const status_not_found: u16 = 404;
const status_too_many_requests: u16 = 429;
const status_server_error_min: u16 = 500;
const status_server_error_max: u16 = 599;

pub const google_ai_plans_url = "https://one.google.com/settings?expand=upgrade&g1_last_touchpoint=64&g1_landing_page=75&utm_source=ai_studio&utm_campaign=ais_gemini_api_upsell&utm_medium=web";
const plan_url_prefix = "https://one.google.com/";
const plan_url_trailing_punctuation = ".,)";

const google_rpc_type_prefix = "type.googleapis.com/google.rpc.";
const retry_info_type = google_rpc_type_prefix ++ "RetryInfo";
const quota_failure_type = google_rpc_type_prefix ++ "QuotaFailure";
const error_info_type = google_rpc_type_prefix ++ "ErrorInfo";
const per_day_quota_marker = "PerDay";
const scope_insufficient_reason = "ACCESS_TOKEN_SCOPE_INSUFFICIENT";
const service_disabled_reason = "SERVICE_DISABLED";
const api_key_invalid_reason = "API_KEY_INVALID";

const daily_limit_start = "reached today's ";
const daily_limit_end = " limit";
const daily_model_prefix = " for ";
const sanitized_start = "rate limit exceeded";
const sanitized_model_prefix = " for model ";
const sanitized_quota_prefix = " (limit: ";
const sanitized_quota_suffix = " per day)";
const quota_unit_tokens = "tokens";
const quota_unit_requests = "requests";
const location_phrases = [_][]const u8{ "location is not supported", "not available in your current location" };
const stateless_phrases = [_][]const u8{ "stored interactions", "previous_interaction_id" };
const per_user_quota_phrase = "not supported for per-user quota";
const scope_message_phrase = "insufficient authentication scopes";
const oauth_client_phrase = "oauth client is not authorized";
// Right after a plan purchase, Google refuses the plan's own project until its
// permission reaches the caller, and its message names this permission.
const plan_setup_phrase = "serviceusage.services.use";
const api_key_invalid_phrase = "API key not valid";

/// Only the fields the classifier reads. String fields borrow from the body
/// when they contain no escapes.
const ErrorBody = struct {
    @"error": ?ErrorObject = null,
};

const ErrorObject = struct {
    message: ?[]const u8 = null,
    details: []const ErrorDetail = &.{},
};

const ErrorDetail = struct {
    @"@type": ?[]const u8 = null,
    reason: ?[]const u8 = null,
    retryDelay: ?[]const u8 = null,
    violations: []const QuotaViolation = &.{},
};

const QuotaViolation = struct {
    quotaId: ?[]const u8 = null,
    quotaValue: ?std.json.Value = null,
    quotaDimensions: ?QuotaDimensions = null,
};

const QuotaDimensions = struct {
    model: ?[]const u8 = null,
};

/// Classifies one Gemini API error reply. Never fails and never allocates.
/// The `model` and `upgrade_url` slices borrow either `body` or static storage,
/// so they live as long as `body`.
pub fn classify(status: u16, body: []const u8, retry_after_header: ?[]const u8) Classification {
    var parse_buffer: [parse_buffer_bytes]u8 = undefined;
    const root = parseErrorBody(body, &parse_buffer) orelse ErrorBody{};
    const err = root.@"error" orelse ErrorObject{};
    const message = err.message orelse "";
    if (status == status_too_many_requests) return classifyTooManyRequests(body, err.details, message, retry_after_header);
    if (status == status_bad_request) return classifyBadRequest(err.details, message);
    if (status == status_forbidden) return classifyForbidden(body, err.details, message);
    if (status == status_payment_required) return notEntitled(body, message);
    if (status == status_unauthorized) return .unauthenticated;
    if (status == status_not_found) return .project_not_allowlisted;
    if (status >= status_server_error_min and status <= status_server_error_max) return .server_error;
    return .{ .other = .{ .status = status } };
}

fn classifyTooManyRequests(
    body: []const u8,
    details: []const ErrorDetail,
    message: []const u8,
    retry_after_header: ?[]const u8,
) Classification {
    const violations = quotaViolations(details);
    const per_day = perDayViolation(violations);
    const violation = per_day orelse firstViolation(violations);
    const daily = matchDailyMessage(message);
    const sanitized = matchSanitizedMessage(message);
    const wait_s = retryInfoSeconds(details) orelse retryAfterSeconds(retry_after_header);
    if (per_day == null and daily == null and sanitized == null) {
        return .{ .rate_limited = .{ .retry_after_s = wait_s orelse default_retry_after_s } };
    }
    const model = borrowedFromBody(body, firstModel(violation, daily, sanitized));
    const per_day_zero = if (per_day) |day| dailyQuotaIsZero(day) else false;
    const sanitized_zero = if (sanitized) |found| found.limit_is_zero else false;
    if (per_day_zero or sanitized_zero) {
        return .{ .model_unavailable = .{ .model = model } };
    }
    return .{ .daily_limit = .{ .model = model, .reset_after_s = wait_s } };
}

fn classifyBadRequest(details: []const ErrorDetail, message: []const u8) Classification {
    if (isApiKeyInvalid(details, message)) return .api_key_invalid;
    if (containsAny(message, &location_phrases)) return .unsupported_location;
    if (containsAny(message, &stateless_phrases)) return .stateless_required;
    if (containsIgnoreCase(message, per_user_quota_phrase)) return .{ .model_unavailable = .{ .model = null } };
    return .{ .other = .{ .status = status_bad_request } };
}

fn isApiKeyInvalid(details: []const ErrorDetail, message: []const u8) bool {
    return reasonIs(errorInfoReason(details), api_key_invalid_reason) or containsIgnoreCase(message, api_key_invalid_phrase);
}

fn classifyForbidden(body: []const u8, details: []const ErrorDetail, message: []const u8) Classification {
    const reason = errorInfoReason(details);
    if (reasonIs(reason, scope_insufficient_reason) or containsIgnoreCase(message, scope_message_phrase)) {
        return .scope_missing;
    }
    if (reasonIs(reason, service_disabled_reason)) return .service_disabled;
    if (containsIgnoreCase(message, oauth_client_phrase)) return .client_not_authorized;
    if (containsIgnoreCase(message, plan_setup_phrase)) return .plan_setup_pending;
    return notEntitled(body, message);
}

fn notEntitled(body: []const u8, message: []const u8) Classification {
    return .{ .not_entitled = .{ .upgrade_url = upgradeUrl(body, message) } };
}

fn upgradeUrl(body: []const u8, message: []const u8) []const u8 {
    const url = planUrlInMessage(message) orelse return google_ai_plans_url;
    return if (isWithin(body, url)) url else google_ai_plans_url;
}

/// Returns null when the body is too large, nested too deeply, or does not
/// match the schema. Those bodies are classified from the status alone.
fn parseErrorBody(body: []const u8, buffer: []u8) ?ErrorBody {
    if (body.len > body_max_bytes or !nestingWithinLimit(body)) return null;
    var fixed = std.heap.FixedBufferAllocator.init(buffer);
    const options: std.json.ParseOptions = .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .use_last,
    };
    return std.json.parseFromSliceLeaky(ErrorBody, fixed.allocator(), body, options) catch null;
}

fn nestingWithinLimit(body: []const u8) bool {
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (body) |byte| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
        } else switch (byte) {
            '"' => in_string = true,
            '[', '{' => {
                depth += 1;
                if (depth > json_max_nesting_levels) return false;
            },
            ']', '}' => depth -|= 1,
            else => {},
        }
    }
    return true;
}

/// Escaped strings are decoded into the parse buffer, which does not outlive
/// classify, so only slices of `body` may be returned.
fn isWithin(outer: []const u8, inner: []const u8) bool {
    const outer_start = @intFromPtr(outer.ptr);
    const inner_start = @intFromPtr(inner.ptr);
    return inner.len > 0 and inner_start >= outer_start and inner_start + inner.len <= outer_start + outer.len;
}

fn borrowedFromBody(body: []const u8, text: ?[]const u8) ?[]const u8 {
    const value = text orelse return null;
    return if (isWithin(body, value)) value else null;
}

fn detailOfType(details: []const ErrorDetail, type_name: []const u8) ?ErrorDetail {
    for (details) |detail| {
        const detail_type = detail.@"@type" orelse continue;
        if (std.mem.eql(u8, detail_type, type_name)) return detail;
    }
    return null;
}

fn errorInfoReason(details: []const ErrorDetail) ?[]const u8 {
    const info = detailOfType(details, error_info_type) orelse return null;
    return info.reason;
}

fn reasonIs(reason: ?[]const u8, expected: []const u8) bool {
    const actual = reason orelse return false;
    return std.mem.eql(u8, actual, expected);
}

fn retryInfoSeconds(details: []const ErrorDetail) ?u32 {
    const info = detailOfType(details, retry_info_type) orelse return null;
    const delay = info.retryDelay orelse return null;
    return protoDurationSeconds(delay);
}

fn quotaViolations(details: []const ErrorDetail) []const QuotaViolation {
    const failure = detailOfType(details, quota_failure_type) orelse return &.{};
    return failure.violations;
}

fn isPerDay(violation: QuotaViolation) bool {
    const quota_id = violation.quotaId orelse return false;
    return std.mem.find(u8, quota_id, per_day_quota_marker) != null;
}

fn perDayViolation(violations: []const QuotaViolation) ?QuotaViolation {
    for (violations) |violation| {
        if (isPerDay(violation)) return violation;
    }
    return null;
}

fn firstViolation(violations: []const QuotaViolation) ?QuotaViolation {
    if (violations.len == 0) return null;
    return violations[0];
}

/// A missing or null quotaValue counts as zero, as in the Python classify_error.
fn dailyQuotaIsZero(violation: QuotaViolation) bool {
    const value = violation.quotaValue orelse return true;
    return switch (value) {
        .null => true,
        .integer => |number| number == 0,
        .float => |number| number == 0,
        .string, .number_string => |text| allZeroDigits(text),
        else => false,
    };
}

fn quotaDimensionModel(violation: ?QuotaViolation) ?[]const u8 {
    const dimensions = (violation orelse return null).quotaDimensions orelse return null;
    return nonEmpty(dimensions.model);
}

fn firstModel(
    violation: ?QuotaViolation,
    daily: ?DailyMessage,
    sanitized: ?SanitizedMessage,
) ?[]const u8 {
    if (quotaDimensionModel(violation)) |model| return model;
    if (daily) |found| {
        if (found.model) |model| return model;
    }
    if (sanitized) |found| {
        if (found.model) |model| return model;
    }
    return null;
}

const Run = struct { text: []const u8, end: usize };

const DailyMessage = struct { model: ?[]const u8 };

/// Matches `reached today's .*? limit(?: for (\S+))?`, ignoring case.
fn matchDailyMessage(message: []const u8) ?DailyMessage {
    const start = findIgnoreCase(message, 0, daily_limit_start) orelse return null;
    const limit_at = findIgnoreCase(message, start + daily_limit_start.len, daily_limit_end) orelse return null;
    const after_limit = limit_at + daily_limit_end.len;
    if (!startsWithIgnoreCaseAt(message, after_limit, daily_model_prefix)) return .{ .model = null };
    const run = nonSpaceRunAt(message, after_limit + daily_model_prefix.len) orelse return .{ .model = null };
    return .{ .model = run.text };
}

const SanitizedMessage = struct { model: ?[]const u8, limit_is_zero: bool };

/// Matches `rate limit exceeded(?: for model (\S+))? \(limit: (\d+) (?:tokens|requests) per day\)`,
/// ignoring case.
fn matchSanitizedMessage(message: []const u8) ?SanitizedMessage {
    var start: usize = 0;
    while (findIgnoreCase(message, start, sanitized_start)) |found| {
        if (sanitizedTail(message, found + sanitized_start.len)) |matched| return matched;
        start = found + 1;
    }
    return null;
}

fn sanitizedTail(message: []const u8, at: usize) ?SanitizedMessage {
    if (startsWithIgnoreCaseAt(message, at, sanitized_model_prefix)) {
        if (nonSpaceRunAt(message, at + sanitized_model_prefix.len)) |run| {
            if (sanitizedQuotaAt(message, run.end)) |limit_is_zero| {
                return .{ .model = run.text, .limit_is_zero = limit_is_zero };
            }
        }
    }
    const limit_is_zero = sanitizedQuotaAt(message, at) orelse return null;
    return .{ .model = null, .limit_is_zero = limit_is_zero };
}

/// Matches ` (limit: (\d+) (?:tokens|requests) per day)` and reports whether the number is zero.
fn sanitizedQuotaAt(message: []const u8, at: usize) ?bool {
    if (!startsWithIgnoreCaseAt(message, at, sanitized_quota_prefix)) return null;
    const digits_start = at + sanitized_quota_prefix.len;
    var digits_end = digits_start;
    while (digits_end < message.len and std.ascii.isDigit(message[digits_end])) : (digits_end += 1) {}
    if (digits_end == digits_start or digits_end >= message.len or message[digits_end] != ' ') return null;
    const unit_at = digits_end + 1;
    const after_unit = if (startsWithIgnoreCaseAt(message, unit_at, quota_unit_tokens))
        unit_at + quota_unit_tokens.len
    else if (startsWithIgnoreCaseAt(message, unit_at, quota_unit_requests))
        unit_at + quota_unit_requests.len
    else
        return null;
    if (!startsWithIgnoreCaseAt(message, after_unit, sanitized_quota_suffix)) return null;
    return allZeroDigits(message[digits_start..digits_end]);
}

/// Matches `https://one\.google\.com/\S+` (case-sensitive), trimmed of trailing `.,)`.
fn planUrlInMessage(message: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (std.mem.findPos(u8, message, start, plan_url_prefix)) |found| {
        if (nonSpaceRunAt(message, found + plan_url_prefix.len)) |run| {
            return std.mem.trimEnd(u8, message[found..run.end], plan_url_trailing_punctuation);
        }
        start = found + 1;
    }
    return null;
}

/// Matches `(\d+(?:\.\d+)?)s` as whole seconds. A fraction rounds up so the
/// wait is never shorter than Google asked.
fn protoDurationSeconds(text: []const u8) ?u32 {
    if (text.len == 0 or text[text.len - 1] != 's') return null;
    const number = text[0 .. text.len - 1];
    const dot = std.mem.findScalar(u8, number, '.') orelse number.len;
    const whole = number[0..dot];
    if (!isDigits(whole)) return null;
    var seconds = saturatingSeconds(whole);
    if (dot == number.len) return seconds;
    const fraction = number[dot + 1 ..];
    if (!isDigits(fraction)) return null;
    if (!allZeroDigits(fraction)) seconds = std.math.add(u32, seconds, 1) catch max_wait_s;
    return seconds;
}

fn retryAfterSeconds(header: ?[]const u8) ?u32 {
    const text = header orelse return null;
    if (!isDigits(text)) return null;
    return saturatingSeconds(text);
}

fn saturatingSeconds(digits: []const u8) u32 {
    var total: u32 = 0;
    for (digits) |digit| {
        total = std.math.mul(u32, total, 10) catch return max_wait_s;
        total = std.math.add(u32, total, digit - '0') catch return max_wait_s;
    }
    return total;
}

fn isDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |char| {
        if (!std.ascii.isDigit(char)) return false;
    }
    return true;
}

fn allZeroDigits(text: []const u8) bool {
    for (text) |char| {
        if (char != '0') return false;
    }
    return true;
}

fn nonEmpty(text: ?[]const u8) ?[]const u8 {
    const value = text orelse return null;
    return if (value.len > 0) value else null;
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (containsIgnoreCase(haystack, needle)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return findIgnoreCase(haystack, 0, needle) != null;
}

fn findIgnoreCase(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    var index = start;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.startsWithIgnoreCase(haystack[index..], needle)) return index;
    }
    return null;
}

fn startsWithIgnoreCaseAt(haystack: []const u8, at: usize, needle: []const u8) bool {
    return at <= haystack.len and std.ascii.startsWithIgnoreCase(haystack[at..], needle);
}

fn nonSpaceRunAt(text: []const u8, at: usize) ?Run {
    var end = at;
    while (end < text.len and !std.ascii.isWhitespace(text[end])) : (end += 1) {}
    if (end == at) return null;
    return .{ .text = text[at..end], .end = end };
}

fn expectModel(expected: ?[]const u8, actual: ?[]const u8) !void {
    const want = expected orelse return std.testing.expect(actual == null);
    const got = actual orelse return error.TestExpectedModel;
    try std.testing.expectEqualStrings(want, got);
}

const daily_limit_body =
    \\{"error":{"code":"too_many_requests","message":"You've reached today's AI Ultra limit for gemini-4-hydrogen in third-party apps. Your daily limit refreshes in 5 hours, 18 minutes. Until then, you can switch to other models."}}
;
const daily_limit_no_model_body =
    \\{"error":{"code":"too_many_requests","message":"You've reached today's AI Ultra limit in third-party apps."}}
;
const per_minute_body =
    \\{"error":{"code":"too_many_requests","message":"Requests per minute limit exceeded. Retry shortly."}}
;
const rpm_retry_info_prefix = "{\"error\":{\"code\":\"too_many_requests\",\"message\":\"Requests per minute limit exceeded.\",\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.RetryInfo\",\"retryDelay\":\"";
const rpm_retry_info_suffix = "\"}]}}";
const zero_quota_body =
    \\{"error":{"code":"too_many_requests","message":"Quota exceeded for gemini-4-hydrogen.","details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaId":"GenerateContentRequestsPerDayPerUserPerProjectPerModel","quotaDimensions":{"model":"gemini-4-hydrogen"},"quotaValue":"0"}]}]}}
;
const sanitized_zero_body =
    \\{"error":{"code":"too_many_requests","message":"Rate limit exceeded for model gemini-4-hydrogen (limit: 0 requests per day)."}}
;
const sanitized_daily_body =
    \\{"error":{"code":"too_many_requests","message":"Rate limit exceeded for model gemini-4-hydrogen (limit: 250 requests per day)."}}
;
const location_body =
    \\{"error":{"code":"invalid_request","message":"User location is not supported for the Gemini API."}}
;
const stateless_body =
    \\{"error":{"code":"invalid_request","message":"Stored interactions aren't supported for this request. Set store to false."}}
;
const per_user_quota_body =
    \\{"error":{"code":"invalid_request","message":"gemini-3.5-flash is not supported for per-user quota requests."}}
;
const invalid_argument_body =
    \\{"error":{"code":400,"message":"Invalid value for thinking_level.","status":"INVALID_ARGUMENT"}}
;
const scope_body =
    \\{"error":{"code":403,"message":"Request had insufficient authentication scopes.","status":"PERMISSION_DENIED","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"ACCESS_TOKEN_SCOPE_INSUFFICIENT","domain":"googleapis.com"}]}}
;
const service_disabled_body =
    \\{"error":{"code":403,"message":"Generative Language API has not been used in project 123 before or it is disabled.","status":"PERMISSION_DENIED","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"SERVICE_DISABLED","domain":"googleapis.com"}]}}
;
const client_not_authorized_body =
    \\{"error":{"code":403,"message":"The OAuth client is not authorized to use this API.","status":"PERMISSION_DENIED"}}
;
const payment_required_body =
    \\{"error":{"code":402,"message":"Google AI Ultra is required to use this model.","status":"PAYMENT_REQUIRED"}}
;
const plan_not_eligible_body =
    \\{"error":{"code":403,"message":"Your account is not eligible for this request.","status":"PERMISSION_DENIED"}}
;
const plan_subscription_body =
    \\{"error":{"message":"Using your Google AI plan in third-party apps requires an active Google AI Pro or Google AI Ultra subscription: https://one.google.com/ai","code":"permission_denied"}}
;
const plan_setup_body =
    \\{"error":{"message":"Caller does not have required permission to use project example-project-123. Grant the caller the roles/serviceusage.serviceUsageConsumer role, or a custom role with the serviceusage.services.use permission, by visiting https://console.developers.google.com/iam-admin/iam?project=example-project-123 and then retry. Propagation of the new permission may take a few minutes.","code":"permission_denied"}}
;
const foreign_upgrade_body =
    \\{"error":{"code":403,"message":"Upgrade at https://evil.example.com/ai to continue.","status":"PERMISSION_DENIED"}}
;
const trailing_punctuation_body =
    \\{"error":{"code":402,"message":"Upgrade to Google AI Ultra at https://one.google.com/ai)."}}
;
const not_found_body =
    \\{"error":{"code":404,"message":"Requested entity was not found.","status":"NOT_FOUND"}}
;
const unauthenticated_body =
    \\{"error":{"code":401,"message":"Request had invalid authentication credentials.","status":"UNAUTHENTICATED"}}
;
const unavailable_body =
    \\{"error":{"code":503,"message":"The service is currently unavailable.","status":"UNAVAILABLE"}}
;
const api_key_invalid_body =
    \\{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"API_KEY_INVALID","domain":"googleapis.com","metadata":{"service":"generativelanguage.googleapis.com"}}]}}
;
const api_key_invalid_message_only_body =
    \\{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT"}}
;
const api_key_invalid_reason_only_body =
    \\{"error":{"code":400,"status":"INVALID_ARGUMENT","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"API_KEY_INVALID","domain":"googleapis.com"}]}}
;

test "gemini errors: per-minute 429 is rate_limited from Retry-After" {
    switch (classify(status_too_many_requests, per_minute_body, "7")) {
        .rate_limited => |limited| try std.testing.expectEqual(@as(u32, 7), limited.retry_after_s),
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: RetryInfo retryDelay wins over Retry-After" {
    const body = rpm_retry_info_prefix ++ "12s" ++ rpm_retry_info_suffix;
    switch (classify(status_too_many_requests, body, "7")) {
        .rate_limited => |limited| try std.testing.expectEqual(@as(u32, 12), limited.retry_after_s),
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: fractional RetryInfo delay rounds up" {
    const body = rpm_retry_info_prefix ++ "0.5s" ++ rpm_retry_info_suffix;
    switch (classify(status_too_many_requests, body, null)) {
        .rate_limited => |limited| try std.testing.expectEqual(@as(u32, 1), limited.retry_after_s),
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: oversized RetryInfo delay saturates at the u32 limit" {
    const body = rpm_retry_info_prefix ++ "99999999999999999999s" ++ rpm_retry_info_suffix;
    switch (classify(status_too_many_requests, body, null)) {
        .rate_limited => |limited| try std.testing.expectEqual(max_wait_s, limited.retry_after_s),
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: 429 with no wait hint defaults to 15 seconds" {
    switch (classify(status_too_many_requests, per_minute_body, null)) {
        .rate_limited => |limited| try std.testing.expectEqual(default_retry_after_s, limited.retry_after_s),
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: a non-numeric Retry-After falls back to 15 seconds" {
    switch (classify(status_too_many_requests, per_minute_body, "Wed, 21 Oct 2026 07:28:00 GMT")) {
        .rate_limited => |limited| try std.testing.expectEqual(default_retry_after_s, limited.retry_after_s),
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: daily-limit message names the model and reset" {
    switch (classify(status_too_many_requests, daily_limit_body, "19104")) {
        .daily_limit => |daily| {
            try expectModel("gemini-4-hydrogen", daily.model);
            try std.testing.expectEqual(@as(?u32, 19104), daily.reset_after_s);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: daily-limit message without a model has no model" {
    switch (classify(status_too_many_requests, daily_limit_no_model_body, "19104")) {
        .daily_limit => |daily| {
            try expectModel(null, daily.model);
            try std.testing.expectEqual(@as(?u32, 19104), daily.reset_after_s);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: sanitized per-day message with a nonzero limit is daily_limit" {
    switch (classify(status_too_many_requests, sanitized_daily_body, "3600")) {
        .daily_limit => |daily| {
            try expectModel("gemini-4-hydrogen", daily.model);
            try std.testing.expectEqual(@as(?u32, 3600), daily.reset_after_s);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: daily model slice borrows from the body" {
    switch (classify(status_too_many_requests, daily_limit_body, null)) {
        .daily_limit => |daily| {
            const model = daily.model orelse return error.TestExpectedModel;
            try std.testing.expect(isWithin(daily_limit_body, model));
        },
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: PerDay quota of zero is model_unavailable with its model" {
    switch (classify(status_too_many_requests, zero_quota_body, null)) {
        .model_unavailable => |unavailable| try expectModel("gemini-4-hydrogen", unavailable.model),
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: sanitized per-day message with a zero limit is model_unavailable" {
    switch (classify(status_too_many_requests, sanitized_zero_body, null)) {
        .model_unavailable => |unavailable| try expectModel("gemini-4-hydrogen", unavailable.model),
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: location text is unsupported_location" {
    switch (classify(status_bad_request, location_body, null)) {
        .unsupported_location => {},
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: stored-interactions text is stateless_required" {
    switch (classify(status_bad_request, stateless_body, null)) {
        .stateless_required => {},
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: per-user quota text is model_unavailable without a model" {
    switch (classify(status_bad_request, per_user_quota_body, null)) {
        .model_unavailable => |unavailable| try expectModel(null, unavailable.model),
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: the Google invalid-key reply with its reason and message is api_key_invalid" {
    switch (classify(status_bad_request, api_key_invalid_body, null)) {
        .api_key_invalid => {},
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: the invalid-key message alone is api_key_invalid" {
    switch (classify(status_bad_request, api_key_invalid_message_only_body, null)) {
        .api_key_invalid => {},
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: the API_KEY_INVALID reason alone is api_key_invalid" {
    switch (classify(status_bad_request, api_key_invalid_reason_only_body, null)) {
        .api_key_invalid => {},
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: the invalid-key message matches in any letter case" {
    switch (classify(status_bad_request, "{\"error\":{\"message\":\"API KEY NOT VALID.\"}}", null)) {
        .api_key_invalid => {},
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: other 400 is other with its status" {
    switch (classify(status_bad_request, invalid_argument_body, null)) {
        .other => |other| try std.testing.expectEqual(status_bad_request, other.status),
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: missing-scope 403 is scope_missing" {
    switch (classify(status_forbidden, scope_body, null)) {
        .scope_missing => {},
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: SERVICE_DISABLED 403 is service_disabled" {
    switch (classify(status_forbidden, service_disabled_body, null)) {
        .service_disabled => {},
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: unauthorized OAuth client 403 is client_not_authorized" {
    switch (classify(status_forbidden, client_not_authorized_body, null)) {
        .client_not_authorized => {},
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: 402 is not_entitled with the plan link" {
    switch (classify(status_payment_required, payment_required_body, null)) {
        .not_entitled => |plan| try std.testing.expectEqualStrings(google_ai_plans_url, plan.upgrade_url),
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: plan-ineligible 403 is not_entitled" {
    switch (classify(status_forbidden, plan_not_eligible_body, null)) {
        .not_entitled => |plan| try std.testing.expectEqualStrings(google_ai_plans_url, plan.upgrade_url),
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: the Pro or Ultra subscription 403 is not_entitled with its plan link" {
    switch (classify(status_forbidden, plan_subscription_body, null)) {
        .not_entitled => |plan| try std.testing.expectEqualStrings("https://one.google.com/ai", plan.upgrade_url),
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: a project permission 403 while Google sets up the plan is plan_setup_pending" {
    switch (classify(status_forbidden, plan_setup_body, null)) {
        .plan_setup_pending => {},
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: upgrade URL on another host is replaced by the plan link" {
    switch (classify(status_forbidden, foreign_upgrade_body, null)) {
        .not_entitled => |plan| try std.testing.expectEqualStrings(google_ai_plans_url, plan.upgrade_url),
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: upgrade URL keeps its path and loses trailing punctuation" {
    switch (classify(status_payment_required, trailing_punctuation_body, null)) {
        .not_entitled => |plan| try std.testing.expectEqualStrings("https://one.google.com/ai", plan.upgrade_url),
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: 401 is unauthenticated" {
    switch (classify(status_unauthorized, unauthenticated_body, null)) {
        .unauthenticated => {},
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: 404 is project_not_allowlisted" {
    switch (classify(status_not_found, not_found_body, null)) {
        .project_not_allowlisted => {},
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: 5xx is server_error" {
    switch (classify(503, unavailable_body, null)) {
        .server_error => {},
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: a body that is not JSON is classified from the status alone" {
    switch (classify(status_too_many_requests, "<html>Too Many Requests</html>", "3")) {
        .rate_limited => |limited| try std.testing.expectEqual(@as(u32, 3), limited.retry_after_s),
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: a body over the size bound is classified from the status alone" {
    var padded: [body_max_bytes + 1]u8 = @splat(' ');
    @memcpy(padded[0..daily_limit_no_model_body.len], daily_limit_no_model_body);
    switch (classify(status_too_many_requests, &padded, null)) {
        .rate_limited => |limited| try std.testing.expectEqual(default_retry_after_s, limited.retry_after_s),
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: a body nested too deeply is classified from the status alone" {
    const deep: [json_max_nesting_levels + 1]u8 = @splat('[');
    switch (classify(status_too_many_requests, &deep, "9")) {
        .rate_limited => |limited| try std.testing.expectEqual(@as(u32, 9), limited.retry_after_s),
        else => return error.TestUnexpectedResult,
    }
}

test "gemini errors: an empty body is classified from the status alone" {
    switch (classify(status_unauthorized, "", null)) {
        .unauthenticated => {},
        else => return error.TestUnexpectedResult,
    }
}

fn expectSafeUpgradeUrl(url: []const u8) !void {
    if (std.mem.eql(u8, url, google_ai_plans_url)) return;
    try std.testing.expect(std.mem.startsWith(u8, url, plan_url_prefix));
    try std.testing.expect(std.mem.findScalar(u8, plan_url_trailing_punctuation, url[url.len - 1]) == null);
}

fn fuzzClassify(_: void, smith: *std.testing.Smith) !void {
    var body_buf: [body_max_bytes + 64]u8 = undefined;
    var header_buf: [32]u8 = undefined;
    const status = smith.value(u16);
    const body = body_buf[0..smith.slice(&body_buf)];
    const header: ?[]const u8 = if (smith.value(bool)) header_buf[0..smith.slice(&header_buf)] else null;
    switch (classify(status, body, header)) {
        .not_entitled => |plan| try expectSafeUpgradeUrl(plan.upgrade_url),
        else => {},
    }
}

test "gemini errors classify returns for fuzzed status, body, and header bytes" {
    try std.testing.fuzz({}, fuzzClassify, .{
        .corpus = &(@import("fuzz_corpus").gemini_errors_classify.*),
    });
}
