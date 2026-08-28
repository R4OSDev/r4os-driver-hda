const std = @import("std");

pub const widget_audio_output: u8 = 0x00;
pub const widget_audio_mixer: u8 = 0x02;
pub const widget_audio_selector: u8 = 0x03;
pub const widget_pin_complex: u8 = 0x04;

pub const widget_cap_stereo: u32 = 1 << 0;
pub const widget_cap_in_amp: u32 = 1 << 1;
pub const widget_cap_out_amp: u32 = 1 << 2;
pub const widget_cap_digital: u32 = 1 << 9;
pub const widget_cap_power: u32 = 1 << 10;
pub const pin_cap_presence: u32 = 1 << 2;
pub const pin_cap_headphone_drive: u32 = 1 << 3;
pub const pin_cap_output: u32 = 1 << 4;
pub const pin_cap_eapd: u32 = 1 << 16;

pub const pcm_rate_48k: u32 = 1 << 6;
pub const pcm_bits_16: u32 = 1 << 17;
pub const stream_pcm: u32 = 1 << 0;
pub const format_48k_stereo_s16: u16 = 0x0011;
pub const stream_id: u8 = 1;

pub const PinRole = enum(u8) {
    line_out = 0,
    speaker = 1,
    headphone = 2,
};

pub const PinCandidate = struct {
    node: u8,
    config: u32,
    pin_caps: u32,
};

pub fn pinRole(config: u32) ?PinRole {
    if (((config >> 30) & 0x03) == 1) return null;
    return switch ((config >> 20) & 0x0f) {
        0 => .line_out,
        1 => .speaker,
        2 => .headphone,
        else => null,
    };
}

pub fn association(config: u32) u8 {
    return @truncate((config >> 4) & 0x0f);
}

pub fn sequence(config: u32) u8 {
    return @truncate(config & 0x0f);
}

pub fn preferPin(candidate: PinCandidate, current: ?PinCandidate) bool {
    const candidate_role = pinRole(candidate.config) orelse return false;
    if ((candidate.pin_caps & pin_cap_output) == 0) return false;
    const best = current orelse return true;
    const best_role = pinRole(best.config) orelse return true;
    const candidate_rank = roleRank(candidate_role);
    const best_rank = roleRank(best_role);
    if (candidate_rank != best_rank) return candidate_rank > best_rank;

    const candidate_assoc = association(candidate.config);
    const best_assoc = association(best.config);
    const candidate_has_assoc = candidate_assoc != 0;
    const best_has_assoc = best_assoc != 0;
    if (candidate_has_assoc != best_has_assoc) return candidate_has_assoc;
    if (candidate_assoc != best_assoc) return candidate_assoc < best_assoc;
    const candidate_sequence = sequence(candidate.config);
    const best_sequence = sequence(best.config);
    if (candidate_sequence != best_sequence) return candidate_sequence < best_sequence;
    return candidate.node < best.node;
}

fn roleRank(role: PinRole) u8 {
    return switch (role) {
        .speaker => 3,
        .headphone => 2,
        .line_out => 1,
    };
}

pub const JackSense = enum(u8) {
    unavailable,
    absent,
    present,
};

/// Presence evidence may override the fixed speaker route.  Without usable
/// evidence the result is a stable speaker, line-out, headphone fallback.
pub fn chooseActiveRole(has_speaker: bool, has_headphone: bool, has_line_out: bool, sense: JackSense) ?PinRole {
    if (sense == .present and has_headphone) return .headphone;
    if (has_speaker) return .speaker;
    if (has_line_out) return .line_out;
    if (has_headphone) return .headphone;
    return null;
}

pub fn supportsRequiredFormat(widget_caps: u32, pcm_caps: u32, stream_caps: u32) bool {
    return (widget_caps & widget_cap_stereo) != 0 and
        (widget_caps & widget_cap_digital) == 0 and
        (pcm_caps & pcm_rate_48k) != 0 and
        (pcm_caps & pcm_bits_16) != 0 and
        (stream_caps & stream_pcm) != 0;
}

pub const AmpDirection = enum(u8) {
    input,
    output,
};

