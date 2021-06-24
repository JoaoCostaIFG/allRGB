const std = @import("std");
const c = @import("c.zig");
const log = std.log;

const Octree = struct {
    refs: usize,
    children: [8]?*Octree,
};

fn fillTree(n: *Octree, cnt: usize) void {
    if (cnt == 0) return;
    const next_cnt: usize = cnt / 8;

    var i: u8 = 0;
    while (i < 8) : (i += 1) {
        var new_node = Octree{
            .refs = next_cnt,
            .children = [8]?*Octree{ null, null, null, null, null, null, null, null },
        };

        n.children[i] = &new_node;
        fillTree(n.children[i].?, next_cnt);
    }
}

fn getColor(root: *Octree, u8: r, u8: g, u8: b) u32 {
    // pesquisar na arvore
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
    const img: ?[*]u8 = c.stbi_load(filename, &w, &h, &nchannels, 0);
    if (img == null) {
        log.err("Can't load the image {s}.", .{filename});
        return;
    }

    log.info("Loaded {}x{} image", .{ w, h });

    var i: usize = 0;
    while (i < w * h) : (i += 1) {
        const r: u8 = img.?[i * 4];
        const g: u8 = img.?[i * 4 + 1];
        const b: u8 = img.?[i * 4 + 2];
        // const a: u32 = img.?[i * 4 + 3]; // ignored
    }
}
