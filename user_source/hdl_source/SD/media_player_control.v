// 执行层：一个在途加载事务 + 一个可覆盖方向的待执行手动请求。
// 接口全部属于 clk 域，跨域同步由外层适配。
module media_player_control #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer AUTO_PERIOD_MS = 1000,
    parameter USE_EXPLICIT_RESULTS = 0,
    parameter integer MAX_RETRIES = 0,
    parameter ENABLE_AUTO_SKIP = 0,
    parameter ENABLE_WRITE_TIMEOUT = 0,
    parameter integer WRITE_FINISH_TIMEOUT_MS = 500,
    parameter ENABLE_CANCEL_TIMEOUT = 0,
    parameter integer CANCEL_TIMEOUT_MS = 500
)(
    input wire clk,
    input wire rst,
    input wire catalog_ready,
    input wire [2:0] img_found_count,
    input wire manual_req,
    input wire manual_prev,
    input wire auto_toggle,
    input wire mode_ready,
    input wire mode_value,
    input wire [1:0] next_idx,
    input wire [1:0] prev_idx,
    input wire bmp_ready,
    input wire frame_write_req,
    input wire write_finish_pulse,
    output reg load_start_pulse,
    output reg [1:0] load_idx,
    output reg [1:0] img_idx,
    output reg [1:0] write_buf_idx,
    output reg [1:0] disp_buf_idx,
    output reg display_valid,
    output reg auto_play_en,
    output reg load_busy,
    output reg load_failed,
    input wire bmp_load_success,
    input wire bmp_load_error,
    input wire write_cancel_ack,
    output wire write_cancel_req
);
localparam integer PERIOD_RAW = (CLK_FREQ_HZ / 1000) * AUTO_PERIOD_MS;
localparam integer PERIOD_CYCLES = (PERIOD_RAW > 0) ? PERIOD_RAW : 1;
localparam integer AUTO_COUNTER_BITS = (PERIOD_CYCLES <= 1) ? 1 : $clog2(PERIOD_CYCLES);
localparam integer RETRY_BITS = (MAX_RETRIES < 1) ? 1 : $clog2(64'd1 + MAX_RETRIES);
localparam [63:0] WRITE_TIMEOUT_RAW = 64'd1 * (CLK_FREQ_HZ / 1000) * WRITE_FINISH_TIMEOUT_MS;
localparam [63:0] WRITE_TIMEOUT_CYCLES = (WRITE_TIMEOUT_RAW > 0) ? WRITE_TIMEOUT_RAW : 64'd1;
localparam integer WRITE_TIMEOUT_BITS = (WRITE_TIMEOUT_CYCLES <= 1) ? 1 : $clog2(WRITE_TIMEOUT_CYCLES);
localparam [63:0] CANCEL_TIMEOUT_RAW = 64'd1 * (CLK_FREQ_HZ / 1000) * CANCEL_TIMEOUT_MS;
localparam [63:0] CANCEL_TIMEOUT_CYCLES = (CANCEL_TIMEOUT_RAW > 0) ? CANCEL_TIMEOUT_RAW : 64'd1;
localparam integer CANCEL_TIMEOUT_BITS = (CANCEL_TIMEOUT_CYCLES <= 1) ? 1 : $clog2(CANCEL_TIMEOUT_CYCLES);
// synthesis translate_off
initial begin
    if (ENABLE_CANCEL_TIMEOUT && (!USE_EXPLICIT_RESULTS || CANCEL_TIMEOUT_MS < 1 ||
        CANCEL_TIMEOUT_RAW > 64'd2147483647)) begin
        $display("MEDIA_CONFIG_ERROR player %m: invalid cancellation deadline or legacy result mode");
        $finish;
    end
    if (ENABLE_WRITE_TIMEOUT && (!USE_EXPLICIT_RESULTS || WRITE_FINISH_TIMEOUT_MS < 1 ||
        WRITE_TIMEOUT_RAW > 64'd2147483647)) begin
        $display("MEDIA_CONFIG_ERROR player %m: invalid write completion deadline or legacy result mode");
        $finish;
    end
    if (MAX_RETRIES < 0 || ((MAX_RETRIES > 0 || ENABLE_AUTO_SKIP) && !USE_EXPLICIT_RESULTS)) begin
        $display("MEDIA_CONFIG_ERROR player %m: retries require explicit results and a nonnegative limit");
        $finish;
    end
    if (CLK_FREQ_HZ < 1000 || (CLK_FREQ_HZ % 1000) != 0 || AUTO_PERIOD_MS < 1 ||
        (64'sd1 * (CLK_FREQ_HZ / 1000) * AUTO_PERIOD_MS) > 64'sd2147483647) begin
        $display("MEDIA_CONFIG_ERROR player %m: invalid clock/timing or cycle-count overflow");
        $finish;
    end
end
// synthesis translate_on
reg [AUTO_COUNTER_BITS-1:0] auto_cnt;
reg manual_pending;
reg pending_prev;
reg load_saw_busy;
reg source_done_seen;
reg write_done_seen;
reg frame_req_seen;
reg retry_pending;
reg [RETRY_BITS-1:0] retries_used;
reg skip_pending;
reg [2:0] failed_images;
reg [1:0] pending_buf_idx;
reg mode_applied;
// 四相取消握手：请求保持至确认，再等待确认撤销，期间禁止新加载。
localparam CANCEL_IDLE = 2'd0, CANCEL_ACK = 2'd1, CANCEL_RELEASE = 2'd2;
reg [1:0] cancel_state;
assign write_cancel_req = (cancel_state == CANCEL_ACK);
wire manual_available = manual_req || manual_pending;
wire selected_prev = manual_req ? manual_prev : pending_prev;
wire skip_available = skip_pending && auto_play_en && !auto_toggle;
wire launch_skip = skip_available && !manual_available && !retry_pending;
wire first_load = !display_valid && !load_failed;
wire auto_due = display_valid && auto_play_en && !auto_toggle && !load_failed &&
                (img_found_count > 3'd1) && (auto_cnt >= PERIOD_CYCLES - 1);
wire launch = catalog_ready && (img_found_count != 3'd0) && !load_busy && bmp_ready &&
              (cancel_state == CANCEL_IDLE) &&
              (!USE_EXPLICIT_RESULTS || (!write_cancel_ack && !bmp_load_error)) &&
              (retry_pending || skip_available || first_load || manual_available || auto_due);
wire source_finished = USE_EXPLICIT_RESULTS ? bmp_load_success : (load_saw_busy && bmp_ready);
wire source_failed = USE_EXPLICIT_RESULTS ? bmp_load_error :
                     (source_finished && !frame_req_seen && !frame_write_req);
wire frame_finished = write_done_seen || (write_finish_pulse && frame_req_seen);
// Start after source success was sampled. All inputs have already crossed into clk.
wire write_waiting = ENABLE_WRITE_TIMEOUT && load_busy && source_done_seen &&
                     !source_failed && !frame_finished;
wire write_timed_out = write_waiting && (write_timeout_count >= WRITE_TIMEOUT_CYCLES - 1);
reg [WRITE_TIMEOUT_BITS-1:0] write_timeout_count;
reg write_finish_timeout;
reg [CANCEL_TIMEOUT_BITS-1:0] cancel_timeout_count;
reg cancel_ack_timeout;
reg cancel_release_timeout;
wire cancel_phase_complete = ((cancel_state == CANCEL_ACK) && write_cancel_ack) ||
                             ((cancel_state == CANCEL_RELEASE) && !write_cancel_ack);

// Diagnostic only: deadlines must NEVER fabricate ACK or release the transaction interlock.
// Reuse one saturating counter, reset on every real four-phase handshake transition.
always @(posedge clk or posedge rst) begin
    if (rst) begin
        cancel_timeout_count <= 0;
        cancel_ack_timeout <= 1'b0;
        cancel_release_timeout <= 1'b0;
    end else if (!catalog_ready || launch) begin
        cancel_timeout_count <= 0;
        cancel_ack_timeout <= 1'b0;
        cancel_release_timeout <= 1'b0;
    end else begin
        if (!ENABLE_CANCEL_TIMEOUT || cancel_state == CANCEL_IDLE || cancel_phase_complete)
            cancel_timeout_count <= 0;
        else if (cancel_timeout_count < CANCEL_TIMEOUT_CYCLES - 1)
            cancel_timeout_count <= cancel_timeout_count + 1'b1;
        else begin
            if (cancel_state == CANCEL_ACK) cancel_ack_timeout <= 1'b1;
            if (cancel_state == CANCEL_RELEASE) cancel_release_timeout <= 1'b1;
        end
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        write_timeout_count <= 0;
        write_finish_timeout <= 1'b0;
    end else if (!catalog_ready || launch) begin
        write_timeout_count <= 0;
        write_finish_timeout <= 1'b0;
    end else begin
        if (!write_waiting) write_timeout_count <= 0;
        else if (!write_timed_out) write_timeout_count <= write_timeout_count + 1'b1;
        if (write_timed_out) write_finish_timeout <= 1'b1;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        cancel_state <= CANCEL_IDLE;
        load_start_pulse <= 1'b0;
        load_idx <= 2'd0;
        img_idx <= 2'd0;
        write_buf_idx <= 2'd0;
        disp_buf_idx <= 2'd0;
        pending_buf_idx <= 2'd0;
        display_valid <= 1'b0;
        auto_play_en <= 1'b0;
        auto_cnt <= 32'd0;
        mode_applied <= 1'b0;
        load_busy <= 1'b0;
        load_failed <= 1'b0;
        manual_pending <= 1'b0;
        pending_prev <= 1'b0;
        load_saw_busy <= 1'b0;
        source_done_seen <= 1'b0;
        write_done_seen <= 1'b0;
        frame_req_seen <= 1'b0;
        retry_pending <= 1'b0;
        retries_used <= 0;
        skip_pending <= 1'b0;
        failed_images <= 3'd0;
    end else begin
        load_start_pulse <= 1'b0;
        if (!catalog_ready) begin
            cancel_state <= CANCEL_IDLE;
            load_idx <= 2'd0;
            img_idx <= 2'd0;
            write_buf_idx <= 2'd0;
            disp_buf_idx <= 2'd0;
            pending_buf_idx <= 2'd0;
            display_valid <= 1'b0;
            auto_play_en <= 1'b0;
            auto_cnt <= 32'd0;
            load_busy <= 1'b0;
            load_failed <= 1'b0;
            manual_pending <= 1'b0;
            pending_prev <= 1'b0;
            load_saw_busy <= 1'b0;
            source_done_seen <= 1'b0;
            write_done_seen <= 1'b0;
            frame_req_seen <= 1'b0;
            retry_pending <= 1'b0;
            retries_used <= 0;
            skip_pending <= 1'b0;
            failed_images <= 3'd0;
            mode_applied <= 1'b0;
        end else begin
            if (mode_ready && !mode_applied) begin
                auto_play_en <= mode_value;
                mode_applied <= 1'b1;
                auto_cnt <= 32'd0;
            end
            if ((cancel_state == CANCEL_ACK) && write_cancel_ack)
                cancel_state <= CANCEL_RELEASE;
            else if ((cancel_state == CANCEL_RELEASE) && !write_cancel_ack)
                cancel_state <= CANCEL_IDLE;
            if (manual_req && (img_found_count != 3'd0)) begin
                manual_pending <= 1'b1;
                pending_prev <= manual_prev;
            end
            if (auto_toggle && (img_found_count > 3'd1))
                auto_play_en <= ~auto_play_en;
            if (auto_toggle && auto_play_en)
                skip_pending <= 1'b0;
            // 忙时不计时；提交后从零开始完整周期。关闭轮播同拍不启动自动加载。
            if (auto_toggle || load_busy || !auto_play_en || !display_valid ||
                load_failed || (img_found_count < 3'd2))
                auto_cnt <= 32'd0;
            else if (auto_cnt < PERIOD_CYCLES - 1)
                auto_cnt <= auto_cnt + 32'd1;

            if (load_busy) begin
                // 先观察本次请求使 BMP 离开空闲，不能把启动前 ready 当成完成。
                if (!bmp_ready)
                    load_saw_busy <= 1'b1;
                if (frame_write_req)
                    frame_req_seen <= 1'b1;
                if (source_finished)
                    source_done_seen <= 1'b1;
                if (write_finish_pulse && frame_req_seen)
                    write_done_seen <= 1'b1;
                // 两种完成可任意先后到达，不能要求完成脉冲恰好同拍。
                if (source_failed || write_timed_out) begin
                    // 失败优先于同拍成功/写完成；失败帧永远不能切到显示缓冲区。
                    load_busy <= 1'b0;
                    load_failed <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen <= 1'b0;
                    // 保持原目标与非显示缓冲区；取消/SD 恢复完成后才允许有限重试。
                    retry_pending <= (retries_used < MAX_RETRIES);
                    // 一轮最多检查整个目录一次，全部坏图则降级停留，不能无限轮转。
                    if (ENABLE_AUTO_SKIP && (retries_used >= MAX_RETRIES) &&
                        auto_play_en && !auto_toggle && (failed_images + 3'd1 < img_found_count)) begin
                        skip_pending <= 1'b1;
                        failed_images <= failed_images + 3'd1;
                    end
                    if (USE_EXPLICIT_RESULTS && (frame_req_seen || frame_write_req || write_timed_out))
                        cancel_state <= CANCEL_ACK;
                end else if ((source_done_seen || source_finished) && frame_finished) begin
                    img_idx <= load_idx;
                    disp_buf_idx <= pending_buf_idx;
                    display_valid <= 1'b1;
                    load_busy <= 1'b0;
                    auto_cnt <= 32'd0;
                    failed_images <= 3'd0;
                end
            end
            if (launch) begin
                if (retry_pending) begin
                    retries_used <= retries_used + 1'b1;
                end else begin
                    retries_used <= 0;
                    if (launch_skip)
                        load_idx <= ({1'b0, load_idx} + 3'd1 >= img_found_count) ? 2'd0 : load_idx + 2'd1;
                    else begin
                        failed_images <= 3'd0;
                        load_idx <= !display_valid ? 2'd0 :
                                    ((manual_available && selected_prev) ? prev_idx : next_idx);
                    end
                    pending_buf_idx <= !display_valid ? 2'd0 : {1'b0, ~disp_buf_idx[0]};
                    write_buf_idx <= !display_valid ? 2'd0 : {1'b0, ~disp_buf_idx[0]};
                end
                retry_pending <= 1'b0;
                skip_pending <= 1'b0;
                load_start_pulse <= 1'b1;
                load_busy <= 1'b1;
                load_failed <= 1'b0;
                load_saw_busy <= 1'b0;
                source_done_seen <= 1'b0;
                write_done_seen <= 1'b0;
                frame_req_seen <= 1'b0;
                auto_cnt <= 32'd0;
                // 首图自动加载不吞掉同时到来的手动请求。
                if (!first_load && !retry_pending)
                    manual_pending <= 1'b0;
            end
        end
    end
end
endmodule
