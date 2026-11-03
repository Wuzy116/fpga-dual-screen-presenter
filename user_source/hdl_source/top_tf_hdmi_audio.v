
module top(
    input                       clk,
    input                       rst_n,          // 板上 KEY1（A2，低有效）：全局复位
    // 板上按键均低有效，端口名与板上丝印 KEY2~KEY4 一致
    input                       key2,           // KEY2（B2）：单击下一张，双击/连续长按减当前参数；缩略图模式内单击焦点右移、双击左移（长按仍为减）
    input                       key3,           // KEY3（B1）：单击轮播开关，双击/连续长按加当前参数；缩略图模式内单击确认打开焦点图
    input                       key4,           // KEY4（C1）：进入/退出 2x2 缩略图总览页（淡出/淡入）
    // 板上拨码 SW1~SW4（C8/C7/C6/C5，拨上为 1）：SW1-2 选调节对象 00 周期/音量、01 亮度、10 对比度、11 亮度对比度复位 128；
    // SW3-4 选步长 1/4/16/32。KEY2/KEY3 的双击/连续长按对所选对象做减/加。
    input  [3:0]                sw,

    output [7:0]                seg_sel,
    output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI A TMDS（手册第 8 页 CLK K1、D0 F5、D1 E3、D2 B3；N 端由 LVDS33 配对）
    output                      HDMIA_CLK_P,
    output                      HDMIA_D2_P,
    output                      HDMIA_D1_P,
    output                      HDMIA_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso,

    // 板载用户 W25Q64；独立于 TF SPI 和固化 Flash。六线位置见 pin.adc（手册第17页）。
    input                       flash_miso,
    output                      flash_cs_n,
    output                      flash_sclk,
    output                      flash_mosi,
    output                      flash_wp_n,
    output                      flash_hold_n,

    // 板载 LED1~4（A4/A3/C10/B12，高电平点亮）：参数写入 W25Q64 并校验成功后全亮一次。
    output [3:0]                led,
    // 板载蜂鸣器 BUZZER（H11，低电平响；SW5 拨上为硬件静音）：D23 提示音
    output                      buzzer,
    // INMP441 I2S 麦克风（J1 扩展口 29=3.3V、30=GND、31 SCK M15、32 WS L16、33 SD N16，L/R 接地）：说话时压低背景音乐
    output                      mic_sck,
    output                      mic_ws,
    input                       mic_sd,
    // VS1838B 红外接收模块（5V 供电：J1 11=VCC、12=GND；OUT 经电平转换接 J1 34 = N14，空闲高）：NEC 遥控器
    input                       ir_rx
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
// SDRAM 地址单位为 32-bit 字；背景槽 0..4 的 bank 基址为 i*FRAME_PIXELS，第 6 个 bank 为总览页，由 loader/reader 内部计算。
parameter [ADDR_BITS-1:0] FRAME_PIXELS = 307200;   // 640*480
// 四 bank 帧缓存只支持四槽预加载播放；置 0（旧双缓冲）在仿真中直接报配置错误。
// 音频/面板跟随实际帧提交；缓存轮播依据返回控制域的显示状态计时。
parameter ENABLE_PRELOAD_PLAYBACK = 1;
// 默认启用周期配置，仅用于预加载通路，初值5000ms。
parameter ENABLE_PERIOD_CONFIG = 1;
// 默认启用音量配置/CDC/PCM链，由新按键调节。
parameter ENABLE_VOLUME_CONFIG = 1;
// 默认启用模式配置，初值为手动；Flash开启后支持恢复模式。
parameter ENABLE_MODE_CONFIG = 1;
// 默认启用完整配置服务；W25Q64 参数持久化依赖其他配置分支同时开启。
parameter ENABLE_FLASH_CONFIG = 1;
// 1：TF 卡按 FAT32 根目录 PIC1~4.BMP 读取；0：旧的物理扇区“BM”扫描（前 64 MB）。
parameter USE_FAT32_STORAGE = 1;

// SD/BMP、按键和面板共用板载 50 MHz 晶振，不是 HDMI 像素时钟域。
localparam integer CTRL_CLK_FREQ_HZ = 50_000_000;
parameter integer KEY_DEBOUNCE_MS     = 20;
parameter integer KEY_LONG_PRESS_MS   = 1000;
parameter integer KEY_DOUBLE_CLICK_MS = 300;
parameter integer KEY_CHORD_WINDOW_MS = 50;
parameter integer AUTO_PERIOD_MS      = 1000;
// 音源仍由参数提供；启用新按键映射后可运行时调节音量。
parameter integer AUDIO_ENABLE        = 1;
// 1：当前显示图的 MUSn.PCM 存在且在播时用 TF 卡 PCM，否则回退媒体音调。
parameter [1:0] AUDIO_SOURCE_SEL       = 2'd1; // 0测试音 / 1 TF卡PCM(回退媒体) / 2媒体 / 3静音
parameter [31:0] AUDIO_TEST_PHASE_INC  = 32'd39370534;
// 备用测试音（卡上无 MUS 文件 / 选测试音时的正弦与媒体提示音）：D31 为腾出资源默认不生成（用户确认演示卡总有音乐），
// 置 0 时 SEL=0/2 与无音乐时输出静音样本（握手照常）；仿真中需要测试音的测试台显式置 1。
parameter ENABLE_FALLBACK_TONE = 0;
// 默认启用新映射、连续长按和调节对象提示；双键短按选择周期/音量。
parameter ENABLE_PARAMETER_KEYS = 1;
parameter integer KEY_REPEAT_MS = 200;
parameter integer SAVE_LED_MS = 1000;
// 第 10 课转场帧数：手动淡出/淡入、轮播从上到下 Wipe 各约 N 帧；0 = 旁路硬切。
parameter integer TRANSITION_FRAMES = 16;
// 第 11 课 TF 卡 PCM：MUS1~4.PCM 为 16 位有符号小端 48 kHz，WAV_CHANNELS=1 单声道复制到左右、2 为交错立体声。
// 播放缓冲 2^WAV_FIFO_ADDR_W-1 帧（12 → 约 85 ms），攒满 256 帧开播。需 FAT32 + 预加载。
parameter ENABLE_WAV_PLAYBACK = 1;
parameter integer WAV_CHANNELS = 1;
parameter integer WAV_FIFO_ADDR_W = 12;
// 音画同步：手动淡出/淡入期间 PCM 增益 = 用户音量 × 画面 alpha / 256（alpha=255 时原样），需音量配置通路。
parameter ENABLE_AUDIO_FADE = 1;
// 第 12 课音频波形：底部 (64,400) 起 512x64 淡白底板 + 多色连续波形（自动增益 + pow0.6 压缩）+ 右侧 dB 分格峰值条，
// 取 HDMI 实际提交的 PCM（含音量/淡出），始终显示。
parameter ENABLE_AUDIO_WAVEFORM = 1;
// 第 13 课：TF 图片可为任意 1..2048 x 1..2048（24 位、任意行填充/行序），加载时等比缩放到 640x480，黑边居中。
parameter ENABLE_ANY_SIZE_IMAGES = 1;
// 第 13/15 课缩略图：加载时 4:1 取样写入第 5 个 bank 的 2x2 总览页（每格 160x120，第 15 课起居中于 (160,120)..(479,359)），
// KEY4 切到总览页显示（居中 2x2），焦点格 2 像素边框，未加载的格子深灰底 + 闪烁灰框。
parameter ENABLE_THUMBNAILS = 1;
localparam [23:0] THUMB_BORDER_RGB = 24'hffd400;
localparam [23:0] THUMB_PENDING_RGB = 24'h303030;        // 未加载格底色
localparam [23:0] THUMB_PENDING_EDGE_RGB = 24'h909090;   // 未加载格闪烁边框
// 第 14 课亮度/对比度：拨码选择对象 + KEY2/KEY3 调节，作用于全屏图与缩略图内的图片，帧边界生效，不写 Flash。
// 置 0 时 B=C=128（图片逐位不变），拨码不改变原有周期/音量调节。
parameter ENABLE_PICTURE_ADJUST = 1;
// 麦克风闪避：检测到说话时背景音乐增益约 0.1 s 降到 64/256（约 -12 dB），说完保持 0.8 s 后约 1 s 恢复；LED1 亮 = 判为说话。
// 麦克风在线时提词屏 KEY3 连续滚动只在说话期间（停顿后再滚 0.3 s）前进，计时条左侧显示话筒电平条；
// 未接麦克风（样本连续 0.5 s 全 0）时滚动照旧、不画电平条。置 0 时不生成，SCK/WS 输出低电平，音乐增益不变。
parameter ENABLE_MIC_DUCK = 1;
// 红外遥控（D29）：上/下 = 提词屏下一页/上一页，左/右 = 观众屏上一张/下一张，* = 提词连续滚动开关，
// 1~4 / 5~8 = 周期/音量/亮度/对比度 加/减（按住连续），OK 按住约 1 s = 保存参数；不看拨码。LED2 闪 = 收到遥控码。
parameter ENABLE_IR_REMOTE = 1;
// 观众屏特效（D30）：每次进入第 3 张（影像）闪光灯光晕 + 全屏白闪 + 快门“咔嚓”（约 170 ms，期间音乐降到 1/4），第 4 张（续航）电池从空快速充满，
// 第 5 张（价格）画面内部抖动约 0.5 s（揭晓时在黑场淡入后段开始）。坐标按演示素材写死，换图需改 media_fx_* 参数。
// D32：第 2 张手机由远到近、零件飞入组装、转一圈；第 2 -> 3、3 -> 4 张的“下一张”先推进镜头再换图（行重映射引擎）。
// D31：第 2 张（外观）中间那台手机原地转一圈（正面 -> 背面 -> 正面，约 1.5 s），背面取自图中右边那台。
parameter ENABLE_SCREEN_FX = 1;
// D32 为特效腾资源（用户定）：提词屏讲稿总览与选页去掉（KEY4 短按不再打开总览；观众屏缩略图总览保留）；
// Flash 只保存音量 / 亮度 / 模式，周期与对比度每次上电回到默认值。置 1 恢复原功能。
parameter ENABLE_SCRIPT_SELECT = 0;
parameter SAVE_PERIOD = 0;
parameter SAVE_CONTRAST = 0;
// 数码管每位点亮占空比（%），100 = 原亮度；调小可降低亮度与板级功耗。
parameter integer SEG_ON_PERCENT = 100;
// D18：状态 OSD 与参数行固定在提词屏 A（OSD 左上、参数行在讲稿下方 y=440），字幕带（D20 移到底部）与音乐波形在观众屏 B。
// PROMPTER_MIRROR：提词屏直接显示时为 0（不生成镜像）；改用 45° 分光玻璃投影时置 1，生成整行镜像（A 晚一行，占 7 块 BRAM9K）。
parameter PROMPTER_MIRROR = 0;
// 双 HDMI 阶段 1.3：提词屏计时条（总用时 / 剩余倒计时，超时变红转正计 / 本页用时），倒计时目标 MM:SS。
// 开发阶段：复位起计时、不暂停；“本页”暂按显示图切换清零（讲稿翻页接入后改为讲稿页）。
parameter integer PROMPTER_TARGET_MM = 10;
parameter integer PROMPTER_TARGET_SS = 0;
// 双 HDMI 阶段 2.2：预加载完成后把 TF 卡 SnPmm.BMP 讲稿（640x480 1 位）装入 SDRAM 讲稿区，装完再开始播放音乐。
// D19：5 个背景 bank（槽 0..4）+ 第 6 个 bank 为 3×2 总览页；讲稿区紧接其后：第 k 页在 SCRIPT_BASE + k*9600，
// 每行 20 字，bit31 为最左像素，1 = 墨迹。
parameter ENABLE_PROMPTER_SCRIPTS = 1;
parameter integer SCRIPT_MAX_PAGES = 26;   // 讲稿页 + 各节总览页（SnP00），SDRAM 余量所限（D19）
localparam [ADDR_BITS-1:0] SCRIPT_BASE = FRAME_PIXELS * 6;
// 讲稿区之后 16 字（4 组，每 bank 一组）为读数据对齐校准字（写入器首页前写入，读取器每行先读一组），须在 2^ADDR_BITS 字之内
localparam [ADDR_BITS-1:0] SCRIPT_CAL_ADDR = SCRIPT_BASE + SCRIPT_MAX_PAGES * 9600;
// 双 HDMI 阶段 2.4：讲稿装好后提词屏 A 的底图为讲稿区窗口（黑底白字），未装好或卡上没有讲稿时为底色。
// D18 产品翻页为直接切换（无动画），只在提词模式（SW4 拨下）下由按键驱动。
localparam [23:0] PROMPTER_INK_RGB = 24'hffffff;
localparam [23:0] PROMPTER_BG_RGB  = 24'h000000;

wire Sdr_init_done;
wire storage_ready_ctrl;
wire config_boot_complete, config_boot_apply;
wire config_service_ready, config_service_busy, config_save_done;
wire config_fatal_error, config_request_dropped;
wire [7:0] config_error_code;
wire [15:0] config_restore_period_ms;
wire [7:0] config_restore_volume;
wire config_restore_mode;
wire [7:0] config_restore_brightness, config_restore_contrast;
wire mode_restore_write = ENABLE_FLASH_CONFIG && config_boot_apply;
wire mode_restore_value = config_restore_mode;
wire mode_boot_config_done = ENABLE_MODE_CONFIG &&
                            (ENABLE_FLASH_CONFIG ? config_boot_apply : storage_ready_ctrl);
// 只等待一次启动加载；保存期间 service_ready 拉低不能撤销媒体启动许可。
wire media_storage_ready_ctrl = storage_ready_ctrl && config_boot_complete;
wire mode_ready_ctrl;
wire mode_value_ctrl;
wire auto_play_active_ctrl;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk = clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data;
wire        display_valid;
wire [1:0]  seg_img_idx;
wire        seg_load_busy;
wire        seg_manual_event;

wire [2:0]  frame_read_index;
wire        frame_player_enable_ctrl, frame_player_enable_pix;
wire [2:0]  cache_slot_ctrl, cache_slot_pix;
wire        cache_slot_manual_ctrl, cache_slot_manual_pix;
wire        cache_slot_sheet_ctrl, cache_slot_sheet_pix;
wire        cache_slot_valid_ctrl, cache_slot_ready_ctrl, cache_slot_update_pix;
wire        frame_video_enable, frame_started, frame_reader_stopped, frame_reader_error;
wire        frame_display_valid_pix;
wire [2:0]  frame_display_slot_pix;
wire        frame_display_valid_ctrl, frame_display_update_ctrl;
wire [2:0]  frame_display_slot_ctrl;
wire        frame_reader_stopped_ctrl, frame_reader_error_ctrl, frame_playback_fault_ctrl;

wire        sd_card_write_en;
wire [31:0] sd_card_write_data;
wire        sd_card_write_top_down;
wire [10:0] thumb_state_ctrl;   // {目录图片数[2:0], 焦点[2:0], 已完成槽[4:0]}，sd_card_clk 域
// 像素域帧锁存（与 reader 采样同拍）：本帧读总览页、焦点、完成掩码，一帧内恒定
reg         thumb_sheet_q;
reg         qr_show_q;     // D21：本帧观众屏是否画二维码（显示第 5 张、转场结束、不在总览页）；在 g_preload_playback 内驱动
reg  [2:0]  thumb_focus_q;
reg  [4:0]  thumb_complete_q;
reg  [4:0]  thumb_expected_q;   // 目录里存在的槽（slot < 图片数），未加载才画占位
wire        sd_card_write_req;
wire        sd_card_write_req_ack;
wire        frame_write_cancel_req; // sd_card_clk 域保持型请求
wire        frame_write_cancel_ack; // ext_mem_clk 域保持型确认
wire        frame_write_finish;
reg         frame_write_toggle_mem;

wire [2:0]  write_buf_idx;
wire [1:0]  disp_buf_idx;   // sd_card_bmp 旧双缓冲输出，四 bank 通路不使用

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

// HDMI 1.4b 音频发射相关
wire        audio_i2s_bclk;
wire        audio_i2s_lrck;
wire        audio_sample_tick;
wire        tone_valid, tone_ready;
wire signed [15:0] tone_left, tone_right;
wire [1:0] audio_media_id;
wire audio_media_present;
wire [1:0] legacy_audio_media_id;
wire legacy_audio_media_present;
wire media_tone_valid, media_tone_ready;
wire signed [15:0] media_tone_left, media_tone_right;
// TF 卡 PCM：字节流/曲目控制在 sd_card_clk 域，样本与 wav_active 在 video_clk 域。
wire wav_byte_valid, wav_stream_restart, wav_stream_flush, wav_track_active_ctrl, wav_hold_ctrl;
wire [7:0] wav_byte;
wire wav_overflow_ctrl, wav_underflow_pix;
wire wav_active, wav_valid, wav_ready;
wire signed [15:0] wav_left, wav_right;
wire [7:0] trans_alpha;
wire [7:0] trans_audio_alpha;   // 只在换槽的淡变中跟随 trans_alpha，仅进出总览页时为 255
wire [7:0] audio_gain_pix;
wire [7:0] audio_gain_fade;   // 音量 x 转场淡变，再经黑场（D21）按比例淡变得到 audio_gain_blk
wire [7:0] audio_gain_blk;    // 再乘麦克风闪避系数得到 audio_gain_pix
wire [7:0] mic_duck_gain;
wire       mic_talking;
wire       mic_speaking, mic_present;   // 提词屏说话滚动 / 电平条
wire [14:0] ir_events_ctrl;            // 遥控事件（控制域单拍），位定义见 ir_nec_remote
wire        ir_rx_pulse;
wire        ir_ready_ctrl;             // 配置恢复完成后才接受遥控事件（与板上按键相同）
wire [4:0] mic_env_log, mic_thr_log;
wire       blackout_ctrl;
wire source_valid, source_ready;
wire signed [15:0] source_left, source_right;
wire signed [15:0] mix_left, mix_right;          // 叠加快门声后的音源（D30）
wire               fx_click;                      // 像素域单拍：开始播快门声
wire volume_sample_valid, volume_sample_ready;
wire signed [15:0] volume_sample_left, volume_sample_right;
wire signed [15:0] pcm_left, pcm_right;
wire        audio_underrun;
wire        audio_rst = ~pix_rst_n; // 音频与视频共享像素域复位
wire        audio_valid;
wire [23:0] audio_left_data;
wire [23:0] audio_right_data;
wire        acr_valid;
wire        acr_raw_valid;
reg         acr_primed;
wire [19:0] acr_cts;
wire [19:0] acr_n;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;
wire        hdmi_audio_overflow;

// PLL 仅由外部复位驱动，禁止将包含 LOCK 的业务复位反馈给 PLL。
// 单 PLL；各域异步复位、两级同步释放，无 POR 或额外 LOCK 延时。
wire sys_pll_lock;
wire ext_rst_n = rst_n & sys_pll_lock;
wire rst_all = ~ext_rst_n;
wire ctrl_rst_n, mem_rst_n, pix_rst_n, serial_rst_n;
reset_sync u_ctrl_reset (.clk(sd_card_clk), .ext_rst_n(ext_rst_n), .rst_n_sync(ctrl_rst_n));
reset_sync u_mem_reset (.clk(ext_mem_clk), .ext_rst_n(ext_rst_n), .rst_n_sync(mem_rst_n));
reset_sync u_pix_reset (.clk(video_clk), .ext_rst_n(ext_rst_n), .rst_n_sync(pix_rst_n));
reset_sync u_serial_reset (.clk(hdmi_5x_clk), .ext_rst_n(ext_rst_n), .rst_n_sync(serial_rst_n));

// SDRAM 初始化完成为存储域保持电平；两拍同步后才允许控制域启动媒体任务。
sync_2ff u_storage_ready_sync (
    .clk(sd_card_clk), .rst_n(ctrl_rst_n),
    .async_in(Sdr_init_done), .sync_out(storage_ready_ctrl)
);

// C0 用于 PLL 内部反馈；C1/C2 为存储，C3 为像素/音频，C4 为串行输出。
sys_pll_promax_40 sys_pll_m0(
    .refclk     (clk),
    .clk0_out   (),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft),
    .clk3_out   (video_clk),
    .clk4_out   (hdmi_5x_clk),
    .locked     (sys_pll_lock),
    .reset      (~rst_n)
);

// mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
always @(posedge ext_mem_clk or negedge mem_rst_n) begin
    if (!mem_rst_n)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

// 周期配置与持久化服务共用控制域/复位；仅启动加载可写恢复入口。
// 旧映射保留 C1f 手势；新映射按当前对象分配 KEY1减/KEY2加，周期步长1000 ms。
wire period_restore_write = ENABLE_FLASH_CONFIG && SAVE_PERIOD && config_boot_apply;
wire [15:0] period_restore_ms = config_restore_period_ms;
wire period_user_write;
wire [15:0] period_user_ms;
wire period_increase_event, period_decrease_event;
// D18：参数模式下 sd_card_bmp 按 param_sel 只给出周期、音量或画面（亮度/对比度）其中一种增减事件。
wire param_mode_ctrl;
wire [1:0] param_sel_ctrl;
wire picture_increase_event, picture_decrease_event;
// 双键持续 3 秒的控制域单拍保存请求；config_save_done 才表示成功完成。
wire config_save_event;
wire period_config_update;
wire [15:0] period_config_ms;
// synthesis translate_off
initial begin
    if ((ENABLE_PARAMETER_KEYS != 0 && ENABLE_PARAMETER_KEYS != 1) ||
        (ENABLE_PARAMETER_KEYS && (!ENABLE_PRELOAD_PLAYBACK ||
            (!ENABLE_PERIOD_CONFIG && !ENABLE_VOLUME_CONFIG)))) begin
        $display("MEDIA_CONFIG_ERROR top parameter keys %m: boolean enable, preload and at least one parameter required");
        $finish;
    end
    if ((ENABLE_PERIOD_CONFIG != 0 && ENABLE_PERIOD_CONFIG != 1) ||
        (ENABLE_PERIOD_CONFIG && !ENABLE_PRELOAD_PLAYBACK)) begin
        $display("MEDIA_CONFIG_ERROR top period config %m: boolean enable and preload mode required");
        $finish;
    end
end
// synthesis translate_on
generate if (ENABLE_PERIOD_CONFIG) begin : g_period_config
    media_period_adjust u_period_adjust (
        .rst(~ctrl_rst_n), .increase_event(period_increase_event),
        .decrease_event(period_decrease_event), .current_period_ms(period_config_ms),
        .user_write(period_user_write), .user_period_ms(period_user_ms)
    );
    media_period_config u_period_config (
        .clk(sd_card_clk), .rst(~ctrl_rst_n),
        .restore_write(period_restore_write), .restore_period_ms(period_restore_ms),
        .user_write(period_user_write), .user_period_ms(period_user_ms),
        .period_update(period_config_update), .period_ms(period_config_ms)
    );
end else begin : g_static_period
    assign period_user_write = 1'b0;
    assign period_user_ms = 16'd0;
    assign period_config_update = 1'b0;
    assign period_config_ms = 16'd0;
end endgenerate

