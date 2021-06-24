const std = @import("std");
const Builder = std.build.Builder;
const mem = std.mem;

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("allrgb", "src/allrgb.zig");
    // exe.setOutputDir(".");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.addIncludeDir("./lodepng");
    exe.linkLibC();
    exe.addCSourceFile("./lodepng/lodepng_impl.c", &[_][]const u8{});
    exe.addCSourceFile("./lodepng/lodepng.c", &[_][]const u8{});

    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    if (b.env_map.get("INCLUDE")) |entry| {
        var it = mem.split(entry, ";");
        while (it.next()) |path| {
            exe.addIncludeDir(path);
        }
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
