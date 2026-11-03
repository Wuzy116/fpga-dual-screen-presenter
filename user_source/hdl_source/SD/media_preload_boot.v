// 启动预加载（D19：最多 5 槽）：源端成功与 B2 写排空都完成后才接受一槽，失败不跳图。
// 接口全属于 clk 域；外层负责 CDC。已接 SD 可选分支，生产顶层尚未启用。
// 源端读取超时由 bmp_read 负责；本模块仅在源端成功后计写排空期限。
module media_preload_boot #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer WRITE_FINISH_TIMEOUT_MS = 500,
    parameter integer CANCEL_TIMEOUT_MS = 500
)(
    input wire clk,
    input wire rst,
    input wire storage_ready,
    input wire catalog_ready,
    input wire [2:0] img_found_count,
    input wire bmp_ready,
    input wire bmp_load_success,
    input wire bmp_load_error,
    input wire frame_write_req,
    input wire write_finish_pulse,
    input wire write_cancel_ack,
    output reg load_start_pulse,
    output reg [2:0] load_idx,
    output wire [2:0] write_buf_idx,
    output wire write_cancel_req,
    output wire preload_busy,
    output reg [4:0] image_complete,
    output reg preload_done,
    output reg preload_error,
    output reg [2:0] error_code,
    output reg cancel_ack_timeout,
    output reg cancel_release_timeout
);
localparam [2:0] ERR_NONE = 3'd0, ERR_CATALOG = 3'd1, ERR_BMP = 3'd2,
                 ERR_WRITE_TIMEOUT = 3'd3, ERR_PROTOCOL = 3'd4;
localparam [2:0] ST_IDLE = 3'd0, ST_LOAD = 3'd1, ST_CANCEL = 3'd2,
                 ST_RELEASE = 3'd3, ST_ERROR = 3'd4, ST_DONE = 3'd5;
