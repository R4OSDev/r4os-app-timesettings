const r4os = @import("r4os");
const r4std = @import("r4std");
const AppApi = struct {
    sys: r4os.r4sys.Context,
    desk: r4os.r4desk.Context,
    draw: r4os.r4draw.Context,
    net: r4os.r4net.Context,
    dev: r4os.r4dev.Context,

    fn init(r4_app: *r4os.App) ?AppApi {
        return .{
            .sys = r4_app.system(),
            .desk = r4_app.desktop() orelse return null,
            .draw = r4_app.drawing() orelse return null,
            .net = r4_app.networkLowLevel() orelse return null,
            .dev = r4_app.devicesLowLevel() orelse return null,
        };
    }
};

const app_bg = r4os.gui.default_palette.face;
const status_bg: u32 = 0xD8D8D8;
const text = r4os.gui.default_palette.text;
const dropdown_rows: usize = 8;

const FocusTarget = enum(usize) {
    timezone,
    year_dec,
    year_inc,
    month_dec,
    month_inc,
    day_dec,
    day_inc,
    format_toggle,
    apply,
    ok,
    cancel,
};

const focus_items = [_]r4os.gui.FocusItem{
    .{},
    .{},
    .{},
    .{},
    .{},
    .{},
    .{},
    .{},
    .{},
    .{},
    .{},
};

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    if (!r4std.init(r4_app.startContext())) return r4os.abi.err_no_group;
    var ctx = AppApi.init(r4_app) orelse return r4os.abi.err_no_group;
    if (hasArg(ctx.sys.argsRaw(), "/SELFTEST")) return runSelfTest(&ctx.sys);
    var app = App{ .ctx = &ctx };
    return app.run();
}

