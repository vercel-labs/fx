//! The `black prism` piece from ascii.rest, rendered at its native 200 by 100
//! resolution and animated at 15 frames per second. The terminal banner packs
//! each frame into Braille cells so the whole triangle fits without scaling,
//! cropping the floor reflection and keeping the apex through the base.
//! Source: https://ascii.rest/black-prism/
//! by @bas3line, with the design idea by @satvikxs. MIT licensed; see
//! THIRD_PARTY_NOTICES.md.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const scene_cols: usize = 200;
pub const scene_rows: usize = 100;
pub const fps: u32 = 15;
pub const banner_rows: u16 = 22;

const n = scene_cols * scene_rows;
const W: f32 = @floatFromInt(scene_cols);
const H: f32 = @floatFromInt(scene_rows);
const Wf: f32 = W;
const Hf: f32 = H;
const scale: f32 = 1.36;
const top: f32 = 12;
const dots = [_][]const u8{ " ", "·", "•", "●" };
const cover = [_]f32{ 0, 0.3, 0.6, 1 };
const bayer = blk: {
    const raw = [_]u8{
        0, 8,  2, 10, 12, 4, 14, 6,
        3, 11, 1, 9,  15, 7, 13, 5,
    };
    var out: [16]f32 = undefined;
    for (raw, 0..) |v, i| out[i] = @as(f32, @floatFromInt(v)) / 16 - 0.47;
    break :blk out;
};
const palette = [_][3]u8{
    .{ 0x16, 0x16, 0x16 }, .{ 0x24, 0x24, 0x24 }, .{ 0x36, 0x36, 0x36 },
    .{ 0x4a, 0x4a, 0x4a }, .{ 0x63, 0x63, 0x63 }, .{ 0x7e, 0x7e, 0x7e },
    .{ 0x9c, 0x9c, 0x9c }, .{ 0xbc, 0xbc, 0xbc }, .{ 0xdc, 0xdc, 0xdc },
    .{ 0xff, 0xff, 0xff }, .{ 0xff, 0x2a, 0x3c }, .{ 0x9a, 0x1c, 0x28 },
    .{ 0xff, 0x74, 0x17 }, .{ 0xa0, 0x4a, 0x10 }, .{ 0xff, 0xdf, 0x2e },
    .{ 0xa0, 0x8c, 0x1c }, .{ 0x38, 0xf5, 0x6a }, .{ 0x1f, 0x9a, 0x42 },
    .{ 0x24, 0xdc, 0xff }, .{ 0x16, 0x87, 0x9e }, .{ 0x3a, 0x64, 0xff },
    .{ 0x23, 0x3f, 0x9e }, .{ 0x9a, 0x4c, 0xff }, .{ 0x5f, 0x2f, 0x9e },
    .{ 0xff, 0xf4, 0xc8 }, .{ 0xd4, 0xf6, 0xff }, .{ 0xff, 0xd2, 0xd6 },
};
const ink = [_][]const u8{
    "                               00",
    "                             000000",
    "                            00000000",
    "                           0000000000",
    "                          000000000000",
    "                         00000000000000",
    "                        0000000000000000",
    "                       000000000000000000",
    "                     0000000000000000000000",
    "                    000000000000000000000000",
    "                   00000000000000000000000000",
    "                  0000000000000000000000000000",
    "                 000000000000000000000000000000",
    "                00000000000000000000000000000000",
    "              000000000000000000000000000000000000",
    "             00000000000000000000000000000000000000",
    "            0000000000000000000000000000000000000000",
    "           000000000000000000000000000000000000000000",
    "          00000000000000000000000000000000000000000000",
    "         0000000000000000000000000000000000000000000000",
    "        000000000000000000000000000000000000000000000000",
    "      0000000000000000000000000000000000000000000000000000",
    "     000000000000000000000000000000000000000000000000000000",
    "    00000000000000000000000000000000000000000000000000000000",
    "   0000000000000000000000000000000000000000000000000000000000",
    "  000000000000000000000000000000000000000000000000000000000000",
};

const enter = 0.46;
const leave = 0.5;
const red = 0.05;
const violet = 0.4;
const dust = 700;
const bands = [_][3]f32{
    .{ 1, 0.08, 0.14 }, .{ 1, 0.42, 0.04 }, .{ 1, 0.88, 0.12 },
    .{ 0.2, 1, 0.38 },  .{ 0.12, 0.84, 1 }, .{ 0.2, 0.36, 1 },
    .{ 0.6, 0.28, 1 },
};

