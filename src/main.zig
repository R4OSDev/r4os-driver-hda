const r4os = @import("r4os");
const pcm = r4os.audio_pcm;

comptime {
    asm (r4os.r4dev.driverEntriesAsm("hda_init", "hda_shutdown"));
}

const CLASS_MULTIMEDIA: u8 = 0x04;
const SUBCLASS_HDA: u8 = 0x03;

const REG_GCAP: u64 = 0x00;
const REG_VMIN: u64 = 0x02;
const REG_VMAJ: u64 = 0x03;
const REG_OUTPAY: u64 = 0x04;
const REG_INPAY: u64 = 0x06;
const REG_GCTL: u64 = 0x08;
const REG_STATESTS: u64 = 0x0E;
const REG_INTCTL: u64 = 0x20;
const REG_INTSTS: u64 = 0x24;
const REG_ICOI: u64 = 0x60;
const REG_ICII: u64 = 0x64;
const REG_ICIS: u64 = 0x68;
const REG_STREAM_BASE: u64 = 0x80;
const STREAM_DESC_SIZE: u64 = 0x20;

const SD_CTL: u64 = 0x00;
const SD_STS: u64 = 0x03;
const SD_LPIB: u64 = 0x04;
const SD_CBL: u64 = 0x08;
const SD_LVI: u64 = 0x0C;
const SD_FORMAT: u64 = 0x12;
const SD_BDPL: u64 = 0x18;
const SD_BDPU: u64 = 0x1C;

const GCTL_CRST: u32 = 0x0000_0001;
const ICIS_BUSY: u16 = 0x0001;
const ICIS_VALID: u16 = 0x0002;
const SD_CTL_SRST: u32 = 0x0000_0001;
const SD_CTL_RUN: u32 = 0x0000_0002;
const SD_CTL_STREAM_SHIFT: u5 = 20;
const SD_STS_BCIS: u8 = 0x04;
const SD_STS_FIFOE: u8 = 0x08;
const SD_STS_DESE: u8 = 0x10;
const SD_STS_CLEAR: u8 = SD_STS_BCIS | SD_STS_FIFOE | SD_STS_DESE;

const RESET_GUARD: u32 = 10_000;
const COMMAND_GUARD: u32 = 10_000;
const STREAM_GUARD: u32 = 10_000;
const MAX_CODECS: usize = 4;
const MAX_WIDGETS: usize = 48;
const DMA_BUFFER_COUNT: usize = 8;
const DMA_BUFFER_BYTES: usize = 4096;
const HDA_BDL_IOC: u32 = 0x0000_0001;
const HDA_FORMAT_48K_STEREO_S16: u16 = 0x0021;
const MIN_RATE: u32 = 8000;
const MAX_RATE: u32 = 192_000;
// 0.56.40: hz-neutral in ms (bei 100 Hz wie zuvor 5/200 Ticks).
const PLAYBACK_WAIT_MS: u64 = 50;
const DRAIN_WAIT_MS: u64 = 2000;

const PARAM_VENDOR_ID: u8 = 0x00;
const PARAM_REVISION_ID: u8 = 0x02;
const PARAM_SUB_NODE_COUNT: u8 = 0x04;
const PARAM_FUNCTION_GROUP_TYPE: u8 = 0x05;
const PARAM_AUDIO_WIDGET_CAPS: u8 = 0x09;
const PARAM_PIN_CAPS: u8 = 0x0C;
const PARAM_CONNECTION_LIST_LENGTH: u8 = 0x0E;
const FUNCTION_GROUP_AUDIO: u8 = 0x01;
const WIDGET_AUDIO_OUTPUT: u8 = 0x00;
const WIDGET_AUDIO_MIXER: u8 = 0x02;
const WIDGET_AUDIO_SELECTOR: u8 = 0x03;
const WIDGET_PIN_COMPLEX: u8 = 0x04;
const WIDGET_CAP_OUT_AMP: u32 = 1 << 2;
const PIN_CAP_OUTPUT: u32 = 1 << 4;
const PIN_CAP_EAPD: u32 = 1 << 16;
const PIN_CONTROL_OUT_ENABLE: u8 = 0x40;
const EAPD_BTL_ENABLE: u8 = 0x02;
const FIRST_STREAM_ID: u8 = 1;
const FIRST_CHANNEL_ID: u8 = 0;

const InitStage = enum(u8) {
    none,
    pci,
    mmio,
    reset,
    transport,
    codec,
    output,
    dma,
    ready,
    failed,
};

const WidgetInfo = struct {
    node: u8 = 0,
    kind: u8 = 0xFF,
    caps: u32 = 0,
    pin_caps: u32 = 0,
};

const CodecInfo = struct {
    present: bool = false,
    address: u8 = 0xFF,
    vendor_id: u32 = 0,
    revision_id: u32 = 0,
    root_start: u8 = 0,
    root_count: u8 = 0,
    afg_node: u8 = 0,
    afg_widgets_start: u8 = 0,
    afg_widgets_count: u8 = 0,
    discovered_widgets: u8 = 0,
    output_count: u8 = 0,
    pin_count: u8 = 0,
    mixer_count: u8 = 0,
    selector_count: u8 = 0,
    widgets: [MAX_WIDGETS]WidgetInfo = .{WidgetInfo{}} ** MAX_WIDGETS,
};

const OutputCandidate = struct {
    found: bool = false,
    codec: u8 = 0xFF,
    afg: u8 = 0,
    converter: u8 = 0,
    converter_caps: u32 = 0,
    pin: u8 = 0,
    pin_widget_caps: u32 = 0,
    pin_caps: u32 = 0,
};

const BdlEntry = extern struct {
    addr: u64 = 0,
    length: u32 = 0,
    flags: u32 = 0,
};

