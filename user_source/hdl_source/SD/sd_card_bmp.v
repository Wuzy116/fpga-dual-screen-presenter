// TF/BMP 适配层：保留扫描目录、扇区查表和跨域适配，按键策略与执行独立。
module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [2:0]   SCAN_TARGET_COUNT = 3'd4,
    parameter integer DEBOUNCE_MS      = 20,
    parameter integer LONG_PRESS_MS    = 1000,
    parameter integer DOUBLE_CLICK_MS  = 300,
    parameter integer CHORD_WINDOW_MS  = 50,
    parameter integer AUTO_PERIOD_MS   = 1000,
    // 未接写侧取消时失败后保持停机；接通完整四相握手后由顶层置 1。
    parameter ENABLE_WRITE_CANCEL     = 0,
    parameter integer BMP_TIMEOUT_MS  = 500,
    parameter integer SD_INIT_TIMEOUT_MS = 500,
    parameter integer MAX_RETRIES     = 1,
    // Independent boot allowance; recovery after a read failure retains its own deadline.
    parameter integer BOOT_INIT_TIMEOUT_MS = 2000,
    // 单次上电初始化超时后仅复位 SD 子树、从 CMD0 重来的次数；0 保持首次超时即失败。
    // 部分卡冷上电首轮停在 CMD55/ACMD41 循环，再发 CMD0 即可完成（等效按复位键）。
    parameter integer BOOT_INIT_RETRIES = 0,
    // 每次启动重试把 SD 引脚保持在复位态（CS 高、DCLK 低）的时间；0 为 32 拍。
    parameter integer BOOT_RETRY_HOLD_MS = 0,
    parameter integer WRITE_FINISH_TIMEOUT_MS = 500,
    parameter integer CANCEL_TIMEOUT_MS = 500,
    // B3：独立预加载接入，默认保留旧播放器；生产顶层启用留到启动/播放屏障完成后。
    parameter ENABLE_PRELOAD = 0,
    // 仅预加载缓存通路支持运行时周期；默认保持静态 AUTO_PERIOD_MS。
    parameter ENABLE_RUNTIME_PERIOD = 0,
    parameter ENABLE_MODE_CONFIG = 0,
    // 新按键映射与连发必须一同启用；默认保留旧策略，生产顶层接线另一步完成。
    parameter integer ENABLE_PARAMETER_KEYS = 0,
    parameter integer ENABLE_VOLUME_ADJUST = 0,
    parameter integer KEY_REPEAT_MS = 200,
    // 1：按 FAT32 根目录 PIC1~4.BMP 读取（SCAN_*_SECTOR 不再使用）；0：原物理扇区魔数扫描。
    parameter USE_FAT32 = 0,
    // 第 13 课：1 = FAT32 图片可为任意 1..2048 x 1..2048，经 media_image_scaler 等比缩放到
    // bmp_width x bmp_height（固定 640x480）后写出；0 = 原固定尺寸校验。扇区扫描模式不支持。
    parameter ANY_SIZE_IMAGES = 0,
    // 缩放输出每 N 拍一个像素（写端口无反压）：4 = 12.5 Mpx/s。读写并发整帧（含缩略图便车写）在 GAP=4 验证通过；
    // GAP=3（16.7 Mpx/s）时 loader 512 字 FIFO 溢出，故不可再调小。
    parameter integer SCALER_OUT_INTERVAL = 4,
    // 1 = 全屏缩放用双线性（讲义：全屏锯齿明显用双线性，缩略图用最近邻）；0 = 最近邻
    parameter SCALER_BILINEAR = 1,
    // 第 13/15 课缩略图模式：key_thumb 进入/退出，模式内 key_next 单击/双击移焦点、key_auto 单击打开焦点图；需预加载
    parameter ENABLE_THUMBS = 0,
    // 双 HDMI 阶段 2.2：预加载完成后把 SnPmm.BMP 讲稿装入 SDRAM 讲稿区（需 FAT32 + 预加载），装完才开始播放音乐
    parameter ENABLE_SCRIPTS = 0,
    parameter integer SCRIPT_MAX_PAGES = 58,
    // 红外遥控事件（ir_nec_remote.events）并入按键事件；0 时 ir_events 不用（可不连接）
    parameter ENABLE_IR = 0,
    // D32：第 2 张 -> 第 3 张、第 3 张 -> 第 4 张的“下一张”先交给像素域推进镜头，推到底（fx_done 翻转）才换图
    parameter ENABLE_FX_GATE = 0
)(
    input                       clk,
    input                       rst,
    // 已同步至 clk 域；只门控新任务，不中断已接受的扫描/加载。
    input                       storage_ready,
    input                       key_next,
    input                       key_auto,
    input                       key_thumb,
    // 红外遥控（clk 域单拍）：[0] 上=提词下一页 [1] 下=上一页 [2] 左=观众屏上一张 [3] 右=下一张 [4] *=提词滚动开关
    // [8:5] 周期/音量/亮度/对比度 加 [12:9] 减 [13] 保存；不看 SW1~SW4（亮度/对比度由顶层直接送 media_picture_adjust）
    input  [13:0]               ir_events,
    // D18 拨码（已消抖电平）：prompter_mode = SW4 拨下，KEY2/KEY3/KEY4 改作提词命令，观众屏切图/缩略图不响应；
    // D20：观众屏不受提词屏影响（不跟随讲稿换节，已开的轮播照常进行）。
    // param_mode = SW1 拨上，KEY2/KEY3 只调 param_sel 选中的参数（0 周期 1 音量 2 亮度 3 对比度），KEY4 不响应。
    input                       prompter_mode,
    input                       param_mode,
    input  [1:0]                param_sel,
    output [5:0]                prompter_cmd,       // 命令翻转位 {overview, key3, 0, 0, prev, next}
    // 时期：0 预备 / 1 演讲（KEY4 长按切换）；prompter_active = 提词模式（SW4 拨下）
    output                      show_phase,
    output                      show_phase_enter,
    output                      prompter_active,
    output                      reveal_event,       // D23：价格揭晓完成单拍（提示音）
    input                       fx_done,            // D32：像素域推进镜头完成（翻转位，异步）
    output                      fx_go_cam,          // D32：翻转位，请求第 2 张推进背面镜头
    output                      fx_go_lens,         // D32：翻转位，请求第 3 张推进主摄
    output                      blackout,           // D21：观众屏黑场（同按翻转；第 4 张时 KEY2 先黑场、再按切第 5 张后淡入；复位清除）
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output                      display_valid,
    input                       write_finish_toggle,
    output [2:0]                write_buf_idx,
    output [1:0]                disp_buf_idx,
    output                      write_req,
    input                       write_req_ack,
    output                      write_en,
    output [31:0]               write_data,
    // 与 write_req 同时有效、保持到下一次加载：1 = 本帧像素按自上而下顺序到达（写端口不翻转）
    output                      write_top_down,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO,
    // 仅供面板读取，全部属于 clk 域，不改变播放器控制逻辑。
    output [1:0]                seg_img_idx,
    output                      seg_load_busy,
    output                      seg_manual_event,
    output                      write_cancel_req,
    input                       write_cancel_ack,
    output                      preload_done,
    output                      preload_error,
    output [4:0]                image_complete,
    output [2:0]                preload_error_code,
    output                      preload_cancel_ack_timeout,
    output                      preload_cancel_release_timeout,
    // B4：仅预加载模式有效，全部属于 clk 域；不能直接作为像素域显示使能。
    output                      player_enable,
    output                      boot_error,
    output [2:0]                boot_error_stage,
    output [2:0]                boot_error_code,
    // 控制域缓存选槽 offer；valid && ready 仅代表受理，不是实际显示提交。
    // 未接下游时 ready 必须接 0；预加载模式以外输出固定无效。
    output [2:0]                cache_slot,
    // 随 cache_slot 发布：1=该目标由按键产生（转场淡入淡出），0=轮播到期（转场 Wipe）。
    output                      cache_slot_manual,
    // 随 cache_slot 发布：1=该目标为第 5 个 bank 总览页（缩略图模式），槽号仍为进入前显示的图。
    output                      cache_slot_sheet,
    output                      cache_slot_valid,
    input                       cache_slot_ready,
    // 预加载轮播反馈：均须属于 clk 域，独立使用时必须显式连接。
    // 显示状态来自整笔邮箱；故障来自独立同步的 reader 保持电平，不能用 !valid 替代。
    input                       cache_display_valid,
    input [2:0]                 cache_display_slot,
    input                       cache_playback_fault,
    // 同 clk 域：update 所在沿采样 1000..60000 ms；不跨域、不自动保存。
    // 合法更新重新计时（含同值），非法值忽略；故障/锁停优先，详见轮播器接口。
    input                       period_update,
    input [15:0]                period_ms,
    // 控制域周期调节事件；新映射按当前对象分配，旧映射仍导出原预留手势。
    output                      period_increase_event,
    output                      period_decrease_event,
    // 同 clk 域单拍请求；新映射受配置就绪门控，旧映射沿用周期开关；不在本层写Flash。
    output                      save_event,
    input                       mode_restore_write,
    input                       mode_restore_value,
    input                       mode_boot_config_done,
    output                      mode_ready,
    output                      mode_value,
    // 只读：当前是否处于自动轮播（clk 域电平），供 OSD 显示 A/E。
    output                      auto_play_active,
    // 仅新映射使用；同clk域，配置恢复完成后置1，不以图片播放许可替代。
    input                       config_events_ready,
    output                      volume_increase_event,
    output                      volume_decrease_event,
    // 亮度/对比度增减（参数模式且 param_sel = 2/3），送 media_picture_adjust
    output                      picture_increase_event,
    output                      picture_decrease_event,
    // 当前调节对象为音量（数码管参数提示用）
    output                      parameter_selected_volume,
    // 只读启动诊断，clk 域，不参与控制。
    output [4:0]                diag_sd_state,
    output [2:0]                diag_recovery_state,
    output                      diag_sd_init_done,
    output                      diag_catalog_ready,
    output [2:0]                diag_found_count,
    output [5:0]                diag_err_cmd,
    output [7:0]                diag_err_resp,
    output [7:0]                diag_boot_retries,
    // 只读 FAT32 诊断，见 fat32_bmp_read.diag_fs；扇区扫描模式固定 0。
    output [19:0]               diag_fs,
    // 面板用：显示槽 -> 文件号（0=PIC1）。FAT32 缺图时槽紧凑排列，按目录资源号还原；扇区模式即槽号。
    input  [2:0]                seg_slot,
    output [2:0]                seg_file_idx,
    // 第 11 讲 PCM 音频流（clk 域）：实际显示图对应 MUSn.PCM 的文件字节；仅预加载 + FAT32 时有效，否则恒 0。
    // audio_hold 由播放缓冲给出（快满）；restart 与新文件首字节对齐，flush 期间缓冲须清空。
    input                       audio_hold,
    output                      audio_byte_valid,
    output [7:0]                audio_byte,
    output                      audio_stream_restart,
    output                      audio_stream_flush,
    output                      audio_track_active,
    // clk 域：{目录图片数[2:0], 焦点槽[2:0], 已完成槽掩码[4:0]}；关闭时恒 0（模式位改随 cache_slot_sheet 发布）
    output [10:0]               thumb_state,
    // 讲稿写入口（clk 域），接 prompter_script_writer 的写侧；关闭时输出恒 0
    output                      script_fifo_we,
    output [31:0]               script_fifo_di,
    input  [8:0]                script_fifo_wrusedw,
    output                      script_page_toggle,
    output [5:0]                script_page_slot,
    output                      script_page_top_down,
    input                       script_page_done,
    output                      script_load_done,
    output                      script_loading,      // 讲稿装载已开始（P-12 提示用；装完后由上层用 load_done 屏蔽）
    output [5:0]                script_pages_loaded,
    output [5:0]                script_slots,          // 讲稿页（不含总览页）槽数（D16）
    output [5:0]                script_pages_failed,
    output [29:0]               script_section_first,
    output [24:0]               script_section_pages,
    output [29:0]               script_section_overview,
    output [4:0]                script_overview_valid
);
wire sd_sec_read;
wire [31:0] sd_sec_read_addr;
wire [7:0] sd_sec_read_data;
wire sd_sec_read_data_valid;
wire sd_sec_read_end;
wire bmp_data_wr_en;
wire [23:0] bmp_data;
wire sd_init_done;
wire bmp_ready;
wire sd_recover_req;
wire sd_recover_ack;
reg catalog_ready;
localparam REC_IDLE=3'd0, REC_RESET=3'd1, REC_INIT=3'd2, REC_ACK=3'd3, REC_FAILED=3'd4, REC_BOOT=3'd5,
           REC_BOOT_RESET=3'd6;
