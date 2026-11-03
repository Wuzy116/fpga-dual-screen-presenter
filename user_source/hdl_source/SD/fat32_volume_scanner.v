`timescale 1ns/1ps

// D19：背景 PIC1~5.BMP、音乐 MUS1~5.PCM（5 个资源槽）。
// ENABLE_SCRIPTS=1：另外识别讲稿 SnPmm.BMP（n=1~5，mm=00~15，00 为节总览页，长度须为 SCRIPT_FILE_SIZE），每个合格目录项
// 在其第 31 字节后输出一拍 script_wr（键 {n-1[2:0], mm[3:0]}、首簇号）；此时扫完整个根目录首簇，不因 PIC/MUS 齐全提前结束。
// 目录项（首簇号 + 文件长度）不在本模块保存：每个匹配的 PIC/MUS 目录项在第 31 字节后输出一拍 cat_wr，
// 地址 {是音乐, 序号}，由使用方写入自己的目录表；resource_valid/audio_valid 照常保持。
module fat32_volume_scanner #(
    parameter ENABLE_SCRIPTS = 0,
    parameter [31:0] SCRIPT_FILE_SIZE = 32'd38462
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        scan_start,
    output wire        scan_busy,
    output reg         scan_done,
    output reg  [7:0]  fs_error,
    output reg  [31:0] partition_lba,
    output reg  [7:0]  sectors_per_cluster,
    output reg  [31:0] fat_start_lba,
    output reg  [31:0] data_start_lba,
    output reg  [31:0] max_cluster,
    output reg  [4:0]  resource_valid,
    // 可选音频资源 MUS1~5.PCM；缺失不报错，fs_error 只反映 PIC1~5。
    output reg  [4:0]  audio_valid,
    output reg         cat_wr,
    output reg  [3:0]  cat_wr_addr,         // {是音乐, 序号 0..4}
    output reg  [31:0] cat_wr_cluster,
    output reg  [31:0] cat_wr_size,
    output reg         script_wr,
    output reg  [6:0]  script_key,
    output reg  [31:0] script_cluster,
    output reg         sector_req,
    output reg  [31:0] sector_lba,
    input  wire        sector_busy,
    input  wire        sector_valid,
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_byte_index,
    input  wire        sector_done,
    input  wire [7:0]  sector_error
);

    localparam ERR_NONE            = 8'h00;
    localparam ERR_SECTOR          = 8'h10;
    localparam ERR_BOOT_SIGNATURE  = 8'h20;
    localparam ERR_UNSUPPORTED_BPB = 8'h21;
    localparam ERR_RESOURCE_MISSING= 8'h22;

    localparam ST_IDLE       = 4'd0;
    localparam ST_READ0_REQ  = 4'd1;
    localparam ST_READ0_WAIT = 4'd2;
    localparam ST_BOOT_PARSE = 4'd3;
    localparam ST_BOOT_REQ   = 4'd4;
    localparam ST_BOOT_WAIT  = 4'd5;
    localparam ST_ROOT_REQ   = 4'd6;
    localparam ST_ROOT_WAIT  = 4'd7;
    localparam ST_DIR_SCAN   = 4'd8;
    localparam ST_FINISH     = 4'd9;
    localparam ST_BOOT_LAYOUT= 4'd10;
    localparam ST_BOOT_ROOT  = 4'd11;

    reg [3:0] state;
    reg [7:0] sector_buffer [0:511];
    reg [4:0] directory_entry_index;
    reg [31:0] root_cluster;
    reg [31:0] total_sectors;
    reg [31:0] fat_sectors;
    reg [7:0] fat_count;
    reg [15:0] reserved_sectors;
    reg [31:0] root_lba;
    reg [31:0] data_sector_count;
    reg [31:0] fat_span;
    reg [2:0] sectors_per_cluster_shift;
    reg [7:0] dir_name0;
    reg [7:0] dir_name1;
    reg [7:0] dir_name2;
    reg [7:0] dir_name3;
    reg [7:0] dir_name4;
    reg [7:0] dir_name5;
    reg [7:0] dir_name6;
    reg [7:0] dir_name7;
    reg [7:0] dir_name8;
    reg [7:0] dir_name9;
    reg [7:0] dir_name10;
    reg       dir_entry_match;
    reg       dir_audio_match;
    reg       dir_script_match;
    reg [6:0] dir_script_key;
    // 页号 00..15 → 0..15（00 为该节总览页，01..15 为讲稿）；其余为 16（不合格）
    wire [4:0] dir_script_page = (dir_name3 == "0" && dir_name4 >= "0" && dir_name4 <= "9") ? {1'b0, dir_name4[3:0]} :
                                 (dir_name3 == "1" && dir_name4 >= "0" && dir_name4 <= "5") ? {1'b0, dir_name4[3:0]} + 5'd10 :
                                 5'd16;
    reg [2:0] dir_resource_index;
    reg [15:0] dir_cluster_high;
    reg [15:0] dir_cluster_low;
    reg [31:0] dir_file_size;
    // 根目录首簇内的扇区序号；遇到首字节 0x00 的目录项即目录结束，之后的残留项不再匹配。
    reg [7:0] root_sector_index;
    reg       dir_end;

    assign scan_busy = (state != ST_IDLE);

    function [15:0] le16;
        input integer offset;
        begin
            le16 = {sector_buffer[offset+1], sector_buffer[offset]};
        end
    endfunction

    function [31:0] le32;
        input integer offset;
        begin
            le32 = {sector_buffer[offset+3], sector_buffer[offset+2],
                    sector_buffer[offset+1], sector_buffer[offset]};
        end
    endfunction

    function valid_spc;
        input [7:0] value;
        begin
            valid_spc = value != 0 && ((value & (value - 1'b1)) == 0);
        end
    endfunction

    function [2:0] spc_shift;
        input [7:0] value;
        begin
            case (value)
                8'd2:   spc_shift = 3'd1;
                8'd4:   spc_shift = 3'd2;
                8'd8:   spc_shift = 3'd3;
                8'd16:  spc_shift = 3'd4;
                8'd32:  spc_shift = 3'd5;
                8'd64:  spc_shift = 3'd6;
                8'd128: spc_shift = 3'd7;
                default: spc_shift = 3'd0;
            endcase
        end
    endfunction

    task finish_with_error;
        input [7:0] code;
        begin
            fs_error <= code;
            state <= ST_FINISH;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            scan_done <= 1'b0;
            fs_error <= ERR_NONE;
            partition_lba <= 32'd0;
            sectors_per_cluster <= 8'd0;
            fat_start_lba <= 32'd0;
            data_start_lba <= 32'd0;
            max_cluster <= 32'd0;
            resource_valid <= 5'd0;
            audio_valid <= 5'd0;
            cat_wr <= 1'b0;
            cat_wr_addr <= 4'd0;
            cat_wr_cluster <= 32'd0;
            cat_wr_size <= 32'd0;
            sector_req <= 1'b0;
            sector_lba <= 32'd0;
            directory_entry_index <= 5'd0;
            root_cluster <= 32'd0;
            total_sectors <= 32'd0;
            fat_sectors <= 32'd0;
            fat_count <= 8'd0;
            reserved_sectors <= 16'd0;
            root_lba <= 32'd0;
            data_sector_count <= 32'd0;
            fat_span <= 32'd0;
            sectors_per_cluster_shift <= 3'd0;
            dir_name0 <= 8'd0;
            dir_name1 <= 8'd0;
            dir_name2 <= 8'd0;
            dir_name3 <= 8'd0;
            dir_name4 <= 8'd0;
            dir_name5 <= 8'd0;
            dir_name6 <= 8'd0;
            dir_name7 <= 8'd0;
            dir_name8 <= 8'd0;
            dir_name9 <= 8'd0;
            dir_name10 <= 8'd0;
            dir_entry_match <= 1'b0;
            dir_audio_match <= 1'b0;
            dir_script_match <= 1'b0;
            dir_script_key <= 7'd0;
            script_wr <= 1'b0;
            script_key <= 7'd0;
            script_cluster <= 32'd0;
            dir_resource_index <= 3'd7;
            dir_cluster_high <= 16'd0;
            dir_cluster_low <= 16'd0;
            dir_file_size <= 32'd0;
            root_sector_index <= 8'd0;
            dir_end <= 1'b0;
        end else begin
            scan_done <= 1'b0;
            sector_req <= 1'b0;
            script_wr <= 1'b0;
            cat_wr <= 1'b0;
            if (sector_valid && state != ST_ROOT_WAIT)
                sector_buffer[sector_byte_index] <= sector_byte;

            if (sector_valid && state == ST_ROOT_WAIT) begin
                case (sector_byte_index[4:0])
                    5'd0: begin
                        dir_name0 <= sector_byte;
                        dir_entry_match <= 1'b0;
                        dir_audio_match <= 1'b0;
                        dir_script_match <= 1'b0;
                        if (sector_byte == 8'h00)
                            dir_end <= 1'b1;
                    end
                    5'd1:  dir_name1 <= sector_byte;
                    5'd2:  dir_name2 <= sector_byte;
                    5'd3:  dir_name3 <= sector_byte;
                    5'd4:  dir_name4 <= sector_byte;
                    5'd5:  dir_name5 <= sector_byte;
                    5'd6:  dir_name6 <= sector_byte;
                    5'd7:  dir_name7 <= sector_byte;
                    5'd8:  dir_name8 <= sector_byte;
                    5'd9:  dir_name9 <= sector_byte;
                    5'd10: dir_name10 <= sector_byte;
                    5'd11: begin
                        if (sector_byte == 8'h20 &&
                            dir_name0 == "P" && dir_name1 == "I" &&
                            dir_name2 == "C" && dir_name3 >= "1" &&
                            dir_name3 <= "5" && dir_name4 == " " &&
                            dir_name5 == " " && dir_name6 == " " &&
                            dir_name7 == " " && dir_name8 == "B" &&
                            dir_name9 == "M" && dir_name10 == "P") begin
                            dir_entry_match <= 1'b1;
                            dir_resource_index <= dir_name3[2:0] - 3'd1;
                        end
                        if (sector_byte == 8'h20 &&
                            dir_name0 == "M" && dir_name1 == "U" &&
                            dir_name2 == "S" && dir_name3 >= "1" &&
                            dir_name3 <= "5" && dir_name4 == " " &&
                            dir_name5 == " " && dir_name6 == " " &&
                            dir_name7 == " " && dir_name8 == "P" &&
                            dir_name9 == "C" && dir_name10 == "M") begin
                            dir_audio_match <= 1'b1;
                            dir_resource_index <= dir_name3[2:0] - 3'd1;
                        end
                        if (ENABLE_SCRIPTS && sector_byte == 8'h20 &&
                            dir_name0 == "S" && dir_name1 >= "1" && dir_name1 <= "5" &&
                            dir_name2 == "P" && !dir_script_page[4] &&
                            dir_name5 == " " && dir_name6 == " " && dir_name7 == " " &&
                            dir_name8 == "B" && dir_name9 == "M" && dir_name10 == "P") begin
                            dir_script_match <= 1'b1;
                            dir_script_key <= {dir_name1[2:0] - 3'd1, dir_script_page[3:0]};
                        end
                    end
                    5'd20: dir_cluster_high[7:0] <= sector_byte;
                    5'd21: dir_cluster_high[15:8] <= sector_byte;
                    5'd26: dir_cluster_low[7:0] <= sector_byte;
                    5'd27: dir_cluster_low[15:8] <= sector_byte;
                    5'd28: dir_file_size[7:0] <= sector_byte;
                    5'd29: dir_file_size[15:8] <= sector_byte;
                    5'd30: dir_file_size[23:16] <= sector_byte;
                    5'd31: begin
                        dir_file_size[31:24] <= sector_byte;
                        if (ENABLE_SCRIPTS && dir_script_match && !dir_end &&
                            {sector_byte, dir_file_size[23:0]} == SCRIPT_FILE_SIZE) begin
                            script_wr <= 1'b1;
                            script_key <= dir_script_key;
                            script_cluster <= {dir_cluster_high, dir_cluster_low};
                        end
                        // PIC 与 MUS 名字互斥，同一目录项最多命中一种；序号由文件名限定在 0..4
                        if ((dir_entry_match || dir_audio_match) && !dir_end) begin
                            cat_wr <= 1'b1;
                            cat_wr_addr <= {dir_audio_match, dir_resource_index};
                            cat_wr_cluster <= {dir_cluster_high, dir_cluster_low};
                            cat_wr_size <= {sector_byte, dir_file_size[23:0]};
                            if (dir_entry_match) resource_valid[dir_resource_index] <= 1'b1;
                            else                 audio_valid[dir_resource_index] <= 1'b1;
                        end
                    end
                    default: begin end
                endcase
            end

            case (state)
                ST_IDLE: if (scan_start) begin
                    fs_error <= ERR_NONE;
                    partition_lba <= 32'd0;
                    resource_valid <= 5'd0;
                    audio_valid <= 5'd0;
                    state <= ST_READ0_REQ;
                end
                ST_READ0_REQ: if (!sector_busy) begin
                    sector_lba <= 32'd0;
                    sector_req <= 1'b1;
                    state <= ST_READ0_WAIT;
                end
                ST_READ0_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else if (sector_buffer[510] != 8'h55 || sector_buffer[511] != 8'haa)
                        finish_with_error(ERR_BOOT_SIGNATURE);
                    else if (sector_buffer[0] == 8'heb || sector_buffer[0] == 8'he9) begin
                        partition_lba <= 32'd0;
                        state <= ST_BOOT_PARSE;
                    end else if (sector_buffer[450] == 8'h0b || sector_buffer[450] == 8'h0c) begin
                        partition_lba <= le32(454);
                        sector_lba <= le32(454);
                        state <= ST_BOOT_REQ;
                    end else begin
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                    end
                end
                ST_BOOT_REQ: if (!sector_busy) begin
                    sector_req <= 1'b1;
                    state <= ST_BOOT_WAIT;
                end
                ST_BOOT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else if (sector_buffer[510] != 8'h55 || sector_buffer[511] != 8'haa)
                        finish_with_error(ERR_BOOT_SIGNATURE);
                    else
                        state <= ST_BOOT_PARSE;
                end
                ST_BOOT_PARSE: begin
                    if (le16(11) != 16'd512 || !valid_spc(sector_buffer[13]) ||
                        le16(14) == 0 || (sector_buffer[16] != 1 && sector_buffer[16] != 2) ||
                        le16(17) != 0 || le16(22) != 0 || le32(32) == 0 ||
                        le32(36) == 0 || le32(44) < 2) begin
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                    end else begin
                        sectors_per_cluster <= sector_buffer[13];
                        reserved_sectors <= le16(14);
                        fat_count <= sector_buffer[16];
                        total_sectors <= le32(32);
                        fat_sectors <= le32(36);
                        root_cluster <= le32(44);
                        sectors_per_cluster_shift <= spc_shift(sector_buffer[13]);
                        fat_span <= sector_buffer[16] == 2 ? (le32(36) << 1) : le32(36);
                        fat_start_lba <= partition_lba + le16(14);
                        state <= ST_BOOT_LAYOUT;
                    end
                end
                ST_BOOT_LAYOUT: begin
                    data_start_lba <= partition_lba + reserved_sectors + fat_span;
                    data_sector_count <= total_sectors - reserved_sectors - fat_span;
                    state <= ST_BOOT_ROOT;
                end
                ST_BOOT_ROOT: begin
                    max_cluster <= (data_sector_count >> sectors_per_cluster_shift) + 1'b1;
                    resource_valid <= 5'd0;
                    audio_valid <= 5'd0;
                    root_sector_index <= 8'd0;
                    dir_end <= 1'b0;
                    root_lba <= data_start_lba
                                + ((root_cluster - 2) << sectors_per_cluster_shift);
                    sector_lba <= data_start_lba
                                  + ((root_cluster - 2) << sectors_per_cluster_shift);
                    state <= ST_ROOT_REQ;
                end
                ST_ROOT_REQ: if (!sector_busy) begin
                    dir_entry_match <= 1'b0;
                    dir_audio_match <= 1'b0;
                    sector_req <= 1'b1;
                    state <= ST_ROOT_WAIT;
                end
                ST_ROOT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else begin
                        directory_entry_index <= 5'd0;
                        state <= ST_DIR_SCAN;
                    end
                end
                ST_DIR_SCAN: begin
                    // 图片与音频都齐才提前结束（讲稿开启时须扫完整簇）；目录尾/簇尾时 PIC1~4 齐即成功（D19：PIC5 可选），缺音频不报错。
                    if (!ENABLE_SCRIPTS && resource_valid == 5'h1f && audio_valid == 5'h1f)
                        state <= ST_FINISH;
                    else if (dir_end || root_sector_index + 8'd1 >= sectors_per_cluster) begin
                        if (resource_valid[3:0] == 4'hf)
                            state <= ST_FINISH;
                        else
                            finish_with_error(ERR_RESOURCE_MISSING);
                    end else begin
                        root_sector_index <= root_sector_index + 8'd1;
                        sector_lba <= sector_lba + 32'd1;
                        state <= ST_ROOT_REQ;
                    end
                end
                ST_FINISH: begin
                    scan_done <= 1'b1;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