localparam [63:0] WRITE_RAW = 64'd1 * (CLK_FREQ_HZ / 1000) * WRITE_FINISH_TIMEOUT_MS;
localparam [63:0] WRITE_CYCLES = (WRITE_RAW > 0) ? WRITE_RAW : 64'd1;
localparam integer WRITE_BITS = (WRITE_CYCLES <= 1) ? 1 : $clog2(WRITE_CYCLES);
localparam [63:0] CANCEL_RAW = 64'd1 * (CLK_FREQ_HZ / 1000) * CANCEL_TIMEOUT_MS;
localparam [63:0] CANCEL_CYCLES = (CANCEL_RAW > 0) ? CANCEL_RAW : 64'd1;
localparam integer CANCEL_BITS = (CANCEL_CYCLES <= 1) ? 1 : $clog2(CANCEL_CYCLES);
// synthesis translate_off
initial begin
    if (CLK_FREQ_HZ < 1000 || (CLK_FREQ_HZ % 1000) != 0 ||
        WRITE_FINISH_TIMEOUT_MS < 1 || WRITE_RAW > 64'd2147483647 ||
        CANCEL_TIMEOUT_MS < 1 || CANCEL_RAW > 64'd2147483647) begin
        $display("MEDIA_CONFIG_ERROR preload %m: invalid clock/deadline or cycle-count overflow");
        $finish;
    end
end
// synthesis translate_on
reg [2:0] state;
reg source_done_seen;
reg frame_req_seen;
reg write_done_seen;
reg [WRITE_BITS-1:0] write_count;
reg [CANCEL_BITS-1:0] cancel_count;
assign write_buf_idx = load_idx;
assign write_cancel_req = (state == ST_CANCEL);
assign preload_busy = (state == ST_LOAD) || (state == ST_CANCEL) || (state == ST_RELEASE);
// 不接受启动前或本次写请求尚未被观察到时的陈旧完成脉冲。
wire frame_finished = write_done_seen || (write_finish_pulse && frame_req_seen);
wire write_waiting = (state == ST_LOAD) && source_done_seen && !frame_finished && !bmp_load_error;
wire write_timed_out = write_waiting && (write_count >= WRITE_CYCLES - 1);
wire missing_request = bmp_load_success && !frame_req_seen && !frame_write_req;
wire cancel_phase_complete = ((state == ST_CANCEL) && write_cancel_ack) ||
                             ((state == ST_RELEASE) && !write_cancel_ack);

// 期限只报告诊断，绝不伪造 ACK 或解除取消联锁。
always @(posedge clk or posedge rst) begin
    if (rst) begin
        write_count <= 0;
        cancel_count <= 0;
        cancel_ack_timeout <= 1'b0;
        cancel_release_timeout <= 1'b0;
    end else begin
        if (!write_waiting) write_count <= 0;
        else if (!write_timed_out) write_count <= write_count + 1'b1;
        if ((state != ST_CANCEL && state != ST_RELEASE) || cancel_phase_complete)
            cancel_count <= 0;
        else if (cancel_count < CANCEL_CYCLES - 1)
            cancel_count <= cancel_count + 1'b1;
        else if (state == ST_CANCEL)
            cancel_ack_timeout <= 1'b1;
        else
            cancel_release_timeout <= 1'b1;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state <= ST_IDLE;
        load_start_pulse <= 1'b0;
        load_idx <= 3'd0;
        image_complete <= 5'b00000;
        preload_done <= 1'b0;
        preload_error <= 1'b0;
        error_code <= ERR_NONE;
        source_done_seen <= 1'b0;
        frame_req_seen <= 1'b0;
        write_done_seen <= 1'b0;
    end else begin
        load_start_pulse <= 1'b0;
        case (state)
            ST_IDLE: begin
                // 目录 1..5 张都可播放，只按实际张数依次装入前 N 槽；0 张或越界计数不启动。
                if (catalog_ready && (img_found_count == 3'd0 || img_found_count > 3'd5)) begin
                    preload_error <= 1'b1;
                    error_code <= ERR_CATALOG;
                    state <= ST_ERROR;
                end else if (catalog_ready && storage_ready && bmp_ready &&
                             !write_cancel_ack && !frame_write_req &&
                             !bmp_load_error && !bmp_load_success && !write_finish_pulse) begin
                    source_done_seen <= 1'b0;
                    frame_req_seen <= 1'b0;
                    write_done_seen <= 1'b0;
                    load_start_pulse <= 1'b1;
                    state <= ST_LOAD;
                end
            end
            ST_LOAD: begin
                if (frame_write_req) frame_req_seen <= 1'b1;
                if (bmp_load_success) source_done_seen <= 1'b1;
                if (write_finish_pulse && frame_req_seen) write_done_seen <= 1'b1;
                // 失败优先于同拍成功。缺图/坏图不重试、不跳过，复位后重启。
                if (bmp_load_error || write_timed_out || missing_request) begin
                    preload_error <= 1'b1;
                    error_code <= bmp_load_error ? ERR_BMP :
                                  (write_timed_out ? ERR_WRITE_TIMEOUT : ERR_PROTOCOL);
                    source_done_seen <= 1'b0;
                    write_done_seen <= 1'b0;
                    state <= (frame_req_seen || frame_write_req || write_timed_out) ? ST_CANCEL : ST_ERROR;
                end else if ((source_done_seen || bmp_load_success) && frame_finished) begin
                    image_complete[load_idx] <= 1'b1;
                    if (load_idx + 3'd1 >= img_found_count) begin
                        preload_done <= 1'b1;
                        state <= ST_DONE;
                    end else begin
                        load_idx <= load_idx + 3'd1;
                        state <= ST_IDLE;
                    end
                end
            end
            ST_CANCEL: if (write_cancel_ack) state <= ST_RELEASE;
            ST_RELEASE: if (!write_cancel_ack) state <= ST_ERROR;
            ST_ERROR: begin end
            ST_DONE: begin end
            default: begin
                state <= ST_ERROR;
                preload_done <= 1'b0;
                preload_error <= 1'b1;
                error_code <= ERR_PROTOCOL;
            end
        endcase
    end
end
endmodule
