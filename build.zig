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

    const coherency_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/dma_coherency.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    const run_coherency_tests = b.addRunArtifact(coherency_tests);

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

    const lifecycle_tests_module = b.createModule(.{
        .root_source_file = b.path("src/lifecycle.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const lifecycle_tests = b.addTest(.{ .root_module = lifecycle_tests_module });
    const run_lifecycle_tests = b.addRunArtifact(lifecycle_tests);

    const snapshot_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/output_snapshot.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    const run_snapshot_tests = b.addRunArtifact(snapshot_tests);
    const cursor_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/playback_cursor.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    const run_cursor_tests = b.addRunArtifact(cursor_tests);
    const test_step = b.step("test", "Run HDA PCM queue and DMA period ownership tests");
    const close_details_module = b.createModule(.{
        .root_source_file = b.path("src/close_diagnostics.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    close_details_module.addImport("r4os", sdk.createR4osModule(b.graph.host, .Debug));
    const close_details_tests = b.addTest(.{ .root_module = close_details_module });
    test_step.dependOn(&b.addRunArtifact(close_details_tests).step);
    const close_snapshot_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    close_snapshot_module.addImport("r4os", sdk.createR4osModule(b.graph.host, .Debug));
    const close_snapshot_tests = b.addTest(.{ .root_module = close_snapshot_module, .filters = &.{"close snapshot"} });
    test_step.dependOn(&b.addRunArtifact(close_snapshot_tests).step);
    const eld_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/eld_probe.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    test_step.dependOn(&b.addRunArtifact(eld_tests).step);
    const idle_drain_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/idle_drain.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    test_step.dependOn(&b.addRunArtifact(idle_drain_tests).step);
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_snapshot_tests.step);
    test_step.dependOn(&run_cursor_tests.step);
    test_step.dependOn(&run_ring_tests.step);
    test_step.dependOn(&run_work_gate_tests.step);
    test_step.dependOn(&run_controller_policy_tests.step);
    test_step.dependOn(&run_controller_reset_tests.step);
    test_step.dependOn(&run_coherency_tests.step);
    test_step.dependOn(&run_command_ring_tests.step);
    test_step.dependOn(&run_codec_inventory_tests.step);
    test_step.dependOn(&run_codec_topology_tests.step);
    test_step.dependOn(&run_codec_program_tests.step);
    test_step.dependOn(&run_stream_hardware_tests.step);
    test_step.dependOn(&run_irq_recovery_tests.step);
    test_step.dependOn(&run_lifecycle_tests.step);
}
