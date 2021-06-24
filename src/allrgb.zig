const std = @import("std");
const c = @import("c.zig");
const log = std.log;

const Octree = struct {
    refs: usize,
    children: [8]?*Octree,
};

const conflict_loopup = [_][8]u8{
    [_]u8{ 0, 1, 4, 5, 2, 3, 6, 7 },
    [_]u8{ 1, 0, 5, 4, 3, 2, 7, 6 },
    [_]u8{ 2, 3, 6, 7, 0, 1, 4, 5 },
    [_]u8{ 3, 2, 7, 6, 1, 0, 5, 4 },
    [_]u8{ 4, 5, 0, 1, 6, 7, 2, 3 },
    [_]u8{ 5, 4, 1, 0, 7, 6, 3, 2 },
    [_]u8{ 6, 7, 2, 3, 4, 5, 0, 1 },
    [_]u8{ 7, 6, 3, 2, 5, 4, 1, 0 },
};

fn fillTree(n: *Octree, cnt: usize) void {
    if (cnt != 8 and cnt != 1 and cnt != 0 and cnt < 64)
        log.debug("{}", .{cnt});
    if (cnt == 0) return;
    const next_cnt: usize = cnt / 8;

    const allocator = std.heap.c_allocator;
    var new_nodes: []Octree = allocator.alloc(Octree, 8) catch {
        log.err("Alloc error", .{});
        return;
    };

    var i: u8 = 0;
    while (i < 8) : (i += 1) {
        new_nodes[i].refs = next_cnt;
        new_nodes[i].children = [8]?*Octree{ null, null, null, null, null, null, null, null };

        n.children[i] = &new_nodes[i];
        fillTree(&new_nodes[i], next_cnt);
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
            const lookup_array: [8]u8 = conflict_loopup[sel_i];

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

pub fn main() !void {
    const rgb_space: usize = 16777216;

    var color_cnt: usize = rgb_space;
    var root_node = Octree{
        .refs = color_cnt,
        .children = [8]?*Octree{ null, null, null, null, null, null, null, null },
    };
    fillTree(&root_node, color_cnt);

    log.info("Tree is done", .{});

    const filename: [*:0]const u8 = "batata.png";
    var w: c_int = undefined;
    var h: c_int = undefined;
    var nchannels: c_int = undefined;
    var img: ?[*]u8 = c.stbi_load(filename, &w, &h, &nchannels, 0);
    if (img == null) {
        log.err("Can't load the image {s}.", .{filename});
        return;
    }

    log.info("Loaded {}x{} image with {} channels", .{ w, h, nchannels });

    var i: usize = 0;
    while (i < w * h) : (i += 1) {
        // log.debug("{}", .{i});
        const r: u8 = img.?[i * 4] * 1.1;
        const g: u8 = img.?[i * 4 + 1] * 1.1;
        const b: u8 = img.?[i * 4 + 2] * 1.1;
        // const a: u32 = img.?[i * 4 + 3]; // ignored

        const new_color: u32 = getColor(&root_node, r, g, b);
        // log.debug("{}", .{new_color});

        img.?[i * 4] = @intCast(u8, (new_color >> 16) & 255);
        img.?[i * 4 + 1] = @intCast(u8, (new_color >> 8) & 255);
        img.?[i * 4 + 2] = @intCast(u8, (new_color) & 255);
        img.?[i * 4 + 3] = 255;
    }

    // int stbi_write_png(char const *filename, int w, int h, int comp, const void *data, int stride_in_bytes);
    if (c.stbi_write_png("batata_rgb.png", w, h, nchannels, @ptrCast(*c_void, img), w * nchannels) == 0) {
        log.err("Failed to write img", .{});
    }
}
