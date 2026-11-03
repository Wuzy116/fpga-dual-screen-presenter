// FAT32 版 BMP 读取器，端口与 bmp_read 一致，可直接替换实例。
// 扫描：卷扫描器按 8.3 文件名找 PIC1~5.BMP（D19），按资源序号(0..4)经 scan_found_sector 上报；
// 加载：load_sector 即资源序号。先读文件首扇区做与 bmp_read 相同的头校验，write_req 握手后
//       由文件流读取器沿 FAT 链输出，像素区字节按 B/G/R 拼成 24 位。
// 目录按目录项查找，scan_start_sector/scan_max_sector 不再使用。
// ANY_SIZE=0：头须与 bmp_width/bmp_height 完全一致、宽为 4 的倍数、自下而上、40 字节信息头（原行为）。
// ANY_SIZE=1：宽高 1..MAX_WIDTH/MAX_HEIGHT，负高度为自上而下，信息头 >=40 字节，行尾填充自动跳过；
//             仍只接受 24 位无压缩。img_width/img_height/img_top_down 在 write_req 起至下次加载前稳定。
// ENABLE_SCRIPTS=1：扫描同时登记讲稿 SnPmm.BMP（键 {n-1, mm}，n=1~5，mm=00 为节总览页），首簇号存入 128 项表
// （块 RAM，寄存读出；有效键 0..79）；
// script_valid 为有效位，在扫描开始时清零，恢复复位不清。
// 讲稿文件流：script_start 单拍登记键 script_key，读取器空闲后按固定长度 SCRIPT_FILE_SIZE 沿 FAT 链输出字节，
// 与音频共用流读取状态（二者由上层保证不同时）；hold/stop 语义同音频。键无效或簇号越界立即 done + 0x22。
module fat32_bmp_read #(
    parameter ENABLE_SCRIPTS = 0,
    parameter [31:0] SCRIPT_FILE_SIZE = 32'd38462,
    parameter CHECK_PIXEL_INTEGRITY = 0,
    parameter ENABLE_TIMEOUT = 0,
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer TIMEOUT_MS = 500,
    parameter ANY_SIZE = 0,
    parameter integer MAX_WIDTH = 2048,
    parameter integer MAX_HEIGHT = 2048
)(
    input                       clk,
    input                       rst,
    output                      ready,
    input                       scan_start,
    input  [31:0]               scan_start_sector,
    input  [31:0]               scan_max_sector,
    input  [2:0]                scan_target_count,
    output reg                  scan_done,
    output reg                  scan_found_valid,
    output reg [31:0]           scan_found_sector,
    output reg [2:0]            scan_found_total,
    input                       load_start,
    input  [31:0]               load_sector,
    input                       sd_init_done,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output reg                  write_req,
    input                       write_req_ack,
    output                      sd_sec_read,
    output [31:0]               sd_sec_read_addr,
    input  [7:0]                sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,
    output reg                  bmp_data_wr_en,
    output reg [23:0]           bmp_data,
    output     [11:0]           img_width,
    output     [11:0]           img_height,
    output                      img_top_down,
    // 下游反压（电平）：像素阶段为高时不发起新扇区，在途扇区照常读完；期间超时计数冻结。
    input                       pixel_hold,
    output reg [2:0]            bmp_error,
    output reg                  load_error,
    output reg                  load_success,
    output                      sd_recover_req,
    input                       sd_recover_ack,
    // 音频文件流（同 clk 域）：audio_start 单拍登记 MUS(idx+1).PCM，读取器空闲后开始；busy 覆盖登记到结束。
    // hold/stop 为电平，只阻止发起新扇区；stop 待扇区口空闲后中止回空闲，不发 done。
    // 自然读完发 done（error=FAT 链错误码），缺资源/空文件立即 done+0x22；ST_AUDIO 不参与 BMP 超时恢复。
    input                       audio_start,
    input  [2:0]                audio_file_idx,
    input                       audio_hold,
    input                       audio_stop,
    output     [4:0]            audio_valid,
    output                      audio_busy,
    output reg                  audio_done,
    output reg [7:0]            audio_error,
    output                      audio_byte_valid,
    output     [7:0]            audio_byte,
    output     [79:0]           script_valid,
    input                       script_start,
    input      [6:0]            script_key,
    input                       script_hold,
    input                       script_stop,
    output                      script_busy,
    output reg                  script_done,
    output reg [7:0]            script_error,
    output                      script_byte_valid,
    output     [7:0]            script_byte,
    // 只读诊断：{扫描器错误码(2位十六进制), 资源有效掩码, 本模块状态, 已完成扇区读取数低 4 位}
    output     [19:0]           diag_fs
);