const State = struct {
    api: *const r4os.r4dev.DriverApi = undefined,
    initialized: bool = false,
    info: r4os.abi.PciDeviceInfo = .{},
    mmio: r4os.abi.MmioRegion = .{},
    backend: r4os.abi.AudioBackend = .{},
    backend_registered: bool = false,
    present: bool = false,
    stage: InitStage = .none,
    failed_stage: InitStage = .none,
    gcap: u16 = 0,
    version_major: u8 = 0,
    version_minor: u8 = 0,
    out_payload: u16 = 0,
    in_payload: u16 = 0,
    gctl: u32 = 0,
    intctl: u32 = 0,
    intsts: u32 = 0,
    statests: u16 = 0,
    output_stream_count: u8 = 0,
    input_stream_count: u8 = 0,
    bidi_stream_count: u8 = 0,
    serial_data_out_count: u8 = 0,
    dma_64bit_supported: bool = false,
    codec_mask: u16 = 0,
    codec_count: u8 = 0,
    discovered_codec_count: u8 = 0,
    command_count: u64 = 0,
    response_count: u64 = 0,
    timeout_count: u64 = 0,
    reset_requested: bool = false,
    reset_done: bool = false,
    transport_ready: bool = false,
    codec_ready: bool = false,
    output: OutputCandidate = .{},
    output_path_ok: bool = false,
    output_path_fail_count: u64 = 0,
    output_stream_id: u8 = 0,
    output_channel_id: u8 = 0,
    output_pin_control: u8 = 0,
    output_connection_index: u8 = 0xFF,
    output_connection_set: bool = false,
    output_eapd_set: bool = false,
    output_converter_unmuted: bool = false,
    output_pin_unmuted: bool = false,
    dma_ready: bool = false,
    stream_desc_index: u8 = 0xFF,
    stream_desc_offset: u64 = 0,
    stream_desc_base: u64 = 0,
    stream_bdl: r4os.abi.DmaBuffer = .{},
    stream_dma: [DMA_BUFFER_COUNT]r4os.abi.DmaBuffer = .{r4os.abi.DmaBuffer{}} ** DMA_BUFFER_COUNT,
    stream_buffer_count: u8 = 0,
    stream_buffer_bytes: u32 = 0,
    stream_total_bytes: u32 = 0,
    stream_format: u16 = 0,
    next_dma_index: usize = 0,
    playback_started: bool = false,
    reset_stream_count: u64 = 0,
    dma_fail_count: u64 = 0,
    write_count: u64 = 0,
    refill_count: u64 = 0,
    silence_refill_count: u64 = 0,
    write_total_ticks: u64 = 0,
    write_max_ticks: u64 = 0,
    write_last_ticks: u64 = 0,
    refill_total_ticks: u64 = 0,
    refill_max_ticks: u64 = 0,
    refill_last_ticks: u64 = 0,
    start_count: u64 = 0,
    stop_count: u64 = 0,
    drain_count: u64 = 0,
    drain_timeout_count: u64 = 0,
    refill_timeout_count: u64 = 0,
    stream_recovery_count: u64 = 0,
    poll_count: u64 = 0,
    bcis_count: u64 = 0,
    fifo_error_count: u64 = 0,
    descriptor_error_count: u64 = 0,
    empty_write_count: u64 = 0,
    error_count: u64 = 0,
    converted_frame_count: u64 = 0,
    last_result: i32 = 0,
    last_source_rate: u32 = 0,
    last_source_channels: u16 = 0,
    last_source_format: u16 = 0,
    last_output_bytes: usize = 0,
    last_output_buffers: usize = 0,
    last_drain_wait_ticks: u64 = 0,
    stream_ctl_last: u32 = 0,
    stream_sts_last: u8 = 0,
    stream_lpib_last: u32 = 0,
    previous_stream_status: u8 = 0,
    last_error: [*:0]const u8 = "none",
    last_recovery: [*:0]const u8 = "none",
    resampler_state: pcm.ResamplerState = .{},
    codecs: [MAX_CODECS]CodecInfo = .{CodecInfo{}} ** MAX_CODECS,
};

var state: State = .{};

// 0.56.40: hz-neutrale Laufzeit-Umrechnung (R4D kennt DEFAULT_HZ nicht
// comptime; timerFrequency liefert die echte Tickrate).
fn msTicks(ctx: *const r4os.r4dev.DriverContext, ms: u64) u64 {
    const freq = @as(u64, ctx.timerFrequency());
    if (freq == 0) return @max(1, ms / 10);
    return @max(1, (ms * freq) / 1000);
}

export fn hda_init(api: *const r4os.r4dev.DriverApi) callconv(.c) i32 {
    state = .{ .api = api };
    var ctx = context();
    ctx.logInfo("HDA.R4D init");
    if (!ctx.apiCompatible()) {
        ctx.logError("HDA.R4D driver api mismatch");
        return -10;
    }

    state.stage = .pci;
    const info = findDevice(&ctx) orelse {
        ctx.logWarn("HDA.R4D device not found");
        failStage(.pci);
        return -1;
    };
    state.info = info;
    logDevice(&ctx, info);

    if (ctx.pciEnableBusMaster(info, r4os.abi.pci_enable_memory_space) != 0) {
        ctx.logError("HDA.R4D bus master enable failed");
        failStage(.pci);
        return -2;
    }

    state.stage = .mmio;
    if (ctx.pciMapBar(info, 0, 4096, 0, &state.mmio) != 0 or state.mmio.virt_addr == 0) {
        ctx.logError("HDA.R4D MMIO map failed");
        failStage(.mmio);
        return -3;
    }
    readGlobalRegisters();
    logMmio(&ctx);

    state.stage = .reset;
    state.reset_requested = optionEnabled(&ctx, "r4d_reset") or (state.gctl & GCTL_CRST) == 0;
    if (state.reset_requested) {
        if (!resetController(&ctx)) {
            ctx.logError("HDA.R4D reset failed");
            failStage(.reset);
            return -4;
        }
        state.reset_done = true;
        readGlobalRegisters();
    }

    state.stage = .transport;
    if (!setupImmediateTransport(&ctx)) {
        ctx.logError("HDA.R4D immediate command path failed");
        failStage(.transport);
        return -5;
    }

    state.stage = .codec;
    if (!discoverCodecs(&ctx)) {
        ctx.logError("HDA.R4D codec discovery failed");
        failStage(.codec);
        return -6;
    }
    chooseOutputCandidate(&ctx);

    state.stage = .output;
    if (!configureOutputPath(&ctx)) {
        ctx.logError("HDA.R4D output path setup failed");
        failStage(.output);
        shutdownHardware(&ctx);
        return -7;
    }

    state.stage = .dma;
    if (!setupStreamDma(&ctx)) {
        ctx.logError("HDA.R4D stream DMA setup failed");
        failStage(.dma);
        shutdownHardware(&ctx);
        return -8;
    }

    state.present = true;
    if (!registerPlaybackBackend(&ctx)) {
        ctx.logError("HDA.R4D audio backend register failed");
        failStage(.dma);
        shutdownHardware(&ctx);
        return -9;
    }

    state.stage = .ready;
    state.initialized = true;
    logPlaybackReady(&ctx);
    return 0;
}

export fn hda_shutdown() callconv(.c) i32 {
    var ctx = context();
    ctx.logInfo("HDA.R4D shutdown");
    unregisterPlaybackBackend(&ctx);
    shutdownHardware(&ctx);
    return 0;
}

fn findDevice(ctx: *const r4os.r4dev.DriverContext) ?r4os.abi.PciDeviceInfo {
    var info: r4os.abi.PciDeviceInfo = .{};
    const found = ctx.pciFindByClass(CLASS_MULTIMEDIA, SUBCLASS_HDA, 0, &info);
    if (found < 0) return null;
    return info;
}

fn readGlobalRegisters() void {
    const base = mmioBase();
    state.gcap = read16(base + REG_GCAP);
    state.version_minor = read8(base + REG_VMIN);
    state.version_major = read8(base + REG_VMAJ);
    state.out_payload = read16(base + REG_OUTPAY);
    state.in_payload = read16(base + REG_INPAY);
    state.gctl = read32(base + REG_GCTL);
    state.intctl = read32(base + REG_INTCTL);
    state.intsts = read32(base + REG_INTSTS);
    state.statests = read16(base + REG_STATESTS);
    decodeCapabilities();
}