pub const Animation = struct {
    alloc: Allocator,
    cols: u16,
    start_ms: i64 = 0,
    frame_index: u32 = 0,
    next_frame_ms: i64 = 0,
    cov: []f32,
    rim: []f32,
    beam_d: []f32,
    beam_s: []f32,
    inner: []f32,
    ghost: []f32,
    fan_u: []f32,
    fan_r: []f32,
    sheen: []f32,
    red: []f32,
    green: []f32,
    blue: []f32,
    spark: []f32,
    dot_ids: []u8,
    color_ids: []u8,
    palette_256: [palette.len]u8,
    static_fields: StaticFields = undefined,

    pub fn init(alloc: Allocator, cols: u16) !Animation {
        var self = Animation{
            .alloc = alloc,
            .cols = cols,
            .cov = &.{},
            .rim = &.{},
            .beam_d = &.{},
            .beam_s = &.{},
            .inner = &.{},
            .ghost = &.{},
            .fan_u = &.{},
            .fan_r = &.{},
            .sheen = &.{},
            .red = &.{},
            .green = &.{},
            .blue = &.{},
            .spark = &.{},
            .dot_ids = &.{},
            .color_ids = &.{},
            .palette_256 = undefined,
        };
        errdefer self.deinit();
        self.cov = try alloc.alloc(f32, n);
        self.rim = try alloc.alloc(f32, n);
        self.beam_d = try alloc.alloc(f32, n);
        self.beam_s = try alloc.alloc(f32, n);
        self.inner = try alloc.alloc(f32, n);
        self.ghost = try alloc.alloc(f32, n);
        self.fan_u = try alloc.alloc(f32, n);
        self.fan_r = try alloc.alloc(f32, n);
        self.sheen = try alloc.alloc(f32, n);
        self.red = try alloc.alloc(f32, n);
        self.green = try alloc.alloc(f32, n);
        self.blue = try alloc.alloc(f32, n);
        self.spark = try alloc.alloc(f32, n);
        self.dot_ids = try alloc.alloc(u8, n);
        self.color_ids = try alloc.alloc(u8, n);
        self.computeStatic();
        for (palette, 0..) |p, i| {
            self.palette_256[i] = nearest256(
                @floatFromInt(p[0]),
                @floatFromInt(p[1]),
                @floatFromInt(p[2]),
            );
        }
        return self;
    }

    pub fn deinit(self: *Animation) void {
        const alloc = self.alloc;
        alloc.free(self.cov);
        alloc.free(self.rim);
        alloc.free(self.beam_d);
        alloc.free(self.beam_s);
        alloc.free(self.inner);
        alloc.free(self.ghost);
        alloc.free(self.fan_u);
        alloc.free(self.fan_r);
        alloc.free(self.sheen);
        alloc.free(self.red);
        alloc.free(self.green);
        alloc.free(self.blue);
        alloc.free(self.spark);
        alloc.free(self.dot_ids);
        alloc.free(self.color_ids);
    }

    pub fn start(self: *Animation, now_ms: i64) void {
        self.start_ms = now_ms;
        self.frame_index = 0;
        self.next_frame_ms = now_ms + frame_interval_ms();
    }

    pub fn nextFrame(self: *Animation, alloc: Allocator, now_ms: i64) !?[]u8 {
        if (self.start_ms == 0) self.start(now_ms);
        if (now_ms < self.next_frame_ms) return null;
        const elapsed = now_ms - self.start_ms;
        const next_index: u32 = @intCast(@max(0, @divFloor(elapsed * @as(i64, fps), 1000)));
        self.frame_index = next_index;
        const next_ms = self.start_ms + @divFloor(@as(i64, next_index + 1) * 1000, fps);
        self.next_frame_ms = @max(next_ms, now_ms + 1);
        return try self.renderFrame(alloc, @as(f32, @floatFromInt(next_index)) / @as(f32, fps));
    }

    pub fn renderFrame(self: *Animation, alloc: Allocator, t: f32) ![]u8 {
        self.computeFrame(t);
        return try self.renderBraille(alloc);
    }

    fn computeStatic(self: *Animation) void {
        const gh = ink.len;
        var gw: usize = 0;
        for (ink) |line| gw = @max(gw, line.len);
        var c0: usize = gw;
        var c1: usize = 0;
        for (ink, 0..) |line, r| {
            _ = r;
            for (line, 0..) |ch, c| {
                if (ch != ' ') {
                    c0 = @min(c0, c);
                    c1 = @max(c1, c);
                }
            }
        }
        const left = W / 2 - ((@as(f32, @floatFromInt(c1 + 1 - c0)) * scale) / 2);
        const base = top + @as(f32, @floatFromInt(gh)) * 2 * scale;
        const floor = @as(usize, @intFromFloat(@round(base)));
        const ax = W / 2;
        const ay = top;
        const lx = left;
        const rx = W - left;
        const by = base;
        const ex = mix(ax, lx, enter);
        const ey = mix(ay, by, enter);
        const xx = mix(ax, rx, leave);
        const xy = mix(ay, by, leave);
        const sx: f32 = -4;
        const sy = ey + 21;
        const bx = mix(ex, xx, 0.62);
        const bby = by - 1;

        for (0..scene_rows) |r| {
            for (0..scene_cols) |x| {
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                const py = @as(f32, @floatFromInt(r)) + 0.5;
                var s: f32 = 0;
                var j: i32 = -1;
                while (j <= 1) : (j += 1) {
                    var i: i32 = -1;
                    while (i <= 1) : (i += 1) {
                        const off_x = @as(f32, @floatFromInt(i)) * 0.9;
                        const off_y = @as(f32, @floatFromInt(j)) * 1.1;
                        const ggx = @as(f32, @floatFromInt(c0)) + ((px + off_x) - left) / scale;
                        const ggy = ((py + off_y) - top) / (2 * scale);
                        s += bilinear_fn(gw, gh, ggx, ggy);
                    }
                }
                self.cov[r * scene_cols + x] = smooth(0.38, 0.62, s / 9);
            }
        }

        for (1..scene_rows - 1) |r| {
            for (1..scene_cols - 1) |x| {
                const k = r * scene_cols + x;
                const gx = self.cov[k + 1] - self.cov[k - 1];
                const gy = self.cov[k + scene_cols] - self.cov[k - scene_cols];
                self.rim[k] = clamp01(@sqrt(gx * gx + gy * gy) * 1.25);
            }
        }

        const beam_len = @sqrt((ex - sx) * (ex - sx) + (ey - sy) * (ey - sy));
        for (0..scene_rows) |r| {
            for (0..scene_cols) |x| {
                const k = r * scene_cols + x;
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                const py = @as(f32, @floatFromInt(r)) + 0.5;
                const b = seg(px, py, sx, sy, ex, ey);
                self.beam_d[k] = b.d;
                self.beam_s[k] = b.s * beam_len;
                const di = seg(px, py, ex, ey, xx, xy);
                self.inner[k] = @exp(-pow2(di.d / (1 + di.s * 0.8)));
                const d1 = seg(px, py, ex, ey, bx, bby);
                const d2 = seg(px, py, bx, bby, xx + 2, xy + 9);
                self.ghost[k] = @exp(-pow2(@min(d1.d, d2.d) / 0.8));
                const dl = ((px - ax) * (by - ay) + (py - ay) * (ax - lx)) / @sqrt(pow2(by - ay) + pow2(ax - lx));
                const dr = ((rx - ax) * (py - ay) - (px - ax) * (by - ay)) / @sqrt(pow2(by - ay) + pow2(rx - ax));
                const db = by - py;
                const edge = @min(@min(dl, dr), db);
                const up = smooth(by, ay + 10, py);
                const echo = @exp(-pow2((dl - 6) / 0.8)) + 0.6 * @exp(-pow2((dr - 6) / 0.8));
                self.sheen[k] = @exp(-edge / 1.4) * 0.07 + echo * up * 0.16 + @exp(-pow2((db - 5) / 0.8)) * 0.06;
                const fx = px - xx;
                const fy = py - xy;
                if (fx > -2 and py < @as(f32, @floatFromInt(floor))) {
                    const a = std.math.atan2(fy, fx);
                    self.fan_u[k] = (a - red) / (violet - red);
                    self.fan_r[k] = @sqrt(fx * fx + fy * fy);
                } else {
                    self.fan_u[k] = -1;
                    self.fan_r[k] = 0;
                }
            }
        }

        // Constants the frame loop reuses.
        self.static_fields = .{
            .ax = ax,
            .ay = ay,
            .lx = lx,
            .rx = rx,
            .by = by,
            .ex = ex,
            .ey = ey,
            .xx = xx,
            .xy = xy,
            .sx = sx,
            .sy = sy,
            .bx = bx,
            .bby = bby,
            .floor = floor,
        };
    }

    fn computeFrame(self: *Animation, t: f32) void {
        const ax = self.static_fields.ax;
        const ax_ = self.static_fields;
        const pulse = 0.84 + 0.16 * @sin(t * 1.6);
        @memset(self.spark, 0);

        var mote: usize = 0;
        while (mote < dust) : (mote += 1) {
            const i: u32 = @intCast(mote);
            const mx = hash(@intCast(i), 1) * W;
            const my = hash(@intCast(i), 2) * @as(f32, @floatFromInt(ax_.floor));
            const vx = 0.6 + hash(@intCast(i), 3) * 2.4;
            const vy = (hash(@intCast(i), 4) - 0.5) * 1.2;
            const ph = hash(@intCast(i), 5) * 6.28;
            const tw = 1 + hash(@intCast(i), 6) * 3;
            const x = wrap(mx + vx * t + 2 * @sin(t * 0.4 + ph), W);
            const y = wrap(my + vy * t + 1.5 * @sin(t * 0.3 + ph * 2), @as(f32, @floatFromInt(ax_.floor)));
            const kk = @as(usize, @intFromFloat(@floor(y))) * scene_cols + @as(usize, @intFromFloat(@floor(x)));
            self.spark[kk] = @max(self.spark[kk], std.math.pow(f32, 0.5 + 0.5 * @sin(t * tw + ph), 3));
        }

        for (0..scene_rows) |r| {
            for (0..scene_cols) |x| {
                const k = r * scene_cols + x;
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                const py = @as(f32, @floatFromInt(r)) + 0.5;
                var cr: f32 = 0;
                var cg: f32 = 0;
                var cb: f32 = 0;
                var floor_value: f32 = 0;

                if (r >= ax_.floor) {
                    const below = r - ax_.floor;
                    const m = (ax_.floor - 1 - below) * scene_cols;
                    const wob = @as(i32, @intFromFloat(@round(0.7 * @sin(@as(f32, @floatFromInt(r)) * 1.7 + t * 2))));
                    const x0 = clampInt(@as(i32, @intCast(x)) - 1 + wob, 0, scene_cols - 1);
                    const x1 = clampInt(@as(i32, @intCast(x)) + 1 + wob, 0, scene_cols - 1);
                    const xc = clampInt(@as(i32, @intCast(x)) + wob, 0, scene_cols - 1);
                    const fall = 0.6 * @exp(-@as(f32, @floatFromInt(below)) / 10);
                    cr = (self.red[m + x0] + 2 * self.red[m + xc] + self.red[m + x1]) * 0.25 * fall;
                    cg = (self.green[m + x0] + 2 * self.green[m + xc] + self.green[m + x1]) * 0.25 * fall;
                    cb = (self.blue[m + x0] + 2 * self.blue[m + xc] + self.blue[m + x1]) * 0.25 * fall;
                    if (below == 0) {
                        const h = 0.1 + 0.25 * @exp(-pow2((px - ax) / 60));
                        cr += h;
                        cg += h;
                        cb += h;
                    }
                    if (px > ax_.xx) {
                        const u = clamp01((px - ax_.xx) / (W - ax_.xx));
                        const s = spectrum(0.55 + 0.45 * u);
                        const spill = 0.13 * smooth(0, 0.25, u) * @exp(-@as(f32, @floatFromInt(below)) / 4) * pulse;
                        cr += s[0] * spill;
                        cg += s[1] * spill;
                        cb += s[2] * spill;
                    }
                    floor_value = 0;
                } else {
                    const c = self.cov[k];
                    var lr: f32 = 0;
                    var lg: f32 = 0;
                    var lb: f32 = 0;

                    const bd = self.beam_d[k];
                    if (bd < 30) {
                        const wave = 0.85 + 0.15 * @sin(self.beam_s[k] * 0.16 - t * 7);
                        const core = @exp(-pow2(bd / 1.45)) * 1.3 * pulse * wave;
                        const halo = @exp(-bd / 2.2) * 0.3 * pulse;
                        const v = (core + halo) * smooth(0, 6, self.beam_s[k]) * (1 - c * 0.9);
                        lr += v;
                        lg += v;
                        lb += v * 1.02;
                    }

                    const u = self.fan_u[k];
                    if (u > -0.3 and u < 1.3 and c < 0.9) {
                        const d = self.fan_r[k];
                        const band = smooth(-0.05, 0.04, u) * smooth(1.05, 0.96, u);
                        if (band > 0) {
                            const s = spectrum(u);
                            const shimmer = 0.82 + 0.18 * noise(u * 16 + t * 0.5, d * 0.05 - t * 0.9) + 0.08 * @sin(d * 0.32 - t * 5 + u * 4);
                            const v = band * shimmer * pulse * (0.75 + 0.35 * @exp(-d / 30)) * smooth(0, 4, d) * (1 - c);
                            lr += s[0] * v;
                            lg += s[1] * v;
                            lb += s[2] * v;
                        }
                        const edge = @exp(-@max(0, @max(-u, u - 1)) * 12) * (1 - band) * 0.12 * smooth(0, 10, self.fan_r[k]) * (1 - c);
                        const s2 = spectrum(u);
                        lr += s2[0] * edge;
                        lg += s2[1] * edge;
                        lb += s2[2] * edge;
                    }

                    const de = @sqrt(pow2(px - ax_.ex) + pow2(py - ax_.ey));
                    const dx = @sqrt(pow2(px - ax_.xx) + pow2(py - ax_.xy));
                    const spot = (@exp(-de / 2.2) * 1.1 + @exp(-de / 7) * 0.08) * pulse;
                    lr += spot;
                    lg += spot;
                    lb += spot;
                    const exit = (@exp(-dx / 2) * 0.7 + @exp(-dx / 7) * 0.08) * pulse;
                    lr += exit;
                    lg += exit * 0.97;
                    lb += exit * 0.95;

                    const lp = @max(@max(lr, lg), lb);
                    if (self.spark[k] > 0 and lp > 0.02) {
                        const s = self.spark[k] * @min(1, lp * 4) * 1.4;
                        const inv = 1 / @max(lp, 1e-3);
                        cr += s * (0.5 + 0.5 * lr * inv);
                        cg += s * (0.5 + 0.5 * lg * inv);
                        cb += s * (0.5 + 0.5 * lb * inv);
                    }
                    cr += lr;
                    cg += lg;
                    cb += lb;

                    if (c > 0.01) {
                        const py_frac = (py - ax_.ay) / (ax_.by - ax_.ay);
                        const drift = 0.5 + 0.5 * @sin(t * 0.5 + (@as(f32, @floatFromInt(x)) - @as(f32, @floatFromInt(r))) * 0.04);
                        var g = 0.012 * py_frac + self.sheen[k] * (0.5 + 0.5 * drift);
                        g += self.inner[k] * 0.55 * pulse + self.ghost[k] * 0.08;
                        const tint = smooth(0.4, 1, (px - ax_.ex) / (ax_.xx - ax_.ex)) * self.inner[k] * 0.25;
                        cr += c * (g + tint * 0.3);
                        cg += c * (g + tint * 0.15);
                        cb += c * (g + tint * 0.45);
                    }

                    const e = self.rim[k];
                    if (e > 0.02) {
                        const near = @exp(-de / 16) * 0.5 + @exp(-dx / 16) * 0.35;
                        const top_spot = @exp(-@sqrt(pow2(px - ax_.ax) + pow2(py - ax_.ay)) / 10) * 0.25;
                        const v = e * (0.62 + near * pulse + top_spot);
                        cr += v;
                        cg += v;
                        cb += v;
                    }
                }

                self.red[k] = cr;
                self.green[k] = cg;
                self.blue[k] = cb;

                const peak = @max(@max(cr, cg), @max(cb, 1e-4));
                const level = clamp01(floor_value + (1 - floor_value) * std.math.pow(f32, peak, 0.85) * 0.95);
                const step = clampInt(@as(i32, @intFromFloat(@round(level * 3 + bayer[(r & 3) * 4 + (x & 3)]))), 0, 3);
                self.dot_ids[k] = @intCast(step);
                if (step != 0) {
                    const want = @min(1, (level + 0.06) / cover[@intCast(step)]);
                    const s = (0.3 + 0.7 * want) / peak;
                    self.color_ids[k] = nearest(clamp01(cr * s), clamp01(cg * s), clamp01(cb * s));
                } else {
                    self.color_ids[k] = 0;
                }
            }
        }
    }

    fn renderBraille(self: *Animation, alloc: Allocator) ![]u8 {
        const braille_cols = scene_cols / 2;
        const out_cols: usize = @min(@as(usize, if (self.cols == 0) 80 else self.cols), braille_cols);
        const start_col = (braille_cols - out_cols) / 2;
        const start_scene_row: usize = 12;
        const end_scene_row = scene_rows;
        const out_rows: usize = @min(@as(usize, banner_rows), (end_scene_row - start_scene_row + 3) / 4);
        const braille_bits = [4][2]u8{
            .{ 0x01, 0x04 },
            .{ 0x02, 0x10 },
            .{ 0x04, 0x20 },
            .{ 0x40, 0x80 },
        };

        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        for (0..out_rows) |row| {
            var current_fg: i16 = -1;
            for (0..out_cols) |col| {
                const braille_x = start_col + col;
                const scene_x = braille_x * 2;
                const scene_y = start_scene_row + row * 4;
                var bits: u8 = 0;
                var best_dot: u8 = 0;
                var color: u8 = 0;
                for (0..4) |dy| {
                    for (0..2) |dx| {
                        const y = scene_y + dy;
                        const x = scene_x + dx;
                        if (y >= end_scene_row or x >= scene_cols) continue;
                        const k = y * scene_cols + x;
                        const dot = self.dot_ids[k];
                        if (dot == 0) continue;
                        bits |= braille_bits[dy][dx];
                        if (dot > best_dot) {
                            best_dot = dot;
                            color = self.color_ids[k];
                        }
                    }
                }
                if (bits == 0) {
                    try out.writer.writeByte(' ');
                    continue;
                }
                const fg = self.palette_256[color];
                if (current_fg != @as(i16, @intCast(fg))) {
                    try out.writer.print("\x1b[38;5;{d}m", .{fg});
                    current_fg = @intCast(fg);
                }
                var encoded: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(@as(u21, 0x2800) + @as(u21, bits), &encoded) catch 0;
                try out.writer.writeAll(encoded[0..len]);
            }
            try out.writer.writeAll("\x1b[0m\n");
        }
        return try out.toOwnedSlice();
    }

    const StaticFields = struct {
        ax: f32,
        ay: f32,
        lx: f32,
        rx: f32,
        by: f32,
        ex: f32,
        ey: f32,
        xx: f32,
        xy: f32,
        sx: f32,
        sy: f32,
        bx: f32,
        bby: f32,
        floor: usize,
    };
};

