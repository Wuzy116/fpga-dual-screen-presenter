`timescale 1ns/1ps

// 首张即显示时 SDRAM 读写仲裁（mem_clk 单域）。读优先：显示连续性由 reader FIFO 余量保证。
// 写 burst 只在 reader 空闲（无进行中 burst、在途读数据已全部返回）且 FIFO 余量不低于
// READ_RESERVE 时插入；reader 未在读帧（消隐期/播放前）则写不受余量限制。
// 每次授权只放行一个写 burst，写完留 QUIET_CYCLES 空拍后才交还 reader。
// hold 只阻止发起新 burst，已开始的 burst 总能按原长度发完。
module media_sdram_arbiter #(
    parameter integer FIFO_LEVEL_W = 9,
    parameter integer READ_RESERVE = 256,
    parameter integer QUIET_CYCLES = 4
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    wr_request,
    input  wire                    wr_idle,
    input  wire                    rd_busy,
    input  wire                    rd_idle,
    input  wire [FIFO_LEVEL_W-1:0] rd_level,
    output wire                    wr_hold,
    output wire                    rd_hold,
    output reg  [31:0]             write_grants
);
    localparam [1:0] ST_READ = 2'd0, ST_GRANT = 2'd1, ST_WRITE = 2'd2, ST_QUIET = 2'd3;
    reg [1:0] state;
    reg [3:0] quiet_count;
    wire reserve_ok = !rd_busy || (rd_level >= READ_RESERVE);
    wire want_write = wr_request && rd_idle && reserve_ok;

    // 同拍决定写授权时一并挡住 reader 本拍的 burst 发起
    assign rd_hold = (state != ST_READ) || want_write;
    assign wr_hold = (state != ST_GRANT);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_READ;
            quiet_count <= 4'd0;
            write_grants <= 32'd0;
        end else begin
            case (state)
                ST_READ: if (want_write) state <= ST_GRANT;
                // loader 在本态看到 hold=0 的当拍发起 burst，下一拍 wr_idle 变低
                ST_GRANT: begin
                    if (!wr_idle) begin
                        state <= ST_WRITE;
                        write_grants <= write_grants + 32'd1;
                    end else if (!wr_request) begin
                        state <= ST_READ;
                    end
                end
                ST_WRITE: if (wr_idle) begin
                    state <= ST_QUIET;
                    quiet_count <= 4'd0;
                end
                default: begin
                    if (quiet_count == QUIET_CYCLES - 1)
                        state <= ST_READ;
                    else
                        quiet_count <= quiet_count + 4'd1;
                end
            endcase
        end
    end
endmodule