fn decodeCapabilities() void {
    state.output_stream_count = @truncate((state.gcap >> 12) & 0x0F);
    state.input_stream_count = @truncate((state.gcap >> 8) & 0x0F);
    state.bidi_stream_count = @truncate((state.gcap >> 3) & 0x1F);
    state.serial_data_out_count = switch ((state.gcap >> 1) & 0x03) {
        0 => 1,
        1 => 2,
        2 => 4,
        else => 0,
    };
    state.dma_64bit_supported = (state.gcap & 0x0001) != 0;
    state.codec_mask = state.statests & 0x7FFF;
    state.codec_count = countBits16(state.codec_mask);
}

fn resetController(ctx: *const r4os.r4dev.DriverContext) bool {
    const base = mmioBase();
    ctx.logInfo("HDA.R4D reset controller");
    write32(base + REG_INTCTL, 0);
    write32(base + REG_GCTL, read32(base + REG_GCTL) & ~GCTL_CRST);
    if (!wait32Clear(base + REG_GCTL, GCTL_CRST, RESET_GUARD)) return false;
    write32(base + REG_GCTL, read32(base + REG_GCTL) | GCTL_CRST);
    if (!wait32Set(base + REG_GCTL, GCTL_CRST, RESET_GUARD)) return false;
    write32(base + REG_INTCTL, 0);
    return true;
}

fn setupImmediateTransport(ctx: *const r4os.r4dev.DriverContext) bool {
    if (state.codec_mask == 0) {
        ctx.logWarn("HDA.R4D no codecs in STATESTS");
        return false;
    }
    const codec = firstCodecAddress() orelse return false;
    const response = sendImmediateVerb(makeVerb(codec, 0, 0xF00, PARAM_VENDOR_ID)) orelse return false;
    state.transport_ready = true;
    logTransport(ctx, codec, response);
    return true;
}

fn discoverCodecs(ctx: *const r4os.r4dev.DriverContext) bool {
    clearCodecInfo();
    var ok = false;
    var addr: u8 = 0;
    while (addr < 15) : (addr += 1) {
        if ((state.codec_mask & (@as(u16, 1) << @intCast(addr))) == 0) continue;
        if (state.discovered_codec_count >= MAX_CODECS) break;

        const index = state.discovered_codec_count;
        if (discoverCodec(ctx, addr, index)) {
            state.discovered_codec_count += 1;
            ok = true;
        }
    }
    state.codec_ready = ok;
    return ok;
}

fn discoverCodec(ctx: *const r4os.r4dev.DriverContext, addr: u8, index: u8) bool {
    var info = CodecInfo{};
    info.present = true;
    info.address = addr;
    info.vendor_id = getParameter(addr, 0, PARAM_VENDOR_ID) orelse return false;
    info.revision_id = getParameter(addr, 0, PARAM_REVISION_ID) orelse return false;
    const root_nodes = getParameter(addr, 0, PARAM_SUB_NODE_COUNT) orelse return false;
    info.root_start = subNodeStart(root_nodes);
    info.root_count = subNodeCount(root_nodes);

    var node_offset: u8 = 0;
    while (node_offset < info.root_count) : (node_offset += 1) {
        const fg_node = info.root_start + node_offset;
        const fg_type_raw = getParameter(addr, fg_node, PARAM_FUNCTION_GROUP_TYPE) orelse continue;
        const fg_type: u8 = @truncate(fg_type_raw & 0xFF);
        if ((fg_type & 0x7F) != FUNCTION_GROUP_AUDIO) continue;

        info.afg_node = fg_node;
        const widget_nodes = getParameter(addr, fg_node, PARAM_SUB_NODE_COUNT) orelse return false;
        info.afg_widgets_start = subNodeStart(widget_nodes);
        info.afg_widgets_count = subNodeCount(widget_nodes);
        discoverWidgets(addr, &info);
        break;
    }

    state.codecs[@intCast(index)] = info;
    logCodecInfo(ctx, &state.codecs[@intCast(index)]);
    return true;
}

fn discoverWidgets(addr: u8, info: *CodecInfo) void {
    var offset: u8 = 0;
    while (offset < info.afg_widgets_count and info.discovered_widgets < MAX_WIDGETS) : (offset += 1) {
        const node = info.afg_widgets_start + offset;
        const caps = getParameter(addr, node, PARAM_AUDIO_WIDGET_CAPS) orelse continue;
        const kind: u8 = @truncate((caps >> 20) & 0x0F);
        if (!isRelevantWidget(kind)) continue;

        const out_index: usize = info.discovered_widgets;
        info.widgets[out_index].node = node;
        info.widgets[out_index].kind = kind;
        info.widgets[out_index].caps = caps;
        if (kind == WIDGET_PIN_COMPLEX) {
            info.widgets[out_index].pin_caps = getParameter(addr, node, PARAM_PIN_CAPS) orelse 0;
            info.pin_count += 1;
        } else if (kind == WIDGET_AUDIO_OUTPUT) {
            info.output_count += 1;
        } else if (kind == WIDGET_AUDIO_MIXER) {
            info.mixer_count += 1;
        } else if (kind == WIDGET_AUDIO_SELECTOR) {
            info.selector_count += 1;
        }
        info.discovered_widgets += 1;
    }
}

fn chooseOutputCandidate(ctx: *const r4os.r4dev.DriverContext) void {
    state.output = .{};
    var codec_index: usize = 0;
    while (codec_index < state.discovered_codec_count and codec_index < MAX_CODECS) : (codec_index += 1) {
        const info = &state.codecs[codec_index];
        if (!info.present or info.afg_node == 0) continue;

        var converter: u8 = 0;
        var pin: u8 = 0;
        var widget_index: usize = 0;
        while (widget_index < info.discovered_widgets and widget_index < MAX_WIDGETS) : (widget_index += 1) {
            const widget = info.widgets[widget_index];
            if (converter == 0 and widget.kind == WIDGET_AUDIO_OUTPUT) converter = widget.node;
            if (pin == 0 and widget.kind == WIDGET_PIN_COMPLEX and (widget.pin_caps & PIN_CAP_OUTPUT) != 0) pin = widget.node;
        }

        if (converter != 0 and pin != 0) {
            state.output = .{
                .found = true,
                .codec = info.address,
                .afg = info.afg_node,
                .converter = converter,
                .converter_caps = widgetCaps(info, converter),
                .pin = pin,
                .pin_widget_caps = widgetCaps(info, pin),
                .pin_caps = pinCaps(info, pin),
            };
            logOutputCandidate(ctx);
            return;
        }
    }
    ctx.logWarn("HDA.R4D no output candidate");
}

fn widgetCaps(info: *const CodecInfo, node: u8) u32 {
    var i: usize = 0;
    while (i < info.discovered_widgets and i < MAX_WIDGETS) : (i += 1) {
        if (info.widgets[i].node == node) return info.widgets[i].caps;
    }
    return 0;
}

fn pinCaps(info: *const CodecInfo, node: u8) u32 {
    var i: usize = 0;
    while (i < info.discovered_widgets and i < MAX_WIDGETS) : (i += 1) {
        if (info.widgets[i].node == node) return info.widgets[i].pin_caps;
    }
    return 0;
}

fn clearOutputPath() void {
    state.output_path_ok = false;
    state.output_path_fail_count = 0;
    state.output_stream_id = 0;
    state.output_channel_id = 0;
    state.output_pin_control = 0;
    state.output_connection_index = 0xFF;
    state.output_connection_set = false;
    state.output_eapd_set = false;
    state.output_converter_unmuted = false;
    state.output_pin_unmuted = false;
}