// 音量启动恢复来自持久化服务；新映射用户写入与恢复共用唯一配置源，恢复优先。
wire volume_restore_write = ENABLE_FLASH_CONFIG && config_boot_apply;
wire [7:0] volume_restore_value = config_restore_volume;
wire volume_user_write;
wire [7:0] volume_user_value;
wire volume_increase_event, volume_decrease_event;
// 只读UI状态，不增加持久化字段；本步导出到顶层，显示提示后续实现。
wire parameter_selected_volume;
wire volume_config_update;
wire [7:0] volume_config_value, volume_value_pix;
wire volume_update_pix;
// 音画同步增益：alpha 只在帧边界变化（像素域寄存器），与已同域的音量组合相乘；alpha=255 原样透传。
wire [15:0] audio_fade_product = volume_value_pix * trans_audio_alpha;
assign audio_gain_fade = (ENABLE_AUDIO_FADE == 0 || trans_audio_alpha == 8'd255) ? volume_value_pix :
                        audio_fade_product[15:8];
// synthesis translate_off
initial begin
    if (ENABLE_VOLUME_CONFIG != 0 && ENABLE_VOLUME_CONFIG != 1) begin
        $display("MEDIA_CONFIG_ERROR top volume config %m: boolean enable required");
        $finish;
    end
end
// synthesis translate_on
generate if (ENABLE_PARAMETER_KEYS && ENABLE_VOLUME_CONFIG) begin : g_volume_adjust
    media_volume_adjust u_volume_adjust (
        .rst(~ctrl_rst_n), .increase_event(volume_increase_event),
        .decrease_event(volume_decrease_event), .current_volume(volume_config_value),
        .user_write(volume_user_write), .user_volume(volume_user_value)
    );
end else begin : g_no_volume_adjust
    assign volume_user_write = 1'b0;
    assign volume_user_value = 8'd0;
end endgenerate
generate if (ENABLE_VOLUME_CONFIG) begin : g_volume_config
    media_volume_config u_volume_config (
        .clk(sd_card_clk), .rst(~ctrl_rst_n),
        .restore_write(volume_restore_write), .restore_volume(volume_restore_value),
        .user_write(volume_user_write), .user_volume(volume_user_value),
        .volume_update(volume_config_update), .volume(volume_config_value)
    );
    // 必须使用共同原始复位源；不能用单个域已同步释放的复位替代。
    audio_volume_cdc u_volume_cdc (
        .src_clk(sd_card_clk), .dst_clk(video_clk), .rst(rst_all),
        .src_volume(volume_config_value), .dst_volume(volume_value_pix),
        .dst_update(volume_update_pix)
    );
    audio_pcm_volume u_pcm_volume (
        .clk(video_clk), .rst(audio_rst), .volume(audio_gain_pix),
        .input_valid(source_valid), .input_ready(source_ready),
        .input_left(mix_left), .input_right(mix_right),
        .sample_valid(volume_sample_valid), .sample_ready(volume_sample_ready),
        .sample_left(volume_sample_left), .sample_right(volume_sample_right)
    );
end else begin : g_static_volume
    // 关闭时不增加流水级，逐线保持原 mux -> adapter 的 valid/ready/data。
    assign volume_config_update = 1'b0;
    assign volume_config_value = 8'd255;
    assign volume_value_pix = 8'd255;
    assign volume_update_pix = 1'b0;
    assign volume_sample_valid = source_valid;
    assign source_ready = volume_sample_ready;
    assign volume_sample_left = mix_left;
    assign volume_sample_right = mix_right;
end endgenerate

// 阶段 3.1 提词模式（D13/D14）：控制域按键命令 → 像素域导航；像素域应显示的节 → 控制域跳槽
wire        prompter_mode_sw_ctrl, prompter_mode_ctrl;
wire [5:0]  prompter_cmd_ctrl;
wire        prompter_timer_clear;
wire [5:0]  prompter_page_no, prompter_page_total;   // D21：计时条“页 NN/NN”
// D18 时期：0 预备 / 1 演讲（KEY4 长按切换），控制域状态在 sd_card_bmp
wire        show_phase_ctrl;
wire        reveal_event_ctrl;
wire        show_phase_enter_ctrl, prompter_active_ctrl;
reg         show_phase_pix;          // 像素域当前时期（同步电平）
reg         phase_f;                 // 帧边界锁存，波形开关整帧不变
assign prompter_mode_ctrl = ENABLE_PROMPTER_SCRIPTS && prompter_mode_sw_ctrl;

// ===================== 拨码解码（D18）+ 亮度/对比度：控制域参数 + 整笔跨到像素域 =====================
// 像素域拿到 {参数模式, 调节对象, 亮度, 对比度}，参数行据此标出当前调节对象。
wire [2:0] picture_sel_pix;
wire [7:0] picture_brightness_ctrl, picture_contrast_ctrl;
wire [7:0] picture_brightness_pix, picture_contrast_pix;
generate if (ENABLE_PICTURE_ADJUST) begin : g_picture_adjust
    media_picture_adjust #(.STABLE_CYCLES((CTRL_CLK_FREQ_HZ / 1000) * KEY_DEBOUNCE_MS),
        .ENABLE_DIRECT(ENABLE_IR_REMOTE)) u_picture_adjust (
        .clk(sd_card_clk), .rst(~ctrl_rst_n), .sw(sw),
        .increase_event(picture_increase_event), .decrease_event(picture_decrease_event),
        .bright_inc(ir_ready_ctrl && ir_events_ctrl[7]), .bright_dec(ir_ready_ctrl && ir_events_ctrl[11]),
        .contrast_inc(ir_ready_ctrl && ir_events_ctrl[8]), .contrast_dec(ir_ready_ctrl && ir_events_ctrl[12]),
        .restore_write(ENABLE_FLASH_CONFIG && config_boot_apply),
        .restore_brightness(config_restore_brightness), .restore_contrast(SAVE_CONTRAST ? config_restore_contrast : 8'd128),
        .param_mode(param_mode_ctrl), .param_sel(param_sel_ctrl),
        .brightness(picture_brightness_ctrl), .contrast(picture_contrast_ctrl),
        .prompter_mode(prompter_mode_sw_ctrl)
    );
    // 与缩略图状态相同：控制域值变化且邮箱空闲时发出最新值，像素域在 dst_update 时更新。
    reg  [18:0] picture_sent_ctrl;
    reg  [18:0] picture_state_pix;
    wire [18:0] picture_state_ctrl = {param_mode_ctrl, param_sel_ctrl, picture_brightness_ctrl, picture_contrast_ctrl};
    wire        picture_cdc_ready, picture_cdc_update;
    wire [18:0] picture_cdc_slot;
    wire        picture_cdc_valid = picture_state_ctrl != picture_sent_ctrl;
    always @(posedge sd_card_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n) picture_sent_ctrl <= {3'd0, 8'd128, 8'd128};
        else if (picture_cdc_valid && picture_cdc_ready) picture_sent_ctrl <= picture_state_ctrl;
    end
    // 必须使用共同原始复位源；复位后两侧均为 {000,128,128}，无需首笔传送。
    media_slot_cdc #(.SLOT_W(19)) u_picture_cdc (
        .src_clk(sd_card_clk), .dst_clk(video_clk), .rst(rst_all),
        .src_slot(picture_state_ctrl), .src_valid(picture_cdc_valid), .src_ready(picture_cdc_ready),
        .dst_slot(picture_cdc_slot), .dst_update(picture_cdc_update)
    );
    always @(posedge video_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) picture_state_pix <= {3'd0, 8'd128, 8'd128};
        else if (picture_cdc_update) picture_state_pix <= picture_cdc_slot;
    end
    assign {picture_sel_pix, picture_brightness_pix, picture_contrast_pix} = picture_state_pix;
end else begin : g_no_picture_adjust
    assign prompter_mode_sw_ctrl = 1'b0;
    assign param_mode_ctrl = 1'b0;
    assign param_sel_ctrl = 2'd0;
    assign picture_brightness_ctrl = 8'd128;
    assign picture_contrast_ctrl = 8'd128;
    assign picture_sel_pix = 3'd0;
    assign picture_brightness_pix = 8'd128;
    assign picture_contrast_pix = 8'd128;
end endgenerate

// synthesis translate_off
initial begin
    if ((ENABLE_FLASH_CONFIG != 0 && ENABLE_FLASH_CONFIG != 1) ||
        (ENABLE_FLASH_CONFIG && (!ENABLE_PRELOAD_PLAYBACK || !ENABLE_PERIOD_CONFIG ||
                                 !ENABLE_VOLUME_CONFIG || !ENABLE_MODE_CONFIG))) begin
        $display("MEDIA_CONFIG_ERROR top Flash config %m: boolean enable and all config paths required");
        $finish;
    end
end
// synthesis translate_on
generate if (ENABLE_FLASH_CONFIG) begin : g_flash_config
    media_config_persistence_bridge u_bridge (
        // SAVE_PERIOD=0 时周期字段固定写 5000：保存服务只接受 1000..60000 ms，写 0 会让每次保存都被拒绝
        .clk(sd_card_clk), .rst_n(ctrl_rst_n), .period_ms(SAVE_PERIOD ? period_config_ms : 16'd5000),
        .volume(volume_config_value), .mode(mode_value_ctrl),
        .brightness(picture_brightness_ctrl), .contrast(SAVE_CONTRAST ? picture_contrast_ctrl : 8'd128), .save_event(config_save_event),
        .boot_complete(config_boot_complete), .boot_apply(config_boot_apply),
        .restore_period_ms(config_restore_period_ms), .restore_volume(config_restore_volume),
        .restore_mode(config_restore_mode), .restore_brightness(config_restore_brightness),
        .restore_contrast(config_restore_contrast), .service_ready(config_service_ready),
        .busy(config_service_busy), .save_done(config_save_done), .fatal_error(config_fatal_error),
        .error_code(config_error_code), .request_dropped(config_request_dropped),
        .flash_miso(flash_miso), .flash_cs_n(flash_cs_n), .flash_sclk(flash_sclk),
        .flash_mosi(flash_mosi), .flash_wp_n(flash_wp_n), .flash_hold_n(flash_hold_n)
    );
end else begin : g_no_flash_config
    assign config_boot_complete = 1'b1;
    assign config_boot_apply = 1'b0;
    assign config_restore_period_ms = 16'd0;
    assign config_restore_volume = 8'd0;
    assign config_restore_mode = 1'b0;
    assign config_restore_brightness = 8'd128;
    assign config_restore_contrast = 8'd128;
    assign config_service_ready = 1'b0;
    assign config_service_busy = 1'b0;
    assign config_save_done = 1'b0;
    assign config_fatal_error = 1'b0;
    assign config_error_code = 8'd0;
    assign config_request_dropped = 1'b0;
    assign flash_cs_n = 1'b1;
    assign flash_sclk = 1'b0;
    assign flash_mosi = 1'b0;
    assign flash_wp_n = 1'b1;
    assign flash_hold_n = 1'b1;
end endgenerate

// save_done 仅在擦除/编程/回读校验全部通过后出现；失败、启动恢复均不点亮。
localparam integer SAVE_LED_CYCLES = (CTRL_CLK_FREQ_HZ / 1000) * SAVE_LED_MS;
localparam integer SAVE_LED_W = $clog2(SAVE_LED_CYCLES + 1);
reg [SAVE_LED_W-1:0] save_led_count;
always @(posedge sd_card_clk or negedge ctrl_rst_n) begin
    if (!ctrl_rst_n)
        save_led_count <= 0;
    else if (config_save_done)
        save_led_count <= SAVE_LED_CYCLES;
    else if (save_led_count != 0)
        save_led_count <= save_led_count - 1'b1;
end
// 红外遥控解码（控制域）。未启用时事件恒 0。
assign ir_ready_ctrl = config_boot_complete && mode_ready_ctrl;
generate if (ENABLE_IR_REMOTE) begin : g_ir_remote
    ir_nec_remote #(.CLK_HZ(CTRL_CLK_FREQ_HZ)) u_ir_remote (
        .clk(sd_card_clk), .rst(~ctrl_rst_n), .ir_in(ir_rx), .events(ir_events_ctrl), .rx_pulse(ir_rx_pulse)
    );
end else begin : g_no_ir_remote
    assign ir_events_ctrl = 15'd0;
    assign ir_rx_pulse = 1'b0;
end endgenerate
// D32 遥控 9：声控滚动开关。控制域每按一次翻转 voice_ctl_ctrl，像素域取变化沿为单拍命令（模式状态在 g_script_reader 内）。
reg  voice_ctl_ctrl;
wire voice_ctl_pix;
wire voice_on_pix, scroll_auto_pix;   // 声控滚动 / 匀速自动滚动（互斥）
always @(posedge sd_card_clk or negedge ctrl_rst_n) begin
    if (!ctrl_rst_n) voice_ctl_ctrl <= 1'b0;
    else if (ir_ready_ctrl && ir_events_ctrl[14]) voice_ctl_ctrl <= !voice_ctl_ctrl;
end
sync_2ff u_voice_ctl_sync (.clk(video_clk), .rst_n(pix_rst_n), .async_in(voice_ctl_ctrl), .sync_out(voice_ctl_pix));
// synthesis translate_off
pullup u_ir_rx_pullup (ir_rx);   // 与 pin.adc 的内部上拉一致：测试台不接遥控时为空闲高电平
// synthesis translate_on
// LED2 在每个有效遥控码后亮约 0.1 s（板测确认接收与解码）
localparam integer IR_LED_CYCLES = CTRL_CLK_FREQ_HZ / 10;
reg [$clog2(IR_LED_CYCLES + 1)-1:0] ir_led_count;
always @(posedge sd_card_clk or negedge ctrl_rst_n) begin
    if (!ctrl_rst_n) ir_led_count <= 0;
    else if (ir_rx_pulse) ir_led_count <= IR_LED_CYCLES;
    else if (ir_led_count != 0) ir_led_count <= ir_led_count - 1'b1;
end
// LED1 另外指示麦克风判为说话（像素域电平两级同步到控制域，仅供现场调灵敏度）
wire mic_talking_ctrl;
sync_2ff u_mic_talking_sync (.clk(sd_card_clk), .rst_n(ctrl_rst_n), .async_in(mic_talking), .sync_out(mic_talking_ctrl));
assign led = {{2{save_led_count != 0}}, save_led_count != 0 || ir_led_count != 0, save_led_count != 0 || mic_talking_ctrl};

// D23 蜂鸣器提示音（控制域）：时期切换“嘀”、保存成功长“嘀”、价格揭晓“叮咚”。
reg phase_q;
always @(posedge sd_card_clk or negedge ctrl_rst_n) begin
    if (!ctrl_rst_n) phase_q <= 1'b0;
    else phase_q <= show_phase_ctrl;
end
media_buzzer #(.CLK_HZ(CTRL_CLK_FREQ_HZ), .TONE_HZ(2700)) u_buzzer (
    .clk(sd_card_clk), .rst(!ctrl_rst_n),
    .ev_click(show_phase_ctrl != phase_q),
    .ev_double(1'b0),
    .ev_triple(1'b0),
    .ev_long(config_save_done),
    .ev_reveal(reveal_event_ctrl),
    .buzzer_n(buzzer)
);

// ===================== TF 多图扫描与缓存（双缓冲） =====================
wire [4:0] diag_sd_state;
wire [2:0] diag_recovery_state, diag_found_count;
wire diag_sd_init_done, diag_catalog_ready;
wire [4:0] diag_image_complete;
wire [2:0] diag_boot_error_stage, diag_boot_error_code;
wire [5:0] diag_err_cmd;
wire [7:0] diag_err_resp, diag_boot_retries;
wire [19:0] diag_fs;
wire [2:0] seg_file_idx;
// 讲稿装载（控制域）↔ 讲稿写入（存储域）
wire        script_fifo_we, script_page_toggle, script_page_top_down, script_page_done;
wire [31:0] script_fifo_di;
wire [8:0]  script_fifo_wrusedw;
wire [5:0]  script_page_slot;
wire        script_load_done_ctrl, script_loading_raw_ctrl;
wire [5:0]  script_pages_loaded_ctrl, script_pages_failed_ctrl, script_slots_ctrl;
wire [29:0] script_section_first_ctrl;
wire [24:0] script_section_pages_ctrl;
wire [29:0] script_section_overview_ctrl;
wire [4:0]  script_overview_valid_ctrl;
sd_card_bmp #(
    .CLK_FREQ_HZ       (CTRL_CLK_FREQ_HZ),
    .SCAN_START_SECTOR (32'd0),
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (USE_FAT32_STORAGE ? 3'd5 : 3'd4),
    .DEBOUNCE_MS       (KEY_DEBOUNCE_MS),
    .LONG_PRESS_MS     (KEY_LONG_PRESS_MS),
    .DOUBLE_CLICK_MS   (KEY_DOUBLE_CLICK_MS),
    .CHORD_WINDOW_MS   (KEY_CHORD_WINDOW_MS),
    .AUTO_PERIOD_MS    (AUTO_PERIOD_MS),
    // 实板冷上电首轮停在 CMD55/ACMD41（诊断 3-4-9-..-1-1），再发 CMD0 即可完成。
    // 单轮 1.5 s（ACMD41 规范上限 1 s），最多重来 4 次，最坏约 7.5 s 后才判定失败。
    .BOOT_INIT_TIMEOUT_MS(1500),
    .BOOT_INIT_RETRIES (4),
    // 32 拍子树复位的 4 次重试实板无效，而按键复位有效；按键复位使 SD 引脚长时间保持 CS 高/DCLK 低，此处模仿。
    .BOOT_RETRY_HOLD_MS(200),
    .ENABLE_WRITE_CANCEL(1),
    .ENABLE_PRELOAD    (ENABLE_PRELOAD_PLAYBACK),
    .ENABLE_RUNTIME_PERIOD(ENABLE_PERIOD_CONFIG),
    .ENABLE_MODE_CONFIG(ENABLE_MODE_CONFIG),
    .ENABLE_PARAMETER_KEYS(ENABLE_PARAMETER_KEYS),
    .ENABLE_VOLUME_ADJUST(ENABLE_PARAMETER_KEYS && ENABLE_VOLUME_CONFIG),
    .KEY_REPEAT_MS     (KEY_REPEAT_MS),
    .USE_FAT32         (USE_FAT32_STORAGE),
    .ANY_SIZE_IMAGES   (ENABLE_ANY_SIZE_IMAGES),
    .ENABLE_THUMBS     (ENABLE_THUMBNAILS),
    .ENABLE_SCRIPTS    (ENABLE_PROMPTER_SCRIPTS),
    .SCRIPT_MAX_PAGES  (SCRIPT_MAX_PAGES),
    .ENABLE_IR         (ENABLE_IR_REMOTE),
    .ENABLE_FX_GATE    (ENABLE_SCREEN_FX)
) sd_card_bmp_m0(
    .ir_events         (ir_events_ctrl[13:0]),
    .script_fifo_we    (script_fifo_we),
    .script_fifo_di    (script_fifo_di),
    .script_fifo_wrusedw(script_fifo_wrusedw),
    .script_page_toggle(script_page_toggle),
    .script_page_slot  (script_page_slot),
    .script_page_top_down(script_page_top_down),
    .script_page_done  (script_page_done),
    .script_load_done  (script_load_done_ctrl),
    .script_loading    (script_loading_raw_ctrl),
    .script_pages_loaded(script_pages_loaded_ctrl),
    .script_slots      (script_slots_ctrl),
    .script_pages_failed(script_pages_failed_ctrl),
    .script_section_first(script_section_first_ctrl),
    .script_section_pages(script_section_pages_ctrl),
    .script_section_overview(script_section_overview_ctrl),
    .script_overview_valid(script_overview_valid_ctrl),
    .clk               (sd_card_clk),
    .rst               (~ctrl_rst_n),
    .storage_ready     (media_storage_ready_ctrl),
    .key_next          (key2),
    .key_auto          (key3),
    .key_thumb         (key4),
    .prompter_mode     (prompter_mode_ctrl),
    .param_mode        (param_mode_ctrl),
    .param_sel         (param_sel_ctrl),
    .prompter_cmd      (prompter_cmd_ctrl),
    .show_phase        (show_phase_ctrl),
    .reveal_event      (reveal_event_ctrl),
    .show_phase_enter  (show_phase_enter_ctrl),
    .prompter_active   (prompter_active_ctrl),
    .blackout          (blackout_ctrl),
    .fx_done           (fx_done_pix),
    .fx_go_cam         (fx_go_cam_ctrl),
    .fx_go_lens        (fx_go_lens_ctrl),
    .thumb_state       (thumb_state_ctrl),
    .seg_img_idx       (seg_img_idx),
    .seg_load_busy     (seg_load_busy),
    .seg_manual_event  (seg_manual_event),
    .bmp_width         (16'd640),
    .bmp_height        (16'd480),
    .display_valid     (display_valid),
    .player_enable     (frame_player_enable_ctrl),
    .cache_slot        (cache_slot_ctrl),
    .cache_slot_manual (cache_slot_manual_ctrl),
    .cache_slot_sheet  (cache_slot_sheet_ctrl),
    .cache_slot_valid  (cache_slot_valid_ctrl),
    .cache_slot_ready  (cache_slot_ready_ctrl),
    .cache_display_valid(frame_display_valid_ctrl),
    .cache_display_slot (frame_display_slot_ctrl),
    .cache_playback_fault(frame_playback_fault_ctrl),
    // 成对寄存的配置在下一控制沿消费；关闭时仍接零、保持原静态周期。
    .period_update     (period_config_update),
    .period_ms         (period_config_ms),
    .period_increase_event(period_increase_event),
    .period_decrease_event(period_decrease_event),
    .save_event        (config_save_event),
    // boot_complete 在恢复已消费后才置位；不能接保存期间会拉低的 service_ready。
    // 不等待四槽完成；模式恢复就绪由 sd_card_bmp 内部继续联合门控。
    .config_events_ready(config_boot_complete),
    .volume_increase_event(volume_increase_event),
    .volume_decrease_event(volume_decrease_event),
    .picture_increase_event(picture_increase_event),
    .picture_decrease_event(picture_decrease_event),
    .parameter_selected_volume(parameter_selected_volume),

    .write_finish_toggle(frame_write_toggle_mem),
    .write_buf_idx     (write_buf_idx),
    .disp_buf_idx      (disp_buf_idx),

    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_cancel_req  (frame_write_cancel_req),
    .write_cancel_ack  (frame_write_cancel_ack),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .write_top_down    (sd_card_write_top_down),
    .SD_nCS            (sd_ncs),
    .SD_DCLK           (sd_dclk),
    .SD_MOSI           (sd_mosi),
    .SD_MISO           (sd_miso),
    .mode_restore_write(mode_restore_write),
    .mode_restore_value(mode_restore_value),
    .mode_boot_config_done(mode_boot_config_done),
    .mode_ready(mode_ready_ctrl),
    .mode_value(mode_value_ctrl),
    .auto_play_active(auto_play_active_ctrl),
    .image_complete(diag_image_complete),
    .boot_error_stage(diag_boot_error_stage),
    .boot_error_code(diag_boot_error_code),
    .diag_sd_state(diag_sd_state),
    .diag_recovery_state(diag_recovery_state),
    .diag_sd_init_done(diag_sd_init_done),
    .diag_catalog_ready(diag_catalog_ready),
    .diag_found_count(diag_found_count),
    .diag_err_cmd(diag_err_cmd),
    .diag_err_resp(diag_err_resp),
    .diag_boot_retries(diag_boot_retries),
    .diag_fs(diag_fs),
    .seg_slot(ENABLE_PRELOAD_PLAYBACK ? frame_display_slot_ctrl : {1'b0, seg_img_idx}),
    .seg_file_idx(seg_file_idx),
    .audio_hold(wav_hold_ctrl),
    .audio_byte_valid(wav_byte_valid),
    .audio_byte(wav_byte),
    .audio_stream_restart(wav_stream_restart),
    .audio_stream_flush(wav_stream_flush),
    .audio_track_active(wav_track_active_ctrl)
);

// 数码管诊断页（全部小数点亮），从左到右：
// 1 TF初始化 0空闲/1 CMD0/2 CMD8/3 CMD55/4 ACMD41/5 CMD16/6就绪  2 恢复状态(0=空闲,4=失败,5=启动中,6=启动重试复位)
// 3 {SDRAM就绪,TF就绪,目录完成,Flash配置完成}
// TF 就绪后：4 找到图片数  5 已预加载槽位掩码
//            6-7 FAT32 扫描错误码(十六进制，00正常/10读扇区错/20无55AA/21不支持的分区或BPB/22缺PIC文件)
//            8 {播放许可,已提交显示,读取端停止,读取端协议错}
// TF 未就绪：4 已用启动重试次数  5-6 最后失败命令号(十六进制)  7-8 该命令的卡响应字节(FF=无响应)
wire [3:0] diag_sd_stage = (diag_sd_state <= 5'd4)  ? diag_sd_state[3:0] :
                           (diag_sd_state == 5'd18) ? 4'd5 :
                           (diag_sd_state == 5'd14) ? 4'he : 4'd6;
wire [19:0] diag_play_digits = {
    {frame_player_enable_ctrl, frame_display_valid_ctrl, frame_reader_stopped_ctrl, frame_reader_error_ctrl},
    diag_fs[15:12], diag_fs[19:16],
    diag_image_complete,
    {1'b0, diag_found_count}
};
wire [19:0] diag_tf_digits = {
    diag_err_resp[3:0], diag_err_resp[7:4],
    diag_err_cmd[3:0], {2'b00, diag_err_cmd[5:4]},
    (diag_boot_retries > 8'd15) ? 4'hf : diag_boot_retries[3:0]
};
wire [31:0] diag_digits = {
    diag_sd_init_done ? diag_play_digits : diag_tf_digits,
    {storage_ready_ctrl, diag_sd_init_done, diag_catalog_ready, config_boot_complete},
    {1'b0, diag_recovery_state},
    diag_sd_stage
};

// 数码管独立面板：与播放器同属 50 MHz 域，只读状态和手动切图请求。
// 可选预加载使用返回控制域的实际提交状态；邮箱/整屏扫描均有延迟。
// 八位物理编号沿用 pin.adc；原第 1～6 位为当前第 3～8 位。
wire [6:0] osd_period_s_ctrl;
seg_panel #(.CLK_FREQ_HZ(CTRL_CLK_FREQ_HZ), .ON_PERCENT(SEG_ON_PERCENT),
    .ENABLE_PARAMETER_HINT(ENABLE_PARAMETER_KEYS),
    .ENABLE_DIAG_PAGE(0), .ENABLE_STAGE(1)) seg_panel_m0(
    .clk               (sd_card_clk),
    .rst               (~ctrl_rst_n),
    .img_idx           (seg_file_idx),
    .display_valid     (ENABLE_PRELOAD_PLAYBACK ? frame_display_valid_ctrl : display_valid),
    .load_busy         (seg_load_busy),
    .manual_pic_event  (seg_manual_event),
    // New mapping reads the single runtime config; legacy/static configurations keep their old display.
    .auto_period_ms    ((ENABLE_PARAMETER_KEYS && ENABLE_PERIOD_CONFIG) ?
                       {16'd0, period_config_ms} : AUTO_PERIOD_MS),
    .parameter_hint_ready (config_boot_complete && mode_ready_ctrl),
    .parameter_selected_volume (parameter_selected_volume),
    .diag_digits       (diag_digits),
    // 与 PRD 页同源：控制域运行参数（Flash 恢复/按键修改后的值），无跨时钟域。
    .volume            (volume_config_value),
    .stage             ({1'b0, show_phase_ctrl}),
    .fault             (diag_boot_error_stage),
    .period_s          (osd_period_s_ctrl),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data)
);

// ===================== 第 8 课四 bank 帧缓存：loader / reader 分离 =====================
// 写：sd_card_bmp 的写握手不变；media_frame_write_port = 像素 CDC + media_frame_loader，
//     第 i 张图固定写 bank i（基址 i*307200），垂直翻转，帧完成等控制器 busy 撤销。
// 读：media_frame_buffer_reader 每个 frame_start 读 cache_slot_pix 指定的 bank，
//     128 字 burst、双时钟异步 FIFO + 预取，像素在 DE 时消费。
// 首张即显示：槽 0 写完即开放播放，其余槽在后台继续写入；media_sdram_arbiter 让写 burst
// 只插在读 burst 空隙里（读优先，reader FIFO 余量足够时才放行写）。
wire [4:0] loader_image_complete;
wire [7:0] loader_memory_error;
wire       loader_pixel_overflow;
wire       loader_burst_hold, loader_burst_request, loader_burst_idle;   // 仲裁器写方（帧 + 讲稿合并后）
wire       frame_burst_hold, frame_burst_request, frame_burst_idle;
wire       script_burst_hold;
// 讲稿读取（提词屏）也走仲裁器写方通道：借用帧读取器空闲窗口读一行，读期间 sread_steal=1，返回数据只交给它。
wire       sread_burst_hold, sread_burst_request, sread_burst_idle, sread_steal, sread_rd_en;
wire [ADDR_BITS-1:0] sread_rd_addr;
wire       frame_rd_en;
wire [ADDR_BITS-1:0] frame_rd_addr;
wire                 frame_wr_en;
wire [ADDR_BITS-1:0] frame_wr_addr;
wire [3:0]           frame_wr_dm;
wire [31:0]          frame_wr_din;
wire       reader_burst_hold, reader_burst_idle;
wire [8:0] reader_fifo_level;
wire [31:0] sdram_write_grants;
media_frame_write_port #(
    .ADDR_WIDTH   (ADDR_BITS),
    .IMAGE_WORDS  (FRAME_PIXELS),
    .FRAME_WIDTH  (640),
    .FRAME_HEIGHT (480),
    .WRITE_V_FLIP (1),
    .ENABLE_THUMBS(ENABLE_THUMBNAILS)
) u_frame_write (
    .write_clk            (sd_card_clk),
    .write_rst_n          (ctrl_rst_n),
    .write_req            (sd_card_write_req),
    .write_req_ack        (sd_card_write_req_ack),
    .write_addr_index     (write_buf_idx),
    .write_top_down       (sd_card_write_top_down),
    .write_en             (sd_card_write_en),
    .write_data           (sd_card_write_data),
    .write_cancel_req     (frame_write_cancel_req),
    .write_cancel_ack     (frame_write_cancel_ack),
    .mem_clk              (ext_mem_clk),
    .mem_rst_n            (mem_rst_n),
    .controller_init_done (Sdr_init_done),
    .controller_busy      (Sdr_busy),
    .refresh_active       (Sdr_init_ref_vld),
    .write_finish         (frame_write_finish),
    .image_complete       (loader_image_complete),
    .memory_error         (loader_memory_error),
    .pixel_overflow       (loader_pixel_overflow),
    .App_wr_en            (frame_wr_en),
    .App_wr_addr          (frame_wr_addr),
    .App_wr_dm            (frame_wr_dm),
    .App_wr_din           (frame_wr_din),
    .burst_hold           (frame_burst_hold),
    .burst_request        (frame_burst_request),
    .burst_idle           (frame_burst_idle)
);

// 讲稿写入：与帧写入口合并成仲裁器的单一写方。帧写入优先（同拍都请求时讲稿让行），任一方 burst 进行中另一方不得发起。
// 实际运行中讲稿只在 4 张图全部写完后才装载，两者不会同时请求。
wire                 script_wr_en, script_burst_request, script_burst_idle, script_underrun;
wire [ADDR_BITS-1:0] script_wr_addr;
wire [31:0]          script_wr_din;
wire [5:0]           script_pages_written;
generate if (ENABLE_PROMPTER_SCRIPTS) begin : g_script_writer
    prompter_script_writer #(
        .ADDR_WIDTH (ADDR_BITS),
        .SCRIPT_BASE(SCRIPT_BASE),
        .CAL_ADDR   (SCRIPT_CAL_ADDR)
    ) u_script_writer (
        .wr_clk(sd_card_clk), .wr_rst_n(ctrl_rst_n),
        .fifo_we(script_fifo_we), .fifo_di(script_fifo_di), .fifo_wrusedw(script_fifo_wrusedw),
        .page_toggle(script_page_toggle), .page_slot(script_page_slot), .page_top_down(script_page_top_down),
        .page_done(script_page_done),
        .mem_clk(ext_mem_clk), .mem_rst_n(mem_rst_n), .controller_busy(Sdr_busy),
        .app_wr_en(script_wr_en), .app_wr_addr(script_wr_addr), .app_wr_data(script_wr_din),
        .burst_hold(script_burst_hold), .burst_request(script_burst_request), .burst_idle(script_burst_idle),
        .pages_written(script_pages_written), .underrun(script_underrun)
    );
end else begin : g_no_script_writer
    assign script_fifo_wrusedw = 9'd0;
    assign script_page_done = 1'b0;
    assign script_wr_en = 1'b0;
    assign script_wr_addr = {ADDR_BITS{1'b0}};
    assign script_wr_din = 32'd0;
    assign script_burst_request = 1'b0;
    assign script_burst_idle = 1'b1;
    assign script_pages_written = 6'd0;
    assign script_underrun = 1'b0;
end endgenerate
// 写方三路合并：讲稿读取优先（实时显示），其次帧写入，最后讲稿写入；任一路 burst 进行中其余各路不得发起。
assign sread_burst_hold  = loader_burst_hold || !frame_burst_idle || !script_burst_idle;
assign frame_burst_hold  = loader_burst_hold || !script_burst_idle || sread_burst_request || !sread_burst_idle;
assign script_burst_hold = loader_burst_hold || frame_burst_request || !frame_burst_idle || sread_burst_request || !sread_burst_idle;
assign loader_burst_request = frame_burst_request || script_burst_request || sread_burst_request;
assign loader_burst_idle    = frame_burst_idle && script_burst_idle && sread_burst_idle;
assign App_rd_en   = frame_rd_en || sread_rd_en;
assign App_rd_addr = sread_rd_en ? sread_rd_addr : frame_rd_addr;
assign App_wr_en   = frame_wr_en || script_wr_en;
assign App_wr_addr = script_wr_en ? script_wr_addr : frame_wr_addr;
assign App_wr_din  = script_wr_en ? script_wr_din : frame_wr_din;
assign App_wr_dm   = script_wr_en ? 4'b0000 : frame_wr_dm;
// synthesis translate_off
always @(posedge ext_mem_clk) if (mem_rst_n && frame_wr_en && script_wr_en) begin
    $display("FATAL: %m frame and script SDRAM writes overlap");
    $finish;
end
always @(posedge ext_mem_clk) if (mem_rst_n && frame_rd_en && (sread_rd_en || sread_steal)) begin
    $display("FATAL: %m frame read issued while the script reader owns the read port");
    $finish;
end
// synthesis translate_on

// 第 13/15 课缩略图焦点、已完成槽与目录图片数整笔跨域：控制域值变化且邮箱空闲时发出最新值，像素域在 dst_update 时更新。
// 第 15 课起总览页标志随槽号走 u_slot_cdc（由转场决定哪一帧切换），此处不再传模式位。
wire [10:0] thumb_state_pix;
generate if (ENABLE_THUMBNAILS) begin : g_thumb_cdc
    reg  [10:0] thumb_sent_ctrl;
    wire        thumb_cdc_ready, thumb_cdc_update;
    wire [10:0] thumb_cdc_slot;
    reg  [10:0] thumb_state_pix_r;
    wire       thumb_cdc_valid = thumb_state_ctrl != thumb_sent_ctrl;
    always @(posedge sd_card_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n) thumb_sent_ctrl <= 11'd0;
        else if (thumb_cdc_valid && thumb_cdc_ready) thumb_sent_ctrl <= thumb_state_ctrl;
    end
    media_slot_cdc #(.SLOT_W(11)) u_thumb_cdc (
        .src_clk(sd_card_clk), .dst_clk(video_clk), .rst(rst_all),
        .src_slot(thumb_state_ctrl), .src_valid(thumb_cdc_valid), .src_ready(thumb_cdc_ready),
        .dst_slot(thumb_cdc_slot), .dst_update(thumb_cdc_update)
    );
    always @(posedge video_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) thumb_state_pix_r <= 11'd0;
        else if (thumb_cdc_update) thumb_state_pix_r <= thumb_cdc_slot;
    end
    assign thumb_state_pix = thumb_state_pix_r;
end else begin : g_no_thumb_cdc
    assign thumb_state_pix = 11'd0;
end endgenerate

// 视频时序：有效区在每行/每帧末尾，HS 拉低后第 144 拍起为有效像素，与 HDMI 符号核一致
wire raw_hs, raw_vs, raw_de;
wire [11:0] raw_x, raw_y;
reg  raw_vs_q;
wire frame_start;
video_timing_ctrl #(
    .H_ACT(640), .H_FP(16), .H_SYNC(96), .H_BP(48),
    .V_ACT(480), .V_FP(10), .V_SYNC(2),  .V_BP(33),
    .ACTIVE_LAST(1)
) u_video_timing (
    .pclk(video_clk), .rst_n(pix_rst_n),
    .hsync(raw_hs), .vsync(raw_vs), .de(raw_de), .x(raw_x), .y(raw_y)
);
always @(posedge video_clk or negedge pix_rst_n) begin
    if (!pix_rst_n) raw_vs_q <= 1'b1;
    else            raw_vs_q <= raw_vs;
end
assign frame_start = raw_vs_q && !raw_vs;

wire frame_player_enable_mem;
wire [23:0] reader_pixel_rgb;
wire        reader_pixel_valid, reader_underflow, reader_busy, reader_frame_done;
wire [2:0]  reader_bank_mem;
wire [7:0]  reader_error_mem;
reg         frame_playing_pix;   // 播放许可打开后、首个帧提交起为 1
reg         reader_error_any_mem;
wire        reader_error_pix;
wire        playback_fault_pix = frame_reader_error || frame_reader_stopped;
wire        reader_frame_start = frame_start && frame_player_enable_pix && !playback_fault_pix;
// 第 10 课转场：像素域拦截目标槽，决定本帧 reader 读哪个/哪两个 bank，并对图片层做 alpha 衰减。
wire [2:0]  trans_read_index, trans_alt_index;
wire        trans_read_sheet;   // 本帧读总览页 bank，与 trans_read_index 同拍切换
wire [ADDR_BITS:0] trans_split_words;
wire [23:0] picture_rgb;
wire        trans_fading;
wire        trans_active;
wire        trans_slide, trans_slide_left;   // D22 左右滑动
wire [9:0]  trans_slide_cols;
// D30 特效：控制器输出（帧消隐内更新）与 reader 采样同拍锁存的本帧抖动量
wire signed [4:0] fx_dx, fx_dy;
wire [7:0]  fx_flash_w, fx_box_w;
wire [6:0]  fx_glow_r;
wire        fx_charge_on;
wire [9:0]  fx_fill_x;
reg  signed [4:0] fx_dx_f, fx_dy_f;
// D32 行重映射：时间轴给出的本帧参数（reader 与 media_fx_engine 同拍锁存）
wire [2:0]  fx_mode, fx_a_bank;
wire        fx_clamp, fx_band_en, fx_spin_back;
wire [8:0]  fx_win_lo, fx_win_hi;
wire signed [19:0] fx_a_acc0, fx_ax0;
wire [9:0]  fx_a_step;
wire [7:0]  fx_alpha;
wire        fx_hide;
wire        fx_rm_en = ENABLE_SCREEN_FX && fx_mode != 3'd0;
wire        fx_rm_band = (fx_mode == 3'd3) ? fx_spin_back : fx_band_en;
// D32 推进镜头转场门：控制域翻转位 <-> 像素域
wire        fx_go_cam_ctrl, fx_go_lens_ctrl;
wire        fx_done_pix;
// 抖动只在普通显示帧生效：水平借用滑动两段（都读当前槽，段长 = dx 或 640+dx），竖直走 reader 的行偏移

generate if (ENABLE_PRELOAD_PLAYBACK) begin : g_preload_playback
// 多位槽号经保持/确认邮箱跨域；统一复位源与业务复位相同，内部两域同步释放。
// 总览页标志、转场类型（手动/轮播）与槽号整笔同一握手；reader 在 frame_start 后一拍锁存，切换只在帧边界生效。
media_slot_cdc #(.SLOT_W(5)) u_slot_cdc (
    .src_clk(sd_card_clk), .dst_clk(video_clk), .rst(rst_all),
    .src_slot({cache_slot_sheet_ctrl, cache_slot_manual_ctrl, cache_slot_ctrl}), .src_valid(cache_slot_valid_ctrl),
    .src_ready(cache_slot_ready_ctrl), .dst_slot({cache_slot_sheet_pix, cache_slot_manual_pix, cache_slot_pix}),
    .dst_update(cache_slot_update_pix)
);
// 手动换图：左右滑动推入（D22，下一张向左、上一张向右，32 帧）；进出总览页：淡出到黑 -> 换槽 -> 淡入；
// 轮播：前 split 字读新槽、其余读旧槽，逐帧下移（从上到下 Wipe）。
video_transition_ctrl #(
    .FADE_FRAMES  (TRANSITION_FRAMES),
    .IMAGE_WORDS  (FRAME_PIXELS),
    .FRAME_HEIGHT (480),
    .BURST_SIZE   (128),
    .ADDR_WIDTH   (ADDR_BITS),
    .ENABLE_SLIDE (1),
    .FRAME_WIDTH  (640),
    .SLIDE_FRAMES (32)
) u_transition (
    .clk          (video_clk),
    .rst_n        (pix_rst_n),
    .frame_tick   (reader_frame_start),
    .playing      (frame_playing_pix),
    .target_slot  (cache_slot_pix),
    .target_sheet (cache_slot_sheet_pix),
    .target_manual(cache_slot_manual_pix),
    // 像素 alpha 乘法已并入第 14 课 brightness_contrast_adjust，本模块只提供 alpha/fading。
    .rgb_in       (24'd0),
    .read_index   (trans_read_index),
    .read_sheet   (trans_read_sheet),
    .alt_index    (trans_alt_index),
    .split_words  (trans_split_words),
    .alpha        (trans_alpha),
    .audio_alpha  (trans_audio_alpha),
    .active       (trans_active),
    .wipe_active  (),
    .fading       (trans_fading),
    .slide_active (trans_slide),
    .slide_left   (trans_slide_left),
    .slide_cols   (trans_slide_cols),
    .rgb_out      ()
);
// 播放许可为控制域保持电平，分别同步到像素域与存储域。
sync_2ff u_player_enable_sync (
    .clk(video_clk), .rst_n(pix_rst_n),
    .async_in(frame_player_enable_ctrl), .sync_out(frame_player_enable_pix)
);
sync_2ff u_player_enable_mem_sync (
    .clk(ext_mem_clk), .rst_n(mem_rst_n),
    .async_in(frame_player_enable_ctrl), .sync_out(frame_player_enable_mem)
);
media_frame_buffer_reader #(
    .ADDR_WIDTH         (ADDR_BITS),
    .IMAGE_WORDS        (FRAME_PIXELS),
    .FIFO_DEPTH         (512),
    .FIFO_MARGIN        (16),
    .BURST_SIZE         (128),
    .BURST_GAP_CYCLES   (12),
    .MAX_INFLIGHT_BURSTS(2),
    .RGB_IN_MSB         (1),
    .ENABLE_SPLIT       (1),
    .ENABLE_SHEET       (ENABLE_THUMBNAILS),
    .ENABLE_SLIDE       (1),
    .FRAME_WIDTH        (640),
    .ENABLE_SHAKE       (0),
    .FRAME_HEIGHT       (480),
    .ENABLE_REMAP       (ENABLE_SCREEN_FX)
) u_reader (
    .mem_clk             (ext_mem_clk),
    .mem_rst_n           (mem_rst_n),
    .controller_init_done(Sdr_init_done && frame_player_enable_mem),
    .controller_busy     (Sdr_busy),
    .refresh_active      (Sdr_init_ref_vld),
    .app_rd_en           (frame_rd_en),
    .app_rd_addr         (frame_rd_addr),
    .burst_hold          (reader_burst_hold),
    .burst_idle          (reader_burst_idle),
    .fifo_level          (reader_fifo_level),
    .sdram_rd_valid      (Sdr_rd_en && !sread_steal),
    .sdram_rd_data       (Sdr_rd_dout),
    .pix_clk             (video_clk),
    .pix_rst_n           (pix_rst_n),
    .frame_start         (reader_frame_start),
    .active_index        (trans_read_index),
    .alt_index           (trans_alt_index),
    .split_words         (trans_split_words),
    .active_sheet        (trans_read_sheet),
    .slide_en            (trans_slide),
    .slide_left          (trans_slide_left),
    .slide_cols          (trans_slide_cols),
    .shake_dy            (5'sd0),
    .rm_en               (fx_rm_en),
    .rm_band_en          (fx_rm_band),
    .rm_win_lo           (fx_win_lo),
    .rm_win_hi           (fx_win_hi),
    .rm_a_bank           (fx_a_bank),
    .rm_a_acc0           (fx_a_acc0),
    .rm_a_step           (fx_a_step),

    .pixel_consume       (raw_de && frame_playing_pix),
    .pixel_rgb           (reader_pixel_rgb),
    .pixel_valid         (reader_pixel_valid),
    .underflow           (reader_underflow),
    .reader_busy         (reader_busy),
    .frame_read_done     (reader_frame_done),
    .reader_index        (reader_bank_mem),
    .reader_error        (reader_error_mem)
);
media_sdram_arbiter #(
    .FIFO_LEVEL_W (9),
    .READ_RESERVE (256),
    .QUIET_CYCLES (4)
) u_sdram_arbiter (
    .clk          (ext_mem_clk),
    .rst_n        (mem_rst_n),
    .wr_request   (loader_burst_request),
    .wr_idle      (loader_burst_idle),
    .rd_busy      (reader_busy),
    .rd_idle      (reader_burst_idle),
    .rd_level     (reader_fifo_level),
    .wr_hold      (loader_burst_hold),
    .rd_hold      (reader_burst_hold),
    .write_grants (sdram_write_grants)
);
// reader_error 为存储域寄存器，先在本域归并成单比特再两拍同步到像素域。
always @(posedge ext_mem_clk or negedge mem_rst_n) begin
    if (!mem_rst_n) reader_error_any_mem <= 1'b0;
    else            reader_error_any_mem <= (reader_error_mem != 8'd0);
end
sync_2ff u_reader_error_pix_sync (
    .clk(video_clk), .rst_n(pix_rst_n),
    .async_in(reader_error_any_mem), .sync_out(reader_error_pix)
);
// 帧提交：frame_start 后一拍与 reader 同拍锁存本帧槽号，再下一拍发出提交脉冲（此时槽号已稳定）；
// 许可撤销或读故障锁停至复位。
reg frame_start_q, frame_commit_q;
reg [2:0] frame_slot_q;
reg frame_stopped_q, frame_error_q, frame_enabled_seen;
always @(posedge video_clk or negedge pix_rst_n) begin
    if (!pix_rst_n) begin
        frame_start_q <= 1'b0;
        frame_commit_q <= 1'b0;
        frame_slot_q <= 3'd0;
        qr_show_q <= 1'b0;
        thumb_sheet_q <= 1'b0;
        thumb_focus_q <= 3'd0;
        thumb_complete_q <= 5'd0;
        thumb_expected_q <= 5'd0;
        frame_playing_pix <= 1'b0;
        frame_stopped_q <= 1'b0;
        frame_error_q <= 1'b0;
        frame_enabled_seen <= 1'b0;
    end else begin
        frame_start_q <= reader_frame_start;
        frame_commit_q <= frame_start_q;
        // 与 reader 同拍取转场后的读槽：OSD/音频/数码管/轮播计时都跟随实际显示的图。
        if (frame_start_q) begin
            frame_slot_q <= trans_read_index;
            qr_show_q <= trans_read_index == 3'd4 && !trans_read_sheet && !trans_active;
            thumb_sheet_q <= ENABLE_THUMBNAILS && trans_read_sheet;
            thumb_focus_q <= thumb_state_pix[7:5];
            thumb_complete_q <= thumb_state_pix[4:0];
            thumb_expected_q <= {thumb_state_pix[10:8] >= 3'd5, thumb_state_pix[10:8] >= 3'd4, thumb_state_pix[10:8] >= 3'd3,
                                 thumb_state_pix[10:8] >= 3'd2, thumb_state_pix[10:8] >= 3'd1};
        end
        if (frame_commit_q)
            frame_playing_pix <= 1'b1;
        if (frame_player_enable_pix) frame_enabled_seen <= 1'b1;
        if (reader_underflow || reader_error_pix) begin
            frame_error_q <= 1'b1;
            frame_stopped_q <= 1'b1;
        end
        if (frame_enabled_seen && !frame_player_enable_pix) frame_stopped_q <= 1'b1;
        if (playback_fault_pix || !frame_player_enable_pix) frame_playing_pix <= 1'b0;
    end
end
assign frame_read_index = frame_slot_q;
assign frame_started = frame_commit_q && frame_player_enable_pix && !playback_fault_pix;
assign frame_reader_stopped = frame_stopped_q;
assign frame_reader_error = frame_error_q;
assign frame_video_enable = (frame_playing_pix || frame_commit_q) && frame_player_enable_pix && !playback_fault_pix;
// reader 故障保持至共同复位，分别同步后合并；返回控制域存在两级采样延迟。
sync_2ff u_reader_stopped_sync (
    .clk(sd_card_clk), .rst_n(ctrl_rst_n),
    .async_in(frame_reader_stopped), .sync_out(frame_reader_stopped_ctrl)
);
sync_2ff u_reader_error_sync (
    .clk(sd_card_clk), .rst_n(ctrl_rst_n),
    .async_in(frame_reader_error), .sync_out(frame_reader_error_ctrl)
);
assign frame_playback_fault_ctrl = frame_reader_stopped_ctrl || frame_reader_error_ctrl;
// 实际帧提交反馈；音频与数码管使用。
media_display_state u_display_state (
    .pix_clk(video_clk), .pix_rst_n(pix_rst_n),
    .playback_ok_pix(frame_player_enable_pix && !frame_reader_stopped && !frame_reader_error),
    .frame_started(frame_started), .frame_slot_pix(frame_read_index),
    .display_valid_pix(frame_display_valid_pix), .display_slot_pix(frame_display_slot_pix)
);
audio_media_cdc #(.ID_W(3)) u_display_feedback_cdc (
    .src_clk(video_clk), .dst_clk(sd_card_clk), .rst(rst_all),
    .src_media_id(frame_display_slot_pix), .src_media_valid(frame_display_valid_pix),
    .dst_media_id(frame_display_slot_ctrl), .dst_media_valid(frame_display_valid_ctrl),
    .dst_update(frame_display_update_ctrl)
);
end endgenerate
// synthesis translate_off
initial begin
    if (ENABLE_PRELOAD_PLAYBACK != 1 || FRAME_PIXELS != 307200) begin
        $display("MEDIA_CONFIG_ERROR top %m: four-bank frame buffer requires preload playback and 640x480");
        $finish;
    end
end
// synthesis translate_on

// ===================== 第 9 课状态 OSD：左上角 [槽号1-4][A/E][错误码两位] =====================
// 自动轮播单比特电平两拍同步；启动首因（控制域、锁存后静止）逐位两拍同步后连续两拍相同才更新。
wire auto_play_active_pix;
sync_2ff u_osd_auto_sync (
    .clk(video_clk), .rst_n(pix_rst_n),
    .async_in(auto_play_active_ctrl), .sync_out(auto_play_active_pix)
);
(* ASYNC_REG="TRUE" *) reg [5:0] osd_boot_err_s1, osd_boot_err_s2;
reg [5:0] osd_boot_err_s3, osd_boot_err_pix;
// frame_slot_q 在 frame_start 后一拍才更新，OSD 的帧锁存沿延后两拍才能取到本帧槽号。
reg [1:0] osd_vs_dly;
always @(posedge video_clk or negedge pix_rst_n) begin
    if (!pix_rst_n) begin
        osd_boot_err_s1 <= 6'd0;
        osd_boot_err_s2 <= 6'd0;
        osd_boot_err_s3 <= 6'd0;
        osd_boot_err_pix <= 6'd0;
        osd_vs_dly <= 2'b11;
    end else begin
        osd_boot_err_s1 <= {diag_boot_error_stage, diag_boot_error_code};
        osd_boot_err_s2 <= osd_boot_err_s1;
        osd_boot_err_s3 <= osd_boot_err_s2;
        if (osd_boot_err_s2 == osd_boot_err_s3)
            osd_boot_err_pix <= osd_boot_err_s3;
        osd_vs_dly <= {osd_vs_dly[0], raw_vs};
    end
end
// 启动首因优先显示 stage/code；否则 F1=读故障、F2=播放停止；正常 00（黄），非零变红。
wire [7:0] osd_error_code =
    (osd_boot_err_pix[5:3] != 3'd0) ? {1'b0, osd_boot_err_pix[5:3], 1'b0, osd_boot_err_pix[2:0]} :
    frame_reader_error   ? 8'hf1 :
    frame_reader_stopped ? 8'hf2 : 8'h00;
// 参数行周期：数码管面板换算出的秒值（与 PRD 页同一结果，两位显示，上限 99，控制域寄存器输出），
// 按启动首因同样方式跨域；音量直接用音频链已跨域的 volume_value_pix。
(* ASYNC_REG="TRUE" *) reg [6:0] osd_period_s1, osd_period_s2;
reg [6:0] osd_period_s3, osd_period_s_pix;
always @(posedge video_clk or negedge pix_rst_n) begin
    if (!pix_rst_n) begin
        osd_period_s1 <= 7'd0;
        osd_period_s2 <= 7'd0;
        osd_period_s3 <= 7'd0;
        osd_period_s_pix <= 7'd0;
    end else begin
        osd_period_s1 <= osd_period_s_ctrl;
        osd_period_s2 <= osd_period_s1;
        osd_period_s3 <= osd_period_s2;
        if (osd_period_s2 == osd_period_s3)
            osd_period_s_pix <= osd_period_s3;
    end
end
// 第 14 课：亮度、对比度与第 10 课淡入淡出合并为每通道一次乘法（同拍组合，不改 hs/vs/de 对齐）。
// D21 一键黑场：KEY2+KEY3 同按（控制域电平）两级同步到像素域，图片层与音乐一起淡出 / 淡入（D24：并入下面的 alpha，
// 不再逐像素相乘）；黑场进行中（level != 16）字幕、二维码、波形隐藏，整个观众屏为黑。
wire        blackout_pix, blackout_on;
wire [4:0]  blackout_level;
wire [7:0]  pic_alpha;
sync_2ff u_blackout_sync (.clk(video_clk), .rst_n(pix_rst_n), .async_in(blackout_ctrl), .sync_out(blackout_pix));
media_blackout #(.STEP_FRAMES(2)) u_blackout (
    .clk(video_clk), .rst_n(pix_rst_n), .frame_start(frame_start), .black(blackout_pix),
    .alpha_in(trans_fading ? trans_alpha : fx_alpha), .alpha_out(pic_alpha),
    .gain_in(audio_gain_fade), .gain_out(audio_gain_blk), .active(blackout_on), .level(blackout_level)
);
// D30 观众屏特效：fx_fs_q 与 reader 采样同拍（frame_start 后一拍）取本帧状态与抖动量，下一拍（仍在场消隐）推进时间轴。
// 进入判定：卡上正好 5 张图（演示素材，与价格揭晓同一条件）、普通显示帧（非转场 / 总览页）、黑场目标为关；
// 黑场淡入到 12/16 之前抖动原地等待。
// D32：reader -> media_fx_engine（行重映射 / 素材区遮罩）-> 亮度对比度与淡变 -> media_fx_pixel（光晕 / 白场 / 充电）。
wire [23:0] fx_rgb, fx_eng_rgb;
wire [23:0] adjusted_rgb;
generate if (ENABLE_SCREEN_FX) begin : g_screen_fx
    reg       fx_fs_q, fx_tick, fx_ok_q;
    reg [2:0] fx_slot_q;
    always @(posedge video_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            fx_fs_q <= 1'b0; fx_tick <= 1'b0; fx_ok_q <= 1'b0; fx_slot_q <= 3'd0;
            fx_dx_f <= 5'sd0; fx_dy_f <= 5'sd0;
        end else begin
            fx_fs_q <= reader_frame_start;
            fx_tick <= fx_fs_q;
            if (fx_fs_q) begin
                fx_ok_q <= thumb_state_pix[10:8] == 3'd5 && !trans_read_sheet && !trans_active && !blackout_pix;   // 只用于 5 张图的演示卡
                fx_slot_q <= trans_read_index;
                // 与 reader 同拍锁存的本帧抖动量（二维码随画面平移）
                fx_dx_f <= (fx_mode == 3'd1 && fx_clamp) ? fx_dx : 5'sd0;
                fx_dy_f <= (fx_mode == 3'd1 && fx_clamp) ? fx_dy : 5'sd0;
            end
        end
    end
    // 控制域翻转位两级同步，变化即单拍请求
    wire go_cam_s, go_lens_s;
    reg  go_cam_q, go_lens_q;
    sync_2ff u_go_cam_sync (.clk(video_clk), .rst_n(pix_rst_n), .async_in(fx_go_cam_ctrl), .sync_out(go_cam_s));
    sync_2ff u_go_lens_sync (.clk(video_clk), .rst_n(pix_rst_n), .async_in(fx_go_lens_ctrl), .sync_out(go_lens_s));
    always @(posedge video_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin go_cam_q <= 1'b0; go_lens_q <= 1'b0; end
        else begin go_cam_q <= go_cam_s; go_lens_q <= go_lens_s; end
    end
    wire [19:0] e_r2;
    wire        e_circ_on, e_circ_iris, e_glint_on;
    wire [6:0]  e_spin_k;
    wire [3:0]  e_light;
    wire signed [10:0] e_glint;
    media_fx_ctrl u_fx_ctrl (
        .clk(video_clk), .rst_n(pix_rst_n), .frame_tick(fx_tick),
        .ok(fx_ok_q && frame_video_enable), .slot(fx_slot_q), .shake_hold(blackout_level < 5'd12),
        .go_cam(go_cam_s != go_cam_q), .go_lens(go_lens_s != go_lens_q), .done_tgl(fx_done_pix),
        .mode(fx_mode), .clamp_oor(fx_clamp), .band_en(fx_band_en), .win_lo(fx_win_lo), .win_hi(fx_win_hi),
        .a_bank(fx_a_bank), .a_acc0(fx_a_acc0), .ax0(fx_ax0), .a_step(fx_a_step),
        .circ_on(e_circ_on), .circ_iris(e_circ_iris), .circ_r2(e_r2), .spin_k(e_spin_k),
        .light(e_light), .glint_on(e_glint_on), .glint(e_glint), .alpha(fx_alpha), .hide(fx_hide),
        .shake_dx(fx_dx), .shake_dy(fx_dy), .flash_w(fx_flash_w), .glow_r(fx_glow_r),
        .charge_on(fx_charge_on), .fill_x(fx_fill_x), .box_w(fx_box_w), .click(fx_click)
    );
    media_fx_engine u_fx_engine (
        .clk(video_clk), .rst_n(pix_rst_n),
        .x(raw_x - 12'd160), .y(raw_y - 12'd45), .de(raw_de), .rgb_in(reader_pixel_rgb), .latch(fx_fs_q),
        .mode(fx_mode), .clamp_oor(fx_clamp), .win_lo(fx_win_lo), .win_hi(fx_win_hi), .band_en(fx_rm_band),
        .a_acc0(fx_a_acc0), .ax0(fx_ax0), .a_step(fx_a_step),
        .circ_on(e_circ_on), .circ_iris(e_circ_iris), .circ_r2(e_r2), .spin_k(e_spin_k), .spin_back(fx_spin_back),
        .light(e_light), .glint_on(e_glint_on), .glint(e_glint),
        .f_index(trans_read_index), .f_alt(trans_alt_index), .f_sheet(trans_read_sheet), .f_slide(trans_slide),
        .f_slide_left(trans_slide_left), .f_slide_cols(trans_slide_cols), .f_split(trans_split_words[18:0]),
        .hide_win(trans_active && trans_read_index == 3'd1 && !trans_read_sheet), .demo(thumb_state_pix[10:8] == 3'd5),
        .rgb_out(fx_eng_rgb)
    );
    media_fx_pixel #(.GX(252), .GY(125)) u_fx_pixel (
        .clk(video_clk), .rst_n(pix_rst_n),
        .x(raw_x - 12'd160), .y(raw_y - 12'd45), .de(raw_de),
        .key_rgb(reader_pixel_rgb), .rgb_in(adjusted_rgb), .shake_dx(5'sd0),
        .flash_w(fx_flash_w), .glow_r(fx_glow_r), .charge_on(fx_charge_on), .fill_x(fx_fill_x), .box_w(fx_box_w),
        .rgb_out(fx_rgb)
    );
    wire        click_active;
    wire signed [15:0] click_sample;
    media_shutter_click u_shutter_click (
        .clk(video_clk), .rst(audio_rst), .start(fx_click),
        .fire(source_valid && source_ready), .active(click_active), .sample(click_sample)
    );
    // 快门声期间音乐降到 1/4（-12 dB）再叠加（快门声上限 3/4 满幅，和不溢出）
    assign mix_left  = click_active ? (source_left  >>> 2) + click_sample : source_left;
    assign mix_right = click_active ? (source_right >>> 2) + click_sample : source_right;
end else begin : g_no_screen_fx
    assign fx_dx = 5'sd0; assign fx_dy = 5'sd0;
    assign fx_flash_w = 8'd0; assign fx_glow_r = 7'd0; assign fx_charge_on = 1'b0;
    assign fx_fill_x = 10'd0; assign fx_box_w = 8'd0; assign fx_click = 1'b0;
    assign fx_mode = 3'd0; assign fx_clamp = 1'b0; assign fx_band_en = 1'b0; assign fx_spin_back = 1'b0;
    assign fx_win_lo = 9'd0; assign fx_win_hi = 9'd479; assign fx_a_bank = 3'd0;
    assign fx_a_acc0 = 20'sd0; assign fx_ax0 = 20'sd0; assign fx_a_step = 10'd256;
    assign fx_alpha = 8'd255; assign fx_hide = 1'b0; assign fx_done_pix = 1'b0;
    assign fx_eng_rgb = reader_pixel_rgb;
    assign fx_rgb = adjusted_rgb;
    assign mix_left = source_left;
    assign mix_right = source_right;
    always @(posedge video_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin fx_dx_f <= 5'sd0; fx_dy_f <= 5'sd0; end
    end
end endgenerate
// 麦克风闪避：系数 255 时原样透传（不说话时音频与原来逐位相同），否则按 /256 比例缩小
generate if (ENABLE_MIC_DUCK) begin : g_mic_duck
    mic_voice_duck u_mic_duck (
        .clk(video_clk), .rst_n(pix_rst_n),
        .mic_sck(mic_sck), .mic_ws(mic_ws), .mic_sd(mic_sd),
        .talking(mic_talking), .speaking(mic_speaking), .present(mic_present),
        .env_log(mic_env_log), .thr_log(mic_thr_log), .duck_gain(mic_duck_gain)
    );
end else begin : g_no_mic_duck
    assign mic_sck = 1'b0;
    assign mic_ws = 1'b0;
    assign mic_talking = 1'b0;
    assign mic_speaking = 1'b0;
    assign mic_present = 1'b0;
    assign mic_env_log = 5'd0;
    assign mic_thr_log = 5'd0;
    assign mic_duck_gain = 8'd255;
end endgenerate
// synthesis translate_off
pulldown u_mic_sd_pulldown (mic_sd);   // 与 pin.adc 的内部下拉一致：测试台不接麦克风时 SD 读 0
// synthesis translate_on
wire [15:0] audio_duck_product = audio_gain_blk * mic_duck_gain;
assign audio_gain_pix = (mic_duck_gain == 8'd255) ? audio_gain_blk : audio_duck_product[15:8];
wire        pic_fading = trans_fading || blackout_on || fx_alpha != 8'd255;
// B/C 在 frame_start 锁存，alpha/fading 只在 frame_tick 变化，系数在场消隐内稳定；总览页帧同样调 B/C 并参与淡变。
brightness_contrast_adjust u_picture_adjust_pix (
    .clk        (video_clk),
    .rst_n      (pix_rst_n),
    .frame_start(frame_start),
    .brightness (picture_brightness_pix),
    .contrast   (picture_contrast_pix),
    .alpha      (pic_alpha),
    .fading     (pic_fading),
    .rgb_in     (fx_eng_rgb),
    .rgb_out    (adjusted_rgb)
);
assign picture_rgb = (frame_video_enable && reader_pixel_valid) ? fx_rgb : 24'd0;
// 第 13/15 课总览页：本帧读的是总览页 bank 时，图片层改为 3×2 布局（D19），居中于 (80,120)..(559,359)；格外黑色，
// 已加载格为缩略图（调亮度/对比度、随转场淡变），焦点格 2 像素黄框；未加载格深灰底 + 每 32 帧闪烁的灰框（加载中）。
// 淡变帧只保留格内图片（已乘 alpha），黄框与占位隐藏。总览页隐藏文字层与状态 OSD；波形在底部照常显示。
localparam [11:0] SHEET_X0 = 12'd80, SHEET_Y0 = 12'd120;
wire [11:0] thumb_pixel_x = raw_x - 12'd160 - SHEET_X0;   // ACTIVE_LAST：有效像素 raw_x 160..799；格外为回绕大值
wire [11:0] thumb_pixel_y = raw_y - 12'd45 - SHEET_Y0;    // ACTIVE_LAST：有效行 raw_y 45..524
wire thumb_de, thumb_focus_border, thumb_pending, thumb_cell_edge;
wire [2:0] thumb_quad;
reg  [4:0] thumb_blink_cnt;
always @(posedge video_clk or negedge pix_rst_n) begin
    if (!pix_rst_n) thumb_blink_cnt <= 5'd0;
    else if (frame_start) thumb_blink_cnt <= thumb_blink_cnt + 5'd1;
end
thumbnail_layout #(.DISPLAY_WIDTH(640), .DISPLAY_HEIGHT(480), .THUMB_WIDTH(160), .THUMB_HEIGHT(120))
    u_thumb_layout (
    .in_de        (raw_de),
    .pixel_x      (thumb_pixel_x),
    .pixel_y      (thumb_pixel_y),
    .focus_index  (thumb_focus_q),
    .image_complete(thumb_complete_q),
    .thumb_de     (thumb_de),
    .source_index (thumb_quad),
    .source_x     (),
    .source_y     (),
    .focus_border (thumb_focus_border),
    .pending_de   (thumb_pending),
    .cell_edge    (thumb_cell_edge)
);
wire thumb_frame = ENABLE_THUMBNAILS && thumb_sheet_q;
wire [23:0] sheet_rgb = thumb_de ? ((thumb_focus_border && !pic_fading) ? THUMB_BORDER_RGB : picture_rgb) :
                        (thumb_pending && !pic_fading && thumb_quad <= 3'd4 && thumb_expected_q[thumb_quad]) ? ((thumb_cell_edge && thumb_blink_cnt[4]) ? THUMB_PENDING_EDGE_RGB : THUMB_PENDING_RGB) :
                        24'd0;
// D21 二维码（qr_rom，脚本由网址生成）：第 5 张图显示且转场结束后，右下 (500,248) 起 132x132 白底黑码，不随亮度/对比度变化。
wire qr_hit, qr_dark;
qr_overlay #(.X0(500), .Y0(248), .SCALE(4)) u_qr_overlay (
    .enable(qr_show_q && !thumb_frame && !blackout_on && !fx_hide), .de(raw_de),
    .x(raw_x - 12'd160 - {{7{fx_dx_f[4]}}, fx_dx_f}), .y(raw_y - 12'd45 + {{7{fx_dy_f[4]}}, fx_dy_f}),   // D30：随画面抖动
    .hit(qr_hit), .dark(qr_dark)
);
// 转场与亮度/对比度只作用于图片层；文字层、状态 OSD、波形叠在其上，保持原色。
wire [23:0] pre_osd_rgb = qr_hit ? (qr_dark ? 24'h000000 : 24'hffffff) : thumb_frame ? sheet_rgb : picture_rgb;
wire [23:0] text_rgb_out, osd_rgb_out;
// ACTIVE_LAST 时序：有效像素 raw_x 160..799，OSD 坐标需换成有效区 0..639。
wire [11:0] osd_pixel_x = raw_x - 12'd160;
// 像素流水：S0 = 原始时序（图片层/总览页），S1 = 文字层 + 状态 OSD，S2 = 波形，适配器再寄存一拍输出。
// hs/vs/de/x 与像素整组逐级寄存，各叠加层看到的是自己那一级的完整视频合同；输出相对原始时序共延迟 3 拍。
// 叠加层 vsync 仍用 osd_vs_dly[1]：其下降沿在场消隐内，晚于 frame_slot_q 更新，各级 line_y 只在 de 下降沿变化。
// 提词屏 A 的底图与 B 共用 S0 时序，各级与 B 同拍。S1 叠加层（文字层 + 状态 OSD）只有一份，按行分流（D18）：
// 状态 OSD 行（y 8..15）与参数行（y 440..455）叠在 A，其余行（底部字幕带 y 458..477）叠在 B，另一路同级旁路；波形（S2）只在 B。
reg [23:0] s1_rgb, s2_rgb, pa2_rgb;
reg [9:0]  s1_x, s2_x;
reg        s1_hs, s1_vs, s1_de, s2_hs, s2_vs, s2_de;
reg        s1_line_a;
localparam integer PARAM_Y_A = 440;   // 参数行在提词屏讲稿区（y 40..431）下方；其下 y 458.. 留给观众屏字幕带
wire [11:0] s0_line = raw_y - 12'd45;   // ACTIVE_LAST：有效行 raw_y 45..524
wire       s0_line_a = (s0_line >= 12'd8 && s0_line < 12'd16) ||
                       (s0_line >= PARAM_Y_A && s0_line < PARAM_Y_A + 16);
// 时期（单个电平，慢变化）两级同步到像素域，帧边界锁存后控制波形
wire       phase_sync;
sync_2ff u_phase_sync (.clk(video_clk), .rst_n(pix_rst_n), .async_in(show_phase_ctrl), .sync_out(phase_sync));
always @(posedge video_clk or negedge pix_rst_n) begin
    if (!pix_rst_n) begin show_phase_pix <= 1'b0; phase_f <= 1'b0; end
    else begin
        show_phase_pix <= phase_sync;
        if (frame_start) phase_f <= show_phase_pix;
    end
end
wire       ov_wave_on = !phase_f;   // 波形只在预备时期
// D32：波形只在观众屏显示第 1 张（槽 0、非转场、非总览页）时画；帧边界锁存，整帧一致
reg        wave_slot0_f;
always @(posedge video_clk or negedge pix_rst_n) begin
    if (!pix_rst_n) wave_slot0_f <= 1'b0;
    else if (frame_start) wave_slot0_f <= frame_read_index == 3'd0 && !thumb_sheet_q && !trans_active;
end
wire       prompter_mirror = 1'b1;   // 仅 PROMPTER_MIRROR=1 时使用；保留为线网便于以后接开关
wire [23:0] pa_rgb;   // S1 对齐
wire        prompter_late_row;
generate if (ENABLE_PROMPTER_SCRIPTS) begin : g_script_reader
    // 讲稿装完（控制域保持电平）同步到像素域；装完后页数不再变化，在同步电平上升沿取样。
    // 窗口起点由 prompter_window_ctrl 在 frame_start 更新，读取器在同一场同步沿锁存上一帧算好的值。
    wire        loaded_pix;
    reg         loaded_q;
    reg  [5:0]  slots;                  // 已装槽数（讲稿页 + 总览页）
    reg  [5:0]  pages;                  // 讲稿页数（D16：连续存放在槽 0..pages-1，总览页在其后）
    wire [15:0] window_row;
    wire [5:0]  page_slot;
    wire        sliding;
    reg         phase_seen;
    always @(posedge video_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) phase_seen <= 1'b0;
        else phase_seen <= show_phase_pix;
    end
    wire        talk_enter = show_phase_pix && !phase_seen;
    // ---- 提词模式：命令邮箱（控制域 → 像素域），整笔 {模式, 命令翻转位}，变化即发 ----
    wire [6:0]  pcmd_state_ctrl = {prompter_active_ctrl, prompter_cmd_ctrl};   // SW4 拨下
    reg  [6:0]  pcmd_sent_ctrl;
    wire        pcmd_ready, pcmd_update;
    wire [6:0]  pcmd_slot;
    wire        pcmd_valid = pcmd_state_ctrl != pcmd_sent_ctrl;
    always @(posedge sd_card_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n) pcmd_sent_ctrl <= 7'd0;
        else if (pcmd_valid && pcmd_ready) pcmd_sent_ctrl <= pcmd_state_ctrl;
    end
    media_slot_cdc #(.SLOT_W(7)) u_prompter_cmd_cdc (
        .src_clk(sd_card_clk), .dst_clk(video_clk), .rst(rst_all),
        .src_slot(pcmd_state_ctrl), .src_valid(pcmd_valid), .src_ready(pcmd_ready),
        .dst_slot(pcmd_slot), .dst_update(pcmd_update)
    );
    reg  [6:0]  pcmd_pix;               // {prompter_mode, 命令翻转位}
    reg  [5:0]  pcmd_pulse;             // 单拍命令 {overview, key3, 0, 0, prev, next}
    always @(posedge video_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin pcmd_pix <= 7'd0; pcmd_pulse <= 6'd0; end
        else begin
            // 命令位只在提词模式（板上按键）或遥控器下翻转，模式位变化本身不产生命令
            pcmd_pulse <= pcmd_update ? (pcmd_slot[5:0] ^ pcmd_pix[5:0]) : 6'd0;
            if (pcmd_update) pcmd_pix <= pcmd_slot;
        end
    end
    wire        pm_pix = pcmd_pix[6];
    // ---- D20 全局总览页 = 第 1 节总览（S1P00）：控制域静态量，讲稿装完后不再变化，与 slots 同时取样 ----
    reg  [5:0]  ov_slot_p;
    reg         ov_valid_p;
    always @(posedge video_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            ov_slot_p <= 6'd0; ov_valid_p <= 1'b0;
        end else if (loaded_pix && !loaded_q) begin
            ov_slot_p <= script_section_overview_ctrl[5:0]; ov_valid_p <= script_overview_valid_ctrl[0];
        end
    end
    wire        nav_next, nav_prev, nav_scroll;
    // D21：总览网格边长与 script_to_bmp.grid_of 同一规则（<=4 页 2、<=9 页 3、<=16 页 4、其余 5）
    wire [2:0]  ov_grid = (pages <= 6'd4) ? 3'd2 : (pages <= 6'd9) ? 3'd3 : (pages <= 6'd16) ? 3'd4 : 3'd5;
    // D29：翻页与连续滚动不再受 SW4 门控（遥控器任何拨码位置都能操作；SW4 拨上时板上按键本来就不发提词命令），
    // 拨回 SW4 不再停止滚动。选页仍只在提词模式下：拨上 SW4 时退出选页、拨回时先回原页（D20）。
    wire        nav_on = loaded_q && pages != 6'd0;
    wire        sel_on = nav_on && pm_pix;
    // 阶段 3.2 选页（D15）：选页期间 KEY2 移焦点、KEY3 确定，prompter_nav 不收翻页命令
    wire        selecting, sel_jump, sel_box;
    // D18 连续滚动：不在选页时 KEY3 单击开/关（prompter_nav 内），速度 = 一页 / 周期参数秒
    wire [7:0]  pace_q4;
    // D32 两种滚动互斥（上电都关）：KEY3 / * 开关匀速自动滚动（nav_scroll，不看麦克风）；遥控 9 开关声控滚动
    // （说话时按同一速度滚、不说话停，无麦克风不动）。开其中一个即关另一个；讲稿未就绪时两者都清零。
    reg  voice_q, voice_on;
    wire voice_cmd = voice_ctl_pix ^ voice_q;
    wire auto_cmd  = pcmd_pulse[4] && !selecting;
    always @(posedge video_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin voice_q <= 1'b0; voice_on <= 1'b0; end
        else begin
            voice_q <= voice_ctl_pix;
            if (!nav_on) voice_on <= 1'b0;
            else if (voice_cmd) voice_on <= !voice_on;
            else if (auto_cmd && !nav_scroll) voice_on <= 1'b0;
        end
    end
    assign voice_on_pix = voice_on;
    assign scroll_auto_pix = nav_scroll;
    prompter_scroll_pace u_scroll_pace (
        .clk(video_clk), .rst_n(pix_rst_n), .frame_start(frame_start),
        .run(nav_scroll || voice_on), .period_s(osd_period_s_pix), .rows_q4(pace_q4)
    );
    wire [5:0]  sel_jump_slot;
    wire [4:0]  sel_cell;
    // D20：观众屏不跟随讲稿，翻页/选页只动提词屏
    prompter_nav u_prompter_nav (
        .clk(video_clk), .rst_n(pix_rst_n), .frame_start(frame_start),
        .enable(nav_on && !selecting), .slots(pages),
        .cmd_next(pcmd_pulse[0]), .cmd_prev(pcmd_pulse[1]), .cmd_scroll(auto_cmd || (voice_cmd && !voice_on && nav_scroll)),
        .page_slot(page_slot), .window_row(window_row), .sliding(sliding),
        .page_next(nav_next), .page_prev(nav_prev), .scroll_en(nav_scroll)
    );
    if (ENABLE_SCRIPT_SELECT) begin : g_select
        prompter_select u_prompter_select (
            .clk(video_clk), .rst_n(pix_rst_n), .nav_active(sel_on),
            .ov_slot(ov_slot_p), .ov_valid(ov_valid_p), .pages(pages),
            .cmd_open(pcmd_pulse[5]), .cmd_next(pcmd_pulse[0]), .cmd_prev(pcmd_pulse[1]), .cmd_confirm(pcmd_pulse[4]),
            .page_slot(page_slot), .sliding(sliding),
            .selecting(selecting), .jump(sel_jump), .jump_slot(sel_jump_slot),
            .focus_cell(sel_cell), .box_on(sel_box)
        );
    end else begin : g_no_select
        assign selecting = 1'b0; assign sel_jump = 1'b0; assign sel_jump_slot = 6'd0;
        assign sel_cell = 5'd0; assign sel_box = 1'b0;
    end
    // ---- 计时条：一直计时（D18 取消暂停）；D21 最后一栏显示讲稿页码 当前页/总页数 ----
    // 选页浏览总览页时仍显示原页（窗口停在总览槽、或不在讲稿页范围内时不更新）
    reg  [5:0]  page_seen;
    always @(posedge video_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) page_seen <= 6'd0;
        else if (frame_start && !selecting && page_slot < pages) page_seen <= page_slot;
    end
    assign prompter_page_no = page_seen + 6'd1;
    assign prompter_page_total = pages;
    assign prompter_timer_clear = talk_enter;   // 进入演讲：计时从零开始
    sync_2ff u_script_loaded_sync (
        .clk(video_clk), .rst_n(pix_rst_n), .async_in(script_load_done_ctrl), .sync_out(loaded_pix)
    );
    always @(posedge video_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            loaded_q <= 1'b0; slots <= 6'd0; pages <= 6'd0;
        end else begin
            loaded_q <= loaded_pix;
            if (loaded_pix && !loaded_q) begin slots <= script_pages_loaded_ctrl; pages <= script_slots_ctrl; end
        end
    end
    // scroll_speed 只在 scroll_en=1 时使用
    prompter_window_ctrl #(.DIRECT(1)) u_window_ctrl (
        .clk(video_clk), .rst_n(pix_rst_n), .frame_start(frame_start), .slots(slots), .pages(pages),
        .page_next(nav_next), .page_prev(nav_prev),
        .jump(pm_pix && sel_jump), .jump_slot(sel_jump_slot),
        .scroll_en(nav_scroll || (voice_on && mic_present && mic_speaking)), .scroll_speed(pace_q4),
        .window_row(window_row), .page_slot(page_slot), .sliding(sliding)
    );
    prompter_script_reader #(
        .ADDR_WIDTH (ADDR_BITS),
        .SCRIPT_BASE(SCRIPT_BASE),
        .TOTAL_ROWS (SCRIPT_MAX_PAGES * 480),
        .CAL_ADDR   (SCRIPT_CAL_ADDR),
        // D24 逐行高亮：屏幕第 160 行为阅读线，排版参数与 script_to_bmp 默认一致（顶 40、行距 40、每页 10 行）
        .HIGHLIGHT  (1),
        .HL_ROW     (160),
        .LINE_TOP   (40),
        .LINE_PITCH (40),
        .LINES      (10),
        .HL_INK     (24'hffd400),
        .HL_BG      (24'h303030)
    ) u_script_reader (
        .pix_clk(video_clk), .pix_rst_n(pix_rst_n),
        .enable(loaded_q && slots != 6'd0), .window_row(window_row),
        .ink_rgb(PROMPTER_INK_RGB), .bg_rgb(PROMPTER_BG_RGB),
        .hs_in(raw_hs), .vs_in(raw_vs), .de_in(raw_de), .rgb_in(PROMPTER_BG_RGB),
        .box_on(pm_pix && sel_box), .box_cell(sel_cell), .box_grid(ov_grid),
        .hs_out(), .vs_out(), .de_out(), .rgb_out(pa_rgb), .late_row(prompter_late_row),
        .mem_clk(ext_mem_clk), .mem_rst_n(mem_rst_n),
        .app_rd_en(sread_rd_en), .app_rd_addr(sread_rd_addr),
        .sdram_rd_valid(Sdr_rd_en), .sdram_rd_data(Sdr_rd_dout),
        .burst_hold(sread_burst_hold), .burst_request(sread_burst_request), .burst_idle(sread_burst_idle),
        .rd_steal(sread_steal)
    );
end else begin : g_prompter_test_pattern
    prompter_test_pattern u_prompter_test_pattern (
        .clk(video_clk), .rst_n(pix_rst_n),
        .hs_in(raw_hs), .vs_in(raw_vs), .de_in(raw_de),
        .hs_out(), .vs_out(), .de_out(), .rgb_out(pa_rgb)
    );
    assign prompter_late_row = 1'b0;
    assign sread_rd_en = 1'b0;
    assign sread_rd_addr = {ADDR_BITS{1'b0}};
    assign sread_burst_request = 1'b0;
    assign sread_burst_idle = 1'b1;
    assign sread_steal = 1'b0;
    assign prompter_page_no = 6'd0;
    assign prompter_page_total = 6'd0;
    assign prompter_timer_clear = 1'b0;
    assign voice_on_pix = 1'b0;
    assign scroll_auto_pix = 1'b0;
end endgenerate
wire [23:0] ov1_rgb_in = s1_line_a ? pa_rgb : s1_rgb;
wire [23:0] ov1_rgb_out = osd_rgb_out;
always @(posedge video_clk or negedge pix_rst_n) begin
    if (!pix_rst_n) begin
        s1_rgb <= 24'd0; s2_rgb <= 24'd0; pa2_rgb <= 24'd0;
        s1_x <= 10'd0; s2_x <= 10'd0;
        s1_hs <= 1'b1; s1_vs <= 1'b1; s1_de <= 1'b0;
        s2_hs <= 1'b1; s2_vs <= 1'b1; s2_de <= 1'b0;
        s1_line_a <= 1'b0;
    end else begin
        s1_line_a <= s0_line_a;
        s1_rgb <= pre_osd_rgb;
        s1_x <= osd_pixel_x[9:0];
        s1_hs <= raw_hs; s1_vs <= raw_vs; s1_de <= raw_de;
        s2_rgb <= s1_line_a ? s1_rgb : ov1_rgb_out;
        pa2_rgb <= s1_line_a ? ov1_rgb_out : pa_rgb;
        s2_x <= s1_x;
        s2_hs <= s1_hs; s2_vs <= s1_vs; s2_de <= s1_de;
    end
end
// 图层自下而上：图片 -> 参数行（提词屏 y=440）/半透明底带滚动字幕（观众屏底部 y 458..477）-> 状态条(y=8) -> 音频波形（y 388..451），区域互不重叠。
// D20：字幕内容在 SD/subtitle.txt，由 python/subtitle_to_rom.py 生成 SD/subtitle_rom.v（改内容后重新综合）。
promax_text_overlay #(.PARAM_X(8), .PARAM_Y(PARAM_Y_A), .SUBTITLE_Y(458), .H_ACTIVE(640),
    .BAND_COLOR(24'he8eef2), .BAND_ALPHA(8'd96)) u_text_overlay (
    .clk            (video_clk),
    .rst_n          (pix_rst_n),
    .vsync          (osd_vs_dly[1]),
    .de             (s1_de),
    .rgb_in         (ov1_rgb_in),
    .pixel_x        (s1_x),
    .enable         (1'b1),
    .subtitle_enable(!thumb_frame && !blackout_on && !fx_hide),
    .param_enable   (1'b1),
    .volume         (volume_value_pix),
    .period_s       (osd_period_s_pix),
    .auto_enabled   (auto_play_active_pix),
    .brightness     (picture_brightness_pix),
    .contrast       (picture_contrast_pix),
    .adjust_sel     (picture_sel_pix),
    .rgb_out        (text_rgb_out),
    .overlay_active ()
);
osd_overlay_24 #(.OSD_X(8), .OSD_Y(8)) u_osd_overlay (
    .clk          (video_clk),
    .rst_n        (pix_rst_n),
    .vsync        (osd_vs_dly[1]),
    .de           (s1_de),
    .rgb_in       (text_rgb_out),
    .pixel_x      (s1_x),
    .active_index (frame_read_index),
    .auto_enabled (auto_play_active_pix),
    .error_code   (osd_error_code),
    .rgb_out      (osd_rgb_out),
    .de_out       (),
    .osd_active   ()
);

// ===================== 第 12 课音频波形：最上层，区域 y400..463 与 OSD/文字层不重叠 =====================
// pcm_tap 必须是每样本一拍的提交脉冲：用 m06 适配器输出（audio_valid/pcm_left，48 kHz，同 video_clk 域），
// 不能用 wav_stream_player 的 ready/valid 电平。像素类型提前一拍寄存、输出同拍组合，不改变 hs/vs/de 对齐。
// synthesis translate_off
initial begin
    if (ENABLE_AUDIO_WAVEFORM != 0 && ENABLE_AUDIO_WAVEFORM != 1) begin
        $display("MEDIA_CONFIG_ERROR top audio waveform %m: boolean enable required");
        $finish;
    end
end
// synthesis translate_on
wire [23:0] wave_rgb_out;
wire [23:0] wave_rgb_in = s2_rgb;
generate if (ENABLE_AUDIO_WAVEFORM) begin : g_audio_waveform
    // D32：精简绿色波形 256x32，只在观众屏第 1 张（开场页）显示，位于标题下方 (192,420)
    promax_audio_waveform #(.LITE(2), .WAVE_X(192), .WAVE_Y(420), .WAVE_WIDTH(256), .WAVE_HEIGHT(32),
        .DECIMATE(12), .TRIG_HYST(2), .TRIG_TIMEOUT(256)) u_audio_waveform (
        .clk            (video_clk),
        .rst_n          (pix_rst_n),
        .vsync          (osd_vs_dly[1]),
        .de             (s2_de),
        .rgb_in         (wave_rgb_in),
        .pixel_x        (s2_x),
        .enable         (ov_wave_on && !blackout_on && !fx_hide && wave_slot0_f),
        .pcm_tap_valid  (audio_valid),
        .pcm_tap_left   (pcm_left),
        .rgb_out        (wave_rgb_out),
        .waveform_active()
    );
end else begin : g_no_audio_waveform
    assign wave_rgb_out = wave_rgb_in;
end endgenerate
wire [23:0] b_out_rgb = wave_rgb_out;
wire [23:0] a_out_rgb = pa2_rgb;

// 输出适配：S2 的 hs/vs/de/rgb 同拍寄存一拍；首帧提交前或故障时黑屏（OSD/波形仍叠加），HS/VS/DE 始终连续。
rgb_video_adapter u_video_adapter (
    .pclk      (video_clk),
    .rst_n     (pix_rst_n),
    .hs_in     (s2_hs),
    .vs_in     (s2_vs),
    .de_in     (s2_de),
    .rgb_in    (b_out_rgb),
    .video_clk (),
    .video_hs  (hs),
    .video_vs  (vs),
    .video_de  (de),
    .video_rgb (vout_data)
);

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (~mem_rst_n),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// ===================== 音频：像素域 PCM，直接交给 HDMI 封装 =====================
audio_i2s_timing u_audio_timing (
    .clk(video_clk), .rst(audio_rst),
    .bclk(audio_i2s_bclk), .lrck(audio_i2s_lrck),
    .bclk_rise_ce(), .bclk_fall_ce(), .frame_bit(),
    .sample_tick(audio_sample_tick)
);
pcm_test_tone u_pcm_test_tone (
    .clk(video_clk), .rst(audio_rst), .enable(AUDIO_ENABLE != 0 && ENABLE_FALLBACK_TONE != 0),
    .phase_inc(AUDIO_TEST_PHASE_INC), .sample_valid(tone_valid),
    .sample_ready(tone_ready), .sample_left(tone_left), .sample_right(tone_right)
);
m06_pcm_contract_adapter u_pcm_adapter (
    .clk(video_clk), .rst(audio_rst), .sample_tick(audio_sample_tick),
    .sample_valid(volume_sample_valid), .sample_ready(volume_sample_ready),
    .sample_left(volume_sample_left), .sample_right(volume_sample_right),
    .pcm_commit(audio_valid), .pcm_left(pcm_left), .pcm_right(pcm_right),
    .underrun(audio_underrun)
);
// 旧通路仍同步加载提交状态；可选预加载通路直接使用同像素域实际帧提交反馈。
// 音源在样本握手时采纳状态，保留已交付/预取样本，不保证 HDMI 输出零延迟换音。
audio_media_cdc u_audio_media_cdc (
    .src_clk(sd_card_clk), .dst_clk(video_clk), .rst(rst_all),
    .src_media_id(seg_img_idx), .src_media_valid(display_valid),
    .dst_media_id(legacy_audio_media_id), .dst_media_valid(legacy_audio_media_present), .dst_update()
);
assign audio_media_id = ENABLE_PRELOAD_PLAYBACK ? frame_display_slot_pix[1:0] : legacy_audio_media_id;   // 回退测试音只按低 2 位区分
assign audio_media_present = ENABLE_PRELOAD_PLAYBACK ? frame_display_valid_pix : legacy_audio_media_present;
pcm_media_tone u_pcm_media_tone (
    .clk(video_clk), .rst(audio_rst), .enable(AUDIO_ENABLE != 0 && ENABLE_FALLBACK_TONE != 0),
    .media_id(audio_media_id), .media_valid(audio_media_present),
    .sample_valid(media_tone_valid), .sample_ready(media_tone_ready),
    .sample_left(media_tone_left), .sample_right(media_tone_right)
);
// 第 11 课 TF 卡 PCM 播放器：写侧与 SD 读取器同在 sd_card_clk 域，异步 FIFO 交给像素/音频域。
// synthesis translate_off
initial begin
    if ((ENABLE_WAV_PLAYBACK != 0 && ENABLE_WAV_PLAYBACK != 1) ||
        (ENABLE_AUDIO_FADE != 0 && ENABLE_AUDIO_FADE != 1)) begin
        $display("MEDIA_CONFIG_ERROR top wav playback %m: boolean enables required");
        $finish;
    end
end
// synthesis translate_on
generate if (ENABLE_WAV_PLAYBACK) begin : g_wav_playback
    wav_stream_player #(
        .CHANNELS    (WAV_CHANNELS),
        .FIFO_ADDR_W (WAV_FIFO_ADDR_W)
    ) u_wav_player (
        .wr_clk        (sd_card_clk),
        .wr_rst_n      (ctrl_rst_n),
        .byte_valid    (wav_byte_valid),
        .byte_data     (wav_byte),
        .stream_restart(wav_stream_restart),
        .stream_flush  (wav_stream_flush),
        .track_active  (wav_track_active_ctrl),
        .hold          (wav_hold_ctrl),
        .overflow      (wav_overflow_ctrl),
        .rd_clk        (video_clk),
        .rd_rst_n      (pix_rst_n),
        .sample_valid  (wav_valid),
        .sample_ready  (wav_ready),
        .sample_left   (wav_left),
        .sample_right  (wav_right),
        .wav_active    (wav_active),
        .underflow     (wav_underflow_pix)
    );
end else begin : g_no_wav_playback
    // 不读字节时 hold 置 0，读取器不会因此停住；wav_active=0 使 SEL=1 回退媒体音调。
    assign wav_hold_ctrl = 1'b0;
    assign wav_overflow_ctrl = 1'b0;
    assign wav_underflow_pix = 1'b0;
    assign wav_valid = 1'b0;
    assign wav_left = 16'sd0;
    assign wav_right = 16'sd0;
    assign wav_active = 1'b0;
end endgenerate
audio_source_mux u_audio_source_mux (
    .clk(video_clk), .rst(audio_rst), .enable(AUDIO_ENABLE != 0), .source_sel(AUDIO_SOURCE_SEL),
    .test_valid(ENABLE_FALLBACK_TONE ? tone_valid : 1'b1), .test_ready(tone_ready),
    .test_left(ENABLE_FALLBACK_TONE ? tone_left : 16'sd0), .test_right(ENABLE_FALLBACK_TONE ? tone_right : 16'sd0),
    .media_valid(ENABLE_FALLBACK_TONE ? media_tone_valid : 1'b1), .media_ready(media_tone_ready),
    .media_left(ENABLE_FALLBACK_TONE ? media_tone_left : 16'sd0), .media_right(ENABLE_FALLBACK_TONE ? media_tone_right : 16'sd0),
    .wav_active(wav_active), .wav_valid(wav_valid), .wav_ready(wav_ready),
    .wav_left(wav_left), .wav_right(wav_right),
    .sample_valid(source_valid), .sample_ready(source_ready),
    .sample_left(source_left), .sample_right(source_right)
);
// 保留 24 位左对齐观测信号；新封包核心直接接收 16 位 PCM。
assign audio_left_data = {pcm_left, 8'd0};
assign audio_right_data = {pcm_right, 8'd0};

// 原测量器的首个 CTS 包含启动延迟，丢弃首窗，仅发送完整测量窗口。
always @(posedge video_clk or posedge audio_rst) begin
    if (audio_rst) acr_primed <= 1'b0;
    else if (acr_raw_valid) acr_primed <= 1'b1;
end
assign acr_valid = acr_raw_valid && acr_primed;

audio_arc_calculate #(
    .ACR_N         (6144)
) u_audio_arc_calculate (
    .I_clk         (video_clk),
    .I_rst         (audio_rst),
    .I_audio_valid (audio_valid),
    .O_acr_valid   (acr_raw_valid),
    .O_acr_cts     (acr_cts),
    .O_acr_n       (acr_n)
);

// ===================== 自主 HDMI 音视频封包及符号编码 =====================
// 固定现有 640x480 / 25 MHz。PHY 内部已有位序转换，此处不可再次反转。
hdmi_audio_symbol_core u_hdmi_audio_symbol_core (
    .clk(video_clk), .rst(audio_rst),
    .video_rgb(vout_data), .video_hs(hs), .video_vs(vs), .video_de(de),
    .pcm_commit(audio_valid), .pcm_left(pcm_left), .pcm_right(pcm_right),
    .acr_valid(acr_valid), .acr_n(acr_n), .acr_cts(acr_cts),
    .channel0_symbol(tmds_ch0_data), .channel1_symbol(tmds_ch1_data),
    .channel2_symbol(tmds_ch2_data), .audio_overflow(hdmi_audio_overflow)
);
assign tmds_clk_data = 10'b1111100000;

// DDC 不再使用：读回的 EDID 无人消费，SCL 保持高电平，SDA 释放（板上上拉）。
assign HDMI_DDC_SCL = 1'b1;
assign HDMI_DDC_SDA = 1'bz;

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (~pix_rst_n),
    .I_serial_rst       (~serial_rst_n),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

// ===================== HDMI A 提词屏：独立 RGB + DVI（无音频） =====================
// S2 合成结果 → 计时条（3 拍）→ [整行镜像，仅 PROMPTER_MIRROR=1] → DVI 编码；两口帧节拍相同。
wire        pa_hs, pa_vs, pa_de;
wire [23:0] pa_out_rgb;
wire [9:0]  tmdsa_ch0_data, tmdsa_ch1_data, tmdsa_ch2_data;

// 计时条只叠在提词屏（D6），位于镜像之前，镜像打开时与讲稿一起翻转。
// P-12：讲稿装载中（四张图装完、讲稿未装完）计时条改显“载入 NN 页”。页数为慢变化的控制域计数，
// 两级同步后连续两拍相同才采用（同 OSD 周期）。无讲稿功能时不显示。
(* ASYNC_REG="TRUE" *) reg [6:0] sload_s1, sload_s2;
reg [6:0] sload_s3, sload_pix;
wire       script_loading_ctrl = ENABLE_PROMPTER_SCRIPTS && script_loading_raw_ctrl && !script_load_done_ctrl;
always @(posedge video_clk or negedge pix_rst_n) begin
    if (!pix_rst_n) begin
        sload_s1 <= 7'd0; sload_s2 <= 7'd0; sload_s3 <= 7'd0; sload_pix <= 7'd0;
    end else begin
        sload_s1 <= {script_loading_ctrl, script_pages_loaded_ctrl};
        sload_s2 <= sload_s1;
        sload_s3 <= sload_s2;
        if (sload_s2 == sload_s3) sload_pix <= sload_s3;
    end
end
wire       script_loading_pix = sload_pix[6];
wire [5:0] script_pages_pix = sload_pix[5:0];
wire        pt_hs, pt_vs, pt_de;
wire [23:0] pt_rgb;
// D17：计时条前显示当前阶段名，底框向左加宽 3 格，右缘不变
prompter_timer_bar #(.CLK_HZ(25_000_000), .TARGET_MM(PROMPTER_TARGET_MM), .TARGET_SS(PROMPTER_TARGET_SS),
    .BOX_X(240), .SHOW_STAGE(1)) u_prompter_timer (
    .clk(video_clk), .rst_n(pix_rst_n), .run(1'b1), .clear(prompter_timer_clear), .stage(show_phase_pix),
    .loading(script_loading_pix), .load_pages(script_pages_pix),
    .page_no(prompter_page_no), .page_total(prompter_page_total),
    .hs_in(s2_hs), .vs_in(s2_vs), .de_in(s2_de), .rgb_in(a_out_rgb),
    .hs_out(pt_hs), .vs_out(pt_vs), .de_out(pt_de), .rgb_out(pt_rgb)
);

// 话筒电平条：计时条左侧、状态 OSD 右侧（x 56..223，y 8..23），组合叠加不改时序，麦克风不在线时不画。
wire [23:0] pm_rgb;
prompter_mic_meter #(.X0(56), .Y0(8)) u_mic_meter (
    .clk(video_clk), .rst_n(pix_rst_n), .enable(mic_present && voice_on_pix), .speaking(mic_speaking),
    .mode_auto(scroll_auto_pix), .mode_voice(voice_on_pix),
    .env_log(mic_env_log), .thr_log(mic_thr_log),
    .vs_in(pt_vs), .de_in(pt_de), .rgb_in(pt_rgb), .rgb_out(pm_rgb)
);

// PROMPTER_MIRROR=0（直接显示）时不生成镜像，计时条输出直送 DVI；=1（分光玻璃）时整行镜像并晚一行。
generate if (PROMPTER_MIRROR) begin : g_prompter_mirror
    prompter_line_mirror #(.LINE_CYCLES(800), .H_ACTIVE(640)) u_prompter_mirror (
        .clk(video_clk), .rst_n(pix_rst_n), .mirror_en(prompter_mirror),
        .hs_in(pt_hs), .vs_in(pt_vs), .de_in(pt_de), .rgb_in(pm_rgb),
        .hs_out(pa_hs), .vs_out(pa_vs), .de_out(pa_de), .rgb_out(pa_out_rgb)
    );
end else begin : g_no_prompter_mirror
    assign {pa_hs, pa_vs, pa_de, pa_out_rgb} = {pt_hs, pt_vs, pt_de, pm_rgb};
end endgenerate

dvi_symbol_core #(.DELAY(0)) u_hdmia_dvi_symbol_core (
    .clk(video_clk), .rst(~pix_rst_n),
    .video_rgb(pa_out_rgb), .video_hs(pa_hs), .video_vs(pa_vs), .video_de(pa_de),
    .channel0_symbol(tmdsa_ch0_data), .channel1_symbol(tmdsa_ch1_data),
    .channel2_symbol(tmdsa_ch2_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmia_phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (~pix_rst_n),
    .I_serial_rst       (~serial_rst_n),
    .I_tmds_channel_0   (tmdsa_ch0_data),
    .I_tmds_channel_1   (tmdsa_ch1_data),
    .I_tmds_channel_2   (tmdsa_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMIA_D0_P),
    .O_tmds_ch1_p       (HDMIA_D1_P),
    .O_tmds_ch2_p       (HDMIA_D2_P),
    .O_tmds_clk_p       (HDMIA_CLK_P)
);

endmodule
