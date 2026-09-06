const std = @import("std");
const common = @import("common.zig");
const catalog_freshness = @import("../catalog_freshness.zig");
const json_number = @import("../json_number.zig");
const mrtr = @import("../mrtr.zig");
const sort_utils = @import("../../shared/sort_utils.zig");

const Allocator = std.mem.Allocator;

pub const Protocol = common.Protocol;
pub const CacheScope = common.CacheScope;
pub const ProtocolError = common.ProtocolError;
pub const ResourceData = common.ResourceData;
pub const ResourceContent = common.ResourceContent;
pub const InputRequired = mrtr.InputRequired;

pub const Limits = struct {
    max_pages: usize = 64,
    max_resources: usize = 4096,
    max_templates: usize = 4096,
    max_cursor_bytes: usize = 4096,
    common: common.Limits = .{},
};

pub const Error = error{
    InvalidListResult,
    InvalidResource,
    InvalidTemplate,
    DuplicateResource,
    DuplicateTemplate,
    DuplicateCursor,
    InconsistentCacheScope,
    PaginationLimitExceeded,
    ResourceLimitExceeded,
    TemplateLimitExceeded,
    InvalidReadResult,
    ContentLimitExceeded,
    InvalidInputRequired,
} || common.Error || Allocator.Error || std.Io.Writer.Error;

