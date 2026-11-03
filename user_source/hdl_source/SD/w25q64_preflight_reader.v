// 复用第五讲 w25q64_preflight_reader；接受条件与参考一致。
// start：空闲时单拍请求，忙时丢弃；done 单拍，结果保持到下次请求或复位。
// 不增加 POR / PLL 启动计数器；调用方提供本时钟域同步释放的复位。
// WAKE_CYCLES 仅为 AB 命令恢复时间，沿用参考值：50 MHz 下至少 200 拍。
// 仅发送 AB/9F/05/35/15，不修改保护位，不发送写使能、擦除或编程命令。
// 沿用参考的 EF4017 / 三状态寄存器接口；写入集成前须确认实物完整后缀。
// SR2.SUS、SR3.WPS 和 SR3 全 1 仅保留原始诊断，不增加参考之外的拒绝条件。
// 本模块不读取独立块锁，不宣称覆盖所有器件后缀的保护机制。
// accepted 仅表示本次采样符合预检条件，不是永久写许可；后续写控制器
// 仍须检查实时状态、WEL、允许地址窗口、超时和回读，不能绕过这些检查。
// 错误码：0 成功，1 ID，2 BUSY/WEL，3 BP，4 CMP，F 控制器非法状态。
// 失败不自动重试或解除保护。
`timescale 1ns/1ps

// 身份及保护状态预检；物理引脚所有权由持久化服务切换。
module w25q64_preflight_reader #(
    parameter integer SPI_CLK_DIV = 4,
    parameter integer WAKE_CYCLES = 200,
    parameter integer CS_HIGH_CYCLES = 3,
    parameter [23:0] EXPECTED_JEDEC_ID = 24'hef4017
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire        flash_miso,
    output reg         flash_cs_n,
    output wire        flash_sclk,
    output wire        flash_mosi,
    output wire        flash_wp_n,
    output wire        flash_hold_n,
    output reg         busy,
    output reg         done,
    output reg         accepted,
    output reg         error,
    output reg  [3:0]  error_code,
    output reg  [23:0] jedec_id,
    output reg  [7:0]  status1,
    output reg  [7:0]  status2,
    output reg  [7:0]  status3
);
    localparam [4:0] ST_IDLE         = 5'd0;
    localparam [4:0] ST_WAKE_ISSUE   = 5'd2;
    localparam [4:0] ST_WAKE_WAIT    = 5'd3;
    localparam [4:0] ST_WAKE_DELAY   = 5'd4;
    localparam [4:0] ST_ID_CMD_ISSUE = 5'd5;
    localparam [4:0] ST_ID_CMD_WAIT  = 5'd6;
    localparam [4:0] ST_ID_DAT_ISSUE = 5'd7;
    localparam [4:0] ST_ID_DAT_WAIT  = 5'd8;
    localparam [4:0] ST_ST_CMD_ISSUE = 5'd9;
    localparam [4:0] ST_ST_CMD_WAIT  = 5'd10;
    localparam [4:0] ST_ST_DAT_ISSUE = 5'd11;
    localparam [4:0] ST_ST_DAT_WAIT  = 5'd12;
    localparam [4:0] ST_CS_GAP       = 5'd13;
    localparam [4:0] ST_COMPLETE     = 5'd14;

    localparam [3:0] ERR_NONE     = 4'd0;
    localparam [3:0] ERR_ID       = 4'd1;
    localparam [3:0] ERR_BUSY_WEL = 4'd2;
    localparam [3:0] ERR_BP       = 4'd3;
    localparam [3:0] ERR_CMP      = 4'd4;

    reg [4:0] state;
    reg [4:0] gap_return_state;
    reg [31:0] delay_count;
    reg [1:0] id_index;
    reg [1:0] status_index;
    reg spi_start;
    reg [7:0] spi_tx_byte;
    wire spi_busy;
    wire spi_done;
    wire [7:0] spi_rx_byte;

    wire preflight_ok = (jedec_id == EXPECTED_JEDEC_ID) &&
                        (status1[1:0] == 2'b00) &&
                        (status1[4:2] == 3'b000) &&
                        !status2[6];

    assign flash_wp_n = 1'b1;
    assign flash_hold_n = 1'b1;

    initial begin
        if (SPI_CLK_DIV < 2 || WAKE_CYCLES < 200 ||
            CS_HIGH_CYCLES < 3) begin
            $display("W25Q64_PREFLIGHT_CONFIG_ERROR invalid timing parameter");
            $finish;
        end
    end

    spi_byte_engine #(.CLK_DIV(SPI_CLK_DIV)) u_spi_byte_engine (
        .clk(clk), .rst_n(rst_n), .start(spi_start), .tx_byte(spi_tx_byte),
        .miso(flash_miso), .busy(spi_busy), .done(spi_done),
        .rx_byte(spi_rx_byte), .sclk(flash_sclk), .mosi(flash_mosi)
    );

    function [7:0] status_command;
        input [1:0] index;
        begin
            case (index)
                2'd0: status_command = 8'h05;
                2'd1: status_command = 8'h35;
                default: status_command = 8'h15;
            endcase
        end
    endfunction

    task begin_gap;
        input [4:0] return_state;
        begin
            flash_cs_n <= 1'b1;
            delay_count <= 32'd0;
            gap_return_state <= return_state;
            state <= ST_CS_GAP;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            gap_return_state <= ST_IDLE;
            delay_count <= 32'd0;
            id_index <= 2'd0;
            status_index <= 2'd0;
            spi_start <= 1'b0;
            spi_tx_byte <= 8'hff;
            flash_cs_n <= 1'b1;
            busy <= 1'b0;
            done <= 1'b0;
            accepted <= 1'b0;
            error <= 1'b0;
            error_code <= ERR_NONE;
            jedec_id <= 24'd0;
            status1 <= 8'd0;
            status2 <= 8'd0;
            status3 <= 8'd0;
        end else begin
            spi_start <= 1'b0;
            done <= 1'b0;
            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    flash_cs_n <= 1'b1;
                    if (start) begin
                        busy <= 1'b1;
                        accepted <= 1'b0;
                        error <= 1'b0;
                        error_code <= ERR_NONE;
                        jedec_id <= 24'd0;
                        status1 <= 8'd0;
                        status2 <= 8'd0;
                        status3 <= 8'd0;
                        delay_count <= 32'd0;
                        state <= ST_WAKE_ISSUE;
                    end
                end
                ST_WAKE_ISSUE: if (!spi_busy) begin
                    flash_cs_n <= 1'b0;
                    spi_tx_byte <= 8'hab;
                    spi_start <= 1'b1;
                    state <= ST_WAKE_WAIT;
                end
                ST_WAKE_WAIT: if (spi_done) begin
                    flash_cs_n <= 1'b1;
                    delay_count <= 32'd0;
                    state <= ST_WAKE_DELAY;
                end
                ST_WAKE_DELAY: begin
                    if (delay_count + 1 >= WAKE_CYCLES) begin
                        delay_count <= 32'd0;
                        state <= ST_ID_CMD_ISSUE;
                    end else delay_count <= delay_count + 1'b1;
                end
                ST_ID_CMD_ISSUE: if (!spi_busy) begin
                    flash_cs_n <= 1'b0;
                    spi_tx_byte <= 8'h9f;
                    spi_start <= 1'b1;
                    state <= ST_ID_CMD_WAIT;
                end
                ST_ID_CMD_WAIT: if (spi_done) begin
                    id_index <= 2'd0;
                    state <= ST_ID_DAT_ISSUE;
                end
                ST_ID_DAT_ISSUE: if (!spi_busy) begin
                    spi_tx_byte <= 8'h00;
                    spi_start <= 1'b1;
                    state <= ST_ID_DAT_WAIT;
                end
                ST_ID_DAT_WAIT: if (spi_done) begin
                    case (id_index)
                        2'd0: jedec_id[23:16] <= spi_rx_byte;
                        2'd1: jedec_id[15:8] <= spi_rx_byte;
                        default: jedec_id[7:0] <= spi_rx_byte;
                    endcase
                    if (id_index == 2'd2) begin
                        status_index <= 2'd0;
                        begin_gap(ST_ST_CMD_ISSUE);
                    end else begin
                        id_index <= id_index + 1'b1;
                        state <= ST_ID_DAT_ISSUE;
                    end
                end
                ST_ST_CMD_ISSUE: if (!spi_busy) begin
                    flash_cs_n <= 1'b0;
                    spi_tx_byte <= status_command(status_index);
                    spi_start <= 1'b1;
                    state <= ST_ST_CMD_WAIT;
                end
                ST_ST_CMD_WAIT: if (spi_done)
                    state <= ST_ST_DAT_ISSUE;
                ST_ST_DAT_ISSUE: if (!spi_busy) begin
                    spi_tx_byte <= 8'h00;
                    spi_start <= 1'b1;
                    state <= ST_ST_DAT_WAIT;
                end
                ST_ST_DAT_WAIT: if (spi_done) begin
                    case (status_index)
                        2'd0: status1 <= spi_rx_byte;
                        2'd1: status2 <= spi_rx_byte;
                        default: status3 <= spi_rx_byte;
                    endcase
                    if (status_index == 2'd2)
                        begin_gap(ST_COMPLETE);
                    else begin
                        status_index <= status_index + 1'b1;
                        begin_gap(ST_ST_CMD_ISSUE);
                    end
                end
                ST_CS_GAP: begin
                    flash_cs_n <= 1'b1;
                    if (delay_count + 1 >= CS_HIGH_CYCLES) begin
                        delay_count <= 32'd0;
                        state <= gap_return_state;
                    end else delay_count <= delay_count + 1'b1;
                end
                ST_COMPLETE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    accepted <= preflight_ok;
                    error <= !preflight_ok;
                    if (jedec_id != EXPECTED_JEDEC_ID)
                        error_code <= ERR_ID;
                    else if (status1[1:0] != 2'b00)
                        error_code <= ERR_BUSY_WEL;
                    else if (status1[4:2] != 3'b000)
                        error_code <= ERR_BP;
                    else if (status2[6])
                        error_code <= ERR_CMP;
                    else
                        error_code <= ERR_NONE;
                    state <= ST_IDLE;
                end
                default: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    accepted <= 1'b0;
                    error <= 1'b1;
                    error_code <= 4'hf;
                    flash_cs_n <= 1'b1;
                    state <= ST_IDLE;
                end
            endcase
        end
    end
endmodule