fn configureOutputPath(ctx: *const r4os.r4dev.DriverContext) bool {
    clearOutputPath();
    if (!state.output.found) {
        state.output_path_fail_count += 1;
        noteHdaWarn(ctx, "no output candidate");
        return false;
    }

    state.output_stream_id = FIRST_STREAM_ID;
    state.output_channel_id = FIRST_CHANNEL_ID;
    state.output_pin_control = PIN_CONTROL_OUT_ENABLE;

    if (!setConverterStreamChannel(state.output.codec, state.output.converter, state.output_stream_id, state.output_channel_id)) {
        state.output_path_fail_count += 1;
        noteHdaWarn(ctx, "converter stream/channel setup failed");
        return false;
    }
    if (findConnectionIndex(state.output.codec, state.output.pin, state.output.converter)) |connection_index| {
        state.output_connection_index = connection_index;
        state.output_connection_set = setConnectionSelect(state.output.codec, state.output.pin, connection_index);
    }
    if (!setPinControl(state.output.codec, state.output.pin, state.output_pin_control)) {
        state.output_path_fail_count += 1;
        noteHdaWarn(ctx, "pin output enable failed");
        return false;
    }
    if ((state.output.pin_caps & PIN_CAP_EAPD) != 0) {
        state.output_eapd_set = setEapd(state.output.codec, state.output.pin);
    }
    state.output_converter_unmuted = unmuteOutput(state.output.codec, state.output.converter, state.output.converter_caps);
    state.output_pin_unmuted = unmuteOutput(state.output.codec, state.output.pin, state.output.pin_widget_caps);

    state.output_path_ok = true;
    logOutputPath(ctx);
    return true;
}

fn setupStreamDma(ctx: *const r4os.r4dev.DriverContext) bool {
    state.dma_ready = false;
    if (!state.output_path_ok) return false;
    if (state.output_stream_count == 0) {
        state.dma_fail_count += 1;
        noteHdaWarn(ctx, "no output stream descriptor");
        return false;
    }
    if (!allocStreamDma(ctx)) {
        state.dma_fail_count += 1;
        noteHdaWarn(ctx, "stream DMA allocation failed");
        return false;
    }

    state.stream_desc_index = state.input_stream_count;
    state.stream_desc_offset = REG_STREAM_BASE + (@as(u64, state.stream_desc_index) * STREAM_DESC_SIZE);
    state.stream_desc_base = mmioBase() + state.stream_desc_offset;
    state.stream_buffer_count = @intCast(DMA_BUFFER_COUNT);
    state.stream_buffer_bytes = @intCast(DMA_BUFFER_BYTES);
    state.stream_total_bytes = @intCast(DMA_BUFFER_COUNT * DMA_BUFFER_BYTES);
    state.stream_format = HDA_FORMAT_48K_STEREO_S16;

    if (!resetStreamDescriptor(ctx)) {
        state.dma_fail_count += 1;
        return false;
    }
    clearStreamBuffers();
    programBdl();
    programStreamDescriptorRegisters();
    state.next_dma_index = 0;
    state.previous_stream_status = 0;
    updateStreamStatus();
    state.dma_ready = true;
    logStreamDma(ctx);
    return true;
}

fn allocStreamDma(ctx: *const r4os.r4dev.DriverContext) bool {
    if (state.stream_bdl.phys_addr == 0) {
        if (ctx.allocDmaRegion(@intCast(@sizeOf(BdlEntry) * DMA_BUFFER_COUNT), 128, &state.stream_bdl) != 0) return false;
        if (state.stream_bdl.phys_addr == 0 or state.stream_bdl.virt_addr == 0) return false;
    }

    var i: usize = 0;
    while (i < DMA_BUFFER_COUNT) : (i += 1) {
        if (state.stream_dma[i].phys_addr != 0) continue;
        if (ctx.allocDmaRegion(@intCast(DMA_BUFFER_BYTES), 128, &state.stream_dma[i]) != 0) return false;
        if (state.stream_dma[i].phys_addr == 0 or state.stream_dma[i].virt_addr == 0) return false;
    }
    return true;
}

fn resetStreamDescriptor(ctx: *const r4os.r4dev.DriverContext) bool {
    state.reset_stream_count += 1;
    const control = read32(state.stream_desc_base + SD_CTL);
    write32(state.stream_desc_base + SD_CTL, control & ~SD_CTL_RUN);
    if (!wait32Clear(state.stream_desc_base + SD_CTL, SD_CTL_RUN, STREAM_GUARD)) {
        noteHdaWarn(ctx, "output stream did not stop");
        return false;
    }
    write32(state.stream_desc_base + SD_CTL, read32(state.stream_desc_base + SD_CTL) | SD_CTL_SRST);
    if (!wait32Set(state.stream_desc_base + SD_CTL, SD_CTL_SRST, STREAM_GUARD)) {
        noteHdaWarn(ctx, "output stream reset did not assert");
        return false;
    }
    write32(state.stream_desc_base + SD_CTL, read32(state.stream_desc_base + SD_CTL) & ~SD_CTL_SRST);
    if (!wait32Clear(state.stream_desc_base + SD_CTL, SD_CTL_SRST, STREAM_GUARD)) {
        noteHdaWarn(ctx, "output stream reset did not clear");
        return false;
    }
    const stream_bits: u32 = @as(u32, state.output_stream_id & 0x0F) << SD_CTL_STREAM_SHIFT;
    write32(state.stream_desc_base + SD_CTL, stream_bits);
    return true;
}

fn clearStreamBuffers() void {
    var i: usize = 0;
    while (i < DMA_BUFFER_COUNT) : (i += 1) {
        if (state.stream_dma[i].virt_addr == 0) continue;
        const ptr: [*]u8 = @ptrFromInt(state.stream_dma[i].virt_addr);
        var j: usize = 0;
        while (j < DMA_BUFFER_BYTES) : (j += 1) ptr[j] = 0;
    }
}

fn programBdl() void {
    if (state.stream_bdl.virt_addr == 0) return;
    const bdl: [*]volatile BdlEntry = @ptrFromInt(state.stream_bdl.virt_addr);
    var i: usize = 0;
    while (i < DMA_BUFFER_COUNT) : (i += 1) {
        bdl[i] = .{
            .addr = state.stream_dma[i].phys_addr,
            .length = @intCast(DMA_BUFFER_BYTES),
            .flags = HDA_BDL_IOC,
        };
    }
}

fn programStreamDescriptorRegisters() void {
    write32(state.stream_desc_base + SD_BDPL, @truncate(state.stream_bdl.phys_addr));
    write32(state.stream_desc_base + SD_BDPU, @truncate(state.stream_bdl.phys_addr >> 32));
    write32(state.stream_desc_base + SD_CBL, state.stream_total_bytes);
    write16(state.stream_desc_base + SD_LVI, @intCast(DMA_BUFFER_COUNT - 1));
    write16(state.stream_desc_base + SD_FORMAT, state.stream_format);
    write8(state.stream_desc_base + SD_STS, SD_STS_CLEAR);
}