localparam [63:0] INIT_TIMEOUT_RAW = 64'd1 * (CLK_FREQ_HZ / 1000) * SD_INIT_TIMEOUT_MS;
localparam [63:0] INIT_TIMEOUT_CYCLES = (INIT_TIMEOUT_RAW > 0) ? INIT_TIMEOUT_RAW : 64'd1;
localparam [63:0] BOOT_TIMEOUT_RAW = 64'd1 * (CLK_FREQ_HZ / 1000) * BOOT_INIT_TIMEOUT_MS;
localparam [63:0] BOOT_TIMEOUT_CYCLES = (BOOT_TIMEOUT_RAW > 0) ? BOOT_TIMEOUT_RAW : 64'd1;
// 启动重试的 SD 子树复位保持时间；至少 32 拍，与运行期恢复一致。
localparam [63:0] BOOT_HOLD_RAW = 64'd1 * (CLK_FREQ_HZ / 1000) * BOOT_RETRY_HOLD_MS;
localparam [63:0] BOOT_HOLD_CYCLES = (BOOT_HOLD_RAW > 64'd32) ? BOOT_HOLD_RAW : 64'd32;
localparam [63:0] TIMEOUT_MAX_CYCLES = (BOOT_TIMEOUT_CYCLES > INIT_TIMEOUT_CYCLES) ? BOOT_TIMEOUT_CYCLES : INIT_TIMEOUT_CYCLES;
localparam [63:0] INIT_COUNTER_CYCLES = (BOOT_HOLD_CYCLES > TIMEOUT_MAX_CYCLES) ? BOOT_HOLD_CYCLES : TIMEOUT_MAX_CYCLES;
localparam integer INIT_TIMEOUT_BITS = (INIT_COUNTER_CYCLES <= 1) ? 1 : $clog2(INIT_COUNTER_CYCLES);
reg [2:0] recovery_state;
reg [4:0] recovery_reset_count;
reg [INIT_TIMEOUT_BITS-1:0] recovery_init_count;
reg sd_recovery_reset;
reg boot_init_timeout;
reg [7:0] boot_retry_count;
wire sd_local_rst = rst || sd_recovery_reset;
assign sd_recover_ack = (recovery_state == REC_ACK);
// synthesis translate_off
initial begin
    if ((ENABLE_PARAMETER_KEYS != 0 && ENABLE_PARAMETER_KEYS != 1) ||
        (ENABLE_VOLUME_ADJUST != 0 && ENABLE_VOLUME_ADJUST != 1) ||
        (ENABLE_PARAMETER_KEYS && (!ENABLE_PRELOAD ||
            (!ENABLE_RUNTIME_PERIOD && !ENABLE_VOLUME_ADJUST))) ||
        (ENABLE_VOLUME_ADJUST && !ENABLE_PARAMETER_KEYS)) begin
        $display("MEDIA_CONFIG_ERROR sd parameter keys %m: boolean enables, preload and at least one parameter required");
        $finish;
    end
    if ((ENABLE_RUNTIME_PERIOD != 0 && ENABLE_RUNTIME_PERIOD != 1) ||
        (ENABLE_RUNTIME_PERIOD && !ENABLE_PRELOAD)) begin
        $display("MEDIA_CONFIG_ERROR sd runtime period %m: boolean enable and preload mode required");
        $finish;
    end
    if (ENABLE_THUMBS && !ENABLE_PRELOAD) begin
        $display("MEDIA_CONFIG_ERROR sd thumbnails %m: preload playback required");
        $finish;
    end
    // D19：预加载目录上限 4 或 5 张（生产 FAT32 用 5；扇区扫描旧存储用 4，缺图时不必扫到末扇区）
    if (ENABLE_PRELOAD && (!ENABLE_WRITE_CANCEL || SCAN_TARGET_COUNT < 3'd4 || SCAN_TARGET_COUNT > 3'd5)) begin
        $display("MEDIA_CONFIG_ERROR sd preload %m: 4- or 5-frame scan and write cancellation required");
        $finish;
    end
    if (CLK_FREQ_HZ < 1000 || (CLK_FREQ_HZ % 1000) != 0 || SD_INIT_TIMEOUT_MS < 1 ||
        INIT_TIMEOUT_RAW > 64'd2147483647 || BOOT_INIT_TIMEOUT_MS < 1 ||
        BOOT_TIMEOUT_RAW > 64'd2147483647 || BOOT_INIT_RETRIES < 0 || BOOT_INIT_RETRIES > 255 ||
        BOOT_RETRY_HOLD_MS < 0 || BOOT_HOLD_RAW > 64'd2147483647) begin
        $display("MEDIA_CONFIG_ERROR sd recovery %m: invalid init timeout or cycle-count overflow");
        $finish;
    end
end
// synthesis translate_on
wire bmp_load_success;
wire bmp_load_error;
wire [2:0] bmp_error;
wire scan_done;
wire scan_found_valid;
wire [31:0] scan_found_sector;
wire [2:0] scan_found_total;
reg scan_start_pulse;
reg scan_kicked;
reg [2:0] img_found_count;
// FAT32 模式下只存目录序号（0..4），旧扇区扫描模式存 32 位扇区号。
localparam integer IMG_SECTOR_W = USE_FAT32 ? 3 : 32;
reg [IMG_SECTOR_W-1:0] img_sector0;
reg [IMG_SECTOR_W-1:0] img_sector1;
reg [IMG_SECTOR_W-1:0] img_sector2;
reg [IMG_SECTOR_W-1:0] img_sector3;
reg [IMG_SECTOR_W-1:0] img_sector4;
wire load_start_pulse;
wire [2:0] load_idx;
wire [1:0] img_idx;
wire [31:0] load_sector;
wire [1:0] next_idx;
wire [1:0] prev_idx;
wire key1_click_event;
wire key1_double_event;
wire key1_long_event;
wire key2_click_event;
wire key2_double_event;
wire key2_long_event;
wire chord_click_event;
wire manual_req;
wire manual_prev;
wire auto_toggle;
wire auto_toggle_mode;
wire auto_play_en;
assign auto_play_active = auto_play_en;
wire mode_restore_accept_unused, mode_key2_accept_unused;
wire thumb_mode;
wire load_busy;
wire load_failed;
wire legacy_start, legacy_valid, legacy_auto, legacy_busy, legacy_failed, legacy_cancel;
wire [1:0] legacy_load_idx, legacy_img_idx, legacy_write_idx, legacy_disp_idx;
wire preload_start, preload_busy, preload_cancel;
wire [2:0] preload_idx, preload_write_idx;
assign load_start_pulse = ENABLE_PRELOAD ? preload_start : legacy_start;
assign load_idx = ENABLE_PRELOAD ? preload_idx : {1'b0, legacy_load_idx};
assign write_buf_idx = ENABLE_PRELOAD ? preload_write_idx : {1'b0, legacy_write_idx};
assign write_cancel_req = ENABLE_PRELOAD ? preload_cancel : legacy_cancel;
assign load_busy = ENABLE_PRELOAD ? preload_busy : legacy_busy;
assign load_failed = ENABLE_PRELOAD ? preload_error : legacy_failed;
// 本阶段只接加载通路；显示/音频/面板的正式播放提交在 B4～B6 中接入。
assign display_valid = ENABLE_PRELOAD ? 1'b0 : legacy_valid;
assign disp_buf_idx = ENABLE_PRELOAD ? 2'd0 : legacy_disp_idx;
assign img_idx = ENABLE_PRELOAD ? 2'd0 : legacy_img_idx;
wire [2:0] reserved_events;
wire legacy_manual_req, legacy_manual_prev, legacy_auto_toggle;
wire router_save_event;
// D18：讲稿功能开启时 SW4 拨下为提词模式。讲稿功能关闭时端口不用（可不连接）。
wire pm_on = ENABLE_SCRIPTS && prompter_mode;
wire [13:0] ir_ev = (ENABLE_IR && ENABLE_PARAMETER_KEYS && config_events_ready && mode_ready) ? ir_events : 14'd0;
wire ir_pm = ENABLE_SCRIPTS && (ir_ev[0] || ir_ev[1] || ir_ev[4]);
assign prompter_active = pm_on;
wire key4_short;
wire pm_n = !pm_on;
wire thumb_prev_event;
wire key4_press;
wire pm_next, pm_prev, pm_key3;
wire blackout_toggle;
wire view_next_raw, view_prev_raw, view_next_pass;   // 观众屏 KEY2 单击/双击；单击经 media_reveal（价格揭晓）后放行
// 只在讲稿功能开启时生成（与 prompter_script_loader 相同），关闭时提词命令恒 0
generate if (ENABLE_SCRIPTS) begin : g_prompter_keys
    // 板上按键只在提词模式下给出 pm_*；遥控器上 / 下 / * 任何模式都直接作用于提词屏
    prompter_key_map u_prompter_keys (
        .clk(clk), .rst(rst), .prompter_mode(pm_on || ir_pm),
        // D32：遥控上 = 上一页、下 = 下一页
        .next(pm_next || ir_ev[1]), .prev(pm_prev || ir_ev[0]), .key3(pm_key3 || ir_ev[4]), .overview(key4_press && pm_on),
        .cmd_toggle(prompter_cmd)
    );
end else begin : g_no_prompter_keys
    assign prompter_cmd = 6'd0;
end endgenerate
generate if (ENABLE_PARAMETER_KEYS) begin : g_parameter_keys
    wire param_inc, param_dec, key_save, key_next, key_prev;
    media_key_mode_map u_key_mode (
        .clk(clk), .rst(rst), .events_ready(config_events_ready && mode_ready),
        // D32：提词模式下打开观众屏缩略图后，KEY2/KEY3 临时按观众屏规则（移焦点 / 确认），关闭后回到提词命令
        .param_mode(param_mode), .prompter_mode(pm_on && !thumb_mode),
        .key2_click(key1_click_event), .key2_double(key1_double_event), .key2_long(key1_long_event),
        .key3_click(key2_click_event), .key3_double(key2_double_event), .key3_long(key2_long_event),
        .chord_click(chord_click_event), .chord_save(router_save_event),
        .increase_event(param_inc), .decrease_event(param_dec), .save_request(key_save),
        .next_event(key_next), .prev_event(key_prev), .auto_toggle_event(auto_toggle),
        .pm_next(pm_next), .pm_prev(pm_prev), .pm_key3(pm_key3), .blackout_toggle(blackout_toggle)
    );
    // 遥控器右 / 左 = KEY2 单击 / 双击（观众屏模式），任何拨码位置都有效
    assign view_next_raw = key_next || ir_ev[3];
    assign view_prev_raw = key_prev || ir_ev[2];
    assign save_event = key_save || ir_ev[13];
    // 缩略图内 KEY2 单击/双击移焦点；其余时候为观众屏下一张/上一张
    assign manual_req = view_next_pass || (view_prev_raw && !thumb_mode);
    assign manual_prev = view_prev_raw && !thumb_mode;
    assign thumb_prev_event = view_prev_raw && thumb_mode;
    // 遥控器 1/5 = 周期加/减、2/6 = 音量加/减，不看 SW1~SW3（增减同拍由调节模块抵消）
    assign period_increase_event = (param_inc && param_sel == 2'd0 || ir_ev[5]) && ENABLE_RUNTIME_PERIOD;
    assign period_decrease_event = (param_dec && param_sel == 2'd0 || ir_ev[9]) && ENABLE_RUNTIME_PERIOD;
    assign volume_increase_event = (param_inc && param_sel == 2'd1 || ir_ev[6]) && ENABLE_VOLUME_ADJUST;
    assign volume_decrease_event = (param_dec && param_sel == 2'd1 || ir_ev[10]) && ENABLE_VOLUME_ADJUST;
    assign picture_increase_event = param_inc && param_sel[1];
    assign picture_decrease_event = param_dec && param_sel[1];
    assign parameter_selected_volume = param_sel == 2'd1;
end else begin : g_legacy_keys
    assign pm_next = 1'b0;
    assign pm_prev = 1'b0;
    assign pm_key3 = 1'b0;
    assign blackout_toggle = 1'b0;
    assign view_next_raw = 1'b0;
    assign view_prev_raw = 1'b0;
    assign thumb_prev_event = key1_double_event && thumb_mode;
    assign picture_increase_event = 1'b0;
    assign picture_decrease_event = 1'b0;
    assign manual_req = legacy_manual_req;
    assign manual_prev = legacy_manual_prev;
    assign auto_toggle = legacy_auto_toggle;
    assign period_increase_event = !rst && ENABLE_PRELOAD && ENABLE_RUNTIME_PERIOD && reserved_events[0];
    assign period_decrease_event = !rst && ENABLE_PRELOAD && ENABLE_RUNTIME_PERIOD && reserved_events[1];
    assign save_event = router_save_event;
    assign volume_increase_event = 1'b0;
    assign volume_decrease_event = 1'b0;
    assign parameter_selected_volume = 1'b0;
end endgenerate

generate
if (ENABLE_MODE_CONFIG) begin : g_mode_config
    media_mode_control u_mode_control (
        .clk(clk), .rst(rst), .restore_write(mode_restore_write), .restore_mode(mode_restore_value),
        .boot_config_done(mode_boot_config_done), .key2_toggle(auto_toggle && !thumb_mode),
        .mode_update(), .mode(mode_value), .mode_ready(mode_ready),
        .restore_accept(mode_restore_accept_unused), .key2_accept(mode_key2_accept_unused)
    );
    // Use the registered arbitration result so a KEY2 pulse coincident with boot completion cannot leak into runtime.
    assign auto_toggle_mode = mode_key2_accept_unused;
end else begin : g_mode_config_disabled
    assign mode_value = 1'b0;
    assign mode_ready = 1'b1;
    assign auto_toggle_mode = auto_toggle && !thumb_mode;
end
endgenerate
reg [2:0] wrfin_tgl_sync;
reg [1:0] write_ack_sync;
reg [1:0] cancel_ack_sync;
wire write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];
wire [11:0] img_width, img_height;
wire img_top_down;
wire scaler_hold;
generate if (USE_FAT32 && ANY_SIZE_IMAGES) begin : g_scaler
    // 写握手被源端接受的那一拍（write_req 下一拍撤销）启动缩放；写取消清空缩放器。
    wire scaler_valid;
    wire [23:0] scaler_rgb;
    media_image_scaler #(.OUT_INTERVAL(SCALER_OUT_INTERVAL), .BILINEAR(SCALER_BILINEAR)) u_scaler (
        .clk(clk), .rst(rst),
        .start(write_req && write_ack_sync[1]), .abort(write_cancel_req),
        .src_w(img_width), .src_h(img_height), .src_top_down(img_top_down),
        .in_valid(bmp_data_wr_en), .in_rgb(bmp_data), .src_hold(scaler_hold),
        .out_valid(scaler_valid), .out_rgb(scaler_rgb),
        .busy(), .frame_done(), .overflow()
    );
    assign write_en = scaler_valid;
    assign write_data = {scaler_rgb, 8'b0};
    assign write_top_down = img_top_down;
end else begin : g_no_scaler
    assign scaler_hold = 1'b0;
    assign write_en = bmp_data_wr_en;
    assign write_data = {bmp_data, 8'b0};
    assign write_top_down = 1'b0;
end endgenerate
assign load_sector = sector_lut(load_idx);
reg [2:0] seg_slot_entry;
always @* begin
    case (seg_slot)
        3'd0: seg_slot_entry = img_sector0[2:0];
        3'd1: seg_slot_entry = img_sector1[2:0];
        3'd2: seg_slot_entry = img_sector2[2:0];
        3'd3: seg_slot_entry = img_sector3[2:0];
        default: seg_slot_entry = img_sector4[2:0];
    endcase
end
assign seg_file_idx = USE_FAT32 ? seg_slot_entry : seg_slot;
reg [2:0] display_file_entry;
always @* begin
    case (cache_display_slot)
        3'd0: display_file_entry = img_sector0[2:0];
        3'd1: display_file_entry = img_sector1[2:0];
        3'd2: display_file_entry = img_sector2[2:0];
        3'd3: display_file_entry = img_sector3[2:0];
        default: display_file_entry = img_sector4[2:0];
    endcase
end
wire aud_start, aud_stop, aud_busy, aud_done;
wire [2:0] aud_idx;
// 讲稿流（fat32_bmp_read ↔ prompter_script_loader）
wire        scr_start, scr_hold, scr_stop, scr_busy, scr_done, scr_bv;
wire [6:0]  scr_key;
wire [7:0]  scr_error, scr_byte;
wire [79:0] scr_valid;
wire        scripts_on = ENABLE_SCRIPTS && USE_FAT32 && ENABLE_PRELOAD;
// 讲稿开启时音乐等讲稿装完；SD 读口因此在两种文件流之间天然互斥
wire        preload_settled;   // 预加载结束：全部完成，或首张已播放后降级（A-8）
wire        script_gate = !scripts_on || script_load_done;
wire [4:0] aud_valid;
wire [7:0] aud_error;
assign seg_img_idx = img_idx;
assign seg_load_busy = load_busy;
assign seg_manual_event = manual_req;
assign diag_recovery_state = recovery_state;
assign diag_sd_init_done = sd_init_done;
assign diag_catalog_ready = catalog_ready;
assign diag_found_count = img_found_count;
assign diag_boot_retries = boot_retry_count;

function [31:0] sector_lut;
    input [2:0] idx;
    begin
        case (idx)
            3'd0: sector_lut = {32'd0, img_sector0};
            3'd1: sector_lut = {32'd0, img_sector1};
            3'd2: sector_lut = {32'd0, img_sector2};
            3'd3: sector_lut = {32'd0, img_sector3};
            3'd4: sector_lut = {32'd0, img_sector4};
            default: sector_lut = {32'd0, img_sector0};
        endcase
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wrfin_tgl_sync <= 3'b000;
        write_ack_sync <= 2'b00;
        cancel_ack_sync <= 2'b00;
    end else begin
        wrfin_tgl_sync <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        // ACK 是保持到请求撤销的电平，先同步后再交给 BMP 状态机。
        write_ack_sync <= {write_ack_sync[0], write_req_ack};
        // 取消 ACK 来自 mem_clk，保持型电平双触发同步，不直接跨域使用。
        cancel_ack_sync <= {cancel_ack_sync[0], ENABLE_WRITE_CANCEL ? write_cancel_ack : 1'b0};
    end
end

// 仅复位 SD/SPI 子树，不动目录、显示缓冲和 SDRAM 读通路。全部属于 clk 域。
always @(posedge clk or posedge rst) begin
    if (rst) begin
        recovery_state <= REC_BOOT;
        recovery_reset_count <= 5'd0;
        recovery_init_count <= 0;
        sd_recovery_reset <= 1'b0;
        boot_init_timeout <= 1'b0;
        boot_retry_count <= 8'd0;
    end else begin
        case (recovery_state)
            // No recovery ACK on initial boot: BMP has not requested recovery yet.
            REC_BOOT: if (sd_init_done) begin
                recovery_init_count <= 0;
                recovery_state <= REC_IDLE;
            end else if (recovery_init_count >= BOOT_TIMEOUT_CYCLES - 1) begin
                recovery_init_count <= 0;
                if (boot_retry_count < BOOT_INIT_RETRIES) begin
                    boot_retry_count <= boot_retry_count + 8'd1;
                    sd_recovery_reset <= 1'b1;
                    recovery_state <= REC_BOOT_RESET;
                end else begin
                    boot_init_timeout <= 1'b1;
                    recovery_state <= REC_FAILED;
                end
            end else recovery_init_count <= recovery_init_count + 1'b1;
            REC_BOOT_RESET: if (recovery_init_count >= BOOT_HOLD_CYCLES - 1) begin
                sd_recovery_reset <= 1'b0;
                recovery_init_count <= 0;
                recovery_state <= REC_BOOT;
            end else recovery_init_count <= recovery_init_count + 1'b1;
            REC_IDLE: if (sd_recover_req) begin
                sd_recovery_reset <= 1'b1;
                recovery_reset_count <= 5'd0;
                recovery_state <= REC_RESET;
            end
            REC_RESET: if (recovery_reset_count == 5'd31) begin
                sd_recovery_reset <= 1'b0;
                recovery_init_count <= 0;
                recovery_state <= REC_INIT;
            end else recovery_reset_count <= recovery_reset_count + 5'd1;
            REC_INIT: if (sd_init_done) begin
                recovery_state <= REC_ACK;
            end else if (recovery_init_count >= INIT_TIMEOUT_CYCLES - 1) begin
                // 初始化失败后不自动反复复位；保留旧图，等待一次新的手动请求。
                recovery_state <= REC_FAILED;
            end else recovery_init_count <= recovery_init_count + 1'b1;
            REC_ACK: if (!sd_recover_req) recovery_state <= REC_IDLE;
            // 旧播放器仍允许手动恢复；完整预加载失败后只允许统一复位重启。
            REC_FAILED: if (manual_req && !ENABLE_PRELOAD) begin
                boot_init_timeout <= 1'b0;
                sd_recovery_reset <= 1'b1;
                recovery_reset_count <= 5'd0;
                recovery_state <= REC_RESET;
            end
            default: recovery_state <= REC_IDLE;
        endcase
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        catalog_ready <= 1'b0;
        scan_start_pulse <= 1'b0;
        scan_kicked <= 1'b0;
        img_found_count <= 3'd0;
        img_sector0 <= {IMG_SECTOR_W{1'b0}};
        img_sector1 <= {IMG_SECTOR_W{1'b0}};
        img_sector2 <= {IMG_SECTOR_W{1'b0}};
        img_sector3 <= {IMG_SECTOR_W{1'b0}};
        img_sector4 <= {IMG_SECTOR_W{1'b0}};
    end else begin
        scan_start_pulse <= 1'b0;
        if (scan_done)
            catalog_ready <= 1'b1;
        if (!scan_kicked && storage_ready && bmp_ready && sd_init_done && recovery_state == REC_IDLE) begin
            scan_start_pulse <= 1'b1;
            scan_kicked <= 1'b1;
            img_found_count <= 3'd0;
        end else if (scan_found_valid) begin
            case (img_found_count)
                3'd0: img_sector0 <= scan_found_sector[IMG_SECTOR_W-1:0];
                3'd1: img_sector1 <= scan_found_sector[IMG_SECTOR_W-1:0];
                3'd2: img_sector2 <= scan_found_sector[IMG_SECTOR_W-1:0];
                3'd3: img_sector3 <= scan_found_sector[IMG_SECTOR_W-1:0];
                3'd4: img_sector4 <= scan_found_sector[IMG_SECTOR_W-1:0];
                default: ;
            endcase
            if (img_found_count < 3'd5)
                img_found_count <= img_found_count + 3'd1;
        end
    end
end

dual_key_chord_router #(
    .CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS),
    .LONG_PRESS_MS(LONG_PRESS_MS), .DOUBLE_CLICK_MS(DOUBLE_CLICK_MS),
    .CHORD_WINDOW_MS(CHORD_WINDOW_MS),
    .ENABLE_SAVE_GESTURE(ENABLE_PARAMETER_KEYS || (ENABLE_PRELOAD && ENABLE_RUNTIME_PERIOD)),
    .ENABLE_LONG_REPEAT(ENABLE_PARAMETER_KEYS), .REPEAT_MS(KEY_REPEAT_MS)
) u_key_router (
    .clk(clk), .rst(rst), .key1(key_next), .key2(key_auto),
    .key1_click_event(key1_click_event), .key1_double_event(key1_double_event),
    .key1_long_event(key1_long_event), .key2_click_event(key2_click_event),
    .key2_double_event(key2_double_event), .key2_long_event(key2_long_event),
    .chord_click_event(chord_click_event), .save_event(router_save_event)
);

media_policy u_media_policy (
    .key1_click_event(key1_click_event), .key1_double_event(key1_double_event && !thumb_mode),
    .key1_long_event(key1_long_event), .key2_click_event(key2_click_event),
    .key2_double_event(key2_double_event), .key2_long_event(key2_long_event),
    .chord_click_event(chord_click_event), .img_idx(img_idx),
    .img_found_count(img_found_count), .manual_req(legacy_manual_req),
    .manual_prev(legacy_manual_prev), .auto_toggle(legacy_auto_toggle),
    .next_idx(next_idx), .prev_idx(prev_idx), .reserved_events(reserved_events)
);

media_player_control #(
    // 预加载运行时路径不使用旧计时器，避免其有符号范围校验拒绝新路径的 60000 ms。
    .CLK_FREQ_HZ(CLK_FREQ_HZ), .AUTO_PERIOD_MS((ENABLE_PRELOAD && ENABLE_RUNTIME_PERIOD) ? 1000 : AUTO_PERIOD_MS),
    .USE_EXPLICIT_RESULTS(1), .MAX_RETRIES(MAX_RETRIES), .ENABLE_AUTO_SKIP(1),
    .ENABLE_WRITE_TIMEOUT(1), .WRITE_FINISH_TIMEOUT_MS(WRITE_FINISH_TIMEOUT_MS),
    .ENABLE_CANCEL_TIMEOUT(1), .CANCEL_TIMEOUT_MS(CANCEL_TIMEOUT_MS)
) u_player_control (
    .clk(clk), .rst(rst), .catalog_ready(catalog_ready && !ENABLE_PRELOAD),
    .img_found_count(img_found_count), .manual_req(manual_req),
    .manual_prev(manual_prev), .auto_toggle(auto_toggle_mode),
    .mode_ready(mode_ready), .mode_value(mode_value),
    .next_idx(next_idx), .prev_idx(prev_idx),
    .bmp_ready(storage_ready && bmp_ready && sd_init_done && recovery_state == REC_IDLE),
    .frame_write_req(write_req), .write_finish_pulse(write_finish_pulse),
    .load_start_pulse(legacy_start), .load_idx(legacy_load_idx), .img_idx(legacy_img_idx),
    .write_buf_idx(legacy_write_idx), .disp_buf_idx(legacy_disp_idx),
    .display_valid(legacy_valid), .auto_play_en(legacy_auto),
    .load_busy(legacy_busy), .load_failed(legacy_failed),
    .bmp_load_success(bmp_load_success), .bmp_load_error(bmp_load_error),
    .write_cancel_req(legacy_cancel), .write_cancel_ack(cancel_ack_sync[1])
);

generate if (ENABLE_PRELOAD) begin : g_preload
    // 首因诊断：1=SD初始化，2=目录扫描，3=BMP加载，4=预加载/写完成，
    // 5=取消握手，6=完成协议。后续取消超时仍由独立诊断输出保留。
    localparam [2:0] BOOT_INIT=3'd1, BOOT_SCAN=3'd2, BOOT_BMP=3'd3,
                     BOOT_PRELOAD=3'd4, BOOT_CANCEL=3'd5, BOOT_PROTOCOL=3'd6;
    reg [2:0] error_stage_now, error_code_now;
    reg [2:0] first_error_stage, first_error_code;
    wire startup_fault = (error_stage_now != 3'd0);
    assign boot_error_stage = first_error_stage;
    assign boot_error_code = first_error_code;
    always @* begin
        error_stage_now = 3'd0;
        error_code_now = 3'd0;
        if (boot_init_timeout) begin
            error_stage_now = BOOT_INIT;
            error_code_now = 3'd1;
        end else if (scan_done && !catalog_ready && bmp_error != 3'd0) begin
            // 扫描超时只有 bmp_error/scan_done，不会伪造 bmp_load_error。
            error_stage_now = BOOT_SCAN;
            error_code_now = bmp_error;
        end else if (catalog_ready && img_found_count == 3'd0) begin
            // 1..4 张都可播放；只有空目录是扫描错误。等目录计数寄存后再判断，避免与 scan_done 同拍误报。
            error_stage_now = BOOT_SCAN;
            error_code_now = 3'd1;
        end else if (bmp_load_error) begin
            error_stage_now = BOOT_BMP;
            error_code_now = bmp_error;
        end else if (preload_error) begin
            error_stage_now = BOOT_PRELOAD;
            error_code_now = preload_error_code;
        end else if (preload_cancel_ack_timeout || preload_cancel_release_timeout) begin
            error_stage_now = BOOT_CANCEL;
            error_code_now = preload_cancel_ack_timeout ? 3'd1 : 3'd2;
        end else if (recovery_state == REC_FAILED) begin
            error_stage_now = BOOT_INIT;
            error_code_now = 3'd2;
        end
    end
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            first_error_stage <= 3'd0;
            first_error_code <= 3'd0;
        end else if (first_error_stage == 3'd0) begin
            if (boot_error) begin
                // 屏障已关门但尚无来源，只可能是上一拍的完成协议异常。
                // 优先补记该首因，不能被这一拍新到的外部错误覆盖。
                first_error_stage <= BOOT_PROTOCOL;
                first_error_code <= 3'd1;
            end else if (startup_fault) begin
                first_error_stage <= error_stage_now;
                first_error_code <= error_code_now;
            end
        end
    end
    media_boot_guard u_boot_guard (
        .clk(clk), .rst(rst), .preload_done(preload_done), .image_complete(image_complete),
        .slot_count(img_found_count), .startup_error(startup_fault), .player_enable(player_enable), .boot_error(boot_error)
    );
    // A-8 降级：首张已开放播放后某张图加载失败，预加载器已结束取消握手、源端空闲、SD 不在恢复中，
    // 则视为加载结束——只播放已装好的前缀槽，讲稿装载与音乐照常开始（SD 口已空闲）。
    reg degraded;
    always @(posedge clk or posedge rst) begin
        if (rst) degraded <= 1'b0;
        else if (player_enable && boot_error && preload_error && !preload_busy && bmp_ready &&
                 recovery_state == REC_IDLE && !write_cancel_ack)
            degraded <= 1'b1;
    end
    assign preload_settled = preload_done || degraded;
    wire cache_step_req, cache_step_prev, cache_autoplay_stopped;
    wire [2:0] cache_desired_slot;
    wire thumb_jump;
    wire [2:0] thumb_jump_slot, thumb_focus;
    // 首张即显示：选槽只在已写排空的前缀槽内环绕（按 0..N-1 顺序装入），随后台加载增长
    wire [2:0] ready_slot_count;
    media_reveal #(.ENABLE_FX_GATE(ENABLE_FX_GATE), .FX_TIMEOUT(CLK_FREQ_HZ * 2)) u_reveal (
        .clk(clk), .rst(rst), .next_in(view_next_raw), .prev_in(view_prev_raw), .chord_toggle(blackout_toggle),
        .thumb_mode(thumb_mode), .desired_slot(cache_desired_slot), .slot_count(ready_slot_count),
        .display_valid(cache_display_valid), .display_slot(cache_display_slot), .fx_done(fx_done),
        .next_out(view_next_pass), .blackout(blackout), .revealed(reveal_event),
        .fx_go_cam(fx_go_cam), .fx_go_lens(fx_go_lens)
    );
    assign ready_slot_count = !image_complete[0] ? 3'd1 :
                                  !image_complete[1] ? 3'd1 :
                                  !image_complete[2] ? 3'd2 :
                                  !image_complete[3] ? 3'd3 :
                                  !image_complete[4] ? 3'd4 : 3'd5;
    // 复用已验证的轮播/选槽组合；显示邮箱不是逐帧 ACK，故障独立返回控制域。
    media_cache_autoplay #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .AUTO_PERIOD_MS(AUTO_PERIOD_MS),
        .ENABLE_RUNTIME_PERIOD(ENABLE_RUNTIME_PERIOD), .ENABLE_PAUSE(ENABLE_THUMBS)) u_cache_autoplay (
        .clk(clk), .rst(rst), .player_enable(player_enable), .playback_fault(cache_playback_fault),
        .manual_req(manual_req && !thumb_mode), .manual_prev(manual_prev), .auto_toggle(auto_toggle_mode),
        .mode_ready(mode_ready), .mode_value(mode_value),
        .display_valid(cache_display_valid), .display_slot(cache_display_slot), .desired_slot(cache_desired_slot),
        .step_req(cache_step_req), .step_prev(cache_step_prev),
        .auto_play_en(auto_play_en), .stopped(cache_autoplay_stopped),
        .period_update(period_update), .period_ms(period_ms),
        .pause(thumb_mode),
        .force_on(1'b0)
    );
    // 故障到达后取消未受理 offer；锁停后不因输入恢复而重开，须共同复位。
    // 已进入 CDC 的事务不能撤回，像素域 reader 原有门控仍负责阻止故障播放。
    if (ENABLE_THUMBS) begin : g_thumbs
        wire key3_stable;
        reg key3_d;
        media_key_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS)) u_key3_debounce (
            .clk(clk), .rst(rst), .button_in(key_thumb), .button_stable(key3_stable));
        always @(posedge clk or posedge rst) begin
            if (rst) key3_d <= 1'b1;
            else key3_d <= key3_stable;
        end
        // KEY4 长按切换时期、短按（松开时）开关观众屏缩略图（D32：提词模式下同样有效）；参数模式下 KEY4 不响应
        prompter_stage #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .LONG_PRESS_MS(LONG_PRESS_MS)) u_stage (
            .clk(clk), .rst(rst), .ready(config_events_ready && mode_ready && player_enable && !param_mode),
            .key_down(!key3_stable), .phase(show_phase), .phase_enter(show_phase_enter), .key_short(key4_short)
        );
        media_thumb_mode u_thumb_mode (
            .clk(clk), .rst(rst),
            .active(player_enable && !cache_playback_fault && !cache_autoplay_stopped && !param_mode),
            .thumb_press(key4_short),
            .next_event(manual_req), .prev_event(thumb_prev_event), .select_event(auto_toggle),
            .display_slot(cache_display_slot), .slot_count(ready_slot_count),
            .thumb_mode(thumb_mode), .focus(thumb_focus),
            .jump_req(thumb_jump), .jump_slot(thumb_jump_slot)
        );
        assign thumb_state = {img_found_count, thumb_focus, image_complete};
        assign key4_press = key4_short;
    end else begin : g_no_thumbs
        assign key4_press = 1'b0;
        assign key4_short = 1'b0;
        assign show_phase = 1'b0;
        assign show_phase_enter = 1'b0;
        assign thumb_mode = 1'b0;
        assign thumb_focus = 3'd0;
        assign thumb_jump = 1'b0;
        assign thumb_jump_slot = 3'd0;
        assign thumb_state = 11'd0;
    end
    media_cache_select #(.ENABLE_JUMP(ENABLE_THUMBS), .ENABLE_SHEET(ENABLE_THUMBS)) u_cache_select (
        .clk(clk), .rst(rst), .player_enable(player_enable && !cache_playback_fault && !cache_autoplay_stopped),
        .step_req(cache_step_req), .step_prev(cache_step_prev), .step_manual(manual_req),
        .slot_count(ready_slot_count), .jump_req(thumb_jump), .jump_slot(thumb_jump_slot), .sheet(thumb_mode), .desired_slot(cache_desired_slot), .src_slot(cache_slot),
        .src_manual(cache_slot_manual), .src_sheet(cache_slot_sheet), .src_valid(cache_slot_valid),
        .src_ready(cache_slot_ready), .stopped()
    );
    media_preload_boot #(.CLK_FREQ_HZ(CLK_FREQ_HZ),
        .WRITE_FINISH_TIMEOUT_MS(WRITE_FINISH_TIMEOUT_MS), .CANCEL_TIMEOUT_MS(CANCEL_TIMEOUT_MS)
    ) u_preload (
        .clk(clk), .rst(rst), .storage_ready(storage_ready), .catalog_ready(catalog_ready),
        .img_found_count(img_found_count),
        .bmp_ready(bmp_ready && sd_init_done && recovery_state == REC_IDLE && !boot_error && !startup_fault),
        .bmp_load_success(bmp_load_success), .bmp_load_error(bmp_load_error),
        .frame_write_req(write_req), .write_finish_pulse(write_finish_pulse),
        .write_cancel_ack(cancel_ack_sync[1]), .load_start_pulse(preload_start),
        .load_idx(preload_idx), .write_buf_idx(preload_write_idx), .write_cancel_req(preload_cancel),
        .preload_busy(preload_busy), .image_complete(image_complete), .preload_done(preload_done),
        .preload_error(preload_error), .error_code(preload_error_code),
        .cancel_ack_timeout(preload_cancel_ack_timeout), .cancel_release_timeout(preload_cancel_release_timeout)
    );
    // 四张图全部写入 SDRAM 后 SD 口才空闲，音频流此后独占读取器；播放故障停流。
    if (USE_FAT32) begin : g_audio_track
        media_audio_track_ctrl u_audio_track (
            .clk(clk), .rst(rst),
            .enable(player_enable && preload_settled && script_gate && (!boot_error || degraded) && !cache_playback_fault),
            // 预备固定循环 MUS1（换图不重启）；演讲跟随当前图
            .display_valid(cache_display_valid),
            .display_file(show_phase ? display_file_entry : 3'd0),
            .audio_valid(aud_valid), .audio_busy(aud_busy), .audio_done(aud_done), .audio_error(aud_error),
            .audio_start(aud_start), .audio_file_idx(aud_idx), .audio_stop(aud_stop),
            .stream_restart(audio_stream_restart), .stream_flush(audio_stream_flush),
            .track_active(audio_track_active)
        );
    end else begin : g_no_audio_track
        assign aud_start = 1'b0;
        assign aud_idx = 3'd0;
        assign aud_stop = 1'b0;
        assign audio_stream_restart = 1'b0;
        assign audio_stream_flush = 1'b0;
        assign audio_track_active = 1'b0;
    end
end else begin : g_no_preload
    assign preload_settled = 1'b0;
    assign view_next_pass = view_next_raw;
    assign blackout = 1'b0;
    assign reveal_event = 1'b0;
    assign fx_go_cam = 1'b0;
    assign fx_go_lens = 1'b0;
    assign key4_press = 1'b0;
    assign key4_short = 1'b0;
    assign show_phase = 1'b0;
    assign show_phase_enter = 1'b0;
    assign thumb_mode = 1'b0;
    assign thumb_state = 11'd0;
    assign aud_start = 1'b0;
    assign aud_idx = 3'd0;
    assign aud_stop = 1'b0;
    assign audio_stream_restart = 1'b0;
    assign audio_stream_flush = 1'b0;
    assign audio_track_active = 1'b0;
    assign auto_play_en = legacy_auto;
    assign cache_slot = 3'd0;
    assign cache_slot_manual = 1'b0;
    assign cache_slot_sheet = 1'b0;
    assign cache_slot_valid = 1'b0;
    assign preload_start = 1'b0;
    assign preload_idx = 3'd0;
    assign preload_write_idx = 3'd0;
    assign preload_cancel = 1'b0;
    assign preload_busy = 1'b0;
    assign preload_done = 1'b0;
    assign preload_error = 1'b0;
    assign image_complete = 5'b00000;
    assign preload_error_code = 3'd0;
    assign preload_cancel_ack_timeout = 1'b0;
    assign preload_cancel_release_timeout = 1'b0;
    assign player_enable = 1'b0;
    assign boot_error = 1'b0;
    assign boot_error_stage = 3'd0;
    assign boot_error_code = 3'd0;
end endgenerate

wire script_start_ok = preload_settled && player_enable;
generate if (ENABLE_SCRIPTS && USE_FAT32 && ENABLE_PRELOAD) begin : g_scripts
    assign script_loading = script_start_ok;
    prompter_script_loader #(.MAX_PAGES(SCRIPT_MAX_PAGES), .STALL_CYCLES(CLK_FREQ_HZ / 2)) u_script_loader (
        .clk(clk), .rst(rst), .start(script_start_ok), .script_valid(scr_valid),
        .file_start(scr_start), .file_key(scr_key), .file_hold(scr_hold), .file_stop(scr_stop),
        .file_busy(scr_busy), .file_done(scr_done), .file_error(scr_error),
        .byte_valid(scr_bv), .byte_data(scr_byte),
        .fifo_we(script_fifo_we), .fifo_di(script_fifo_di), .fifo_wrusedw(script_fifo_wrusedw),
        .page_toggle(script_page_toggle), .page_slot(script_page_slot), .page_top_down(script_page_top_down),
        .page_done(script_page_done), .busy(), .done(script_load_done),
        .pages_loaded(script_pages_loaded), .pages_failed(script_pages_failed), .script_slots(script_slots),
        .section_first(script_section_first), .section_pages(script_section_pages),
        .section_overview(script_section_overview), .overview_valid(script_overview_valid)
    );
end else begin : g_no_scripts
    assign script_loading = 1'b0;
    assign scr_start = 1'b0; assign scr_key = 7'd0; assign scr_hold = 1'b0; assign scr_stop = 1'b0;
    assign script_fifo_we = 1'b0; assign script_fifo_di = 32'd0;
    assign script_page_toggle = 1'b0; assign script_page_slot = 6'd0; assign script_page_top_down = 1'b0;
    assign script_load_done = 1'b0; assign script_pages_loaded = 6'd0; assign script_pages_failed = 6'd0;
    assign script_slots = 6'd0;
    assign script_section_first = 30'd0; assign script_section_pages = 25'd0;
    assign script_section_overview = 30'd0; assign script_overview_valid = 5'd0;
end endgenerate

generate if (USE_FAT32) begin : g_fat32_read
fat32_bmp_read #(.CHECK_PIXEL_INTEGRITY(1), .ENABLE_TIMEOUT(1), .ENABLE_SCRIPTS(ENABLE_SCRIPTS && ENABLE_PRELOAD),
    .CLK_FREQ_HZ(CLK_FREQ_HZ), .TIMEOUT_MS(BMP_TIMEOUT_MS), .ANY_SIZE(ANY_SIZE_IMAGES)) bmp_read_m0 (
    .clk(clk), .rst(rst), .ready(bmp_ready),
    .scan_start(scan_start_pulse), .scan_start_sector(SCAN_START_SECTOR),
    .scan_max_sector(SCAN_MAX_SECTOR), .scan_target_count(SCAN_TARGET_COUNT),
    .scan_done(scan_done), .scan_found_valid(scan_found_valid),
    .scan_found_sector(scan_found_sector), .scan_found_total(scan_found_total),
    .load_start(load_start_pulse), .load_sector(load_sector),
    .sd_init_done(sd_init_done),
    .bmp_width(bmp_width), .bmp_height(bmp_height),
    .write_req(write_req), .write_req_ack(write_ack_sync[1]),
    .sd_sec_read(sd_sec_read), .sd_sec_read_addr(sd_sec_read_addr),
    .sd_sec_read_data(sd_sec_read_data), .sd_sec_read_data_valid(sd_sec_read_data_valid),
    .sd_sec_read_end(sd_sec_read_end), .bmp_data_wr_en(bmp_data_wr_en), .bmp_data(bmp_data),
    .img_width(img_width), .img_height(img_height), .img_top_down(img_top_down),
    .pixel_hold(scaler_hold),
    .bmp_error(bmp_error), .load_error(bmp_load_error), .load_success(bmp_load_success),
    .sd_recover_req(sd_recover_req), .sd_recover_ack(sd_recover_ack),
    .audio_start(aud_start), .audio_file_idx(aud_idx), .audio_hold(audio_hold), .audio_stop(aud_stop),
    .audio_valid(aud_valid), .audio_busy(aud_busy), .audio_done(aud_done), .audio_error(aud_error),
    .audio_byte_valid(audio_byte_valid), .audio_byte(audio_byte),
    .script_valid(scr_valid),
    .script_start(scr_start), .script_key(scr_key), .script_hold(scr_hold), .script_stop(scr_stop),
    .script_busy(scr_busy), .script_done(scr_done), .script_error(scr_error),
    .script_byte_valid(scr_bv), .script_byte(scr_byte),
    .diag_fs(diag_fs)
);
end else begin : g_sector_read
assign scr_valid = 80'd0;
assign scr_busy = 1'b0;
assign scr_done = 1'b0;
assign scr_error = 8'd0;
assign scr_bv = 1'b0;
assign scr_byte = 8'd0;
assign img_width = 12'd0;
assign img_height = 12'd0;
assign img_top_down = 1'b0;
assign diag_fs = 20'd0;
assign aud_valid = 5'd0;
assign aud_busy = 1'b0;
assign aud_done = 1'b0;
assign aud_error = 8'd0;
assign audio_byte_valid = 1'b0;
assign audio_byte = 8'd0;
bmp_read #(.CHECK_PIXEL_INTEGRITY(1), .ENABLE_TIMEOUT(1),
    .CLK_FREQ_HZ(CLK_FREQ_HZ), .TIMEOUT_MS(BMP_TIMEOUT_MS)) bmp_read_m0 (
    .clk(clk), .rst(rst), .ready(bmp_ready),
    .scan_start(scan_start_pulse), .scan_start_sector(SCAN_START_SECTOR),
    .scan_max_sector(SCAN_MAX_SECTOR), .scan_target_count(SCAN_TARGET_COUNT),
    .scan_done(scan_done), .scan_found_valid(scan_found_valid),
    .scan_found_sector(scan_found_sector), .scan_found_total(scan_found_total),
    .load_start(load_start_pulse), .load_sector(load_sector),
    .sd_init_done(sd_init_done),
    .bmp_width(bmp_width), .bmp_height(bmp_height),
    .write_req(write_req), .write_req_ack(write_ack_sync[1]),
    .sd_sec_read(sd_sec_read), .sd_sec_read_addr(sd_sec_read_addr),
    .sd_sec_read_data(sd_sec_read_data), .sd_sec_read_data_valid(sd_sec_read_data_valid),
    .sd_sec_read_end(sd_sec_read_end), .bmp_data_wr_en(bmp_data_wr_en), .bmp_data(bmp_data),
    .bmp_error(bmp_error), .load_error(bmp_load_error), .load_success(bmp_load_success),
    .sd_recover_req(sd_recover_req), .sd_recover_ack(sd_recover_ack)
);
end endgenerate

// 保持初始化 SPI 不高于原工程的 200 kHz：SCLK=clk/[2*(DIV+2)]。
// 100 MHz -> 248，50 MHz -> 123；低频仿真配置钳位为最小分频 0。
localparam integer SPI_INIT_DIV = (CLK_FREQ_HZ <= 800_000) ? 0 :
                                 ((CLK_FREQ_HZ + 399_999) / 400_000) - 2;
// 不重写字节引擎；高速分频仍为 0，在 50 MHz 控制域产生 12.5 MHz。
sd_card_top #(.SPI_LOW_SPEED_DIV(SPI_INIT_DIV), .SPI_HIGH_SPEED_DIV(0)) sd_card_top_m0 (
    .clk(clk), .rst(sd_local_rst), .SD_nCS(SD_nCS), .SD_DCLK(SD_DCLK),
    .SD_MOSI(SD_MOSI), .SD_MISO(SD_MISO), .sd_init_done(sd_init_done),
    .init_state_code(diag_sd_state), .init_err_cmd(diag_err_cmd), .init_err_resp(diag_err_resp),
    .sd_sec_read(sd_sec_read), .sd_sec_read_addr(sd_sec_read_addr),
    .sd_sec_read_data(sd_sec_read_data), .sd_sec_read_data_valid(sd_sec_read_data_valid),
    .sd_sec_read_end(sd_sec_read_end), .sd_sec_write(1'b0),
    .sd_sec_write_addr(32'd0), .sd_sec_write_data(8'd0),
    .sd_sec_write_data_req(), .sd_sec_write_end()
);
endmodule
