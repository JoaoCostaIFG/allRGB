const std = @import("std");
const c = @import("c.zig");
const log = std.log;

const Octree = struct {
    refs: usize,
    children: [8]?*Octree,
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
        const sel_i: u8 = (((r & mask) >> @intCast(u3, i)) << 2) +
            (((g & mask) >> @intCast(u3, i)) << 1) +
            ((b & mask) >> @intCast(u3, i));

        // log.debug("{} {} {} - {}", .{ r, g, b, sel_i });
        // log.debug("refs: {} sel: {}", .{ curr_node.refs, sel_i });

        var sel: *Octree = curr_node.children[sel_i].?;
        if (sel.refs <= 0) { // TODO better algorithm for dealing with conflicts
            // log.debug(":C", .{});

            var j: u8 = 0;
            while (j < 8) : (j += 1) {
                sel = curr_node.children[j].?;
                if (sel.refs > 0) {
                    // we always reach this
                    ret += (@intCast(u32, j & 4) << @intCast(u5, 16 - 2 + i)) +
                        (@intCast(u32, j & 2) << @intCast(u5, 8 - 1 + i)) +
                        (@intCast(u32, j & 1) << @intCast(u5, i));
                    break;
                }
            }
        } else {
            ret += (@intCast(u32, r & mask) << 16) +
                (@intCast(u32, g & mask) << 8) +
                (b & mask);
        }

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
        log.debug("{}", .{i});
        const r: u8 = img.?[i * 4];
        const g: u8 = img.?[i * 4 + 1];
        const b: u8 = img.?[i * 4 + 2];
        // const a: u32 = img.?[i * 4 + 3]; // ignored

        const new_color: u32 = getColor(&root_node, r, g, b);
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