fn registerPlaybackBackend(ctx: *const r4os.r4dev.DriverContext) bool {
    state.backend = .{
        .formats = r4os.abi.audio_backend_format_s16le | r4os.abi.audio_backend_format_u8,
        .min_rate = MIN_RATE,
        .max_rate = MAX_RATE,
        .preferred_rate = pcm.TARGET_RATE,
        .max_channels = pcm.TARGET_CHANNELS,
        .write_pcm = writePcm,
        .stop = stopPlaybackBackend,
        .shutdown = shutdownBackend,
        .status = backendStatus,
    };
    const rc = ctx.registerAudioOutputBackend("HDA", &state.backend);
    state.last_result = rc;
    if (rc != 0) {
        state.error_count += 1;
        return false;
    }
    state.backend_registered = true;
    return true;
}

fn unregisterPlaybackBackend(ctx: *const r4os.r4dev.DriverContext) void {
    if (!state.backend_registered) return;
    _ = ctx.unregisterAudioBackend("HDA");
    state.backend_registered = false;
}

fn writePcm(context_arg: ?*anyopaque, data: [*]const u8, len: u32, rate: u32, channels: u16, format: u16) callconv(.c) i32 {
    _ = context_arg;
    var ctx = context();
    const write_start = ctx.tickCount();
    if (!state.present or !state.dma_ready) return finishWrite(-1, write_start);
    const input = data[0..@as(usize, @intCast(len))];
    if (pcm.outputFrameCount(input.len, rate, channels, format) == 0) {
        state.empty_write_count += 1;
        return finishWrite(-2, write_start);
    }

    state.last_source_rate = rate;
    state.last_source_channels = channels;
    state.last_source_format = format;
    state.last_output_bytes = 0;
    state.last_output_buffers = 0;
    state.resampler_state.beginChunk(rate, channels, format);

    if (!preparePlaybackWrite(&ctx)) return setLastResult(-3);

    var produced_any = false;
    var guard: usize = 0;
    while (guard < DMA_BUFFER_COUNT) : (guard += 1) {
        const buffer_index = state.next_dma_index;
        if (!waitDmaSlotReusable(&ctx, buffer_index)) {
            _ = recoverStream(&ctx, "refill timeout");
            return finishWrite(-4, write_start);
        }
        const refill_start = ctx.tickCount();
        const out = dmaSlice(buffer_index) orelse return finishWrite(-5, write_start);
        const converted = pcm.convertStreamingToStereoS16(&state.resampler_state, input, rate, channels, format, out);
        if (converted < pcm.TARGET_FRAME_BYTES) break;
        zeroTail(buffer_index, converted);
        queueBdlEntry(buffer_index, DMA_BUFFER_BYTES);
        state.last_output_bytes += converted;
        state.last_output_buffers += 1;
        state.converted_frame_count += converted / pcm.TARGET_FRAME_BYTES;
        state.refill_count += 1;
        recordTickStat(&state.refill_total_ticks, &state.refill_max_ticks, &state.refill_last_ticks, refill_start);
        produced_any = true;
        state.next_dma_index = (state.next_dma_index + 1) % DMA_BUFFER_COUNT;
    }

    if (!produced_any or state.last_output_bytes == 0 or state.last_output_buffers == 0) {
        state.empty_write_count += 1;
        return finishWrite(-6, write_start);
    }

    fillSilenceSlot(state.next_dma_index);
    state.write_count += 1;
    startPlaybackIfNeeded();
    serviceStreamStatus(&ctx);
    return finishWrite(0, write_start);
}

fn stopPlaybackBackend(context_arg: ?*anyopaque) callconv(.c) i32 {
    _ = context_arg;
    var ctx = context();
    stopPlayback(&ctx);
    return setLastResult(0);
}

fn shutdownBackend(context_arg: ?*anyopaque) callconv(.c) i32 {
    _ = context_arg;
    var ctx = context();
    shutdownHardware(&ctx);
    return setLastResult(0);
}

fn backendStatus(context_arg: ?*anyopaque, out: *r4os.abi.AudioBackendStatus) callconv(.c) i32 {
    _ = context_arg;
    out.* = .{
        .active = if (state.present and state.backend_registered and state.dma_ready) 1 else 0,
        .writes = state.write_count,
        .underruns = state.refill_timeout_count + state.drain_timeout_count,
        .errors = state.error_count + state.timeout_count + state.fifo_error_count + state.descriptor_error_count,
        .last_result = state.last_result,
        .reserved = 0,
        .refills = state.refill_count,
        .silence_refills = state.silence_refill_count,
        .buffer_bytes = @intCast(state.stream_total_bytes),
        .queued_buffers = @intCast(state.last_output_buffers),
        .last_buffer_bytes = @intCast(state.last_output_bytes),
        .last_write_ticks = state.write_last_ticks,
        .max_write_ticks = state.write_max_ticks,
        .total_write_ticks = state.write_total_ticks,
        .last_refill_ticks = state.refill_last_ticks,
        .max_refill_ticks = state.refill_max_ticks,
        .total_refill_ticks = state.refill_total_ticks,
    };
    return 0;
}

fn preparePlaybackWrite(ctx: *const r4os.r4dev.DriverContext) bool {
    serviceStreamStatus(ctx);
    if (state.playback_started) return true;
    if (!resetStreamDescriptor(ctx)) {
        noteHdaWarn(ctx, "prepare reset failed");
        return false;
    }
    clearStreamBuffers();
    programBdl();
    programStreamDescriptorRegisters();
    state.next_dma_index = 0;
    return true;
}

fn zeroTail(buffer_index: usize, used: usize) void {
    if (used >= DMA_BUFFER_BYTES) return;
    const out = dmaSlice(buffer_index) orelse return;
    var i = used;
    while (i < out.len) : (i += 1) out[i] = 0;
}

fn fillSilenceSlot(index: usize) void {
    const out = dmaSlice(index) orelse return;
    var i: usize = 0;
    while (i < out.len) : (i += 1) out[i] = 0;
    queueBdlEntry(index, DMA_BUFFER_BYTES);
    state.silence_refill_count += 1;
}

fn queueBdlEntry(index: usize, len: usize) void {
    if (state.stream_bdl.virt_addr == 0 or index >= DMA_BUFFER_COUNT) return;
    const bdl: [*]volatile BdlEntry = @ptrFromInt(state.stream_bdl.virt_addr);
    bdl[index] = .{
        .addr = state.stream_dma[index].phys_addr,
        .length = @intCast(len),
        .flags = HDA_BDL_IOC,
    };
}

fn updateStreamStatus() void {
    if (state.stream_desc_base == 0) return;
    state.stream_ctl_last = read32(state.stream_desc_base + SD_CTL);
    state.stream_sts_last = read8(state.stream_desc_base + SD_STS);
    state.stream_lpib_last = read32(state.stream_desc_base + SD_LPIB);
}