const App = struct {
    ctx: *AppApi,
    w: i32 = 460,
    h: i32 = 300,
    should_exit: bool = false,
    config: r4std.time.Config = .{},
    selected_index: usize = r4std.time.utc_index,
    selected_clock_format: u32 = r4os.abi.clock_format_24h,
    date_year: u16 = 2026,
    date_month: u8 = 1,
    date_day: u8 = 1,
    first_index: usize = r4std.time.utc_index,
    dropdown_open: bool = false,
    zone_label_storage: [r4std.time.zone_count][r4std.time.zone_label_max + 1]u8 = undefined,
    zone_labels: [r4std.time.zone_count][]const u8 = undefined,
    focus: r4os.gui.FocusState = .{ .index = focusIndex(.timezone) },
    mouse_capture: r4os.gui.MouseCapture = .{},
    status: [96]u8 = .{0} ** 96,

    fn run(self: *App) i32 {
        if (self.ctx.desk.programWindowId() >= 0) return self.runHosted();
        self.ctx.sys.println("TIMESET is a desktop GUI application.");
        self.ctx.sys.println("Please start from Desktop or through GUI launch.");
        return 0;
    }

    fn runHosted(self: *App) i32 {
        _ = self.ctx.desk.guiSetTitle("Time Settings");
        _ = self.ctx.desk.guiSetMinSize(460, 300);
        self.initZoneLabels(self.ctx.sys.timeState());
        self.loadConfig();
        self.updateMetrics();
        self.render();

        while (!self.ctx.sys.programShouldClose() and !self.should_exit) {
            var event: r4os.abi.GuiEvent = .{};
            while (self.ctx.desk.guiPollEvent(&event) > 0) {
                const kind: r4os.abi.GuiEventKind = @enumFromInt(event.kind);
                switch (kind) {
                    .close => return 0,
                    .resize => {
                        self.updateMetrics();
                        self.render();
                    },
                    .mouse_down => self.handleMouseDown(event.x, event.y),
                    .mouse_up => self.handleMouseUp(event.x, event.y),
                    .key_down => self.handleKey(@intCast(event.key & 0xFF)),
                    else => {},
                }
            }
            self.ctx.sys.sleepTicks(3);
        }
        return 0;
    }

    fn loadConfig(self: *App) void {
        var status: r4os.abi.TimeServiceStatus = .{};
        if (self.ctx.sys.timeServiceStatus(&status) == r4os.abi.service_api_result_ok and status.timezone_index < @as(u32, @intCast(r4std.time.zoneCount()))) {
            self.config.setIndex(@intCast(status.timezone_index));
            self.config.setClockFormat(status.clock_format);
            self.selected_index = self.config.selectedIndex();
            self.selected_clock_format = self.config.selectedClockFormat();
            self.date_year = status.local_year;
            self.date_month = status.local_month;
            self.date_day = status.local_day;
            self.first_index = self.dropdown().firstIndexForSelection();
            self.setStatus("TIMESVC ready.");
            return;
        }
        var buffer: [768]u8 = undefined;
        const len = self.ctx.sys.fileRead(r4std.settings.paths.time, buffer[0..]);
        if (len > 0) _ = self.config.loadFromBytes(buffer[0..@intCast(len)]);
        self.selected_index = self.config.selectedIndex();
        self.selected_clock_format = self.config.selectedClockFormat();
        self.loadDateFromSystemClock();
        self.first_index = self.dropdown().firstIndexForSelection();
        self.setStatus("TIMESVC unavailable.");
    }

    fn initZoneLabels(self: *App, state: r4os.abi.TimeState) void {
        var index: usize = 0;
        while (index < self.zone_labels.len) : (index += 1) {
            self.zone_labels[index] = r4std.time.copyZoneLabelForState(self.zone_label_storage[index][0..], index, state);
        }
    }

    fn updateMetrics(self: *App) void {
        var info: r4os.abi.GuiWindowInfo = .{};
        _ = self.ctx.desk.guiWindowInfo(&info);
        const canvas = r4os.gui.Canvas.init(&self.ctx.draw, info);
        self.w = clampI32(canvas.w, 460, 900);
        self.h = clampI32(canvas.h, 300, 620);
    }

    fn render(self: *App) void {
        var paint = switch (r4os.app_gui.beginPaintForSize(&self.ctx.draw, self.w, self.h)) {
            .paint => |value| value,
            .failure => return,
        };
        defer paint.discard();
        const canvas = paint.canvas;
        var scratch: [128]u8 = .{0} ** 128;
        const time_state = self.ctx.sys.timeState();
        self.initZoneLabels(time_state);
        const offset_minutes = r4std.time.offsetAtState(self.selected_index, self.selectedDateState(time_state));
        var offset: [10]u8 = .{0} ** 10;
        var zone_id: [r4std.time.zone_id_max + 1]u8 = .{0} ** (r4std.time.zone_id_max + 1);
        var title_text: [16]u8 = .{0} ** 16;
        var zone_text: [8]u8 = .{0} ** 8;
        var offset_text: [8]u8 = .{0} ** 8;
        var date_text: [8]u8 = .{0} ** 8;
        var format_label: [8]u8 = .{0} ** 8;
        var year_text: [5]u8 = .{0} ** 5;
        var month_text: [3]u8 = .{0} ** 3;
        var day_text: [3]u8 = .{0} ** 3;
        _ = r4std.time.formatOffset(offset[0..], offset_minutes);
        const id = r4std.time.copyZoneId(zone_id[0..], self.selected_index);
        formatU16(year_text[0..], self.date_year);
        formatU8(month_text[0..], self.date_month);
        formatU8(day_text[0..], self.date_day);

        _ = canvas.clear(app_bg);
        _ = canvas.groupBox(.{ .rect = self.groupRect(), .title = copyLit(title_text[0..], "Time") }, scratch[0..]);
        _ = canvas.label(.{ .rect = .{ .x = 28, .y = 46, .w = 92, .h = 16 }, .text = copyLit(zone_text[0..], "Zone:"), .alignment = .right, .fg = text, .bg = app_bg }, scratch[0..]);
        _ = canvas.dropdown(self.dropdown(), scratch[0..]);
        _ = canvas.label(.{ .rect = .{ .x = 28, .y = 86, .w = 92, .h = 16 }, .text = copyLit(offset_text[0..], "Offset:"), .alignment = .right, .fg = text, .bg = app_bg }, scratch[0..]);
        _ = canvas.label(.{ .rect = .{ .x = 132, .y = 86, .w = 96, .h = 16 }, .text = spanZ(offset[0..]), .fg = text, .bg = app_bg }, scratch[0..]);
        _ = canvas.textClipped(132, 110, self.w - 160, scratch[0..], id, text, app_bg);
        _ = canvas.label(.{ .rect = .{ .x = 28, .y = 146, .w = 92, .h = 16 }, .text = copyLit(date_text[0..], "Date:"), .alignment = .right, .fg = text, .bg = app_bg }, scratch[0..]);
        self.drawButton(canvas, scratch[0..], self.yearDecRect(), "-", .year_dec, false, false);
        _ = canvas.label(.{ .rect = self.yearValueRect(), .text = spanZ(year_text[0..]), .alignment = .center, .fg = text, .bg = app_bg }, scratch[0..]);
        self.drawButton(canvas, scratch[0..], self.yearIncRect(), "+", .year_inc, false, false);
        self.drawButton(canvas, scratch[0..], self.monthDecRect(), "-", .month_dec, false, false);
        _ = canvas.label(.{ .rect = self.monthValueRect(), .text = spanZ(month_text[0..]), .alignment = .center, .fg = text, .bg = app_bg }, scratch[0..]);
        self.drawButton(canvas, scratch[0..], self.monthIncRect(), "+", .month_inc, false, false);
        self.drawButton(canvas, scratch[0..], self.dayDecRect(), "-", .day_dec, false, false);
        _ = canvas.label(.{ .rect = self.dayValueRect(), .text = spanZ(day_text[0..]), .alignment = .center, .fg = text, .bg = app_bg }, scratch[0..]);
        self.drawButton(canvas, scratch[0..], self.dayIncRect(), "+", .day_inc, false, false);
        _ = canvas.label(.{ .rect = .{ .x = 28, .y = 186, .w = 92, .h = 16 }, .text = copyLit(format_label[0..], "Format:"), .alignment = .right, .fg = text, .bg = app_bg }, scratch[0..]);
        self.drawButton(canvas, scratch[0..], self.formatRect(), if (self.selected_clock_format == r4os.abi.clock_format_12h) "12-hour" else "24-hour", .format_toggle, false, false);

        _ = canvas.rect(self.statusRect(), status_bg);
        _ = canvas.label(.{ .rect = self.statusRect().inset(6, 3), .text = spanZ(self.status[0..]), .fg = text, .bg = status_bg }, scratch[0..]);
        self.drawButton(canvas, scratch[0..], self.applyRect(), "Apply", .apply, false, false);
        self.drawButton(canvas, scratch[0..], self.okRect(), "OK", .ok, true, false);
        self.drawButton(canvas, scratch[0..], self.cancelRect(), "Cancel", .cancel, false, true);
        _ = paint.present();
    }

    fn drawButton(self: *App, canvas: r4os.gui.Canvas, scratch: []u8, rect: r4os.gui.Rect, label: []const u8, target: FocusTarget, is_default: bool, is_cancel: bool) void {
        var label_buffer: [16]u8 = .{0} ** 16;
        const safe_label = copyZ(label_buffer[0..], label);
        _ = canvas.button(.{
            .rect = rect,
            .text = safe_label,
            .state = if (self.mouse_capture.isActive(focusIndex(target))) .pressed else .normal,
            .focused = self.hasFocus(target),
            .is_default = is_default,
            .is_cancel = is_cancel,
        }, scratch);
    }

    fn handleMouseDown(self: *App, x: i32, y: i32) void {
        self.mouse_capture.clear();
        const drop = self.dropdown();
        if (self.dropdown_open) {
            if (drop.indexAt(x, y)) |index| {
                self.selectTimezone(index);
                self.dropdown_open = false;
                _ = self.focus.set(focus_items[0..], focusIndex(.timezone));
                self.render();
                return;
            }
            if (!drop.contains(x, y)) {
                self.dropdown_open = false;
                self.render();
                return;
            }
        }
        if (drop.contains(x, y)) {
            _ = self.focus.set(focus_items[0..], focusIndex(.timezone));
            self.dropdown_open = !self.dropdown_open;
            self.first_index = self.dropdown().firstIndexForSelection();
            self.render();
            return;
        }
        if (self.captureButton(x, y, .apply, self.applyRect())) return;
        if (self.captureButton(x, y, .ok, self.okRect())) return;
        if (self.captureButton(x, y, .cancel, self.cancelRect())) return;
        if (self.captureButton(x, y, .year_dec, self.yearDecRect())) return;
        if (self.captureButton(x, y, .year_inc, self.yearIncRect())) return;
        if (self.captureButton(x, y, .month_dec, self.monthDecRect())) return;
        if (self.captureButton(x, y, .month_inc, self.monthIncRect())) return;
        if (self.captureButton(x, y, .day_dec, self.dayDecRect())) return;
        if (self.captureButton(x, y, .day_inc, self.dayIncRect())) return;
        if (self.captureButton(x, y, .format_toggle, self.formatRect())) return;
    }

    fn handleMouseUp(self: *App, x: i32, y: i32) void {
        if (self.releaseButton(x, y, .apply, self.applyRect())) return;
        if (self.releaseButton(x, y, .ok, self.okRect())) return;
        if (self.releaseButton(x, y, .cancel, self.cancelRect())) return;
        if (self.releaseButton(x, y, .year_dec, self.yearDecRect())) return;
        if (self.releaseButton(x, y, .year_inc, self.yearIncRect())) return;
        if (self.releaseButton(x, y, .month_dec, self.monthDecRect())) return;
        if (self.releaseButton(x, y, .month_inc, self.monthIncRect())) return;
        if (self.releaseButton(x, y, .day_dec, self.dayDecRect())) return;
        if (self.releaseButton(x, y, .day_inc, self.dayIncRect())) return;
        if (self.releaseButton(x, y, .format_toggle, self.formatRect())) return;
    }

    fn handleKey(self: *App, key: u8) void {
        if (self.hasFocus(.timezone)) {
            switch (key) {
                r4os.gui.Key.up, r4os.gui.Key.down => {
                    const step = self.dropdown().keyAction(key);
                    if (step.action == .selection_changed) self.selectTimezone(step.index);
                    self.dropdown_open = true;
                    self.render();
                    return;
                },
                r4os.gui.Key.enter, ' ' => {
                    self.dropdown_open = !self.dropdown_open;
                    self.first_index = self.dropdown().firstIndexForSelection();
                    self.render();
                    return;
                },
                r4os.gui.Key.escape => {
                    if (self.dropdown_open) {
                        self.dropdown_open = false;
                        self.render();
                    } else {
                        self.should_exit = true;
                    }
                    return;
                },
                else => {},
            }
        }
        if (self.dropdown_open and (key == r4os.gui.Key.tab or key == r4os.gui.Key.shift_tab)) self.dropdown_open = false;
        const result = self.focus.handleKey(focus_items[0..], key);
        switch (result.action) {
            .changed => self.render(),
            .submitted, .clicked => {
                self.activate(focusedTarget(self.focus.index));
                self.render();
            },
            .cancelled => self.should_exit = true,
            else => {},
        }
    }

    fn captureButton(self: *App, x: i32, y: i32, target: FocusTarget, rect: r4os.gui.Rect) bool {
        if (!rect.contains(x, y)) return false;
        _ = self.focus.set(focus_items[0..], focusIndex(target));
        self.dropdown_open = false;
        self.mouse_capture.begin(focusIndex(target), .clicked);
        self.render();
        return true;
    }

    fn releaseButton(self: *App, x: i32, y: i32, target: FocusTarget, rect: r4os.gui.Rect) bool {
        if (self.mouse_capture.release(focusIndex(target), rect.contains(x, y)) != .clicked) return false;
        self.activate(target);
        self.render();
        return true;
    }

    fn activate(self: *App, target: FocusTarget) void {
        switch (target) {
            .timezone => self.dropdown_open = !self.dropdown_open,
            .year_dec => self.adjustYear(-1),
            .year_inc => self.adjustYear(1),
            .month_dec => self.adjustMonth(-1),
            .month_inc => self.adjustMonth(1),
            .day_dec => self.adjustDay(-1),
            .day_inc => self.adjustDay(1),
            .format_toggle => self.toggleFormat(),
            .apply => self.apply(false),
            .ok => self.apply(true),
            .cancel => self.should_exit = true,
        }
    }

    fn apply(self: *App, close_on_success: bool) void {
        if (!self.applyViaService(close_on_success)) self.setStatus("TIMESVC save failed.");
    }

    fn applyViaService(self: *App, close_on_success: bool) bool {
        if (!r4std.date.validDateValue(self.date_year, self.date_month, self.date_day)) {
            self.setStatus("Invalid date.");
            return true;
        }
        var request = r4os.abi.TimeServiceConfig{
            .timezone_index = @intCast(self.selected_index),
            .clock_format = self.selected_clock_format,
            .date_year = self.date_year,
            .date_month = self.date_month,
            .date_day = self.date_day,
            .flags = r4os.abi.time_service_config_flag_timezone_index |
                r4os.abi.time_service_config_flag_clock_format |
                r4os.abi.time_service_config_flag_date,
        };
        var status: r4os.abi.TimeServiceStatus = .{};
        const rc = self.ctx.sys.timeServiceSetConfig(&request, &status);
        if (rc != r4os.abi.service_api_result_ok) return false;
        self.config.setIndex(@intCast(status.timezone_index));
        self.config.setClockFormat(status.clock_format);
        self.selected_index = self.config.selectedIndex();
        self.selected_clock_format = self.config.selectedClockFormat();
        self.date_year = status.local_year;
        self.date_month = status.local_month;
        self.date_day = status.local_day;
        self.first_index = self.dropdown().firstIndexForSelection();
        self.setStatus("Saved.");
        if (close_on_success) self.should_exit = true;
        return true;
    }

    fn selectTimezone(self: *App, index: usize) void {
        if (index >= r4std.time.zoneCount()) return;
        self.selected_index = index;
        self.first_index = self.dropdown().firstIndexForSelection();
        self.setStatus("Not saved yet.");
    }

    fn adjustYear(self: *App, delta: i32) void {
        var next: i32 = @intCast(self.date_year);
        next += delta;
        if (next < 1980) next = 1980;
        if (next > 2099) next = 2099;
        self.date_year = @intCast(next);
        self.clampDay();
        self.setStatus("Not saved yet.");
    }

    fn adjustMonth(self: *App, delta: i32) void {
        var next: i32 = @intCast(self.date_month);
        next += delta;
        if (next < 1) next = 1;
        if (next > 12) next = 12;
        self.date_month = @intCast(next);
        self.clampDay();
        self.setStatus("Not saved yet.");
    }

    fn adjustDay(self: *App, delta: i32) void {
        var next: i32 = @intCast(self.date_day);
        const max_day: i32 = @intCast(r4std.date.daysInMonth(self.date_year, self.date_month));
        next += delta;
        if (next < 1) next = 1;
        if (next > max_day) next = max_day;
        self.date_day = @intCast(next);
        self.setStatus("Not saved yet.");
    }

    fn toggleFormat(self: *App) void {
        self.selected_clock_format = if (self.selected_clock_format == r4os.abi.clock_format_12h)
            r4os.abi.clock_format_24h
        else
            r4os.abi.clock_format_12h;
        self.setStatus("Not saved yet.");
    }

    fn clampDay(self: *App) void {
        const max_day = r4std.date.daysInMonth(self.date_year, self.date_month);
        if (self.date_day > max_day) self.date_day = max_day;
        if (self.date_day == 0) self.date_day = 1;
    }

    fn loadDateFromSystemClock(self: *App) void {
        const state = self.ctx.sys.timeState();
        if (r4std.time.localDateTimeForConfig(self.config, state)) |local| {
            self.date_year = local.date.year;
            self.date_month = local.date.month;
            self.date_day = local.date.day;
        } else {
            self.date_year = state.year;
            self.date_month = state.month;
            self.date_day = state.day;
        }
        self.clampDay();
    }

    fn selectedDateState(self: *const App, fallback: r4os.abi.TimeState) r4os.abi.TimeState {
        const value = r4std.date.DateTime{
            .date = .{ .year = self.date_year, .month = self.date_month, .day = self.date_day },
            .time = .{ .hour = fallback.hour, .minute = fallback.minute, .second = fallback.second },
        };
        var state = r4std.date.toTimeState(value) orelse fallback;
        state.monotonic_ticks = fallback.monotonic_ticks;
        state.monotonic_hz = fallback.monotonic_hz;
        state.monotonic_backend = fallback.monotonic_backend;
        return state;
    }

    fn dropdown(self: *const App) r4os.gui.Dropdown {
        return .{
            .rect = self.dropdownRect(),
            .items = self.zone_labels[0..],
            .selected_index = self.selected_index,
            .first_index = self.first_index,
            .max_visible_rows = dropdown_rows,
            .open = self.dropdown_open,
            .focused = self.hasFocus(.timezone),
        };
    }

    fn groupRect(self: *const App) r4os.gui.Rect {
        return .{ .x = 12, .y = 12, .w = self.w - 24, .h = self.h - 92 };
    }

    fn dropdownRect(self: *const App) r4os.gui.Rect {
        return .{ .x = 132, .y = 42, .w = @max(250, self.w - 160), .h = 22 };
    }

    fn yearDecRect(self: *const App) r4os.gui.Rect {
        _ = self;
        return .{ .x = 132, .y = 140, .w = 24, .h = 24 };
    }

    fn yearValueRect(self: *const App) r4os.gui.Rect {
        _ = self;
        return .{ .x = 160, .y = 144, .w = 48, .h = 16 };
    }

    fn yearIncRect(self: *const App) r4os.gui.Rect {
        _ = self;
        return .{ .x = 212, .y = 140, .w = 24, .h = 24 };
    }

    fn monthDecRect(self: *const App) r4os.gui.Rect {
        _ = self;
        return .{ .x = 252, .y = 140, .w = 24, .h = 24 };
    }

    fn monthValueRect(self: *const App) r4os.gui.Rect {
        _ = self;
        return .{ .x = 280, .y = 144, .w = 28, .h = 16 };
    }

    fn monthIncRect(self: *const App) r4os.gui.Rect {
        _ = self;
        return .{ .x = 312, .y = 140, .w = 24, .h = 24 };
    }

    fn dayDecRect(self: *const App) r4os.gui.Rect {
        _ = self;
        return .{ .x = 352, .y = 140, .w = 24, .h = 24 };
    }

    fn dayValueRect(self: *const App) r4os.gui.Rect {
        _ = self;
        return .{ .x = 380, .y = 144, .w = 28, .h = 16 };
    }

    fn dayIncRect(self: *const App) r4os.gui.Rect {
        _ = self;
        return .{ .x = 412, .y = 140, .w = 24, .h = 24 };
    }

    fn formatRect(self: *const App) r4os.gui.Rect {
        _ = self;
        return .{ .x = 132, .y = 180, .w = 92, .h = 24 };
    }

    fn statusRect(self: *const App) r4os.gui.Rect {
        return .{ .x = 12, .y = self.h - 72, .w = self.w - 24, .h = 22 };
    }

    fn buttonY(self: *const App) i32 {
        return self.h - 38;
    }

    fn applyRect(self: *const App) r4os.gui.Rect {
        return .{ .x = self.w - 260, .y = self.buttonY(), .w = 72, .h = 24 };
    }

    fn okRect(self: *const App) r4os.gui.Rect {
        return .{ .x = self.w - 176, .y = self.buttonY(), .w = 72, .h = 24 };
    }

    fn cancelRect(self: *const App) r4os.gui.Rect {
        return .{ .x = self.w - 92, .y = self.buttonY(), .w = 80, .h = 24 };
    }

    fn hasFocus(self: *const App, target: FocusTarget) bool {
        return self.focus.index == focusIndex(target);
    }

    fn setStatus(self: *App, value: []const u8) void {
        setZ(self.status[0..], value);
    }
};