/// Construct an exact stereo unmute payload at the advertised 0-dB step.
/// The offset is clamped to NumSteps for malformed capability blocks.
pub fn ampPayload(caps: u32, direction: AmpDirection, connection_index: u8) ?u16 {
    if (direction == .input and connection_index > 0x0f) return null;
    const offset: u16 = @truncate(caps & 0x7f);
    const steps: u16 = @truncate((caps >> 8) & 0x7f);
    const gain = @min(offset, steps);
    var payload: u16 = (1 << 13) | (1 << 12) | gain;
    if (direction == .input) {
        payload |= 1 << 14;
        payload |= @as(u16, connection_index) << 8;
    } else {
        payload |= 1 << 15;
    }
    return payload;
}

pub const max_route_nodes: usize = 64;
pub const max_operations: usize = 320;

pub const RouteNode = struct {
    node: u8 = 0,
    kind: u8 = 0xff,
    widget_caps: u32 = 0,
    input_amp_caps: u32 = 0,
    output_amp_caps: u32 = 0,
    power_caps: u32 = 0,
    connection_index: u8 = 0,
    connection_count: u16 = 0,
};

pub const PlanInput = struct {
    afg: u8 = 0,
    afg_power_caps: u32 = 0,
    pin_caps: u32 = 0,
    pin_role: PinRole = .line_out,
    pcm_caps: u32 = 0,
    stream_caps: u32 = 0,
    route_count: u8 = 0,
    route: [max_route_nodes]RouteNode = .{RouteNode{}} ** max_route_nodes,
};

pub const OperationKind = enum(u8) {
    set_power_d0,
    verify_power_d0,
    clear_stream,
    verify_stream,
    set_format,
    verify_format,
    set_connection,
    set_amp,
    set_pin_control,
    set_eapd,
    set_stream,
};

pub const Operation = struct {
    kind: OperationKind,
    node: u8,
    value: u16 = 0,
};

pub const ProgramPlan = struct {
    count: u16 = 0,
    operations: [max_operations]Operation = undefined,

    fn append(self: *ProgramPlan, operation: Operation) bool {
        if (self.count >= self.operations.len) return false;
        self.operations[self.count] = operation;
        self.count += 1;
        return true;
    }

    pub fn slice(self: *const ProgramPlan) []const Operation {
        return self.operations[0..self.count];
    }
};

/// Produce the single bounded verb plan used by both the driver and the
/// synthetic topology models.  The route is ordered pin -> ... -> converter.
pub fn buildPlan(input: *const PlanInput) ?ProgramPlan {
    const count: usize = input.route_count;
    if (input.afg == 0 or count < 2 or count > input.route.len) return null;
    const pin = input.route[0];
    const converter = input.route[count - 1];
    if (pin.node == 0 or pin.kind != widget_pin_complex or (input.pin_caps & pin_cap_output) == 0) return null;
    if (converter.node == 0 or converter.kind != widget_audio_output) return null;
    if (!supportsRequiredFormat(converter.widget_caps, input.pcm_caps, input.stream_caps)) return null;
    if (input.afg_power_caps != 0 and (input.afg_power_caps & 1) == 0) return null;

    var plan = ProgramPlan{};
    if (!plan.append(.{ .kind = .set_power_d0, .node = input.afg }) or
        !plan.append(.{ .kind = .verify_power_d0, .node = input.afg })) return null;

    var reverse_index = count;
    while (reverse_index > 0) {
        reverse_index -= 1;
        const item = input.route[reverse_index];
        if (item.node == 0 or (item.widget_caps & widget_cap_stereo) == 0) return null;
        if ((item.widget_caps & widget_cap_power) != 0) {
            if ((item.power_caps & 1) == 0) return null;
            if (!plan.append(.{ .kind = .set_power_d0, .node = item.node }) or
                !plan.append(.{ .kind = .verify_power_d0, .node = item.node })) return null;
        }
    }

    if (!plan.append(.{ .kind = .clear_stream, .node = converter.node }) or
        !plan.append(.{ .kind = .verify_stream, .node = converter.node }) or
        !plan.append(.{ .kind = .set_format, .node = converter.node, .value = format_48k_stereo_s16 }) or
        !plan.append(.{ .kind = .verify_format, .node = converter.node, .value = format_48k_stereo_s16 })) return null;

    reverse_index = count;
    while (reverse_index > 0) {
        reverse_index -= 1;
        const source = input.route[reverse_index];
        if ((source.widget_caps & widget_cap_out_amp) != 0) {
            const payload = ampPayload(source.output_amp_caps, .output, 0) orelse return null;
            if (!plan.append(.{ .kind = .set_amp, .node = source.node, .value = payload })) return null;
        }
        if (reverse_index == 0) continue;

        const sink = input.route[reverse_index - 1];
        const connection_index = sink.connection_index;
        if (sink.kind == widget_audio_selector or
            (sink.kind == widget_pin_complex and (sink.connection_count > 1 or connection_index != 0)))
        {
            if (!plan.append(.{ .kind = .set_connection, .node = sink.node, .value = connection_index })) return null;
        } else if (sink.kind != widget_audio_mixer and sink.kind != widget_pin_complex) {
            return null;
        }
        if ((sink.widget_caps & widget_cap_in_amp) != 0) {
            const payload = ampPayload(sink.input_amp_caps, .input, connection_index) orelse return null;
            if (!plan.append(.{ .kind = .set_amp, .node = sink.node, .value = payload })) return null;
        }
    }

    var pin_control: u16 = 1 << 6;
    if (input.pin_role == .headphone and (input.pin_caps & pin_cap_headphone_drive) != 0) pin_control |= 1 << 7;
    if (!plan.append(.{ .kind = .set_pin_control, .node = pin.node, .value = pin_control })) return null;
    if ((input.pin_caps & pin_cap_eapd) != 0) {
        if (!plan.append(.{ .kind = .set_eapd, .node = pin.node, .value = 1 << 1 })) return null;
    }
    const stream_value: u16 = @as(u16, stream_id) << 4;
    if (!plan.append(.{ .kind = .set_stream, .node = converter.node, .value = stream_value }) or
        !plan.append(.{ .kind = .verify_stream, .node = converter.node, .value = stream_value })) return null;
    return plan;
}