localparam ST_IDLE      = 3'd0;
localparam ST_SCAN      = 3'd1;
localparam ST_LOAD_HDR  = 3'd2;
localparam ST_LOAD_WAIT = 3'd3;
localparam ST_LOAD_DATA = 3'd4;
localparam ST_RECOVER   = 3'd5;
localparam ST_REPORT    = 3'd6;
localparam ST_AUDIO     = 3'd7;

localparam [7:0] AUDIO_ERR_MISSING = 8'h22;

localparam ERR_NONE      = 3'd0;
localparam ERR_HEADER    = 3'd1;
localparam ERR_TIMEOUT   = 3'd2;
localparam ERR_TRUNCATED = 3'd3;

reg [2:0] state;

localparam [63:0] TIMEOUT_RAW = 64'd1 * (CLK_FREQ_HZ / 1000) * TIMEOUT_MS;
localparam [63:0] TIMEOUT_CYCLES = (TIMEOUT_RAW > 0) ? TIMEOUT_RAW : 64'd1;
localparam integer TIMEOUT_BITS = (TIMEOUT_CYCLES <= 1) ? 1 : $clog2(TIMEOUT_CYCLES);
reg [TIMEOUT_BITS-1:0] timeout_count;
wire read_phase = (state == ST_SCAN) || (state == ST_LOAD_HDR) || (state == ST_LOAD_DATA);
wire load_phase = (state == ST_LOAD_HDR) || (state == ST_LOAD_WAIT) || (state == ST_LOAD_DATA);
wire timed_phase = read_phase || (state == ST_LOAD_WAIT);
wire phase_complete = (read_phase && sd_sec_read_end) || ((state == ST_LOAD_WAIT) && write_req_ack);
wire recover_needed = ENABLE_TIMEOUT && timed_phase &&
                      (!sd_init_done || (!phase_complete && (timeout_count >= TIMEOUT_CYCLES - 1)));