fn runSelfTest(ctx: *const r4os.r4sys.Context) i32 {
    ctx.println("TIMESET selftest");
    if (!ensureTimeService(ctx)) return fail(ctx, "timesvc");
    var original: r4os.abi.TimeServiceStatus = .{};
    if (ctx.timeServiceStatus(&original) != r4os.abi.service_api_result_ok) return fail(ctx, "status");
    const restore_index = original.timezone_index;
    const restore_format = original.clock_format;
    const restore_year = original.local_year;
    const restore_month = original.local_month;
    const restore_day = original.local_day;
    defer {
        var ignored: r4os.abi.TimeServiceStatus = .{};
        var request = r4os.abi.TimeServiceConfig{
            .timezone_index = restore_index,
            .clock_format = @as(u32, restore_format),
            .date_year = restore_year,
            .date_month = restore_month,
            .date_day = restore_day,
            .flags = r4os.abi.time_service_config_flag_timezone_index |
                r4os.abi.time_service_config_flag_clock_format |
                r4os.abi.time_service_config_flag_date,
        };
        _ = ctx.timeServiceSetConfig(&request, &ignored);
    }

    const berlin = r4std.time.indexForId("Europe/Berlin") orelse return fail(ctx, "berlin-index");
    var status: r4os.abi.TimeServiceStatus = .{};
    if (ctx.timeServiceSetTimezone(@intCast(berlin), &status) != r4os.abi.service_api_result_ok) return fail(ctx, "save");
    if (status.timezone_index != @as(u32, @intCast(berlin))) return fail(ctx, "status-index");

    var buffer: [384]u8 = undefined;
    const len = ctx.fileRead(r4std.settings.paths.time, buffer[0..]);
    if (len <= 0 or !contains(buffer[0..@intCast(len)], "TIMEZONE=Europe/Berlin")) return fail(ctx, "file");

    if (ctx.timeServiceSetClockFormat(r4os.abi.clock_format_12h, &status) != r4os.abi.service_api_result_ok) return fail(ctx, "format-save");
    if (@as(u32, status.clock_format) != r4os.abi.clock_format_12h) return fail(ctx, "format-status");

    if (ctx.timeServiceSetDate(2026, 5, 14, &status) != r4os.abi.service_api_result_ok) return fail(ctx, "date-save");
    if (status.local_year != 2026 or status.local_month != 5 or status.local_day != 14) return fail(ctx, "date-status");
    if (ctx.timeServiceSetDate(2026, 2, 29, &status) == r4os.abi.service_api_result_ok) return fail(ctx, "bad-date");

    ctx.println("TIMESET selftest: OK");
    return 0;
}