test "pin defaults rank analog outputs by role association sequence and NID" {
    const digital = PinCandidate{ .node = 2, .config = @as(u32, 4) << 20, .pin_caps = pin_cap_output };
    try std.testing.expect(!preferPin(digital, null));

    const line = PinCandidate{ .node = 9, .config = (@as(u32, 0) << 20) | (2 << 4), .pin_caps = pin_cap_output };
    const hp = PinCandidate{ .node = 8, .config = (@as(u32, 2) << 20) | (2 << 4), .pin_caps = pin_cap_output };
    const speaker_late = PinCandidate{ .node = 7, .config = (@as(u32, 1) << 20) | (2 << 4) | 4, .pin_caps = pin_cap_output };
    const speaker_early = PinCandidate{ .node = 6, .config = (@as(u32, 1) << 20) | (2 << 4) | 1, .pin_caps = pin_cap_output };
    try std.testing.expect(preferPin(hp, line));
    try std.testing.expect(preferPin(speaker_late, hp));
    try std.testing.expect(preferPin(speaker_early, speaker_late));
}

test "jack policy has deterministic fixed fallback" {
    try std.testing.expectEqual(PinRole.headphone, chooseActiveRole(true, true, true, .present).?);
    try std.testing.expectEqual(PinRole.speaker, chooseActiveRole(true, true, true, .absent).?);
    try std.testing.expectEqual(PinRole.speaker, chooseActiveRole(true, true, true, .unavailable).?);
    try std.testing.expectEqual(PinRole.line_out, chooseActiveRole(false, true, true, .unavailable).?);
}

test "capability and amp models accept exact 48k stereo S16" {
    try std.testing.expect(supportsRequiredFormat(widget_cap_stereo, pcm_rate_48k | pcm_bits_16, stream_pcm));
    try std.testing.expect(!supportsRequiredFormat(widget_cap_stereo | widget_cap_digital, pcm_rate_48k | pcm_bits_16, stream_pcm));
    try std.testing.expectEqual(@as(?u16, 0xb04a), ampPayload(0x80004a4a, .output, 0));
    try std.testing.expectEqual(@as(?u16, 0x7310), ampPayload(0x00001020, .input, 3));
    try std.testing.expectEqual(@as(?u16, null), ampPayload(0, .input, 16));
}