pub const Descriptor = struct {
    uri: []u8,
    name: []u8,
    title: ?[]u8 = null,
    description: ?[]u8 = null,
    mime_type: ?[]u8 = null,
    size: ?u64 = null,
    icons_json: ?[]u8 = null,
    annotations_json: ?[]u8 = null,
    metadata_json: ?[]u8 = null,

    pub fn deinit(self: *Descriptor, alloc: Allocator) void {
        alloc.free(self.uri);
        alloc.free(self.name);
        if (self.title) |value| alloc.free(value);
        if (self.description) |value| alloc.free(value);
        if (self.mime_type) |value| alloc.free(value);
        if (self.icons_json) |value| alloc.free(value);
        if (self.annotations_json) |value| alloc.free(value);
        if (self.metadata_json) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const Template = struct {
    uri_template: []u8,
    name: []u8,
    title: ?[]u8 = null,
    description: ?[]u8 = null,
    mime_type: ?[]u8 = null,
    icons_json: ?[]u8 = null,
    annotations_json: ?[]u8 = null,
    metadata_json: ?[]u8 = null,

    pub fn deinit(self: *Template, alloc: Allocator) void {
        alloc.free(self.uri_template);
        alloc.free(self.name);
        if (self.title) |value| alloc.free(value);
        if (self.description) |value| alloc.free(value);
        if (self.mime_type) |value| alloc.free(value);
        if (self.icons_json) |value| alloc.free(value);
        if (self.annotations_json) |value| alloc.free(value);
        if (self.metadata_json) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const ResourcePage = struct {
    items: []Descriptor,
    next_cursor: ?[]u8 = null,
    cache: common.CacheHints,

    pub fn deinit(self: *ResourcePage, alloc: Allocator) void {
        for (self.items) |*item| item.deinit(alloc);
        alloc.free(self.items);
        if (self.next_cursor) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const TemplatePage = struct {
    items: []Template,
    next_cursor: ?[]u8 = null,
    cache: common.CacheHints,

    pub fn deinit(self: *TemplatePage, alloc: Allocator) void {
        for (self.items) |*item| item.deinit(alloc);
        alloc.free(self.items);
        if (self.next_cursor) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const ResourceCatalog = struct {
    items: []Descriptor,
    fetched_at_ms: u64,
    expires_at_ms: u64,
    cache_scope: CacheScope,

    pub fn deinit(self: *ResourceCatalog, alloc: Allocator) void {
        for (self.items) |*item| item.deinit(alloc);
        alloc.free(self.items);
        self.* = undefined;
    }

    pub fn containsUri(self: ResourceCatalog, uri: []const u8) bool {
        for (self.items) |item| if (std.mem.eql(u8, item.uri, uri)) return true;
        return false;
    }
};

pub const TemplateCatalog = struct {
    items: []Template,
    fetched_at_ms: u64,
    expires_at_ms: u64,
    cache_scope: CacheScope,

    pub fn deinit(self: *TemplateCatalog, alloc: Allocator) void {
        for (self.items) |*item| item.deinit(alloc);
        alloc.free(self.items);
        self.* = undefined;
    }
};

pub const ResourceCatalogBuilder = struct {
    items: std.ArrayList(Descriptor) = .empty,
    cursors: std.StringHashMap(void),
    protocol: Protocol,
    pages: usize = 0,
    first_received_at_ms: ?u64 = null,
    expires_at_ms: ?u64 = null,
    cache_scope: ?CacheScope = null,

    pub fn init(alloc: Allocator, protocol: Protocol) ResourceCatalogBuilder {
        return .{ .cursors = std.StringHashMap(void).init(alloc), .protocol = protocol };
    }

    pub fn deinit(self: *ResourceCatalogBuilder, alloc: Allocator) void {
        for (self.items.items) |*item| item.deinit(alloc);
        self.items.deinit(alloc);
        freeCursors(alloc, &self.cursors);
        self.* = undefined;
    }

    pub fn appendPage(self: *ResourceCatalogBuilder, alloc: Allocator, page: *ResourcePage, received_at_ms: u64, limits: Limits) Error!void {
        try validatePageTransition(
            alloc,
            &self.cursors,
            &self.pages,
            &self.first_received_at_ms,
            &self.expires_at_ms,
            &self.cache_scope,
            self.protocol,
            page.next_cursor,
            page.cache,
            received_at_ms,
            limits.max_pages,
        );
        const total = std.math.add(usize, self.items.items.len, page.items.len) catch
            return error.ResourceLimitExceeded;
        if (total > limits.max_resources) return error.ResourceLimitExceeded;
        for (page.items, 0..) |item, index| {
            for (self.items.items) |existing| {
                if (std.mem.eql(u8, existing.uri, item.uri)) return error.DuplicateResource;
            }
            for (page.items[0..index]) |previous| {
                if (std.mem.eql(u8, previous.uri, item.uri)) return error.DuplicateResource;
            }
        }
        try self.items.ensureUnusedCapacity(alloc, page.items.len);
        for (page.items) |*item| {
            self.items.appendAssumeCapacity(item.*);
            item.* = undefined;
        }
        alloc.free(page.items);
        page.items = &.{};
    }

    pub fn finish(self: *ResourceCatalogBuilder, alloc: Allocator) Error!ResourceCatalog {
        if (self.pages == 0) return error.InvalidListResult;
        sort_utils.sort(Descriptor, self.items.items, {}, lessDescriptor);
        return .{
            .items = try self.items.toOwnedSlice(alloc),
            .fetched_at_ms = self.first_received_at_ms.?,
            .expires_at_ms = self.expires_at_ms.?,
            .cache_scope = self.cache_scope orelse .private,
        };
    }
};

pub const TemplateCatalogBuilder = struct {
    items: std.ArrayList(Template) = .empty,
    cursors: std.StringHashMap(void),
    protocol: Protocol,
    pages: usize = 0,
    first_received_at_ms: ?u64 = null,
    expires_at_ms: ?u64 = null,
    cache_scope: ?CacheScope = null,

    pub fn init(alloc: Allocator, protocol: Protocol) TemplateCatalogBuilder {
        return .{ .cursors = std.StringHashMap(void).init(alloc), .protocol = protocol };
    }

    pub fn deinit(self: *TemplateCatalogBuilder, alloc: Allocator) void {
        for (self.items.items) |*item| item.deinit(alloc);
        self.items.deinit(alloc);
        freeCursors(alloc, &self.cursors);
        self.* = undefined;
    }

    pub fn appendPage(self: *TemplateCatalogBuilder, alloc: Allocator, page: *TemplatePage, received_at_ms: u64, limits: Limits) Error!void {
        try validatePageTransition(
            alloc,
            &self.cursors,
            &self.pages,
            &self.first_received_at_ms,
            &self.expires_at_ms,
            &self.cache_scope,
            self.protocol,
            page.next_cursor,
            page.cache,
            received_at_ms,
            limits.max_pages,
        );
        const total = std.math.add(usize, self.items.items.len, page.items.len) catch
            return error.TemplateLimitExceeded;
        if (total > limits.max_templates) return error.TemplateLimitExceeded;
        for (page.items, 0..) |item, index| {
            for (self.items.items) |existing| {
                if (std.mem.eql(u8, existing.uri_template, item.uri_template)) return error.DuplicateTemplate;
            }
            for (page.items[0..index]) |previous| {
                if (std.mem.eql(u8, previous.uri_template, item.uri_template)) return error.DuplicateTemplate;
            }
        }
        try self.items.ensureUnusedCapacity(alloc, page.items.len);
        for (page.items) |*item| {
            self.items.appendAssumeCapacity(item.*);
            item.* = undefined;
        }
        alloc.free(page.items);
        page.items = &.{};
    }

    pub fn finish(self: *TemplateCatalogBuilder, alloc: Allocator) Error!TemplateCatalog {
        if (self.pages == 0) return error.InvalidListResult;
        sort_utils.sort(Template, self.items.items, {}, lessTemplate);
        return .{
            .items = try self.items.toOwnedSlice(alloc),
            .fetched_at_ms = self.first_received_at_ms.?,
            .expires_at_ms = self.expires_at_ms.?,
            .cache_scope = self.cache_scope orelse .private,
        };
    }
};

pub const ReadResult = struct {
    contents: []ResourceContent,
    cache: common.CacheHints,
    cache_eligible: bool = true,

    pub fn deinit(self: *ReadResult, alloc: Allocator) void {
        for (self.contents) |*content| content.deinit(alloc);
        alloc.free(self.contents);
        self.* = undefined;
    }
};

pub const ReadRequestProvenance = struct {
    input_responses_present: bool = false,
    request_state_present: bool = false,

    fn cacheEligible(self: ReadRequestProvenance) bool {
        return !self.input_responses_present and !self.request_state_present;
    }
};

pub const ReadOutcome = union(enum) {
    complete: ReadResult,
    input_required: InputRequired,
    protocol_failure: ProtocolError,

    pub fn deinit(self: *ReadOutcome, alloc: Allocator) void {
        switch (self.*) {
            .complete => |*value| value.deinit(alloc),
            .input_required => |*value| value.deinit(alloc),
            .protocol_failure => |*value| value.deinit(alloc),
        }
        self.* = undefined;
    }
};

pub fn staleFallbackEligible(err: anyerror) bool {
    return switch (err) {
        error.McpConnectionClosed,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.HttpConnectionClosing,
        error.BrokenPipe,
        error.EndOfStream,
        => true,
        else => false,
    };
}

pub fn parseResourcePage(alloc: Allocator, response: []const u8, protocol: Protocol, limits: Limits) Error!ResourcePage {
    var parsed = try common.parseEnvelope(alloc, response, limits.common);
    defer parsed.deinit();
    const result = common.completeResult(parsed.value, protocol) catch |err| return mapCommonResultError(err);
    const value = result.object.get("resources") orelse return error.InvalidListResult;
    if (value != .array or value.array.items.len > limits.max_resources) return error.InvalidListResult;
    const items = try alloc.alloc(Descriptor, value.array.items.len);
    var count: usize = 0;
    errdefer {
        for (items[0..count]) |*item| item.deinit(alloc);
        alloc.free(items);
    }
    for (value.array.items, 0..) |item, index| {
        items[index] = try parseDescriptor(alloc, item, limits.common);
        count += 1;
    }
    const next_cursor = try parseCursor(alloc, result, limits.max_cursor_bytes);
    errdefer if (next_cursor) |cursor| alloc.free(cursor);
    return .{ .items = items, .next_cursor = next_cursor, .cache = try common.parseCacheHints(alloc, result) };
}

pub fn parseTemplatePage(alloc: Allocator, response: []const u8, protocol: Protocol, limits: Limits) Error!TemplatePage {
    var parsed = try common.parseEnvelope(alloc, response, limits.common);
    defer parsed.deinit();
    const result = common.completeResult(parsed.value, protocol) catch |err| return mapCommonResultError(err);
    const value = result.object.get("resourceTemplates") orelse return error.InvalidListResult;
    if (value != .array or value.array.items.len > limits.max_templates) return error.InvalidListResult;
    const items = try alloc.alloc(Template, value.array.items.len);
    var count: usize = 0;
    errdefer {
        for (items[0..count]) |*item| item.deinit(alloc);
        alloc.free(items);
    }
    for (value.array.items, 0..) |item, index| {
        items[index] = try parseTemplate(alloc, item, limits.common);
        count += 1;
    }
    const next_cursor = try parseCursor(alloc, result, limits.max_cursor_bytes);
    errdefer if (next_cursor) |cursor| alloc.free(cursor);
    return .{ .items = items, .next_cursor = next_cursor, .cache = try common.parseCacheHints(alloc, result) };
}

fn parseReadOutcome(alloc: Allocator, response: []const u8, protocol: Protocol, limits: Limits) Error!ReadOutcome {
    return parseReadOutcomeForRequest(alloc, response, protocol, limits, .{});
}

pub fn parseReadOutcomeForRequest(
    alloc: Allocator,
    response: []const u8,
    protocol: Protocol,
    limits: Limits,
    provenance: ReadRequestProvenance,
) Error!ReadOutcome {
    var parsed = try common.parseEnvelope(alloc, response, limits.common);
    defer parsed.deinit();
    if (parsed.value.object.get("error")) |protocol_error| {
        return .{ .protocol_failure = try common.parseProtocolError(alloc, protocol_error, limits.common) };
    }
    const result = parsed.value.object.get("result") orelse return error.InvalidReadResult;
    if (result != .object) return error.InvalidReadResult;
    if (result.object.get("resultType")) |result_type| {
        if (result_type != .string) return error.InvalidReadResult;
        if (std.mem.eql(u8, result_type.string, "input_required")) {
            if (protocol != .modern) return error.UnsupportedResultType;
            return .{ .input_required = try mrtr.parseInputRequired(
                alloc,
                result,
                common.mrtrLimits(limits.common),
            ) };
        }
        if (!std.mem.eql(u8, result_type.string, "complete")) return error.UnsupportedResultType;
    }
    const contents_value = result.object.get("contents") orelse return error.InvalidReadResult;
    if (contents_value != .array or contents_value.array.items.len > limits.common.max_content_items) {
        return error.ContentLimitExceeded;
    }
    const contents = try alloc.alloc(ResourceContent, contents_value.array.items.len);
    var count: usize = 0;
    var total_content_bytes: usize = 0;
    errdefer {
        for (contents[0..count]) |*content| content.deinit(alloc);
        alloc.free(contents);
    }
    for (contents_value.array.items, 0..) |content, index| {
        contents[index] = try common.parseResourceContent(alloc, content, limits.common);
        count += 1;
        total_content_bytes = std.math.add(
            usize,
            total_content_bytes,
            resourceContentBytes(contents[index]),
        ) catch return error.ContentLimitExceeded;
        if (total_content_bytes > limits.common.max_total_content_bytes) {
            return error.ContentLimitExceeded;
        }
    }
    return .{ .complete = .{
        .contents = contents,
        .cache = try common.parseCacheHints(alloc, result),
        .cache_eligible = provenance.cacheEligible(),
    } };
}

fn resourceContentBytes(content: ResourceContent) usize {
    var total = content.uri.len;
    if (content.mime_type) |value| total +|= value.len;
    if (content.annotations_json) |value| total +|= value.len;
    if (content.metadata_json) |value| total +|= value.len;
    total +|= switch (content.data) {
        .text => |value| value.len,
        .blob => |value| value.len,
    };
    return total;
}

pub fn buildListRequest(alloc: Allocator, request_id: u64, protocol: Protocol, cursor: ?[]const u8, write_modern_metadata: *const fn (*std.Io.Writer) anyerror!void) ![]u8 {
    return buildPaginatedRequest(alloc, request_id, protocol, "resources/list", cursor, write_modern_metadata);
}

pub fn buildTemplatesListRequest(alloc: Allocator, request_id: u64, protocol: Protocol, cursor: ?[]const u8, write_modern_metadata: *const fn (*std.Io.Writer) anyerror!void) ![]u8 {
    return buildPaginatedRequest(alloc, request_id, protocol, "resources/templates/list", cursor, write_modern_metadata);
}

pub fn buildReadRequest(
    alloc: Allocator,
    request_id: u64,
    protocol: Protocol,
    uri: []const u8,
    write_modern_metadata: *const fn (*std.Io.Writer) anyerror!void,
    input_responses_json: ?[]const u8,
    request_state_json: ?[]const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"resources/read\",\"params\":{{", .{request_id});
    if (protocol == .modern) {
        try out.writer.writeAll("\"_meta\":");
        try write_modern_metadata(&out.writer);
        try out.writer.writeByte(',');
    }
    try out.writer.writeAll("\"uri\":");
    try std.json.Stringify.value(uri, .{}, &out.writer);
    if (input_responses_json) |responses| {
        try out.writer.writeAll(",\"inputResponses\":");
        try writeCompactJson(alloc, &out.writer, responses);
        if (request_state_json) |state| {
            try out.writer.writeAll(",\"requestState\":");
            try writeCompactJson(alloc, &out.writer, state);
        }
    }
    try out.writer.writeAll("}}");
    return try out.toOwnedSlice();
}

pub fn templateMayResolve(template: []const u8, uri: []const u8) bool {
    var budget = TemplateMatchBudget.init(default_template_match_steps);
    return matchTemplateWithBudget(template, uri, &budget) == .matches;
}

const max_template_expressions: usize = 64;
pub const default_template_match_steps: usize = 1024 * 1024;

pub const TemplateMatchResult = enum {
    matches,
    no_match,
    work_limit_exceeded,
};

pub const TemplateMatchBudget = struct {
    remaining: usize,
    exhausted: bool = false,

    pub fn init(max_steps: usize) TemplateMatchBudget {
        return .{ .remaining = max_steps };
    }

    fn consume(self: *TemplateMatchBudget, count: usize) bool {
        if (count > self.remaining) {
            self.remaining = 0;
            self.exhausted = true;
            return false;
        }
        self.remaining -= count;
        return true;
    }
};

pub fn matchTemplateWithBudget(
    template: []const u8,
    uri: []const u8,
    budget: *TemplateMatchBudget,
) TemplateMatchResult {
    const max_uri_bytes = (common.Limits{}).max_uri_bytes;
    if (template.len > max_uri_bytes or uri.len > max_uri_bytes) return .no_match;
    const parse_steps = std.math.mul(usize, template.len, 2) catch {
        budget.exhausted = true;
        budget.remaining = 0;
        return .work_limit_exceeded;
    };
    if (!budget.consume(parse_steps)) return .work_limit_exceeded;
    const parsed = parseUriTemplate(template) orelse return .no_match;
    const matches = matchTemplateFrom(parsed, uri, 0, 0, budget);
    if (budget.exhausted) return .work_limit_exceeded;
    return if (matches) .matches else .no_match;
}

const TemplateOperator = enum {
    simple,
    reserved,
    fragment,
    label,
    path,
    path_parameter,
    query,
    query_continuation,
};

const TemplateExpression = struct {
    open: usize,
    close: usize,
    operator: TemplateOperator,
    variable: []const u8,
};

const ParsedTemplate = struct {
    source: []const u8,
    expressions: [max_template_expressions]TemplateExpression = undefined,
    expression_count: usize = 0,
};

fn parseUriTemplate(template: []const u8) ?ParsedTemplate {
    var parsed = ParsedTemplate{ .source = template };
    var literal_start: usize = 0;
    var index: usize = 0;
    while (index < template.len) {
        if (template[index] == '}') return null;
        if (template[index] != '{') {
            index += 1;
            continue;
        }
        if (parsed.expression_count > 0 and literal_start == index) return null;
        if (!validTemplateLiteral(template[literal_start..index])) return null;
        if (parsed.expression_count >= max_template_expressions) return null;
        const open = index;
        index += 1;
        const expression_start = index;
        while (index < template.len and template[index] != '}') : (index += 1) {
            if (template[index] == '{') return null;
        }
        if (index >= template.len or index == expression_start) return null;
        const close = index;
        const expression = parseTemplateExpression(template[expression_start..close], open, close) orelse
            return null;
        parsed.expressions[parsed.expression_count] = expression;
        parsed.expression_count += 1;
        index += 1;
        literal_start = index;
    }
    if (!validTemplateLiteral(template[literal_start..])) return null;
    return parsed;
}

fn parseTemplateExpression(
    expression: []const u8,
    open: usize,
    close: usize,
) ?TemplateExpression {
    var operator: TemplateOperator = .simple;
    var variable_start: usize = 0;
    operator = switch (expression[0]) {
        '+' => .reserved,
        '#' => .fragment,
        '.' => .label,
        '/' => .path,
        ';' => .path_parameter,
        '?' => .query,
        '&' => .query_continuation,
        else => .simple,
    };
    if (operator != .simple) variable_start = 1;
    const variable = expression[variable_start..];
    if (!validTemplateVariable(variable)) return null;
    return .{
        .open = open,
        .close = close,
        .operator = operator,
        .variable = variable,
    };
}

fn validTemplateVariable(variable: []const u8) bool {
    if (variable.len == 0 or variable[0] == '.' or variable[variable.len - 1] == '.') return false;
    var previous_dot = false;
    for (variable) |byte| {
        if (byte == '.') {
            if (previous_dot) return false;
            previous_dot = true;
            continue;
        }
        previous_dot = false;
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    }
    return true;
}

fn validTemplateLiteral(literal: []const u8) bool {
    var index: usize = 0;
    while (index < literal.len) {
        const byte = literal[index];
        if (byte == '%') {
            if (index + 2 >= literal.len or
                !std.ascii.isHex(literal[index + 1]) or
                !std.ascii.isHex(literal[index + 2]))
            {
                return false;
            }
            index += 3;
            continue;
        }
        if (!isUnreserved(byte) and !isReserved(byte)) return false;
        index += 1;
    }
    return true;
}

fn matchTemplateFrom(
    parsed: ParsedTemplate,
    uri: []const u8,
    expression_index: usize,
    uri_index: usize,
    budget: *TemplateMatchBudget,
) bool {
    if (expression_index == parsed.expression_count) {
        const literal_start = if (expression_index == 0)
            0
        else
            parsed.expressions[expression_index - 1].close + 1;
        return boundedEqual(parsed.source[literal_start..], uri[uri_index..], budget);
    }

    const expression = parsed.expressions[expression_index];
    const literal_start = if (expression_index == 0)
        0
    else
        parsed.expressions[expression_index - 1].close + 1;
    const literal = parsed.source[literal_start..expression.open];
    if (!boundedStartsWith(uri[uri_index..], literal, budget)) return false;
    const value_start = uri_index + literal.len;
    const next_literal_end = if (expression_index + 1 < parsed.expression_count)
        parsed.expressions[expression_index + 1].open
    else
        parsed.source.len;
    const next_literal = parsed.source[expression.close + 1 .. next_literal_end];

    if (expression_index + 1 == parsed.expression_count and next_literal.len == 0) {
        return expressionMatches(expression, uri[value_start..], budget);
    }

    if (next_literal.len > 0) {
        var search_start = value_start;
        while (findTemplateLiteral(uri, next_literal, search_start, budget)) |value_end| {
            if (expressionMatches(expression, uri[value_start..value_end], budget) and
                matchTemplateFrom(parsed, uri, expression_index + 1, value_end, budget))
            {
                return true;
            }
            if (budget.exhausted) return false;
            search_start = std.math.add(usize, value_end, 1) catch return false;
        }
        return false;
    }

    // Catalog parsing rejects adjacent expressions because they have no literal
    // boundary for deterministic bounded matching.
    return false;
}

fn findTemplateLiteral(
    uri: []const u8,
    literal: []const u8,
    start: usize,
    budget: *TemplateMatchBudget,
) ?usize {
    if (literal.len == 0 or start > uri.len) return null;
    var search_start = start;
    while (search_start < uri.len) {
        const index = std.mem.findScalarPos(u8, uri, search_start, literal[0]) orelse {
            _ = budget.consume(uri.len - search_start);
            return null;
        };
        if (!budget.consume(index - search_start + 1)) return null;
        if (literal.len > uri.len - index) return null;
        if (boundedEqual(uri[index .. index + literal.len], literal, budget)) return index;
        if (budget.exhausted) return null;
        search_start = index + 1;
    }
    return null;
}

fn boundedStartsWith(
    value: []const u8,
    prefix: []const u8,
    budget: *TemplateMatchBudget,
) bool {
    if (prefix.len > value.len) return false;
    return boundedEqual(value[0..prefix.len], prefix, budget);
}

fn boundedEqual(
    left: []const u8,
    right: []const u8,
    budget: *TemplateMatchBudget,
) bool {
    if (left.len != right.len) return false;
    if (!budget.consume(left.len)) return false;
    return std.mem.eql(u8, left, right);
}

fn expressionMatches(
    expression: TemplateExpression,
    value: []const u8,
    budget: *TemplateMatchBudget,
) bool {
    return switch (expression.operator) {
        .simple => validExpandedValue(value, false, budget),
        .reserved => validExpandedValue(value, true, budget),
        .fragment => value.len == 0 or
            (value[0] == '#' and validExpandedValue(value[1..], true, budget)),
        .label => value.len == 0 or
            (value[0] == '.' and validExpandedValue(value[1..], false, budget)),
        .path => value.len == 0 or
            (value[0] == '/' and validExpandedValue(value[1..], false, budget)),
        .path_parameter => namedExpansionMatches(';', expression.variable, value, true, budget),
        .query => namedExpansionMatches('?', expression.variable, value, false, budget),
        .query_continuation => namedExpansionMatches('&', expression.variable, value, false, budget),
    };
}

fn namedExpansionMatches(
    prefix: u8,
    variable: []const u8,
    value: []const u8,
    value_optional: bool,
    budget: *TemplateMatchBudget,
) bool {
    if (value.len == 0) return true;
    if (value[0] != prefix or value.len < variable.len + 1 or
        !boundedEqual(value[1 .. variable.len + 1], variable, budget))
    {
        return false;
    }
    const remainder = value[variable.len + 1 ..];
    if (remainder.len == 0) return value_optional;
    if (remainder[0] != '=') return false;
    return validExpandedValue(remainder[1..], false, budget);
}

fn validExpandedValue(value: []const u8, allow_reserved: bool, budget: *TemplateMatchBudget) bool {
    var index: usize = 0;
    while (index < value.len) {
        const byte = value[index];
        if (byte == '%') {
            if (!budget.consume(3)) return false;
            if (index + 2 >= value.len or
                !std.ascii.isHex(value[index + 1]) or
                !std.ascii.isHex(value[index + 2]))
            {
                return false;
            }
            index += 3;
            continue;
        }
        if (!budget.consume(1)) return false;
        if (!isUnreserved(byte) and !(allow_reserved and isReserved(byte))) return false;
        index += 1;
    }
    return true;
}

fn isUnreserved(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or
        byte == '_' or byte == '~';
}

fn isReserved(byte: u8) bool {
    return switch (byte) {
        ':', '/', '?', '#', '[', ']', '@', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=' => true,
        else => false,
    };
}

fn parseDescriptor(alloc: Allocator, value: std.json.Value, limits: common.Limits) Error!Descriptor {
    if (value != .object) return error.InvalidResource;
    const uri = common.requiredString(value.object, "uri", limits.max_uri_bytes) catch return error.InvalidResource;
    const name = common.requiredString(value.object, "name", limits.max_name_bytes) catch return error.InvalidResource;
    const fields = try parseDescriptorFields(alloc, value.object, limits);
    errdefer fields.deinit(alloc);
    const owned_uri = try alloc.dupe(u8, uri);
    errdefer alloc.free(owned_uri);
    const owned_name = try alloc.dupe(u8, name);
    return .{
        .uri = owned_uri,
        .name = owned_name,
        .title = fields.title,
        .description = fields.description,
        .mime_type = fields.mime_type,
        .size = fields.size,
        .icons_json = fields.icons_json,
        .annotations_json = fields.annotations_json,
        .metadata_json = fields.metadata_json,
    };
}

fn parseTemplate(alloc: Allocator, value: std.json.Value, limits: common.Limits) Error!Template {
    if (value != .object) return error.InvalidTemplate;
    const uri_template = common.requiredString(value.object, "uriTemplate", limits.max_uri_bytes) catch return error.InvalidTemplate;
    if (parseUriTemplate(uri_template) == null) return error.InvalidTemplate;
    const name = common.requiredString(value.object, "name", limits.max_name_bytes) catch return error.InvalidTemplate;
    const fields = parseDescriptorFields(alloc, value.object, limits) catch return error.InvalidTemplate;
    errdefer fields.deinit(alloc);
    const owned_uri_template = try alloc.dupe(u8, uri_template);
    errdefer alloc.free(owned_uri_template);
    const owned_name = try alloc.dupe(u8, name);
    return .{
        .uri_template = owned_uri_template,
        .name = owned_name,
        .title = fields.title,
        .description = fields.description,
        .mime_type = fields.mime_type,
        .icons_json = fields.icons_json,
        .annotations_json = fields.annotations_json,
        .metadata_json = fields.metadata_json,
    };
}

const DescriptorFields = struct {
    title: ?[]u8,
    description: ?[]u8,
    mime_type: ?[]u8,
    size: ?u64,
    icons_json: ?[]u8,
    annotations_json: ?[]u8,
    metadata_json: ?[]u8,

    fn deinit(self: DescriptorFields, alloc: Allocator) void {
        if (self.title) |value| alloc.free(value);
        if (self.description) |value| alloc.free(value);
        if (self.mime_type) |value| alloc.free(value);
        if (self.icons_json) |value| alloc.free(value);
        if (self.annotations_json) |value| alloc.free(value);
        if (self.metadata_json) |value| alloc.free(value);
    }
};

fn parseDescriptorFields(alloc: Allocator, object: std.json.ObjectMap, limits: common.Limits) Error!DescriptorFields {
    const title = try common.optionalString(object, "title", limits.max_title_bytes);
    const description = try common.optionalString(object, "description", limits.max_description_bytes);
    const mime_type = try common.optionalString(object, "mimeType", limits.max_title_bytes);
    if (object.get("icons")) |icons| try common.validateIcons(icons, limits);
    if (object.get("annotations")) |annotations| try common.validateAnnotations(annotations, limits);
    if (object.get("_meta")) |metadata| {
        if (metadata != .object) return error.InvalidContent;
        _ = try common.boundedJsonLength(metadata, limits.max_metadata_bytes, limits.max_json_depth);
    }
    const size = if (object.get("size")) |value|
        (try nonNegativeU64(alloc, value)) orelse return error.InvalidContent
    else
        null;
    const owned_title = if (title) |value| try alloc.dupe(u8, value) else null;
    errdefer if (owned_title) |value| alloc.free(value);
    const owned_description = if (description) |value| try alloc.dupe(u8, value) else null;
    errdefer if (owned_description) |value| alloc.free(value);
    const owned_mime_type = if (mime_type) |value| try alloc.dupe(u8, value) else null;
    errdefer if (owned_mime_type) |value| alloc.free(value);
    const icons_json = if (object.get("icons")) |value|
        try common.stringifyValueAlloc(alloc, value, limits.max_metadata_bytes, limits.max_json_depth)
    else
        null;
    errdefer if (icons_json) |value| alloc.free(value);
    const annotations_json = if (object.get("annotations")) |value|
        try common.stringifyValueAlloc(alloc, value, limits.max_metadata_bytes, limits.max_json_depth)
    else
        null;
    errdefer if (annotations_json) |value| alloc.free(value);
    const metadata_json = if (object.get("_meta")) |value|
        try common.stringifyValueAlloc(alloc, value, limits.max_metadata_bytes, limits.max_json_depth)
    else
        null;
    return .{
        .title = owned_title,
        .description = owned_description,
        .mime_type = owned_mime_type,
        .size = size,
        .icons_json = icons_json,
        .annotations_json = annotations_json,
        .metadata_json = metadata_json,
    };
}

fn validatePageTransition(
    alloc: Allocator,
    cursors: *std.StringHashMap(void),
    pages: *usize,
    first_received_at_ms: *?u64,
    expires_at_ms: *?u64,
    cache_scope: *?CacheScope,
    protocol: Protocol,
    next_cursor: ?[]const u8,
    cache: common.CacheHints,
    received_at_ms: u64,
    max_pages: usize,
) Error!void {
    const next_pages = std.math.add(usize, pages.*, 1) catch return error.PaginationLimitExceeded;
    if (next_pages > max_pages) return error.PaginationLimitExceeded;
    if (next_cursor) |cursor| if (cursors.contains(cursor)) return error.DuplicateCursor;
    if (cache_scope.*) |scope| {
        if (scope != cache.scope) return error.InconsistentCacheScope;
    }
    if (next_cursor) |cursor| {
        const owned = try alloc.dupe(u8, cursor);
        errdefer alloc.free(owned);
        try cursors.put(owned, {});
    }
    pages.* = next_pages;
    if (first_received_at_ms.* == null) first_received_at_ms.* = received_at_ms;
    cache_scope.* = cache_scope.* orelse cache.scope;
    const page_expiry = catalog_freshness.pageExpiry(
        switch (protocol) {
            .legacy => .legacy,
            .modern => .modern,
        },
        received_at_ms,
        cache.ttl_present,
        cache.ttl_ms,
    );
    expires_at_ms.* = catalog_freshness.earliestExpiry(expires_at_ms.*, page_expiry);
}

fn buildPaginatedRequest(alloc: Allocator, request_id: u64, protocol: Protocol, method: []const u8, cursor: ?[]const u8, write_modern_metadata: *const fn (*std.Io.Writer) anyerror!void) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":", .{request_id});
    try std.json.Stringify.value(method, .{}, &out.writer);
    try out.writer.writeAll(",\"params\":{");
    var wrote = false;
    if (protocol == .modern) {
        try out.writer.writeAll("\"_meta\":");
        try write_modern_metadata(&out.writer);
        wrote = true;
    }
    if (cursor) |value| {
        if (wrote) try out.writer.writeByte(',');
        try out.writer.writeAll("\"cursor\":");
        try std.json.Stringify.value(value, .{}, &out.writer);
    }
    try out.writer.writeAll("}}");
    return try out.toOwnedSlice();
}

fn parseCursor(alloc: Allocator, result: std.json.Value, max_bytes: usize) Error!?[]u8 {
    const cursor = result.object.get("nextCursor") orelse return null;
    if (cursor != .string or cursor.string.len > max_bytes) return error.InvalidListResult;
    return try alloc.dupe(u8, cursor.string);
}

fn mapCommonResultError(err: common.Error) Error {
    return switch (err) {
        error.ProtocolFailure => error.ProtocolFailure,
        error.UnsupportedResultType => error.UnsupportedResultType,
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidListResult,
    };
}

fn lessDescriptor(_: void, left: Descriptor, right: Descriptor) bool {
    const order = std.mem.order(u8, left.uri, right.uri);
    if (order != .eq) return order == .lt;
    return std.mem.lessThan(u8, left.name, right.name);
}

fn lessTemplate(_: void, left: Template, right: Template) bool {
    const order = std.mem.order(u8, left.uri_template, right.uri_template);
    if (order != .eq) return order == .lt;
    return std.mem.lessThan(u8, left.name, right.name);
}

fn freeCursors(alloc: Allocator, cursors: *std.StringHashMap(void)) void {
    var iterator = cursors.keyIterator();
    while (iterator.next()) |cursor| alloc.free(cursor.*);
    cursors.deinit();
}

fn nonNegativeU64(alloc: Allocator, value: std.json.Value) Error!?u64 {
    const parsed = json_number.fromValue(alloc, value, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (parsed == null) return null;
    var number = parsed.?;
    defer number.deinit(alloc);
    const result = number.toNonNegativeUsize() orelse return null;
    return std.math.cast(u64, result);
}

fn writeCompactJson(alloc: Allocator, writer: *std.Io.Writer, json: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    try std.json.Stringify.value(parsed.value, .{}, writer);
}

fn writeMetadata(writer: *std.Io.Writer) !void {
    try writer.writeAll("{\"io.modelcontextprotocol/related-task\":{\"taskId\":\"fx-test\"}}");
}

test "resource and template pagination publishes complete sorted snapshots" {
    const alloc = std.testing.allocator;
    var resources_builder = ResourceCatalogBuilder.init(alloc, .modern);
    defer resources_builder.deinit(alloc);
    var first = try parseResourcePage(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resources\":[{\"uri\":\"git://b\",\"name\":\"B\"}],\"nextCursor\":\"\",\"ttlMs\":100}}",
        .modern,
        .{},
    );
    defer first.deinit(alloc);
    try resources_builder.appendPage(alloc, &first, 1000, .{});
    var second = try parseResourcePage(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"resources\":[{\"uri\":\"custom://a\",\"name\":\"A\",\"annotations\":{\"audience\":[\"user\"]},\"_meta\":{\"x\":1}}],\"ttlMs\":50}}",
        .modern,
        .{},
    );
    defer second.deinit(alloc);
    try resources_builder.appendPage(alloc, &second, 1010, .{});
    var catalog = try resources_builder.finish(alloc);
    defer catalog.deinit(alloc);
    try std.testing.expectEqualStrings("custom://a", catalog.items[0].uri);
    try std.testing.expectEqual(@as(u64, 1060), catalog.expires_at_ms);

    var templates_builder = TemplateCatalogBuilder.init(alloc, .modern);
    defer templates_builder.deinit(alloc);
    var templates = try parseTemplatePage(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"resourceTemplates\":[{\"uriTemplate\":\"db:///{table}/{id}\",\"name\":\"row\"}]}}",
        .modern,
        .{},
    );
    defer templates.deinit(alloc);
    try templates_builder.appendPage(alloc, &templates, 2000, .{});
    var template_catalog = try templates_builder.finish(alloc);
    defer template_catalog.deinit(alloc);
    try std.testing.expect(templateMayResolve(template_catalog.items[0].uri_template, "db:///users/7"));
}

test "resource templates match supported RFC 6570 expansions conservatively" {
    try std.testing.expect(templateMayResolve(
        "db:///{table}/records/{id}",
        "db:///users/records/7",
    ));
    try std.testing.expect(!templateMayResolve(
        "db:///{table}/records/{id}",
        "db:///anything",
    ));
    try std.testing.expect(!templateMayResolve(
        "db:///{table}/records/{id}",
        "db:///users/record/7",
    ));

    try std.testing.expect(templateMayResolve(
        "https://example.test/{+path}",
        "https://example.test/a/b?view=full",
    ));
    try std.testing.expect(!templateMayResolve(
        "https://example.test/{path}",
        "https://example.test/a/b",
    ));
    try std.testing.expect(templateMayResolve(
        "https://example.test/{path}",
        "https://example.test/a%2Fb",
    ));
    try std.testing.expect(!templateMayResolve(
        "https://example.test/{path}",
        "https://example.test/a%2Gb",
    ));

    try std.testing.expect(templateMayResolve(
        "https://example.test/items{/id}",
        "https://example.test/items/42",
    ));
    try std.testing.expect(templateMayResolve(
        "https://example.test/search{?query}",
        "https://example.test/search?query=zig",
    ));
    try std.testing.expect(!templateMayResolve(
        "https://example.test/search{?query}",
        "https://example.test/search?other=zig",
    ));
}

test "resource template matching accepts bounded long terminal expansions" {
    const alloc = std.testing.allocator;
    const prefix = "memory://";

    const medium_len: usize = 2 * 1024;
    const medium_uri = try alloc.alloc(u8, medium_len);
    defer alloc.free(medium_uri);
    @memcpy(medium_uri[0..prefix.len], prefix);
    @memset(medium_uri[prefix.len..], 'a');
    try std.testing.expect(templateMayResolve("memory://{value}", medium_uri));

    const boundary_len = (common.Limits{}).max_uri_bytes;
    const boundary_uri = try alloc.alloc(u8, boundary_len);
    defer alloc.free(boundary_uri);
    @memcpy(boundary_uri[0..prefix.len], prefix);
    @memset(boundary_uri[prefix.len..], 'b');
    try std.testing.expect(templateMayResolve("memory://{value}", boundary_uri));

    const oversized_uri = try alloc.alloc(u8, boundary_len + 1);
    defer alloc.free(oversized_uri);
    @memcpy(oversized_uri[0..prefix.len], prefix);
    @memset(oversized_uri[prefix.len..], 'c');
    try std.testing.expect(!templateMayResolve("memory://{value}", oversized_uri));
}

test "resource template matching anchors long intervening literals" {
    const alloc = std.testing.allocator;
    const prefix = "memory://";
    const marker = "/records/";
    const left_len: usize = 16 * 1024;
    const right_len: usize = 16 * 1024;
    const uri_len = prefix.len + left_len + marker.len + right_len;

    const uri = try alloc.alloc(u8, uri_len);
    defer alloc.free(uri);
    @memcpy(uri[0..prefix.len], prefix);
    @memset(uri[prefix.len .. prefix.len + left_len], 'a');
    @memcpy(uri[prefix.len + left_len .. prefix.len + left_len + marker.len], marker);
    @memset(uri[prefix.len + left_len + marker.len ..], 'b');
    try std.testing.expect(templateMayResolve("memory://{collection}/records/{id}", uri));

    uri[prefix.len + left_len + marker.len - 1] = 'x';
    try std.testing.expect(!templateMayResolve("memory://{collection}/records/{id}", uri));
}

test "resource template matching charges repeated-prefix literal comparisons" {
    const alloc = std.testing.allocator;
    const template_prefix = "memory://{value}";
    const literal_len: usize = 32 * 1024;
    const uri_prefix = "memory://";

    const template = try alloc.alloc(u8, template_prefix.len + literal_len);
    defer alloc.free(template);
    @memcpy(template[0..template_prefix.len], template_prefix);
    @memset(template[template_prefix.len..], 'a');
    template[template.len - 1] = 'b';

    const uri = try alloc.alloc(u8, (common.Limits{}).max_uri_bytes);
    defer alloc.free(uri);
    @memcpy(uri[0..uri_prefix.len], uri_prefix);
    @memset(uri[uri_prefix.len..], 'a');

    var budget = TemplateMatchBudget.init(default_template_match_steps);
    try std.testing.expectEqual(
        TemplateMatchResult.work_limit_exceeded,
        matchTemplateWithBudget(template, uri, &budget),
    );
    try std.testing.expectEqual(@as(usize, 0), budget.remaining);
}

test "resource template matching shares one work budget across catalog candidates" {
    const alloc = std.testing.allocator;
    const template_prefix = "memory://{value}";
    const literal_len: usize = 1024;
    const uri_prefix = "memory://";
    const expansion_len: usize = 1800;

    const template = try alloc.alloc(u8, template_prefix.len + literal_len);
    defer alloc.free(template);
    @memcpy(template[0..template_prefix.len], template_prefix);
    @memset(template[template_prefix.len..], 'a');
    template[template.len - 1] = 'b';

    const uri = try alloc.alloc(u8, uri_prefix.len + expansion_len);
    defer alloc.free(uri);
    @memcpy(uri[0..uri_prefix.len], uri_prefix);
    @memset(uri[uri_prefix.len..], 'a');

    var budget = TemplateMatchBudget.init(default_template_match_steps);
    try std.testing.expectEqual(
        TemplateMatchResult.no_match,
        matchTemplateWithBudget(template, uri, &budget),
    );
    try std.testing.expect(budget.remaining > 0);
    try std.testing.expectEqual(
        TemplateMatchResult.work_limit_exceeded,
        matchTemplateWithBudget(template, uri, &budget),
    );
}

test "resource template matching rejects adjacent expressions as unsupported" {
    const uri = "memory://" ++ ("a" ** 2048) ++ "/42";
    try std.testing.expect(!templateMayResolve("memory://{prefix}{/id}", uri));
}

test "resource template matching rejects malformed long expansions and unsupported syntax" {
    const malformed = "memory://" ++ ("a" ** 2048) ++ "%GG";
    try std.testing.expect(!templateMayResolve("memory://{value}", malformed));
    try std.testing.expect(!templateMayResolve("memory://{first,second}", "memory://one,two"));
    try std.testing.expect(!templateMayResolve("memory://{value*}", "memory://one"));
}

test "resource template catalogs reject malformed and unsupported syntax" {
    const alloc = std.testing.allocator;
    const invalid_templates = [_][]const u8{
        "db:///{table",
        "db:///table}",
        "db:///{table,id}",
        "db:///{table*}",
        "db:///{table:3}",
        "db:///{table}{/id}",
        "db:///%GG/{table}",
    };
    for (invalid_templates) |uri_template| {
        var response: std.Io.Writer.Allocating = .init(alloc);
        defer response.deinit();
        try response.writer.writeAll(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resourceTemplates\":[{\"uriTemplate\":",
        );
        try std.json.Stringify.value(uri_template, .{}, &response.writer);
        try response.writer.writeAll(",\"name\":\"row\"}]}}");
        try std.testing.expectError(
            error.InvalidTemplate,
            parseTemplatePage(alloc, response.writer.buffered(), .modern, .{}),
        );
        try std.testing.expect(!templateMayResolve(uri_template, "db:///users"));
    }
}

test "resource catalog metadata enforces the shared JSON depth boundary" {
    const alloc = std.testing.allocator;
    const limits = Limits{ .common = .{ .max_json_depth = 6 } };

    var below = try parseResourcePage(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resources\":[{\"uri\":\"memory://below\",\"name\":\"below\",\"_meta\":{\"value\":1}}]}}",
        .modern,
        limits,
    );
    below.deinit(alloc);
    var at = try parseResourcePage(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"resources\":[{\"uri\":\"memory://at\",\"name\":\"at\",\"_meta\":{\"nested\":{\"value\":1}}}]}}",
        .modern,
        limits,
    );
    at.deinit(alloc);
    try std.testing.expectError(
        error.JsonDepthLimitExceeded,
        parseResourcePage(
            alloc,
            "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"resources\":[{\"uri\":\"memory://above\",\"name\":\"above\",\"_meta\":{\"nested\":{\"again\":{\"value\":1}}}}]}}",
            .modern,
            limits,
        ),
    );
}

test "resource content enforces the shared JSON depth boundary" {
    const alloc = std.testing.allocator;
    const limits = Limits{ .common = .{ .max_json_depth = 6 } };

    var below = try parseReadOutcome(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"contents\":[{\"uri\":\"memory://below\",\"text\":\"ok\",\"_meta\":{\"value\":1}}]}}",
        .modern,
        limits,
    );
    below.deinit(alloc);
    var at = try parseReadOutcome(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"contents\":[{\"uri\":\"memory://at\",\"text\":\"ok\",\"_meta\":{\"nested\":{\"value\":1}}}]}}",
        .modern,
        limits,
    );
    at.deinit(alloc);
    try std.testing.expectError(
        error.JsonDepthLimitExceeded,
        parseReadOutcome(
            alloc,
            "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"contents\":[{\"uri\":\"memory://above\",\"text\":\"no\",\"_meta\":{\"nested\":{\"again\":{\"value\":1}}}}]}}",
            .modern,
            limits,
        ),
    );
}

test "resource read preserves multiple text and blob contents" {
    const alloc = std.testing.allocator;
    var outcome = try parseReadOutcome(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{\"contents\":[{\"uri\":\"git://one\",\"mimeType\":\"text/plain\",\"text\":\"hello\"},{\"uri\":\"memory://two\",\"blob\":\"aGVsbG8=\"}],\"ttlMs\":100}}",
        .modern,
        .{},
    );
    defer outcome.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), outcome.complete.contents.len);
    try std.testing.expectError(
        error.ContentLimitExceeded,
        parseReadOutcome(
            alloc,
            "{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{\"contents\":[{\"uri\":\"git://one\",\"text\":\"hello\"}]}}",
            .modern,
            .{ .common = .{ .max_total_content_bytes = 4 } },
        ),
    );
}

test "resource read cache eligibility is derived from request provenance" {
    const alloc = std.testing.allocator;
    const response =
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"contents\":[{\"uri\":\"memory://one\",\"text\":\"input-dependent\"}],\"ttlMs\":60000}}";
    var ordinary = try parseReadOutcomeForRequest(
        alloc,
        response,
        .modern,
        .{},
        .{},
    );
    defer ordinary.deinit(alloc);
    try std.testing.expect(ordinary.complete.cache_eligible);

    var continued = try parseReadOutcomeForRequest(
        alloc,
        response,
        .modern,
        .{},
        .{ .input_responses_present = true, .request_state_present = true },
    );
    defer continued.deinit(alloc);
    try std.testing.expect(!continued.complete.cache_eligible);
}

test "resource requests preserve arbitrary URIs and exact continuation state" {
    const alloc = std.testing.allocator;
    const request = try buildReadRequest(
        alloc,
        7,
        .modern,
        "git+ssh://host/repo?ref=main#README",
        writeMetadata,
        "{\"answer\":\"yes\"}",
        "{\"opaque\":1}",
    );
    defer alloc.free(request);
    try std.testing.expect(std.mem.find(u8, request, "git+ssh://host/repo?ref=main#README") != null);
    try std.testing.expect(std.mem.find(u8, request, "\"requestState\":{\"opaque\":1}") != null);
}

test "resource stale fallback accepts only transient transport failures" {
    try std.testing.expect(staleFallbackEligible(error.ConnectionResetByPeer));
    for ([_]anyerror{
        error.McpRequestTimedOut,
        error.Cancelled,
        error.McpInputRequired,
        error.McpInputRequiredLimitExceeded,
        error.InvalidInputRequired,
        error.InvalidInputResponses,
        error.OutOfMemory,
        error.McpAuthenticationRequired,
        error.McpAuthenticationUpdated,
        error.McpRefreshRejected,
        error.McpResourceNotFound,
        error.McpResourceCatalogUnavailable,
        error.McpFeatureCatalogChanged,
        error.McpGenerationExhausted,
    }) |err| {
        try std.testing.expect(!staleFallbackEligible(err));
    }
}

fn checkResourceCatalogAllocationFailures(alloc: Allocator) !void {
    var builder = ResourceCatalogBuilder.init(alloc, .modern);
    defer builder.deinit(alloc);
    var page = try parseResourcePage(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resources\":[{\"uri\":\"custom://one\",\"name\":\"one\",\"title\":\"One\",\"description\":\"fixture\",\"mimeType\":\"text/plain\",\"icons\":[{\"src\":\"data:image/png;base64,AA==\"}],\"annotations\":{\"audience\":[\"assistant\"]},\"_meta\":{\"version\":1}}]}}",
        .modern,
        .{},
    );
    defer page.deinit(alloc);
    try builder.appendPage(alloc, &page, 1, .{});
    var catalog = try builder.finish(alloc);
    defer catalog.deinit(alloc);
}

test "resource catalog construction is allocation failure safe" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkResourceCatalogAllocationFailures,
        .{},
    );
}