assign sd_recover_req = (state == ST_RECOVER);
assign ready = (state == ST_IDLE);
// synthesis translate_off
initial begin
    if (ENABLE_TIMEOUT && (CLK_FREQ_HZ < 1000 || (CLK_FREQ_HZ % 1000) != 0 ||
        TIMEOUT_MS < 1 || TIMEOUT_RAW > 64'd2147483647)) begin
        $display("MEDIA_CONFIG_ERROR bmp %m: invalid timeout clock/timing or cycle-count overflow");
        $finish;
    end
end
// synthesis translate_on
wire load_gate = (state == ST_LOAD_DATA) && pixel_hold;
always @(posedge clk or posedge rst) begin
    if (rst)
        timeout_count <= 0;
    else if (!ENABLE_TIMEOUT || !timed_phase || phase_complete || recover_needed)
        timeout_count <= 0;
    else if (load_gate)
        timeout_count <= timeout_count;
    else if (timeout_count < TIMEOUT_CYCLES - 1)
        timeout_count <= timeout_count + 1'b1;
end

// 恢复或卡未就绪时复位 FAT32 子模块，使其放弃未完成的扇区事务；寄存后使用，避免异步复位毛刺。
reg sub_hold;
always @(posedge clk or posedge rst) begin
    if (rst)
        sub_hold <= 1'b1;
    else
        sub_hold <= recover_needed || (state == ST_RECOVER) || !sd_init_done;
end
wire sub_rst_n = !rst && !sub_hold;
// 音频中止只复位文件流读取器；适配器保持，避免与 SD 命令层失步。
reg streamer_abort;
wire streamer_rst_n = sub_rst_n && !streamer_abort;

reg         fs_scan_start;
wire [7:0]  fs_error;
wire        fs_scan_done;
wire [7:0]  fs_spc;
wire [31:0] fs_fat_lba, fs_data_lba, fs_max_cluster;
wire [4:0]  fs_valid;
wire [4:0]  fs_audio_valid;
wire        fs_cat_wr;
wire [3:0]  fs_cat_wr_addr;
wire [31:0] fs_cat_wr_cluster, fs_cat_wr_size;
reg         file_start;
wire        file_done, file_valid;
wire [7:0]  file_byte, file_error;
wire [31:0] file_offset;
reg         hdr_req;

wire        scan_sector_req, file_sector_req;
wire [31:0] scan_sector_lba, file_sector_lba;
wire        sector_busy, sector_valid, sector_done;
wire [7:0]  sector_byte, sector_error;
wire [8:0]  sector_byte_index;

// 有效位与卷参数在扫描完成时锁存，仅全局复位清除；恢复复位子模块后仍可按序号加载。
reg [4:0]  cat_valid;
reg [7:0]  cat_spc;
reg [31:0] cat_fat_lba, cat_data_lba, cat_max_cluster;
reg [2:0]  report_idx;
reg [31:0] sel_cluster, sel_size;
reg        sel_ok;
reg        hdr_issued;
reg        load_idx_ok, cat_wait;

reg [4:0]  cat_audio_valid;
reg        audio_pending;
reg [2:0]  audio_pending_idx;

// ---------- PIC/MUS 目录表：16 项 {首簇号, 长度}，地址 {是音乐, 序号}，扫描时逐项写入（块 RAM，同步读）。
// 读口由图片加载与音乐共用：ST_IDLE 时跟随音乐序号、收到 load_start 改为图片序号，离开 IDLE 后保持。
// 读出与判定各寄存一拍，读地址作为标签随数据走流水；使用方只在标签等于所需地址时取用。
// 表内容只在扫描中改变，扫描后经 ST_REPORT（5 拍）才回 IDLE，流水已刷新，标签相等即数据正确。
reg [63:0] cat_mem [0:15];
reg [63:0] cat_q, cat_d;
reg [3:0]  cat_raddr, cat_q_tag, cat_ok_tag;
reg        cat_cl_ok, cat_size_nz;
always @(posedge clk) begin
    if (fs_cat_wr)
        cat_mem[fs_cat_wr_addr] <= {fs_cat_wr_cluster, fs_cat_wr_size};
    cat_q <= cat_mem[cat_raddr];
    cat_d <= cat_q;
end
// 复位时三者同为图片序号 7（不存在的资源，load_idx_ok 必为 0），不会被误用。
always @(posedge clk or posedge rst) begin
    if (rst) begin
        cat_raddr <= 4'b0111;
        cat_q_tag <= 4'b0111;
        cat_ok_tag <= 4'b0111;
        cat_cl_ok <= 1'b0;
        cat_size_nz <= 1'b0;
    end else begin
        if (state == ST_IDLE)
            cat_raddr <= load_start ? {1'b0, load_sector[2:0]} : {1'b1, audio_pending_idx};
        cat_q_tag <= cat_raddr;
        cat_ok_tag <= cat_q_tag;
        cat_cl_ok <= (cat_q[63:32] >= 32'd2) && (cat_q[63:32] <= cat_max_cluster);
        cat_size_nz <= (cat_q[31:0] != 32'd0);
    end
end
wire [31:0] cat_cluster_d = cat_d[63:32];
wire [31:0] cat_size_d = cat_d[31:0];
wire        audio_cat_ready = (cat_ok_tag == {1'b1, audio_pending_idx});
wire        audio_resource_ok = (audio_pending_idx <= 3'd4) && cat_audio_valid[audio_pending_idx] &&
                                cat_size_nz && cat_cl_ok;
// 流读取状态由音频与讲稿共用：stream_script 区分当前流的归属
reg        stream_script;
reg        script_pending;
reg [6:0]  script_pending_key;
wire       stream_stop = stream_script ? script_stop : audio_stop;
wire audio_gate = (state == ST_AUDIO) && (stream_script ? (script_hold || script_stop) : (audio_hold || audio_stop));
assign audio_valid = cat_audio_valid;
assign audio_busy = audio_pending || ((state == ST_AUDIO) && !stream_script);
assign audio_byte_valid = (state == ST_AUDIO) && !stream_script && file_valid && !audio_stop;
assign audio_byte = file_byte;
assign script_busy = script_pending || ((state == ST_AUDIO) && stream_script);
assign script_byte_valid = (state == ST_AUDIO) && stream_script && file_valid && !script_stop;
assign script_byte = file_byte;
wire [31:0] hdr_lba = cat_data_lba + (sel_cluster - 32'd2) * cat_spc;

// 三个请求方状态互斥，req 相或、返回信号广播；各模块只在自身等待态响应。
sd_sector_adapter u_adapter (
    .clk(clk), .rst_n(sub_rst_n),
    .sector_req(scan_sector_req | hdr_req | file_sector_req),
    .sector_lba(scan_sector_req ? scan_sector_lba : (hdr_req ? hdr_lba : file_sector_lba)),
    .sector_busy(sector_busy), .sector_valid(sector_valid), .sector_byte(sector_byte),
    .sector_byte_index(sector_byte_index), .sector_done(sector_done), .sector_error(sector_error),
    .sd_sec_read(sd_sec_read), .sd_sec_read_addr(sd_sec_read_addr),
    .sd_sec_read_data_valid(sd_sec_read_data_valid), .sd_sec_read_data(sd_sec_read_data),
    .sd_sec_read_end(sd_sec_read_end)
);

wire        fs_script_wr;
wire [6:0]  fs_script_key;
wire [31:0] fs_script_cluster;
fat32_volume_scanner #(.ENABLE_SCRIPTS(ENABLE_SCRIPTS)) u_scanner (
    .clk(clk), .rst_n(sub_rst_n), .scan_start(fs_scan_start), .scan_busy(),
    .scan_done(fs_scan_done), .fs_error(fs_error), .partition_lba(),
    .sectors_per_cluster(fs_spc), .fat_start_lba(fs_fat_lba), .data_start_lba(fs_data_lba),
    .max_cluster(fs_max_cluster), .resource_valid(fs_valid), .audio_valid(fs_audio_valid),
    .cat_wr(fs_cat_wr), .cat_wr_addr(fs_cat_wr_addr), .cat_wr_cluster(fs_cat_wr_cluster), .cat_wr_size(fs_cat_wr_size),
    .script_wr(fs_script_wr), .script_key(fs_script_key), .script_cluster(fs_script_cluster),
    .sector_req(scan_sector_req), .sector_lba(scan_sector_lba), .sector_busy(sector_busy),
    .sector_valid(sector_valid), .sector_byte(sector_byte), .sector_byte_index(sector_byte_index),
    .sector_done(sector_done), .sector_error(sector_error)
);

// 音频 hold/stop 只并入流读取器看到的 busy：仅在其 REQ 态阻止新扇区，在途扇区照常读完。
fat32_file_streamer u_streamer (
    .clk(clk), .rst_n(streamer_rst_n), .file_start(file_start), .first_cluster(sel_cluster),
    .file_size(sel_size), .sectors_per_cluster(cat_spc), .fat_start_lba(cat_fat_lba),
    .data_start_lba(cat_data_lba), .max_cluster(cat_max_cluster), .file_busy(),
    .file_done(file_done), .file_valid(file_valid), .file_byte(file_byte),
    .file_byte_offset(file_offset), .fs_error(file_error),
    .sector_req(file_sector_req), .sector_lba(file_sector_lba), .sector_busy(sector_busy || audio_gate || load_gate),
    .sector_valid(sector_valid), .sector_byte(sector_byte), .sector_byte_index(sector_byte_index),
    .sector_done(sector_done), .sector_error(sector_error)
);

// ---------- 讲稿目录表：扫描期间逐项写入。簇号表为同步写、寄存读的块 RAM：
// 读地址 script_pending_key 在 script_start 后一拍更新，script_table_ready 再晚一拍才允许 ST_IDLE 分派。 ----------
reg [31:0] script_cluster_mem [0:127];
reg [31:0] script_cluster_q;
reg        script_table_ready;
reg [79:0] cat_script_valid;
wire       script_scan_begin = !recover_needed && sd_init_done && (state == ST_IDLE) && scan_start;
always @(posedge clk) begin
    if (ENABLE_SCRIPTS && fs_script_wr)
        script_cluster_mem[fs_script_key] <= fs_script_cluster;
    script_cluster_q <= script_cluster_mem[script_pending_key];
end
always @(posedge clk or posedge rst) begin
    if (rst)               script_table_ready <= 1'b0;
    else if (script_start) script_table_ready <= 1'b0;
    else                   script_table_ready <= script_pending;
end
always @(posedge clk or posedge rst) begin
    if (rst)
        cat_script_valid <= 80'd0;
    else if (script_scan_begin)
        cat_script_valid <= 80'd0;
    else if (ENABLE_SCRIPTS && fs_script_wr && fs_script_key < 7'd80)
        cat_script_valid[fs_script_key] <= 1'b1;
end
assign script_valid = cat_script_valid;
wire [31:0] script_cluster_sel = script_cluster_q;
wire        script_resource_ok = (script_pending_key < 7'd80) && cat_script_valid[script_pending_key] &&
                                 (script_cluster_sel >= 32'd2) && (script_cluster_sel <= cat_max_cluster);
// 判定同音频路径寄存一拍（块 RAM 读出 → 32 位比较链 → IDLE 分派曾是 50 MHz 域最差路径）。
// 要求上一拍已在 ST_IDLE：扫描完成那一拍 cat_max_cluster 才更新，避免用到旧值的判定。
reg         script_ok_q, script_ok_ready;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        script_ok_q <= 1'b0;
        script_ok_ready <= 1'b0;
    end else begin
        script_ok_q <= script_resource_ok;
        script_ok_ready <= script_table_ready && !script_start && (state == ST_IDLE);
    end
end

// ---------- BMP 头：与 bmp_read 相同的字段与校验，长度另需落在目录项文件大小内 ----------
reg [9:0]  hdr_bytes;
reg [7:0]  header_0, header_1;
reg [31:0] file_len, pixel_offset, dib_size;
// 宽高只存低 12 位，另记高 20 位（bit31..12）全 0 / 全 1 与符号；planes/bit_count/compression 只记“等于期望值”。
// 头扇区每次加载都按偏移 0..33 顺序全部重写，标志在各字段首字节处重新初始化。MAX_WIDTH/MAX_HEIGHT < 4096 时
// 与原 32 位比较逐位等价：负高度合法 ⟺ 高 20 位全 1 且 (-height) 的低 12 位在 1..MAX_HEIGHT。
reg [11:0] width_lo, height_lo;
reg        w_hi_zero, h_hi_zero, h_hi_ones, h_sign;
reg        planes_one, bits_24, comp_zero;
wire [11:0] geo_w = width_lo;
wire [11:0] geo_h = h_sign ? (~height_lo + 12'd1) : height_lo;
wire        width_zero  = w_hi_zero && (width_lo == 12'd0);
wire        height_zero = h_hi_zero && (height_lo == 12'd0);
wire        height_range_ok = (h_sign ? h_hi_ones : h_hi_zero) && (geo_h != 12'd0) && (geo_h <= MAX_HEIGHT);
// synthesis translate_off
initial if (MAX_WIDTH >= 4096 || MAX_HEIGHT >= 4096) begin
    $display("MEDIA_CONFIG_ERROR bmp %m: MAX_WIDTH/MAX_HEIGHT must be < 4096");
    $finish;
end
// synthesis translate_on
// 每行字节数补齐到 4：3W + (W mod 4)
wire [13:0] row_bytes = {geo_w, 1'b0} + {2'd0, geo_w} + {12'd0, geo_w[1:0]};
reg [23:0] expected_pixels;
reg [25:0] pixel_bytes;
reg [33:0] pixel_end;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        expected_pixels <= 24'd0;
        pixel_bytes <= 26'd0;
        pixel_end <= 34'd0;
    end else begin
        expected_pixels <= geo_w * geo_h;
        pixel_bytes <= row_bytes * geo_h;
        pixel_end <= {2'd0, pixel_offset} + {8'd0, pixel_bytes};
    end
end

wire header_common = (header_0 == "B") && (header_1 == "M") &&
                     (((hdr_bytes == 10'd512) && !sector_valid) ||
                      ((hdr_bytes == 10'd511) && sector_valid)) &&
                     planes_one && (pixel_offset >= 32'd54) && bits_24 && comp_zero;
wire header_legacy_match = header_common && (dib_size == 32'd40) &&
                           !width_zero && !height_zero && w_hi_zero && h_hi_zero &&
                           (width_lo[1:0] == 2'd0) &&
                           ({4'd0, width_lo} == bmp_width) && ({4'd0, height_lo} == bmp_height);
wire header_any_match = header_common && (dib_size >= 32'd40) &&
                        ({1'b0, pixel_offset} >= {1'b0, dib_size} + 33'd14) &&
                        w_hi_zero && !width_zero && (width_lo <= MAX_WIDTH) && height_range_ok;
wire header_format_match = ANY_SIZE ? header_any_match : header_legacy_match;
assign img_width = geo_w;
assign img_height = geo_h;
assign img_top_down = ANY_SIZE ? h_sign : 1'b0;
wire pixel_past_end = (pixel_end > {2'd0, file_len}) || (pixel_end > {2'd0, sel_size});
wire header_match = header_format_match && (pixel_offset < file_len) && !pixel_past_end;

always @(posedge clk or posedge rst) begin
    if (rst)
        hdr_bytes <= 10'd0;
    else if (state != ST_LOAD_HDR)
        hdr_bytes <= 10'd0;
    else if (sector_valid && hdr_bytes < 10'd513)
        hdr_bytes <= hdr_bytes + 10'd1;
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        header_0 <= 8'd0; header_1 <= 8'd0; file_len <= 32'd0; pixel_offset <= 32'd54;
        dib_size <= 32'd0; width_lo <= 12'd0; height_lo <= 12'd0;
        w_hi_zero <= 1'b1; h_hi_zero <= 1'b1; h_hi_ones <= 1'b0; h_sign <= 1'b0;
        planes_one <= 1'b0; bits_24 <= 1'b0; comp_zero <= 1'b1;
    end else if ((state == ST_LOAD_HDR) && sector_valid) begin
        case (sector_byte_index)
            9'd0 : header_0 <= sector_byte;
            9'd1 : header_1 <= sector_byte;
            9'd2 : file_len[7:0] <= sector_byte;
            9'd3 : file_len[15:8] <= sector_byte;
            9'd4 : file_len[23:16] <= sector_byte;
            9'd5 : file_len[31:24] <= sector_byte;
            9'd10: pixel_offset[7:0] <= sector_byte;
            9'd11: pixel_offset[15:8] <= sector_byte;
            9'd12: pixel_offset[23:16] <= sector_byte;
            9'd13: pixel_offset[31:24] <= sector_byte;
            9'd14: dib_size[7:0] <= sector_byte;
            9'd15: dib_size[15:8] <= sector_byte;
            9'd16: dib_size[23:16] <= sector_byte;
            9'd17: dib_size[31:24] <= sector_byte;
            9'd18: width_lo[7:0] <= sector_byte;
            9'd19: begin width_lo[11:8] <= sector_byte[3:0]; w_hi_zero <= (sector_byte[7:4] == 4'h0); end
            9'd20, 9'd21: w_hi_zero <= w_hi_zero && (sector_byte == 8'h00);
            9'd22: height_lo[7:0] <= sector_byte;
            9'd23: begin
                height_lo[11:8] <= sector_byte[3:0];
                h_hi_zero <= (sector_byte[7:4] == 4'h0);
                h_hi_ones <= (sector_byte[7:4] == 4'hf);
            end
            9'd24: begin
                h_hi_zero <= h_hi_zero && (sector_byte == 8'h00);
                h_hi_ones <= h_hi_ones && (sector_byte == 8'hff);
            end
            9'd25: begin
                h_hi_zero <= h_hi_zero && (sector_byte == 8'h00);
                h_hi_ones <= h_hi_ones && (sector_byte == 8'hff);
                h_sign <= sector_byte[7];
            end
            9'd26: planes_one <= (sector_byte == 8'd1);
            9'd27: planes_one <= planes_one && (sector_byte == 8'd0);
            9'd28: bits_24 <= (sector_byte == 8'd24);
            9'd29: bits_24 <= bits_24 && (sector_byte == 8'd0);
            9'd30: comp_zero <= (sector_byte == 8'd0);
            9'd31, 9'd32, 9'd33: comp_zero <= comp_zero && (sector_byte == 8'd0);
            default: ;
        endcase
    end
end

// ---------- 像素：文件偏移落在 [pixel_offset, pixel_end) 的字节按 B/G/R 拼装 ----------
// 行尾填充 W mod 4 字节：每行第 W 个像素后进入跳过计数，不产生像素。
reg [1:0]  bmp_byte_idx;
reg [1:0]  pad_left;
reg [11:0] row_col;
reg [24:0] pixel_count;          // 像素数 <= 26 位像素字节数 / 3 < 2^25
wire pixel_byte = (state == ST_LOAD_DATA) && file_valid && !recover_needed &&
                  (file_offset >= pixel_offset) && ({2'd0, file_offset} < pixel_end);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_byte_idx <= 2'd0;
        pad_left <= 2'd0;
        row_col <= 12'd0;
        pixel_count <= 25'd0;
        bmp_data_wr_en <= 1'b0;
        bmp_data <= 24'd0;
    end else if (state != ST_LOAD_DATA) begin
        bmp_byte_idx <= 2'd0;
        pad_left <= 2'd0;
        row_col <= 12'd0;
        pixel_count <= 25'd0;
        bmp_data_wr_en <= 1'b0;
    end else begin
        bmp_data_wr_en <= 1'b0;
        if (pixel_byte) begin
            if (pad_left != 2'd0) begin
                pad_left <= pad_left - 2'd1;
            end else begin
                case (bmp_byte_idx)
                    2'd0: bmp_data[7:0] <= file_byte;
                    2'd1: bmp_data[15:8] <= file_byte;
                    default: begin
                        bmp_data[23:16] <= file_byte;
                        bmp_data_wr_en <= 1'b1;
                        pixel_count <= pixel_count + 25'd1;
                        if (row_col == geo_w - 12'd1) begin
                            row_col <= 12'd0;
                            pad_left <= geo_w[1:0];
                        end else begin
                            row_col <= row_col + 12'd1;
                        end
                    end
                endcase
                bmp_byte_idx <= (bmp_byte_idx == 2'd2) ? 2'd0 : (bmp_byte_idx + 2'd1);
            end
        end
    end
end

wire data_integrity_error = CHECK_PIXEL_INTEGRITY &&
                            ((pixel_count != {1'b0, expected_pixels}) || (bmp_byte_idx != 2'd0) ||
                             (pad_left != 2'd0));

// ---------- 主状态机 ----------
always @(posedge clk or posedge rst) begin
    if (rst) begin
        state <= ST_IDLE;
        write_req <= 1'b0;
        scan_done <= 1'b0;
        scan_found_valid <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total <= 3'd0;
        bmp_error <= ERR_NONE;
        load_error <= 1'b0;
        load_success <= 1'b0;
        fs_scan_start <= 1'b0;
        file_start <= 1'b0;
        hdr_req <= 1'b0;
        hdr_issued <= 1'b0;
        report_idx <= 3'd0;
        sel_cluster <= 32'd0;
        sel_size <= 32'd0;
        sel_ok <= 1'b0;
        cat_valid <= 5'd0;
        cat_spc <= 8'd0;
        cat_fat_lba <= 32'd0;
        cat_data_lba <= 32'd0;
        cat_max_cluster <= 32'd0;
        cat_audio_valid <= 5'd0;
        load_idx_ok <= 1'b0;
        cat_wait <= 1'b0;
        audio_pending <= 1'b0;
        audio_pending_idx <= 3'd0;
        audio_done <= 1'b0;
        audio_error <= 8'd0;
        streamer_abort <= 1'b0;
        stream_script <= 1'b0;
        script_pending <= 1'b0;
        script_pending_key <= 7'd0;
        script_done <= 1'b0;
        script_error <= 8'd0;
    end else begin
        scan_found_valid <= 1'b0;
        load_error <= 1'b0;
        load_success <= 1'b0;
        fs_scan_start <= 1'b0;
        file_start <= 1'b0;
        hdr_req <= 1'b0;
        audio_done <= 1'b0;
        script_done <= 1'b0;
        streamer_abort <= 1'b0;
        if (ENABLE_SCRIPTS && script_start) begin
            script_pending <= 1'b1;
            script_pending_key <= script_key;
        end
        if (script_stop)
            script_pending <= 1'b0;
        if (audio_start) begin
            audio_pending <= 1'b1;
            audio_pending_idx <= audio_file_idx;
        end
        if (audio_stop)
            audio_pending <= 1'b0;
        if (recover_needed) begin
            state <= ST_RECOVER;
            write_req <= 1'b0;
            bmp_error <= ERR_TIMEOUT;
            // 扫描也上报错误码，但不能伪造单张加载结果。
            load_error <= load_phase;
            if (state == ST_SCAN)
                scan_done <= 1'b1;
        end else if (state == ST_RECOVER) begin
            write_req <= 1'b0;
            if (sd_recover_ack && sd_init_done)
                state <= ST_IDLE;
        end else if (!sd_init_done) begin
            if (state == ST_AUDIO && stream_script) begin
                script_done <= 1'b1;
                script_error <= 8'h10;
            end else if (state == ST_AUDIO) begin
                audio_done <= 1'b1;
                audio_error <= 8'h10;
            end
            state <= ST_IDLE;
            write_req <= 1'b0;
            scan_done <= 1'b0;
            scan_found_sector <= 32'd0;
            scan_found_total <= 3'd0;
        end else begin
            case (state)
                ST_IDLE: begin
                    write_req <= 1'b0;
                    if (scan_start) begin
                        scan_done <= 1'b0;
                        scan_found_total <= 3'd0;
                        cat_valid <= 5'd0;
                        // 目标数为 0 时照常扫描、上报 0 个；不另设分支，TD 会把常量折叠后的分支连同整个状态机删掉。
                        fs_scan_start <= 1'b1;
                        state <= ST_SCAN;
                    end else if (load_start) begin
                        // 目录项在 ST_LOAD_HDR 开头经目录表读出（cat_wait）
                        bmp_error <= ERR_NONE;
                        load_idx_ok <= (load_sector < 32'd5) && cat_valid[load_sector[2:0]];
                        cat_wait <= 1'b1;
                        hdr_issued <= 1'b0;
                        state <= ST_LOAD_HDR;
                    end else if (audio_pending && audio_cat_ready && !audio_stop) begin
                        audio_pending <= 1'b0;
                        if (audio_resource_ok) begin
                            sel_cluster <= cat_cluster_d;
                            sel_size <= cat_size_d;
                            file_start <= 1'b1;
                            stream_script <= 1'b0;
                            state <= ST_AUDIO;
                        end else begin
                            audio_done <= 1'b1;
                            audio_error <= AUDIO_ERR_MISSING;
                        end
                    end else if (ENABLE_SCRIPTS && script_pending && script_ok_ready && !script_stop) begin
                        script_pending <= 1'b0;
                        if (script_ok_q) begin
                            sel_cluster <= script_cluster_sel;
                            sel_size <= SCRIPT_FILE_SIZE;
                            file_start <= 1'b1;
                            stream_script <= 1'b1;
                            state <= ST_AUDIO;
                        end else begin
                            script_done <= 1'b1;
                            script_error <= AUDIO_ERR_MISSING;
                        end
                    end
                end
                ST_SCAN: if (fs_scan_done) begin
                    // 缺文件时扫描器报错，但已匹配的资源仍有效，按实际数量上报。
                    cat_valid <= fs_valid;
                    cat_spc <= fs_spc;
                    cat_fat_lba <= fs_fat_lba;
                    cat_data_lba <= fs_data_lba;
                    cat_max_cluster <= fs_max_cluster;
                    cat_audio_valid <= fs_audio_valid;
                    report_idx <= 3'd0;
                    state <= ST_REPORT;
                end
                ST_REPORT: begin
                    if (cat_valid[report_idx] && (scan_found_total < scan_target_count)) begin
                        scan_found_valid <= 1'b1;
                        scan_found_sector <= {29'd0, report_idx};
                        scan_found_total <= scan_found_total + 3'd1;
                    end
                    if (report_idx == 3'd4) begin
                        scan_done <= 1'b1;
                        state <= ST_IDLE;
                    end else begin
                        report_idx <= report_idx + 3'd1;
                    end
                end
                ST_LOAD_HDR: begin
                    if (cat_wait) begin
                        // 读口在 LOAD_HDR 中保持图片地址；标签到位即为该序号的目录项
                        if (cat_ok_tag == cat_raddr) begin
                            sel_cluster <= cat_cluster_d;
                            sel_size <= cat_size_d;
                            sel_ok <= load_idx_ok && cat_cl_ok;
                            cat_wait <= 1'b0;
                        end
                    end else if (!sel_ok) begin
                        bmp_error <= ERR_HEADER;
                        load_error <= 1'b1;
                        state <= ST_IDLE;
                    end else if (!hdr_issued) begin
                        if (!sector_busy) begin
                            hdr_req <= 1'b1;
                            hdr_issued <= 1'b1;
                        end
                    end else if (sector_done) begin
                        if (header_match) begin
                            write_req <= 1'b1;
                            state <= ST_LOAD_WAIT;
                        end else begin
                            bmp_error <= (header_format_match && pixel_past_end) ? ERR_TRUNCATED : ERR_HEADER;
                            load_error <= 1'b1;
                            state <= ST_IDLE;
                        end
                    end
                end
                ST_LOAD_WAIT: if (write_req_ack) begin
                    write_req <= 1'b0;
                    file_start <= 1'b1;
                    state <= ST_LOAD_DATA;
                end
                ST_LOAD_DATA: if (file_done) begin
                    if ((file_error != 8'd0) || data_integrity_error) begin
                        bmp_error <= ERR_TRUNCATED;
                        load_error <= 1'b1;
                    end else begin
                        load_success <= 1'b1;
                    end
                    state <= ST_IDLE;
                end
                // 中止须等扇区口空闲且无刚发出的请求脉冲，复位后流读取器不会留下半个事务。
                ST_AUDIO: if (file_done) begin
                    if (stream_script) begin
                        script_done <= 1'b1;
                        script_error <= file_error;
                    end else begin
                        audio_done <= 1'b1;
                        audio_error <= file_error;
                    end
                    state <= ST_IDLE;
                end else if (stream_stop && !sector_busy && !file_sector_req) begin
                    streamer_abort <= 1'b1;
                    state <= ST_IDLE;
                end
                default: begin
                    state <= ST_IDLE;
                    write_req <= 1'b0;
                end
            endcase
        end
    end
end

// 最后一次扫描的错误码，在扫描完成时锁存，仅全局复位清除。
reg [7:0] diag_fs_error;
reg [3:0] diag_sector_count;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        diag_fs_error <= 8'd0;
        diag_sector_count <= 4'd0;
    end else begin
        if (fs_scan_done)
            diag_fs_error <= fs_error;
        if (sd_sec_read_end)
            diag_sector_count <= diag_sector_count + 4'd1;
    end
end
assign diag_fs = {diag_fs_error, cat_valid[3:0], 1'b0, state, diag_sector_count};

endmodule