fn clamp01(v: f32) f32 {
    return if (v < 0) 0 else if (v > 1) 1 else v;
}

fn smooth(a: f32, b: f32, v: f32) f32 {
    const k = clamp01((v - a) / (b - a));
    return k * k * (3 - 2 * k);
}

fn mix(a: f32, b: f32, k: f32) f32 {
    return a + (b - a) * k;
}

fn pow2(v: f32) f32 {
    return v * v;
}

fn wrap(v: f32, m: f32) f32 {
    return v - @floor(v / m) * m;
}

fn clampInt(v: i32, lo: usize, hi: usize) usize {
    if (v < 0) return lo;
    const uv: usize = @intCast(v);
    if (uv < lo) return lo;
    if (uv > hi) return hi;
    return uv;
}

const Seg = struct { d: f32, s: f32 };

fn seg(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32) Seg {
    const dx = bx - ax;
    const dy = by - ay;
    const s = clamp01(((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy));
    const ex = ax + dx * s - px;
    const ey = ay + dy * s - py;
    return .{ .d = @sqrt(ex * ex + ey * ey), .s = s };
}

fn hash(x: i32, y: i32) f32 {
    const ux: u32 = @bitCast(x);
    const uy: u32 = @bitCast(y);
    var h: u32 = ux *% 374761393 +% uy *% 668265263;
    h = (h ^ (h >> 13)) *% 1274126177;
    h ^= h >> 16;
    return @as(f32, @floatFromInt(h)) / 4294967296.0;
}

fn noise(x: f32, y: f32) f32 {
    const xi = @floor(x);
    const yi = @floor(y);
    const fx = x - xi;
    const fy = y - yi;
    const u = fx * fx * (3 - 2 * fx);
    const v = fy * fy * (3 - 2 * fy);
    const ix: i32 = @intFromFloat(xi);
    const iy: i32 = @intFromFloat(yi);
    const a = hash(ix, iy);
    const b = hash(ix + 1, iy);
    const c = hash(ix, iy + 1);
    const d = hash(ix + 1, iy + 1);
    return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v;
}

fn spectrum(u: f32) [3]f32 {
    const f = clamp01(u) * @as(f32, @floatFromInt(bands.len - 1));
    const i: usize = @intFromFloat(@min(@floor(f), @as(f32, @floatFromInt(bands.len - 2))));
    const k = f - @as(f32, @floatFromInt(i));
    const a = bands[i];
    const b = bands[i + 1];
    return .{
        mix(a[0], b[0], k),
        mix(a[1], b[1], k),
        mix(a[2], b[2], k),
    };
}

fn nearest(r: f32, g: f32, b: f32) u8 {
    var best: u8 = 0;
    var best_distance: f32 = 1e9;
    for (palette, 0..) |p, i| {
        const dr = @as(f32, @floatFromInt(p[0])) / 255 - r;
        const dg = @as(f32, @floatFromInt(p[1])) / 255 - g;
        const db = @as(f32, @floatFromInt(p[2])) / 255 - b;
        const d = 0.3 * dr * dr + 0.5 * dg * dg + 0.2 * db * db;
        if (d < best_distance) {
            best_distance = d;
            best = @intCast(i);
        }
    }
    return best;
}

fn nearest256(r: f32, g: f32, b: f32) u8 {
    // r, g, b are 0..255 floats. Use the xterm cube and grayscale ramp.
    const levels = [_]u8{ 0, 95, 135, 175, 215, 255 };
    var best: u8 = 0;
    var best_distance: f32 = 1e9;
    for (levels, 0..) |lr, ri| {
        for (levels, 0..) |lg, gi| {
            for (levels, 0..) |lb, bi| {
                const dr = @as(f32, @floatFromInt(lr)) - r;
                const dg = @as(f32, @floatFromInt(lg)) - g;
                const db = @as(f32, @floatFromInt(lb)) - b;
                const d = dr * dr + dg * dg + db * db;
                if (d < best_distance) {
                    best_distance = d;
                    best = @intCast(16 + 36 * ri + 6 * gi + bi);
                }
            }
        }
    }
    var k: usize = 0;
    while (k < 24) : (k += 1) {
        const v = @as(f32, @floatFromInt(8 + 10 * k));
        const dr = v - r;
        const dg = v - g;
        const db = v - b;
        const d = dr * dr + dg * dg + db * db;
        if (d < best_distance) {
            best_distance = d;
            best = @intCast(232 + k);
        }
    }
    return best;
}

fn at_ink_fn(gw: usize, gh: usize, c: i32, r: i32) f32 {
    if (r < 0 or r >= @as(i32, @intCast(gh)) or c < 0 or c >= @as(i32, @intCast(gw))) return 0;
    const line = ink[@intCast(r)];
    const cc: usize = @intCast(c);
    if (cc >= line.len) return 0;
    return if (line[cc] != ' ') 1 else 0;
}

fn bilinear_fn(gw: usize, gh: usize, gx: f32, gy: f32) f32 {
    const x = gx - 0.5;
    const y = gy - 0.5;
    const xi = @floor(x);
    const yi = @floor(y);
    const fx = x - xi;
    const fy = y - yi;
    const x0: i32 = @intFromFloat(xi);
    const y0: i32 = @intFromFloat(yi);
    const a = at_ink_fn(gw, gh, x0, y0);
    const b = at_ink_fn(gw, gh, x0 + 1, y0);
    const c = at_ink_fn(gw, gh, x0, y0 + 1);
    const d = at_ink_fn(gw, gh, x0 + 1, y0 + 1);
    return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy;
}

pub fn renderStill(alloc: Allocator, cols: u16, t: f32) ![]u8 {
    var anim = try Animation.init(alloc, cols);
    defer anim.deinit();
    return anim.renderFrame(alloc, t);
}

pub fn frame_interval_ms() i64 {
    return @divFloor(1000, @as(i64, fps));
}