test "QEMU direct route produces the exact safe verb plan" {
    var input = PlanInput{
        .afg = 1,
        .pin_caps = pin_cap_output,
        .pin_role = .line_out,
        .pcm_caps = pcm_rate_48k | pcm_bits_16,
        .stream_caps = stream_pcm,
        .route_count = 2,
    };
    input.route[0] = .{ .node = 3, .kind = widget_pin_complex, .widget_caps = widget_cap_stereo, .connection_index = 0 };
    input.route[1] = .{ .node = 2, .kind = widget_audio_output, .widget_caps = widget_cap_stereo | widget_cap_out_amp, .output_amp_caps = 0x80004a4a };
    const plan = buildPlan(&input).?;
    const expected = [_]Operation{
        .{ .kind = .set_power_d0, .node = 1 },
        .{ .kind = .verify_power_d0, .node = 1 },
        .{ .kind = .clear_stream, .node = 2 },
        .{ .kind = .verify_stream, .node = 2 },
        .{ .kind = .set_format, .node = 2, .value = format_48k_stereo_s16 },
        .{ .kind = .verify_format, .node = 2, .value = format_48k_stereo_s16 },
        .{ .kind = .set_amp, .node = 2, .value = 0xb04a },
        .{ .kind = .set_pin_control, .node = 3, .value = 0x40 },
        .{ .kind = .set_stream, .node = 2, .value = 0x10 },
        .{ .kind = .verify_stream, .node = 2, .value = 0x10 },
    };
    try std.testing.expectEqualSlices(Operation, &expected, plan.slice());
}

test "multistage plan configures selector mixer amps power EAPD and headphone drive" {
    var input = PlanInput{
        .afg = 1,
        .afg_power_caps = 1,
        .pin_caps = pin_cap_output | pin_cap_headphone_drive | pin_cap_eapd | pin_cap_presence,
        .pin_role = .headphone,
        .pcm_caps = pcm_rate_48k | pcm_bits_16,
        .stream_caps = stream_pcm,
        .route_count = 4,
    };
    input.route[0] = .{ .node = 10, .kind = widget_pin_complex, .widget_caps = widget_cap_stereo | widget_cap_in_amp, .input_amp_caps = 0x00002020, .connection_index = 1, .connection_count = 2 };
    input.route[1] = .{ .node = 8, .kind = widget_audio_selector, .widget_caps = widget_cap_stereo | widget_cap_in_amp, .input_amp_caps = 0x00002020, .connection_index = 2 };
    input.route[2] = .{ .node = 7, .kind = widget_audio_mixer, .widget_caps = widget_cap_stereo | widget_cap_in_amp | widget_cap_power, .input_amp_caps = 0x00002020, .power_caps = 1, .connection_index = 3 };
    input.route[3] = .{ .node = 2, .kind = widget_audio_output, .widget_caps = widget_cap_stereo | widget_cap_out_amp, .output_amp_caps = 0x00002020 };
    const plan = buildPlan(&input).?;
    try std.testing.expectEqual(OperationKind.set_power_d0, plan.slice()[2].kind);
    try std.testing.expectEqual(@as(u8, 7), plan.slice()[2].node);
    try std.testing.expectEqual(OperationKind.set_eapd, plan.slice()[plan.slice().len - 3].kind);
    try std.testing.expectEqual(@as(u16, 0xc0), plan.slice()[plan.slice().len - 4].value);
}

test "missing required format or power capability rejects the route" {
    var input = PlanInput{
        .afg = 1,
        .pin_caps = pin_cap_output,
        .pcm_caps = pcm_rate_48k,
        .stream_caps = stream_pcm,
        .route_count = 2,
    };
    input.route[0] = .{ .node = 3, .kind = widget_pin_complex, .widget_caps = widget_cap_stereo };
    input.route[1] = .{ .node = 2, .kind = widget_audio_output, .widget_caps = widget_cap_stereo };
    try std.testing.expectEqual(@as(?ProgramPlan, null), buildPlan(&input));
    input.pcm_caps |= pcm_bits_16;
    input.route[1].widget_caps |= widget_cap_power;
    try std.testing.expectEqual(@as(?ProgramPlan, null), buildPlan(&input));
}