fn focusIndex(target: FocusTarget) usize {
    return @intFromEnum(target);
}

fn focusedTarget(index: usize) FocusTarget {
    return switch (index) {
        1 => .year_dec,
        2 => .year_inc,
        3 => .month_dec,
        4 => .month_inc,
        5 => .day_dec,
        6 => .day_inc,
        7 => .format_toggle,
        8 => .apply,
        9 => .ok,
        10 => .cancel,
        else => .timezone,
    };
}

fn clampI32(value: i32, min: i32, max: i32) i32 {
    if (value < min) return min;
    if (value > max) return max;
    return value;
}

fn setZ(out: []u8, value: []const u8) void {
    @memset(out, 0);
    if (out.len == 0) return;
    const count = @min(value.len, out.len - 1);
    if (count > 0) @memcpy(out[0..count], value[0..count]);
    out[count] = 0;
}

fn copyZ(out: []u8, value: []const u8) []const u8 {
    setZ(out, value);
    return spanZ(out);
}

fn copyLit(out: []u8, comptime value: []const u8) []const u8 {
    if (out.len == 0) return out[0..0];
    @memset(out, 0);
    const count = @min(value.len, out.len - 1);
    inline for (value, 0..) |ch, i| {
        if (i < count) out[i] = ch;
    }
    out[count] = 0;
    return out[0..count];
}