fn serviceStreamStatus(ctx: *const r4os.r4dev.DriverContext) void {
    if (!state.dma_ready or state.stream_desc_base == 0) return;
    state.poll_count += 1;
    const status = read8(state.stream_desc_base + SD_STS);
    const raised = status & ~state.previous_stream_status;
    if ((raised & SD_STS_BCIS) != 0) state.bcis_count += 1;
    if ((raised & SD_STS_FIFOE) != 0) {
        state.fifo_error_count += 1;
        noteHdaWarn(ctx, "stream fifo error");
    }
    if ((raised & SD_STS_DESE) != 0) {
        state.descriptor_error_count += 1;
        noteHdaWarn(ctx, "stream descriptor error");
    }
    if ((status & SD_STS_CLEAR) != 0) write8(state.stream_desc_base + SD_STS, status & SD_STS_CLEAR);
    state.previous_stream_status = read8(state.stream_desc_base + SD_STS);
    updateStreamStatus();
}

fn waitDmaSlotReusable(ctx: *const r4os.r4dev.DriverContext, index: usize) bool {
    if (!state.playback_started) return true;
    const deadline = ctx.tickCount() + msTicks(ctx, PLAYBACK_WAIT_MS);
    while (ctx.tickCount() <= deadline) {
        serviceStreamStatus(ctx);
        if ((read32(state.stream_desc_base + SD_CTL) & SD_CTL_RUN) == 0) return true;
        if (currentDmaSlot() != index) return true;
    }
    state.refill_timeout_count += 1;
    noteHdaWarn(ctx, "refill timeout");
    return false;
}

fn currentDmaSlot() usize {
    if (state.stream_buffer_bytes == 0) return 0;
    const byte_pos: usize = @intCast(read32(state.stream_desc_base + SD_LPIB));
    return (byte_pos / @as(usize, @intCast(state.stream_buffer_bytes))) % DMA_BUFFER_COUNT;
}

fn startPlaybackIfNeeded() void {
    if (state.playback_started) return;
    programStreamDescriptorRegisters();
    const stream_bits: u32 = @as(u32, state.output_stream_id & 0x0F) << SD_CTL_STREAM_SHIFT;
    write32(state.stream_desc_base + SD_CTL, stream_bits | SD_CTL_RUN);
    state.playback_started = true;
    state.start_count += 1;
    updateStreamStatus();
}

fn drainPlayback(ctx: *const r4os.r4dev.DriverContext) void {
    if (!state.playback_started) return;
    state.drain_count += 1;
    const start_tick = ctx.tickCount();
    const deadline = start_tick + msTicks(ctx, DRAIN_WAIT_MS);
    var drained = false;
    while (ctx.tickCount() <= deadline) {
        serviceStreamStatus(ctx);
        if ((read32(state.stream_desc_base + SD_CTL) & SD_CTL_RUN) == 0) {
            drained = true;
            break;
        }
        if (currentDmaSlot() == state.next_dma_index) {
            drained = true;
            break;
        }
    }
    state.last_drain_wait_ticks = ctx.tickCount() - start_tick;
    if (!drained) {
        state.drain_timeout_count += 1;
        noteHdaWarn(ctx, "drain timeout");
    }
}

fn stopPlayback(ctx: *const r4os.r4dev.DriverContext) void {
    if (!state.dma_ready or state.stream_desc_base == 0) return;
    drainPlayback(ctx);
    const control = read32(state.stream_desc_base + SD_CTL);
    write32(state.stream_desc_base + SD_CTL, control & ~SD_CTL_RUN);
    if (!wait32Clear(state.stream_desc_base + SD_CTL, SD_CTL_RUN, STREAM_GUARD)) {
        state.error_count += 1;
        _ = recoverStream(ctx, "stop timeout");
        return;
    }
    write8(state.stream_desc_base + SD_STS, SD_STS_CLEAR);
    state.playback_started = false;
    state.next_dma_index = 0;
    state.resampler_state.reset();
    state.stop_count += 1;
    updateStreamStatus();
}

fn recoverStream(ctx: *const r4os.r4dev.DriverContext, reason: [*:0]const u8) bool {
    if (!state.dma_ready) return false;
    state.stream_recovery_count += 1;
    state.last_recovery = reason;
    state.playback_started = false;
    if (!resetStreamDescriptor(ctx)) {
        state.dma_fail_count += 1;
        noteHdaWarn(ctx, "stream recovery reset failed");
        return false;
    }
    clearStreamBuffers();
    programBdl();
    programStreamDescriptorRegisters();
    state.next_dma_index = 0;
    state.previous_stream_status = 0;
    state.resampler_state.reset();
    updateStreamStatus();
    return true;
}

fn shutdownHardware(ctx: *const r4os.r4dev.DriverContext) void {
    stopPlayback(ctx);
    if (state.stream_desc_base != 0) {
        write32(state.stream_desc_base + SD_CTL, read32(state.stream_desc_base + SD_CTL) & ~SD_CTL_RUN);
        write8(state.stream_desc_base + SD_STS, SD_STS_CLEAR);
    }
    clearStreamBuffers();

    var i: usize = 0;
    while (i < DMA_BUFFER_COUNT) : (i += 1) {
        if (state.stream_dma[i].phys_addr != 0) {
            ctx.freeDmaRegion(&state.stream_dma[i]);
            state.stream_dma[i] = .{};
        }
    }
    if (state.stream_bdl.phys_addr != 0) {
        ctx.freeDmaRegion(&state.stream_bdl);
        state.stream_bdl = .{};
    }
    state.initialized = false;
    state.present = false;
    state.dma_ready = false;
    state.playback_started = false;
    state.next_dma_index = 0;
    state.backend_registered = false;
}

fn dmaSlice(index: usize) ?[]u8 {
    if (index >= DMA_BUFFER_COUNT) return null;
    const buffer = state.stream_dma[index];
    if (buffer.virt_addr == 0 or buffer.bytes == 0) return null;
    const available: usize = @intCast(buffer.bytes);
    const bytes = if (available < DMA_BUFFER_BYTES) available else DMA_BUFFER_BYTES;
    const ptr: [*]u8 = @ptrFromInt(buffer.virt_addr);
    return ptr[0..bytes];
}

fn setLastResult(result: i32) i32 {
    state.last_result = result;
    if (result < 0) state.error_count += 1;
    return result;
}

fn finishWrite(result: i32, start_tick: u64) i32 {
    recordTickStat(&state.write_total_ticks, &state.write_max_ticks, &state.write_last_ticks, start_tick);
    return setLastResult(result);
}

fn recordTickStat(total: *u64, max: *u64, last: *u64, start_tick: u64) void {
    const now = context().tickCount();
    const elapsed = if (now >= start_tick) now - start_tick else 0;
    total.* +%= elapsed;
    last.* = elapsed;
    if (elapsed > max.*) max.* = elapsed;
}

fn noteHdaWarn(ctx: *const r4os.r4dev.DriverContext, message: [*:0]const u8) void {
    state.last_error = message;
    ctx.logWarn(message);
}

fn getParameter(codec: u8, node: u8, parameter: u8) ?u32 {
    return sendImmediateVerb(makeVerb(codec, node, 0xF00, parameter));
}

fn setConverterStreamChannel(codec: u8, node: u8, stream_id: u8, channel_id: u8) bool {
    const payload: u8 = ((stream_id & 0x0F) << 4) | (channel_id & 0x0F);
    return sendImmediateVerb(makeVerb(codec, node, 0x706, payload)) != null;
}

