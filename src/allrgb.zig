const std = @import("std");
const fs = std.fs;
const log = std.log;
const allocator = std.heap.c_allocator;

const c = @import("c.zig");

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

const rgb_space: usize = 16777216;
const conflict_lookup = [_][8]u8{
    [_]u8{ 0, 1, 4, 5, 2, 3, 6, 7 },
    [_]u8{ 1, 0, 5, 4, 3, 2, 7, 6 },
    [_]u8{ 2, 3, 6, 7, 0, 1, 4, 5 },
    [_]u8{ 3, 2, 7, 6, 1, 0, 5, 4 },
    [_]u8{ 4, 5, 0, 1, 6, 7, 2, 3 },
    [_]u8{ 5, 4, 1, 0, 7, 6, 3, 2 },
    [_]u8{ 6, 7, 2, 3, 4, 5, 0, 1 },
    [_]u8{ 7, 6, 3, 2, 5, 4, 1, 0 },
};

fn fillTree(n: *Octree, cnt: usize, allocator_inner: *std.mem.Allocator) void {
    const next_cnt: usize = cnt / 8;

    var new_nodes: []Octree = allocator_inner.alloc(Octree, 8) catch {
        log.err("Alloc error", .{});
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

fn getColor(root: *Octree, r: u8, g: u8, b: u8) u32 {
    var curr_node: *Octree = root;
    var ret: u32 = 0;

    var i: i8 = 7;
    while (i >= 0) : (i -= 1) {
        curr_node.refs -= 1;

        const mask: u8 = std.math.pow(u8, 2, @intCast(u8, i));
        var sel_i: u32 = (((r & mask) >> @intCast(u3, i)) << 2) +
            (((g & mask) >> @intCast(u3, i)) << 1) +
            ((b & mask) >> @intCast(u3, i));

        var sel: *Octree = curr_node.children[sel_i].?;

        if (sel.refs <= 0) { // TODO better algorithm for dealing with conflicts
            const lookup_array: [8]u8 = conflict_lookup[sel_i];

            var j: u8 = 0;
            while (j < 8) : (j += 1) {
                sel_i = lookup_array[j];
                sel = curr_node.children[sel_i].?;
                if (sel.refs > 0) {
                    break;
                }
            }
        }

        // we always reach this
        const new_r: u32 = (((sel_i & 4) >> 2) << @intCast(u5, i));
        const new_g: u32 = (((sel_i & 2) >> 1) << @intCast(u5, i));
        const new_b: u32 = ((sel_i & 1) << @intCast(u5, i));

        ret += (new_r << 16) + (new_g << 8) + new_b;
        curr_node = sel;
    }

    return ret;
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
        log.err("Memory alloc for indexes failed.", .{});
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
                log.err("Os getRandom failed.", .{});
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

fn convertImg(img: *Image, do_random: bool) void {
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

        const r: u8 = img.data.?[ind];
        const g: u8 = img.data.?[ind + 1];
        const b: u8 = img.data.?[ind + 2];
        const a: u8 = img.data.?[ind + 3]; // ignored

        const new_color: u32 = getColor(&root_node, r, g, b);

        img.data.?[ind] = @intCast(u8, (new_color >> 16) & 255);
        img.data.?[ind + 1] = @intCast(u8, (new_color >> 8) & 255);
        img.data.?[ind + 2] = @intCast(u8, (new_color) & 255);
        img.data.?[ind + 3] = a;
    }
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

    var arg_i: usize = 0;
    while (arg_i < args.len) : (arg_i += 1) {
        const arg = args[arg_i];
        if (std.mem.eql(u8, arg, "--no_random")) {
            do_random = false;
        } else if (std.mem.eql(u8, arg, "-o")) {
            arg_i += 1;
            outfile = args[arg_i];
        } else {
            filename = arg;
        }
    }

    if (filename == null) usage();

    // load image
    var img = loadImage(filename.?);

    convertImg(&img, do_random);
    log.info("Image is converted. Writting...", .{});

    if (c.lodepng_encode_file(outfile, img.data, img.w, img.h, img.pngcolortype, img.bitdepth) != 0) {
        log.err("Failed to write img", .{});
    }
}
