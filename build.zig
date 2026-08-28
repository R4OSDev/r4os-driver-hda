const std = @import("std");

/// Eigenstaendiger Bau aus dem Manifest.
///
/// Die build.zig zeigt seit 0.61.8 nur noch auf module.R4MF, statt Name,
/// Typ beziehungsweise Rolle und Metadaten ein zweites Mal hinzuschreiben.
/// Damit gibt es hier nichts mehr, was vom Manifest abweichen koennte.
pub fn build(b: *std.Build) void {
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const sdk_dep = b.dependencyFromBuildZig(sdk_build, .{});
    const sdk = sdk_build.sdk(b, sdk_dep, .{});
    _ = sdk.addR4MF(b.path("module.R4MF"));

    const ring_tests_module = b.createModule(.{
        .root_source_file = b.path("src/stream_ring.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const ring_tests = b.addTest(.{ .root_module = ring_tests_module });
    const run_ring_tests = b.addRunArtifact(ring_tests);

    const work_gate_tests_module = b.createModule(.{
        .root_source_file = b.path("src/work_gate.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const work_gate_tests = b.addTest(.{ .root_module = work_gate_tests_module });
    const run_work_gate_tests = b.addRunArtifact(work_gate_tests);

    const controller_policy_tests_module = b.createModule(.{
        .root_source_file = b.path("src/controller_policy.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const controller_policy_tests = b.addTest(.{ .root_module = controller_policy_tests_module });
    const run_controller_policy_tests = b.addRunArtifact(controller_policy_tests);

    const controller_reset_tests_module = b.createModule(.{
        .root_source_file = b.path("src/controller_reset.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const controller_reset_tests = b.addTest(.{ .root_module = controller_reset_tests_module });
    const run_controller_reset_tests = b.addRunArtifact(controller_reset_tests);

    const command_ring_tests_module = b.createModule(.{
        .root_source_file = b.path("src/command_ring.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const command_ring_tests = b.addTest(.{ .root_module = command_ring_tests_module });
    const run_command_ring_tests = b.addRunArtifact(command_ring_tests);

    const codec_inventory_tests_module = b.createModule(.{
        .root_source_file = b.path("src/codec_inventory.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const codec_inventory_tests = b.addTest(.{ .root_module = codec_inventory_tests_module });
    const run_codec_inventory_tests = b.addRunArtifact(codec_inventory_tests);

    const codec_topology_tests_module = b.createModule(.{
        .root_source_file = b.path("src/codec_topology.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const codec_topology_tests = b.addTest(.{ .root_module = codec_topology_tests_module });
    const run_codec_topology_tests = b.addRunArtifact(codec_topology_tests);

    const codec_program_tests_module = b.createModule(.{
        .root_source_file = b.path("src/codec_program.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const codec_program_tests = b.addTest(.{ .root_module = codec_program_tests_module });
    const run_codec_program_tests = b.addRunArtifact(codec_program_tests);

    const stream_hardware_tests_module = b.createModule(.{
        .root_source_file = b.path("src/stream_hardware.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const stream_hardware_tests = b.addTest(.{ .root_module = stream_hardware_tests_module });
    const run_stream_hardware_tests = b.addRunArtifact(stream_hardware_tests);

    const irq_recovery_tests_module = b.createModule(.{
        .root_source_file = b.path("src/irq_recovery.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const irq_recovery_tests = b.addTest(.{ .root_module = irq_recovery_tests_module });
    const run_irq_recovery_tests = b.addRunArtifact(irq_recovery_tests);

    const test_step = b.step("test", "Run HDA PCM queue and DMA period ownership tests");
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_ring_tests.step);
    test_step.dependOn(&run_work_gate_tests.step);
    test_step.dependOn(&run_controller_policy_tests.step);
    test_step.dependOn(&run_controller_reset_tests.step);
    test_step.dependOn(&run_command_ring_tests.step);
    test_step.dependOn(&run_codec_inventory_tests.step);
    test_step.dependOn(&run_codec_topology_tests.step);
    test_step.dependOn(&run_codec_program_tests.step);
    test_step.dependOn(&run_stream_hardware_tests.step);
    test_step.dependOn(&run_irq_recovery_tests.step);
}
