// 控制域接口适配：播放器参数源保持运行时所有权，Flash 仅在启动时恢复参数。
// save_event 延迟一拍，使同沿参数寄存器更新先完成；服务同拍更新并保存完整快照。
// 参数值与服务 live_* 比较产生更新事件，包含无显式 update 输出的模式变化。
// 保存期间的参数变化不阻塞播放器；服务回到 READY 后同步最新值，不自动补写 Flash。
// 忙中 save_event 明确丢弃，不排队；boot_complete 只置位，不随保存 busy/fatal 撤销。
// D18：亮度/对比度存入 period 字段高 16 位 {亮度^0x80, 对比度^0x80}——旧记录该处为 0，恢复为 128/128；
// 画面参数为默认 128 时写出的记录与旧格式逐字节相同。
// 启动预检/加载失败时 boot_complete 保持低；运行时保存失败不清除已应用的播放器参数。
module media_config_persistence_bridge (
    input wire clk, rst_n,
    input wire [15:0] period_ms,
    input wire [7:0] volume,
    input wire mode,
    input wire [7:0] brightness,
    input wire [7:0] contrast,
    input wire save_event,
    output reg boot_complete,
    output wire boot_apply,
    output wire [15:0] restore_period_ms,
    output wire [7:0] restore_volume,
    output wire restore_mode,
    output wire [7:0] restore_brightness,
    output wire [7:0] restore_contrast,
    output wire service_ready, busy, save_done, fatal_error,
    output wire [7:0] error_code,
    output wire request_dropped,
    input wire flash_miso,
    output wire flash_cs_n, flash_sclk, flash_mosi, flash_wp_n, flash_hold_n
);
wire load_done, apply_valid;
wire [31:0] live_period_ms;
wire [7:0] live_volume, live_mode;
wire service_dropped;
reg load_seen, save_pending, event_dropped;
wire events_ready = boot_complete && service_ready;
wire [31:0] period_word = {brightness ^ 8'h80, contrast ^ 8'h80, period_ms};
wire values_changed = live_period_ms != period_word ||
                      live_volume != volume || live_mode != {7'd0,mode};
wire cfg_update_valid = events_ready && (values_changed || save_pending);
wire save_request = events_ready && save_pending;
assign boot_apply = load_done && apply_valid;
assign restore_period_ms = live_period_ms[15:0];
assign restore_volume = live_volume;
assign restore_mode = live_mode[0];
assign restore_brightness = live_period_ms[31:24] ^ 8'h80;
assign restore_contrast = live_period_ms[23:16] ^ 8'h80;
assign request_dropped = event_dropped || service_dropped;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        load_seen <= 1'b0;
        boot_complete <= 1'b0;
        save_pending <= 1'b0;
        event_dropped <= 1'b0;
    end else begin
        // load_done 被参数源采样恢复后再开放；防止默认发布回写覆盖 Flash 恢复值。
        if (boot_apply) load_seen <= 1'b1;
        if (load_seen) boot_complete <= 1'b1;
        save_pending <= save_event && events_ready && !save_pending;
        event_dropped <= save_event && (!events_ready || save_pending);
    end
end

player_config_persistence u_service (
    .clk(clk), .rst_n(rst_n), .cfg_update_valid(cfg_update_valid),
    .cfg_period_ms(period_word), .cfg_volume(volume), .cfg_mode({7'd0,mode}),
    .save_request(save_request), .service_ready(service_ready), .busy(busy),
    .load_done(load_done), .save_done(save_done), .apply_valid(apply_valid),
    .config_rejected(), .fatal_error(fatal_error), .error_code(error_code),
    .request_dropped(service_dropped), .stored_config_valid(), .active_version(),
    .live_period_ms(live_period_ms), .live_period_cycles(), .live_volume(live_volume),
    .live_mode(live_mode), .jedec_id(), .status1(), .status2(), .status3(),
    .flash_miso(flash_miso), .flash_cs_n(flash_cs_n), .flash_sclk(flash_sclk),
    .flash_mosi(flash_mosi), .flash_wp_n(flash_wp_n), .flash_hold_n(flash_hold_n)
);
endmodule
