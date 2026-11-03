module bmp_read #(
    // 上层接入显式结果/失败保护后启用；独立测试可先验证新逻辑。
    parameter CHECK_PIXEL_INTEGRITY = 0,
    parameter ENABLE_TIMEOUT = 0,
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer TIMEOUT_MS = 500
)(
    input                       clk,
    input                       rst,
    output                      ready,

    // 上电扫描：从 scan_start_sector 开始，顺序寻找前 scan_target_count 张 BMP
    input                       scan_start,
    input  [31:0]               scan_start_sector,
    input  [31:0]               scan_max_sector,
    input  [2:0]                scan_target_count,
    output reg                  scan_done,
    output reg                  scan_found_valid,
    output reg [31:0]           scan_found_sector,
    output reg [2:0]            scan_found_total,

    // 按指定扇区加载一张图到 SDRAM
    input                       load_start,
    input  [31:0]               load_sector,

    input                       sd_init_done,
    // 配置尺寸在扫描/加载事务期间保持稳定；生产顶层固定为 640x480。
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,

    output reg                  write_req,
    input                       write_req_ack,

    output reg                  sd_sec_read,
    output reg [31:0]           sd_sec_read_addr,
    input  [7:0]                sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,

    output reg                  bmp_data_wr_en,
    output reg [23:0]           bmp_data,

    // 加载结果属于 clk 域；脉冲单拍，错误码保持至下一次加载或复位。
    output reg [2:0]            bmp_error,
    output reg                  load_error,
    output reg                  load_success,
    // 同属 clk 域。超时后保持请求，只有底层复位/重初始化确认后才能再加载。
    output                      sd_recover_req,
    input                       sd_recover_ack
);

localparam ST_IDLE      = 3'd0;
localparam ST_SCAN      = 3'd1;
localparam ST_LOAD_HDR  = 3'd2;
localparam ST_LOAD_WAIT = 3'd3;
localparam ST_LOAD_DATA = 3'd4;
localparam ST_RECOVER   = 3'd5;

localparam ERR_NONE      = 3'd0;
localparam ERR_HEADER    = 3'd1;
localparam ERR_TIMEOUT   = 3'd2;
localparam ERR_TRUNCATED = 3'd3;

reg [2:0]  state;
reg [9:0]  rd_cnt;

reg [7:0]  header_0;
reg [7:0]  header_1;
reg [31:0] file_len;
reg [31:0] pixel_offset;
reg [31:0] dib_size;
reg [31:0] width;
reg [31:0] height;
reg [15:0] planes;
reg [15:0] bit_count;
reg [31:0] compression;

reg [31:0] scan_sector;
reg [31:0] load_sector_latched;
reg [32:0] bmp_len_cnt;
reg [1:0]  bmp_byte_idx;
reg [32:0] pixel_count;
reg [9:0] data_sector_count;
localparam [63:0] TIMEOUT_RAW = 64'd1 * (CLK_FREQ_HZ / 1000) * TIMEOUT_MS;
localparam [63:0] TIMEOUT_CYCLES = (TIMEOUT_RAW > 0) ? TIMEOUT_RAW : 64'd1;
localparam integer TIMEOUT_BITS = (TIMEOUT_CYCLES <= 1) ? 1 : $clog2(TIMEOUT_CYCLES);
reg [TIMEOUT_BITS-1:0] timeout_count;
wire read_phase = (state == ST_SCAN) || (state == ST_LOAD_HDR) || (state == ST_LOAD_DATA);
wire load_phase = (state == ST_LOAD_HDR) || (state == ST_LOAD_WAIT) || (state == ST_LOAD_DATA);
wire timed_phase = read_phase || (state == ST_LOAD_WAIT);
wire phase_complete = (read_phase && sd_sec_read_end) || ((state == ST_LOAD_WAIT) && write_req_ack);
// 合法结束/ACK 与期限同拍时，优先接受完成；初始化丢失始终按失败处理。
wire recover_needed = ENABLE_TIMEOUT && timed_phase &&
                      (!sd_init_done || (!phase_complete && (timeout_count >= TIMEOUT_CYCLES - 1)));
