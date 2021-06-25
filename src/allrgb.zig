const std = @import("std");
const fs = std.fs;
const log = std.log;
const allocator = std.heap.c_allocator;

const c = @import("c.zig");

// Consts
const rgb_space: usize = 16777216;
const conflict_lookup = [_][7]u8{
    [_]u8{ 1, 4, 5, 2, 3, 6, 7 },
    [_]u8{ 0, 5, 4, 3, 2, 7, 6 },
    [_]u8{ 3, 6, 7, 0, 1, 4, 5 },
    [_]u8{ 2, 7, 6, 1, 0, 5, 4 },
    [_]u8{ 5, 0, 1, 6, 7, 2, 3 },
    [_]u8{ 4, 1, 0, 7, 6, 3, 2 },
    [_]u8{ 7, 2, 3, 4, 5, 0, 1 },
    [_]u8{ 6, 3, 2, 5, 4, 1, 0 },
};

// Structs
const Octree = struct {
    refs: usize,
    children: [8]?*Octree,
};

const Image = struct {
    nchannels: u32,
    pngcolortype: c.LodePNGColorType,
    bitdepth: c_uint,
    w: c_uint = undefined,
    h: c_uint = undefined,
    data: ?[*]u8 = undefined,
};

const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,

    pub fn getStep(self: *Color, i: u3) u8 {
        const mask: u8 = std.math.pow(u8, 2, i);

        return (((self.r & mask) >> i) << 2) +
            (((self.g & mask) >> i) << 1) +
            ((self.b & mask) >> i);
    }

    pub fn setStep(self: *Color, step: u8, i: u3) void {
        const mask = @intCast(u8, 1) << i;

        // red
        const r_bit = ((step & 4) >> 2);
        if (r_bit == 1) { // set
            self.r |= mask;
        } else { // clear
            self.r &= ~mask;
        }

        // green
        const g_bit = ((step & 2) >> 1);
        if (g_bit == 1) { // set
            self.g |= mask;
        } else { // clear
            self.g &= ~mask;
        }

        // blue
        const b_bit = (step & 1);
        if (b_bit == 1) { // set
            self.b |= mask;
        } else { // clear
            self.b &= ~mask;
        }
    }
};

fn fillTree(n: *Octree, cnt: usize, allocator_inner: *std.mem.Allocator) void {
    const next_cnt: usize = cnt / 8;

    var new_nodes: []Octree = allocator_inner.alloc(Octree, 8) catch {
        log.crit("Alloc error", .{});
        return;
    };

    var i: u8 = 0;
    while (i < 8) : (i += 1) {
        new_nodes[i].refs = next_cnt;
        new_nodes[i].children = [8]?*Octree{ null, null, null, null, null, null, null, null };

        n.children[i] = &new_nodes[i];
        if (next_cnt > 0)
            fillTree(&new_nodes[i], next_cnt, allocator_inner);
    }
}

fn loadImage(filename: [*:0]const u8) Image {
    var img = Image{
        .nchannels = 4,
        .pngcolortype = c.LodePNGColorType.LCT_RGBA,
        .bitdepth = 8,
    };
    if (c.lodepng_decode_file(&img.data, &img.w, &img.h, filename, img.pngcolortype, img.bitdepth) != 0) {
        log.err("Can't load the image {s}.", .{filename});
        std.process.exit(1);
    }
    log.info("Loaded {}x{} image with {} channels", .{ img.w, img.h, img.nchannels });
    if (img.w * img.h > rgb_space) {
        log.err("The image has more pixels than the RGB space: {} > {}.", .{ img.w * img.h, rgb_space });
        std.process.exit(1);
    } else if (img.w * img.h < rgb_space) {
        log.warn("The image has less pixels than the RGB space: {} < {}.", .{ img.w * img.h, rgb_space });
    }

    return img;
}

fn genIndexPermutation(color_n: u32, do_random: bool) []u32 {
    // prepare shuffled indexes
    var indexes = allocator.alloc(u32, color_n) catch {
        log.crit("Memory alloc for indexes failed.", .{});
        std.process.exit(1);
    };

    var i: u32 = 0;
    while (i < indexes.len) : (i += 1)
        indexes[i] = i;
    if (do_random) {
        // random number generator
        var prng = std.rand.DefaultPrng.init(blk: {
            var seed: u64 = undefined;
            std.os.getrandom(std.mem.asBytes(&seed)) catch {
                log.crit("Os getRandom failed.", .{});
                std.process.exit(1);
            };
            break :blk seed;
        });
        const rand = &prng.random;

        // shuffle
        i = 0;
        while (i < indexes.len - 1) : (i += 1) {
            const new_i: u32 = rand.intRangeLessThan(u32, i + 1, @intCast(u32, indexes.len));
            const temp: u32 = indexes[i];
            indexes[i] = indexes[new_i];
            indexes[new_i] = temp;
        }
        log.info("Shuffled indexes", .{});
    }

    return indexes;
}

fn getColorConflict0(curr_node: *Octree, sel_i: *u8, sel: **Octree) bool {
    var found: bool = false;
    const lookup_array: [7]u8 = conflict_lookup[sel_i.*];

    var j: u8 = 0;
    while (j < 8) : (j += 1) {
        sel_i.* = lookup_array[j];
        sel.* = curr_node.children[sel_i.*].?;
        if (sel.*.refs > 0) {
            found = true;
            break;
        }
    }

    return found;
}