fn setPinControl(codec: u8, node: u8, control: u8) bool {
    return sendImmediateVerb(makeVerb(codec, node, 0x707, control)) != null;
}

fn setConnectionSelect(codec: u8, node: u8, index: u8) bool {
    return sendImmediateVerb(makeVerb(codec, node, 0x701, index)) != null;
}

fn setEapd(codec: u8, node: u8) bool {
    return sendImmediateVerb(makeVerb(codec, node, 0x70C, EAPD_BTL_ENABLE)) != null;
}

fn unmuteOutput(codec: u8, node: u8, caps: u32) bool {
    if ((caps & WIDGET_CAP_OUT_AMP) == 0) return false;
    const payload: u16 = 0xB000 | 0x40;
    return sendImmediateVerb(makeLongVerb(codec, node, 0x3, payload)) != null;
}

fn findConnectionIndex(codec: u8, pin_node: u8, target_node: u8) ?u8 {
    const list_info = getParameter(codec, pin_node, PARAM_CONNECTION_LIST_LENGTH) orelse return null;
    const count: u8 = @truncate(list_info & 0x7F);
    const long_form = (list_info & 0x80) != 0;
    if (count == 0) return null;

    var index: u8 = 0;
    while (index < count) : (index += 1) {
        const command_index = if (long_form) index & 0xFE else index & 0xFC;
        const entry_block = sendImmediateVerb(makeVerb(codec, pin_node, 0xF02, command_index)) orelse return null;
        const entry_node: u16 = if (long_form)
            @truncate((entry_block >> @as(u5, @truncate((index & 1) * 16))) & 0xFFFF)
        else
            @truncate((entry_block >> @as(u5, @truncate((index & 3) * 8))) & 0xFF);
        if (entry_node == target_node) return index;
    }
    return null;
}

fn sendImmediateVerb(verb: u32) ?u32 {
    const base = mmioBase();
    if (!wait16Clear(base + REG_ICIS, ICIS_BUSY, COMMAND_GUARD)) {
        state.timeout_count += 1;
        return null;
    }
    write16(base + REG_ICIS, ICIS_VALID);
    write32(base + REG_ICOI, verb);
    write16(base + REG_ICIS, ICIS_BUSY);
    if (!wait16Clear(base + REG_ICIS, ICIS_BUSY, COMMAND_GUARD)) {
        state.timeout_count += 1;
        return null;
    }
    if ((read16(base + REG_ICIS) & ICIS_VALID) == 0) {
        state.timeout_count += 1;
        return null;
    }

    const response = read32(base + REG_ICII);
    write16(base + REG_ICIS, ICIS_VALID);
    state.command_count += 1;
    state.response_count += 1;
    return response;
}

fn clearCodecInfo() void {
    state.discovered_codec_count = 0;
    var i: usize = 0;
    while (i < MAX_CODECS) : (i += 1) state.codecs[i] = .{};
}

fn mmioBase() u64 {
    return state.mmio.virt_addr;
}

fn makeVerb(codec: u8, node: u8, verb: u16, payload: u8) u32 {
    return (@as(u32, codec & 0x0F) << 28) |
        (@as(u32, node) << 20) |
        (@as(u32, verb & 0x0FFF) << 8) |
        @as(u32, payload);
}

fn makeLongVerb(codec: u8, node: u8, verb: u16, payload: u16) u32 {
    return (@as(u32, codec & 0x0F) << 28) |
        (@as(u32, node) << 20) |
        (@as(u32, verb & 0x000F) << 16) |
        @as(u32, payload);
}

fn firstCodecAddress() ?u8 {
    var i: u8 = 0;
    while (i < 15) : (i += 1) {
        if ((state.codec_mask & (@as(u16, 1) << @intCast(i))) != 0) return i;
    }
    return null;
}

fn subNodeStart(value: u32) u8 {
    return @truncate((value >> 16) & 0xFF);
}

fn subNodeCount(value: u32) u8 {
    return @truncate(value & 0xFF);
}

fn isRelevantWidget(kind: u8) bool {
    return kind == WIDGET_AUDIO_OUTPUT or
        kind == WIDGET_PIN_COMPLEX or
        kind == WIDGET_AUDIO_MIXER or
        kind == WIDGET_AUDIO_SELECTOR;
}

fn countBits16(value: u16) u8 {
    var v = value;
    var count: u8 = 0;
    while (v != 0) : (v >>= 1) {
        if ((v & 1) != 0) count += 1;
    }
    return count;
}

fn optionEnabled(ctx: *const r4os.r4dev.DriverContext, key: [*:0]const u8) bool {
    const value = ctx.getOption("HDA", key);
    return zEq(value, "1") or zEq(value, "yes") or zEq(value, "true") or zEq(value, "on");
}

fn zEq(z: [*:0]const u8, text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (upper(z[i]) != upper(text[i])) return false;
    }
    return z[i] == 0;
}

fn failStage(stage: InitStage) void {
    state.stage = .failed;
    state.failed_stage = stage;
}

fn context() r4os.r4dev.DriverContext {
    return r4os.r4dev.DriverContext.init(state.api);
}

fn read8(addr: u64) u8 {
    const ptr: *volatile u8 = @ptrFromInt(addr);
    return ptr.*;
}

fn read16(addr: u64) u16 {
    const ptr: *volatile u16 = @ptrFromInt(addr);
    return ptr.*;
}

fn read32(addr: u64) u32 {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    return ptr.*;
}

fn write8(addr: u64, value: u8) void {
    const ptr: *volatile u8 = @ptrFromInt(addr);
    ptr.* = value;
}

fn write16(addr: u64, value: u16) void {
    const ptr: *volatile u16 = @ptrFromInt(addr);
    ptr.* = value;
}

fn write32(addr: u64, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    ptr.* = value;
}

fn wait16Clear(addr: u64, mask: u16, limit: u32) bool {
    var guard: u32 = 0;
    while ((read16(addr) & mask) != 0 and guard < limit) : (guard += 1) {}
    return (read16(addr) & mask) == 0;
}

fn wait32Set(addr: u64, mask: u32, limit: u32) bool {
    var guard: u32 = 0;
    while ((read32(addr) & mask) == 0 and guard < limit) : (guard += 1) {}
    return (read32(addr) & mask) != 0;
}

fn wait32Clear(addr: u64, mask: u32, limit: u32) bool {
    var guard: u32 = 0;
    while ((read32(addr) & mask) != 0 and guard < limit) : (guard += 1) {}
    return (read32(addr) & mask) == 0;
}

fn logDevice(ctx: *const r4os.r4dev.DriverContext, info: r4os.abi.PciDeviceInfo) void {
    var line: [128:0]u8 = undefined;
    var len: usize = 0;
    appendText(&line, &len, "HDA.R4D device ");
    appendDec(&line, &len, info.bus);
    appendText(&line, &len, ":");
    appendDec(&line, &len, info.device);
    appendText(&line, &len, ".");
    appendDec(&line, &len, info.function);
    appendText(&line, &len, " vendor=0x");
    appendHex(&line, &len, info.vendor_id, 4);
    appendText(&line, &len, " device=0x");
    appendHex(&line, &len, info.device_id, 4);
    appendText(&line, &len, " irq=");
    appendDec(&line, &len, info.interrupt_line);
    logLine(ctx, &line, len);
}