fn formatU16(out: []u8, value: u16) void {
    if (out.len < 5) return;
    out[0] = digit(@intCast(value / 1000));
    out[1] = digit(@intCast((value / 100) % 10));
    out[2] = digit(@intCast((value / 10) % 10));
    out[3] = digit(@intCast(value % 10));
    out[4] = 0;
}

fn formatU8(out: []u8, value: u8) void {
    if (out.len < 3) return;
    out[0] = digit(value / 10);
    out[1] = digit(value % 10);
    out[2] = 0;
}

fn digit(value: u8) u8 {
    return '0' + value % 10;
}

fn spanZ(buffer: []const u8) []const u8 {
    var len: usize = 0;
    while (len < buffer.len and buffer[len] != 0) : (len += 1) {}
    return buffer[0..len];
}

fn ensureTimeService(ctx: *const r4os.r4sys.Context) bool {
    if (!ctx.hasFn("service_start") or !ctx.hasFn("service_call")) return false;
    var info: r4os.abi.ServiceInfo = .{};
    const status = ctx.serviceStatus("TIMESVC", &info);
    if (status != r4os.abi.service_api_result_ok) return false;
    if (info.state != r4os.abi.service_state_running) {
        const start = ctx.serviceStart("TIMESVC", &info);
        if (start != r4os.abi.service_api_result_ok and start != r4os.abi.service_api_result_running) return false;
    }
    var svc_status: r4os.abi.TimeServiceStatus = .{};
    return ctx.timeServiceStatus(&svc_status) == r4os.abi.service_api_result_ok;
}

fn fail(ctx: *const r4os.r4sys.Context, label: []const u8) i32 {
    ctx.write("TIMESET selftest FAILED: ");
    ctx.println(label);
    return 1;
}

fn hasArg(args: [*:0]const u8, wanted: []const u8) bool {
    var offset: usize = 0;
    while (offset < 256 and args[offset] != 0) {
        while (offset < 256 and (args[offset] == ' ' or args[offset] == '\t')) : (offset += 1) {}
        const start = offset;
        while (offset < 256 and args[offset] != 0 and args[offset] != ' ' and args[offset] != '\t') : (offset += 1) {}
        if (equalsIgnoreCase(args[start..offset], wanted)) return true;
    }
    return false;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len and haystack[i + j] == needle[j]) : (j += 1) {}
        if (j == needle.len) return true;
    }
    return false;
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (upper(a[i]) != upper(b[i])) return false;
    }
    return true;
}

fn upper(ch: u8) u8 {
    return if (ch >= 'a' and ch <= 'z') ch - 32 else ch;
}