fn redmean(c1: *Color, c2: *Color) f32 {
    const c1r: f32 = @intToFloat(f32, c1.r);
    const c1g: f32 = @intToFloat(f32, c1.g);
    const c1b: f32 = @intToFloat(f32, c1.b);
    const c2r: f32 = @intToFloat(f32, c2.r);
    const c2g: f32 = @intToFloat(f32, c2.g);
    const c2b: f32 = @intToFloat(f32, c2.b);

    const rm: f32 = (c1r + c2r) / 2;
    return std.math.sqrt((2 + rm / 256) * std.math.pow(f32, c2r - c1r, 2) +
        4 * std.math.pow(f32, c2g - c1g, 2) +
        (2 + (255 - rm) / 256) * std.math.pow(f32, c2b - c1b, 2));
}

fn getColorConflict1(curr_node: *Octree, color: *Color, i: u3, sel_i: *u8, sel: **Octree) bool {
    var color_copy: Color = color.*;
    var best_dist: ?f32 = null;

    var found: bool = false;
    var j: u8 = 0;
    while (j < 8) : (j += 1) {
        const child = curr_node.children[j].?;
        if (child.refs <= 0) continue;

        color_copy.setStep(j, i);
        const child_dist = redmean(color, &color_copy);

        if (best_dist == null or best_dist.? > child_dist) {
            found = true;
            best_dist = child_dist;
            sel_i.* = j;
            sel.* = child;
        }
    }

    return found;
}

fn getColor(root: *Octree, color: *Color, algorithm: i32) Color {
    var curr_node: *Octree = root;
    var ret = Color{ .a = color.a };

    var i: i8 = 7;
    while (i >= 0) : (i -= 1) {
        if (curr_node.refs <= 0) {
            log.emerg("Color selection selected a repeated color. Aborting.", .{});
            std.process.exit(1);
        }
        curr_node.refs -= 1;

        var sel_i = color.getStep(@intCast(u3, i));
        var sel: *Octree = curr_node.children[sel_i].?;

        if (sel.refs <= 0) {
            switch (algorithm) {
                0 => {
                    if (!getColorConflict0(curr_node, &sel_i, &sel))
                        log.crit("Something went wrong while selecting colors: no available colors. Will repeat a color.", .{});
                },
                1 => {
                    if (!getColorConflict1(curr_node, color, @intCast(u3, i), &sel_i, &sel))
                        log.crit("Something went wrong while selecting colors: no available colors. Will repeat a color.", .{});
                },
                else => {
                    log.emerg("Unknown algorithm.", .{});
                    std.process.exit(1);
                },
            }
        }

        ret.setStep(sel_i, @intCast(u3, i));
        curr_node = sel;
    }

    return ret;
}

fn convertImg(img: *Image, do_random: bool, algorithm: i32) void {
    // prepare octree
    // TODO lazy allocations?
    var root_node = Octree{
        .refs = rgb_space,
        .children = [8]?*Octree{ null, null, null, null, null, null, null, null },
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    fillTree(&root_node, rgb_space, &arena.allocator);
    log.info("Tree is done", .{});

    // prepare shuffled indexes
    const indexes = genIndexPermutation(img.w * img.h, do_random);
    defer allocator.free(indexes);

    // convert image
    var i: u32 = 0;
    while (i < indexes.len) : (i += 1) {
        const ind: u32 = indexes[i] * img.nchannels;

        var color = Color{
            .r = img.data.?[ind],
            .g = img.data.?[ind + 1],
            .b = img.data.?[ind + 2],
            .a = img.data.?[ind + 3], // ignored
        };

        color = getColor(&root_node, &color, algorithm);

        img.data.?[ind] = color.r;
        img.data.?[ind + 1] = color.g;
        img.data.?[ind + 2] = color.b;
        img.data.?[ind + 3] = color.a;
    }

    log.info("Used {} different colors", .{rgb_space - root_node.refs});
}

fn usage() void {
    log.info("./allrgb [--no_random] [-o <out.png>] <filename.png>", .{});
    std.process.exit(1);
}

pub fn main() !void {
    const proc_args = try std.process.argsAlloc(allocator);
    const args = proc_args[1..];
    if (args.len == 0) usage();

    var filename: ?[*:0]const u8 = null;
    var outfile: [*:0]const u8 = "out.png";
    var do_random: bool = true;
    var algorithm: i32 = 0;

    var arg_i: usize = 0;
    while (arg_i < args.len) : (arg_i += 1) {
        const arg = args[arg_i];
        if (std.mem.eql(u8, arg, "--no_random")) {
            do_random = false;
        } else if (std.mem.eql(u8, arg, "-o")) {
            arg_i += 1;
            outfile = args[arg_i];
        } else if (std.mem.eql(u8, arg, "--slow")) {
            algorithm = 1;
        } else {
            filename = arg;
        }
    }

    if (filename == null) usage();

    // load image
    var img = loadImage(filename.?);

    convertImg(&img, do_random, algorithm);
    log.info("Image is converted. Writting...", .{});

    if (c.lodepng_encode_file(outfile, img.data, img.w, img.h, img.pngcolortype, img.bitdepth) != 0) {
        log.crit("Failed to write img", .{});
    }
}