fn logMmio(ctx: *const r4os.r4dev.DriverContext) void {
    var line: [160:0]u8 = undefined;
    var len: usize = 0;
    appendText(&line, &len, "HDA.R4D mmio phys=0x");
    appendHex(&line, &len, state.mmio.phys_addr, 16);
    appendText(&line, &len, " virt=0x");
    appendHex(&line, &len, state.mmio.virt_addr, 16);
    appendText(&line, &len, " gcap=0x");
    appendHex(&line, &len, state.gcap, 4);
    appendText(&line, &len, " ver=");
    appendDec(&line, &len, state.version_major);
    appendText(&line, &len, ".");
    appendDec(&line, &len, state.version_minor);
    appendText(&line, &len, " streams=");
    appendDec(&line, &len, state.output_stream_count);
    appendText(&line, &len, "/");
    appendDec(&line, &len, state.input_stream_count);
    appendText(&line, &len, "/");
    appendDec(&line, &len, state.bidi_stream_count);
    appendText(&line, &len, " codec-mask=0x");
    appendHex(&line, &len, state.codec_mask, 4);
    logLine(ctx, &line, len);
}

fn logTransport(ctx: *const r4os.r4dev.DriverContext, codec: u8, vendor_id: u32) void {
    var line: [96:0]u8 = undefined;
    var len: usize = 0;
    appendText(&line, &len, "HDA.R4D transport immediate codec=");
    appendDec(&line, &len, codec);
    appendText(&line, &len, " vendor=0x");
    appendHex(&line, &len, vendor_id, 8);
    logLine(ctx, &line, len);
}

fn logCodecInfo(ctx: *const r4os.r4dev.DriverContext, info: *const CodecInfo) void {
    var line: [144:0]u8 = undefined;
    var len: usize = 0;
    appendText(&line, &len, "HDA.R4D codec ");
    appendDec(&line, &len, info.address);
    appendText(&line, &len, " vendor=0x");
    appendHex(&line, &len, info.vendor_id, 8);
    appendText(&line, &len, " rev=0x");
    appendHex(&line, &len, info.revision_id, 8);
    appendText(&line, &len, " afg=");
    appendDec(&line, &len, info.afg_node);
    appendText(&line, &len, " widgets=");
    appendDec(&line, &len, info.discovered_widgets);
    appendText(&line, &len, " out=");
    appendDec(&line, &len, info.output_count);
    appendText(&line, &len, " pin=");
    appendDec(&line, &len, info.pin_count);
    logLine(ctx, &line, len);
}

fn logOutputCandidate(ctx: *const r4os.r4dev.DriverContext) void {
    var line: [112:0]u8 = undefined;
    var len: usize = 0;
    appendText(&line, &len, "HDA.R4D output candidate codec=");
    appendDec(&line, &len, state.output.codec);
    appendText(&line, &len, " afg=");
    appendDec(&line, &len, state.output.afg);
    appendText(&line, &len, " conv=");
    appendDec(&line, &len, state.output.converter);
    appendText(&line, &len, " pin=");
    appendDec(&line, &len, state.output.pin);
    logLine(ctx, &line, len);
}

fn logOutputPath(ctx: *const r4os.r4dev.DriverContext) void {
    var line: [144:0]u8 = undefined;
    var len: usize = 0;
    appendText(&line, &len, "HDA.R4D output path codec=");
    appendDec(&line, &len, state.output.codec);
    appendText(&line, &len, " afg=");
    appendDec(&line, &len, state.output.afg);
    appendText(&line, &len, " conv=");
    appendDec(&line, &len, state.output.converter);
    appendText(&line, &len, " pin=");
    appendDec(&line, &len, state.output.pin);
    appendText(&line, &len, " stream=");
    appendDec(&line, &len, state.output_stream_id);
    appendText(&line, &len, " eapd=");
    appendText(&line, &len, if (state.output_eapd_set) "yes" else "no");
    logLine(ctx, &line, len);
}

fn logStreamDma(ctx: *const r4os.r4dev.DriverContext) void {
    var line: [128:0]u8 = undefined;
    var len: usize = 0;
    appendText(&line, &len, "HDA.R4D stream dma desc=");
    appendDec(&line, &len, state.stream_desc_index);
    appendText(&line, &len, " bdl=0x");
    appendHex(&line, &len, state.stream_bdl.phys_addr, 16);
    appendText(&line, &len, " buffers=");
    appendDec(&line, &len, DMA_BUFFER_COUNT);
    appendText(&line, &len, " bytes=");
    appendDec(&line, &len, DMA_BUFFER_BYTES);
    appendText(&line, &len, " format=0x");
    appendHex(&line, &len, state.stream_format, 4);
    logLine(ctx, &line, len);
}

fn logPlaybackReady(ctx: *const r4os.r4dev.DriverContext) void {
    var line: [160:0]u8 = undefined;
    var len: usize = 0;
    appendText(&line, &len, "HDA.R4D playback backend ready codecs=");
    appendDec(&line, &len, state.discovered_codec_count);
    appendText(&line, &len, " transport=immediate reset=");
    appendText(&line, &len, if (state.reset_done) "done" else "passive");
    appendText(&line, &len, " commands=");
    appendDec(&line, &len, state.command_count);
    appendText(&line, &len, " backend=");
    appendText(&line, &len, if (state.backend_registered) "registered" else "missing");
    logLine(ctx, &line, len);
}

fn logLine(ctx: *const r4os.r4dev.DriverContext, line: anytype, len: usize) void {
    var capped = len;
    if (capped >= line.len) capped = line.len - 1;
    line[capped] = 0;
    const text: [*:0]u8 = @ptrCast(line);
    ctx.logInfo(text);
}

fn appendText(buf: anytype, len: *usize, text: []const u8) void {
    var i: usize = 0;
    while (i < text.len and len.* + 1 < buf.len) : (i += 1) {
        buf[len.*] = text[i];
        len.* += 1;
    }
}

fn appendDec(buf: anytype, len: *usize, value: anytype) void {
    var n: u64 = @intCast(value);
    var tmp: [20]u8 = undefined;
    var count: usize = 0;
    if (n == 0) {
        appendText(buf, len, "0");
        return;
    }
    while (n > 0 and count < tmp.len) : (count += 1) {
        tmp[count] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
    }
    while (count > 0) {
        count -= 1;
        if (len.* + 1 >= buf.len) return;
        buf[len.*] = tmp[count];
        len.* += 1;
    }
}

fn appendHex(buf: anytype, len: *usize, value: anytype, digits: usize) void {
    const hex = "0123456789ABCDEF";
    const raw: u64 = @intCast(value);
    var shift: usize = digits * 4;
    while (shift > 0) {
        shift -= 4;
        const nibble: usize = @intCast((raw >> @intCast(shift)) & 0xF);
        if (len.* + 1 >= buf.len) return;
        buf[len.*] = hex[nibble];
        len.* += 1;
    }
}

fn upper(c: u8) u8 {
    if (c >= 'a' and c <= 'z') return c - ('a' - 'A');
    return c;
}