assign sd_recover_req = (state == ST_RECOVER);
// synthesis translate_off
initial begin
    if (ENABLE_TIMEOUT && (CLK_FREQ_HZ < 1000 || (CLK_FREQ_HZ % 1000) != 0 ||
        TIMEOUT_MS < 1 || TIMEOUT_RAW > 64'd2147483647)) begin
        $display("MEDIA_CONFIG_ERROR bmp %m: invalid timeout clock/timing or cycle-count overflow");
        $finish;
    end
end
// synthesis translate_on
// 按扇区/写应答计时，字节 valid 不刷新期限，防止持续零星字节拖住事务。
always @(posedge clk or posedge rst) begin
    if (rst)
        timeout_count <= 0;
    else if (!ENABLE_TIMEOUT || !timed_phase || phase_complete || recover_needed)
        timeout_count <= 0;
    else if (timeout_count < TIMEOUT_CYCLES - 1)
        timeout_count <= timeout_count + 1'b1;
end

wire header_match;
wire header_format_match;
wire header_structure_match;
wire header_extent_match;
wire bmp_data_valid;
reg [31:0] expected_pixels;
wire [33:0] pixel_bytes;
reg [33:0] pixel_end;
wire [32:0] bmp_len_next;
wire [31:0] header_sector;
wire [33:0] last_pixel_sector;
wire [31:0] file_sector_count;
wire [32:0] next_scan_sector_if_match;
wire [32:0] next_scan_sector_if_miss;
wire pixel_emit = (state == ST_LOAD_DATA) && bmp_data_valid && (bmp_byte_idx == 2'd2);
wire [32:0] pixel_count_next = pixel_count + (pixel_emit ? 33'd1 : 33'd0);
wire [10:0] data_sector_next = {1'b0, data_sector_count} +
                              (sd_sec_read_data_valid ? 11'd1 : 11'd0);
wire [1:0] byte_idx_next = !bmp_data_valid ? bmp_byte_idx :
                          ((bmp_byte_idx == 2'd2) ? 2'd0 : bmp_byte_idx + 2'd1);
wire pixels_finished = ({1'b0, bmp_len_next} >= pixel_end);
wire data_integrity_error = CHECK_PIXEL_INTEGRITY &&
                           ((data_sector_next != 11'd512) ||
                            (pixels_finished && ((pixel_count_next != {1'b0, expected_pixels}) ||
                                                 (byte_idx_next != 2'd0))));

assign ready = (state == ST_IDLE);
// 扫描按文件自身尺寸验证长度；加载仍按配置尺寸计数。共用一个 16x16 乘法表达式。
// 扫描只信任正的 16 位尺寸，完整字段范围由 header_structure_match 检查。
wire [15:0] count_width = (state == ST_SCAN) ? width[15:0] : bmp_width;
wire [15:0] count_height = (state == ST_SCAN) ? height[15:0] : bmp_height;
// 将乘法与后续 34 位范围运算分拍，避免状态选择 -> 乘法 -> 比较的长组合路径。
// 扫描尺寸最晚在头字节 25 收齐；完整 512 字节头扇区结束前此级已稳定。
// 加载配置尺寸保持不变，头扇区/写应答期间也已稳定；不增加握手或结果延迟。
always @(posedge clk or posedge rst) begin
    if (rst)
        expected_pixels <= 32'd0;
    else
        expected_pixels <= {16'd0, count_width} * {16'd0, count_height};
end
assign pixel_bytes = {2'd0, expected_pixels} + ({2'd0, expected_pixels} << 1);
// 再将像素终点与后续绝对扇区/范围判定分拍，保留 34 位防止溢出截断。
// offset 在头字节 13、尺寸在字节 25 收齐；完整 512 字节头结束前已稳定。
// 加载配置尺寸在事务内保持不变；短头仍由结构检查拒绝，不增加结果延迟。
always @(posedge clk or posedge rst) begin
    if (rst)
        pixel_end <= 34'd0;
    else
        pixel_end <= {2'd0, pixel_offset} + pixel_bytes;
end
// 包含本拍字节；末字节和扇区结束同拍时，完成判断不能使用旧计数。
assign bmp_len_next = bmp_len_cnt + (sd_sec_read_data_valid ? 33'd1 : 33'd0);
assign header_sector = (state == ST_SCAN) ? scan_sector : load_sector_latched;
// 像素区最后一个字节对应的绝对扇区，禁止加载时地址回绕到卡首部。
assign last_pixel_sector = {2'd0, header_sector} + ((pixel_end - 34'd1) >> 9);
// 本轮只接受 40 字节 BITMAPINFOHEADER、正高度、24 位无压缩 BMP。
// 必须收到完整头扇区，避免短读沿用上一张图片的字段；兼容末字节与结束同拍。
assign header_structure_match = (header_0 == "B") &&
                      (header_1 == "M") &&
                      (((rd_cnt == 10'd512) && !sd_sec_read_data_valid) ||
                       ((rd_cnt == 10'd511) && sd_sec_read_data_valid)) &&
                      (dib_size == 32'd40) &&
                      (planes == 16'd1) &&
                      (width != 32'd0) && (height != 32'd0) &&
                      (width[31:16] == 16'd0) && (height[31:16] == 16'd0) &&
                      // 现有数据通路不跳过行填充；只接受无需 padding 的宽度。
                      (width[1:0] == 2'd0) &&
                      (pixel_offset >= 32'd54) &&
                      (bit_count    == 16'd24) &&
                      (compression  == 32'd0);
assign header_format_match = header_structure_match &&
                             (width == {16'd0, bmp_width}) && (height == {16'd0, bmp_height});
assign header_extent_match = header_structure_match &&
                      (pixel_offset < file_len) &&
                      (pixel_end <= {2'd0, file_len}) &&
                      (last_pixel_sector[33:32] == 2'd0);
assign header_match = header_format_match && header_extent_match;
assign bmp_data_valid = (sd_sec_read_data_valid == 1'b1) && !recover_needed &&
                        (!CHECK_PIXEL_INTEGRITY || (data_sector_count < 10'd512)) &&
                        (bmp_len_cnt >= {1'b0, pixel_offset}) &&
                        ({1'b0, bmp_len_cnt} < pixel_end);
// 商加余数标记，避免 file_len + 511 在 32 位上界回绕。
assign file_sector_count = (file_len == 32'd0) ? 32'd1 :
                           ((file_len >> 9) + ((|file_len[8:0]) ? 32'd1 : 32'd0));
assign next_scan_sector_if_match = {1'b0, scan_sector} + {1'b0, file_sector_count};
// 分辨率不匹配但结构/长度自洽的 BMP 可整文件跳过；不可信头仍逐扇区查找。
assign next_scan_sector_if_miss = header_extent_match ? next_scan_sector_if_match :
                                 ({1'b0, scan_sector} + 33'd1);

// 成功表示 BMP 源端完成，不代表 SDRAM 已完成写入；上层需同时等待两者。
always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_error    <= ERR_NONE;
        load_error   <= 1'b0;
        load_success <= 1'b0;
    end else begin
        load_error   <= 1'b0;
        load_success <= 1'b0;
        if (recover_needed) begin
            bmp_error <= ERR_TIMEOUT;
            // 扫描也上报错误码，但不能伪造单张加载结果。
            load_error <= load_phase;
        end else if (sd_init_done) begin
            // 与状态机相同：扫描优先，只有实际接受的加载才清除错误码。
            if ((state == ST_IDLE) && !scan_start && load_start) begin
                bmp_error <= ERR_NONE;
            end else if ((state == ST_LOAD_HDR) && sd_sec_read_end && !header_match) begin
                bmp_error <= (header_format_match && (pixel_end > {2'd0, file_len})) ?
                             ERR_TRUNCATED : ERR_HEADER;
                load_error <= 1'b1;
            end else if ((state == ST_LOAD_DATA) && sd_sec_read_end && data_integrity_error) begin
                bmp_error <= ERR_TRUNCATED;
                load_error <= 1'b1;
            end else if ((state == ST_LOAD_DATA) && sd_sec_read_end && pixels_finished) begin
                load_success <= 1'b1;
            end
        end
    end
end

// 计数与产生 bmp_data_wr_en 的条件一致；next 值包括结束同拍生成的最后像素。
always @(posedge clk or posedge rst) begin
    if (rst) begin
        pixel_count <= 33'd0;
        data_sector_count <= 10'd0;
    end else if (state != ST_LOAD_DATA) begin
        pixel_count <= 33'd0;
        data_sector_count <= 10'd0;
    end else begin
        pixel_count <= pixel_count_next;
        if (sd_sec_read_end)
            data_sector_count <= 10'd0;
        else if (sd_sec_read_data_valid && data_sector_count < 10'd513)
            data_sector_count <= data_sector_count + 10'd1;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rd_cnt <= 10'd0;
    end else if ((state == ST_SCAN) || (state == ST_LOAD_HDR)) begin
        if (sd_sec_read_end)
            rd_cnt <= 10'd0;
        // 超过一个扇区后停在 513，不能回绕后再次看起来像合法头。
        else if (sd_sec_read_data_valid && (rd_cnt < 10'd513))
            rd_cnt <= rd_cnt + 10'd1;
    end else begin
        rd_cnt <= 10'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        header_0     <= 8'd0;
        header_1     <= 8'd0;
        file_len     <= 32'd0;
        pixel_offset <= 32'd54;
        dib_size     <= 32'd0;
        width        <= 32'd0;
        height       <= 32'd0;
        planes       <= 16'd0;
        bit_count    <= 16'd0;
        compression  <= 32'd0;
    end else if (((state == ST_SCAN) || (state == ST_LOAD_HDR)) && sd_sec_read_data_valid) begin
        case (rd_cnt)
            10'd0 : header_0 <= sd_sec_read_data;
            10'd1 : header_1 <= sd_sec_read_data;

            10'd2 : file_len[7:0] <= sd_sec_read_data;
            10'd3 : file_len[15:8] <= sd_sec_read_data;
            10'd4 : file_len[23:16] <= sd_sec_read_data;
            10'd5 : file_len[31:24] <= sd_sec_read_data;

            10'd10: pixel_offset[7:0] <= sd_sec_read_data;
            10'd11: pixel_offset[15:8] <= sd_sec_read_data;
            10'd12: pixel_offset[23:16] <= sd_sec_read_data;
            10'd13: pixel_offset[31:24] <= sd_sec_read_data;

            10'd14: dib_size[7:0] <= sd_sec_read_data;
            10'd15: dib_size[15:8] <= sd_sec_read_data;
            10'd16: dib_size[23:16] <= sd_sec_read_data;
            10'd17: dib_size[31:24] <= sd_sec_read_data;

            10'd18: width[7:0] <= sd_sec_read_data;
            10'd19: width[15:8] <= sd_sec_read_data;
            10'd20: width[23:16] <= sd_sec_read_data;
            10'd21: width[31:24] <= sd_sec_read_data;

            10'd22: height[7:0] <= sd_sec_read_data;
            10'd23: height[15:8] <= sd_sec_read_data;
            10'd24: height[23:16] <= sd_sec_read_data;
            10'd25: height[31:24] <= sd_sec_read_data;

            10'd26: planes[7:0] <= sd_sec_read_data;
            10'd27: planes[15:8] <= sd_sec_read_data;

            10'd28: bit_count[7:0] <= sd_sec_read_data;
            10'd29: bit_count[15:8] <= sd_sec_read_data;

            10'd30: compression[7:0] <= sd_sec_read_data;
            10'd31: compression[15:8] <= sd_sec_read_data;
            10'd32: compression[23:16] <= sd_sec_read_data;
            10'd33: compression[31:24] <= sd_sec_read_data;
            default: ;
        endcase
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_len_cnt <= 33'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (sd_sec_read_data_valid)
            bmp_len_cnt <= bmp_len_next;
    end else begin
        bmp_len_cnt <= 33'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_byte_idx <= 2'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (bmp_data_valid)
            bmp_byte_idx <= (bmp_byte_idx == 2'd2) ? 2'd0 : (bmp_byte_idx + 2'd1);
    end else begin
        bmp_byte_idx <= 2'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_data_wr_en <= 1'b0;
        bmp_data       <= 24'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (bmp_data_valid) begin
            case (bmp_byte_idx)
                2'd0: begin
                    bmp_data_wr_en <= 1'b0;
                    bmp_data[7:0]  <= sd_sec_read_data;
                end
                2'd1: begin
                    bmp_data_wr_en <= 1'b0;
                    bmp_data[15:8] <= sd_sec_read_data;
                end
                2'd2: begin
                    bmp_data_wr_en  <= 1'b1;
                    bmp_data[23:16] <= sd_sec_read_data;
                end
                default: begin
                    bmp_data_wr_en <= 1'b0;
                end
            endcase
        end else begin
            bmp_data_wr_en <= 1'b0;
        end
    end else begin
        bmp_data_wr_en <= 1'b0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state             <= ST_IDLE;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
    end else if (recover_needed) begin
        state <= ST_RECOVER;
        sd_sec_read <= 1'b0;
        write_req <= 1'b0;
        scan_found_valid <= 1'b0;
        if (state == ST_SCAN)
            scan_done <= 1'b1; // 扫描有限结束，已找到的目录交由上层保留。
    end else if (state == ST_RECOVER) begin
        sd_sec_read <= 1'b0;
        write_req <= 1'b0;
        scan_found_valid <= 1'b0;
        if (sd_recover_ack && sd_init_done)
            state <= ST_IDLE;
    end else if (!sd_init_done) begin
        state             <= ST_IDLE;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
    end else begin
        scan_found_valid <= 1'b0;

        case (state)
            ST_IDLE: begin
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;

                if (scan_start) begin
                    scan_done        <= 1'b0;
                    scan_found_total <= 3'd0;
                    scan_sector      <= scan_start_sector;
                    sd_sec_read_addr <= scan_start_sector;
                    if ((scan_target_count == 3'd0) || (scan_start_sector > scan_max_sector)) begin
                        scan_done <= 1'b1;
                    end else begin
                        state <= ST_SCAN;
                    end
                end else if (load_start) begin
                    load_sector_latched <= load_sector;
                    sd_sec_read_addr    <= load_sector;
                    state               <= ST_LOAD_HDR;
                end
            end

            ST_SCAN: begin
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;

                    if (header_match) begin
                        scan_found_valid  <= 1'b1;
                        scan_found_sector <= scan_sector;
                        scan_found_total  <= scan_found_total + 3'd1;

                        if ((scan_found_total + 3'd1 >= scan_target_count) ||
                            (next_scan_sector_if_match > {1'b0, scan_max_sector})) begin
                            scan_done        <= 1'b1;
                            state            <= ST_IDLE;
                        end else begin
                            sd_sec_read_addr <= next_scan_sector_if_match[31:0];
                            scan_sector      <= next_scan_sector_if_match[31:0];
                        end
                    end else begin
                        if (next_scan_sector_if_miss > {1'b0, scan_max_sector}) begin
                            scan_done <= 1'b1;
                            state     <= ST_IDLE;
                        end else begin
                            sd_sec_read_addr <= next_scan_sector_if_miss[31:0];
                            scan_sector      <= next_scan_sector_if_miss[31:0];
                        end
                    end
                end
            end

            ST_LOAD_HDR: begin
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (header_match) begin
                        write_req        <= 1'b1;
                        sd_sec_read_addr <= load_sector_latched;
                        state            <= ST_LOAD_WAIT;
                    end else begin
                        state <= ST_IDLE;
                    end
                end
            end

            ST_LOAD_WAIT: begin
                if (write_req_ack) begin
                    write_req <= 1'b0;
                    state     <= ST_LOAD_DATA;
                end
            end

            ST_LOAD_DATA: begin
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    // 像素已齐后只等当前扇区收尾，不再读取文件尾部附加数据。
                    if (data_integrity_error || pixels_finished) begin
                        state <= ST_IDLE;
                    end else begin
                        sd_sec_read_addr <= sd_sec_read_addr + 32'd1;
                    end
                end
            end

            default: begin
                state       <= ST_IDLE;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;
            end
        endcase
    end
end

endmodule
