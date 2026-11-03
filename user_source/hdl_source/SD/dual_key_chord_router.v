// 所有状态机均工作在 clk 域；按键低有效，事件为单拍高脉冲。
module dual_key_chord_router #(
    parameter integer CLK_FREQ_HZ     = 100_000_000,
    parameter integer DEBOUNCE_MS     = 20,
    parameter integer LONG_PRESS_MS   = 1000,
    parameter integer DOUBLE_CLICK_MS = 300,
    parameter integer CHORD_WINDOW_MS = 50,
    // 可选保存手势；默认不实例化，保持原七路媒体事件行为。
    parameter integer ENABLE_SAVE_GESTURE = 0,
    // 新参数操作路径才启用；默认保持旧长按只发一次，不能直接启用到旧媒体映射。
    parameter integer ENABLE_LONG_REPEAT = 0,
    parameter integer REPEAT_MS = 200
)(
    input wire clk,
    input wire rst,
    input wire key1,
    input wire key2,
    output wire key1_click_event,
    output wire key1_double_event,
    output wire key1_long_event,
    output wire key2_click_event,
    output wire key2_double_event,
    output wire key2_long_event,
    output reg chord_click_event,
    output wire save_event
);
localparam integer CHORD_RAW = (CLK_FREQ_HZ / 1000) * CHORD_WINDOW_MS;
localparam integer LONG_RAW = (CLK_FREQ_HZ / 1000) * LONG_PRESS_MS;
localparam integer CHORD_CYCLES = (CHORD_RAW > 0) ? CHORD_RAW : 1;
localparam integer LONG_CYCLES = (LONG_RAW > 0) ? LONG_RAW : 1;
// 窗口计数器饱和到 CHORD_CYCLES 本身，位宽不能只按阈值减一计算。
// 用 64 位常量求和，避免最大合法参数加一时发生有符号溢出。
localparam integer CHORD_BITS = $clog2(64'd1 + CHORD_CYCLES);
localparam integer HOLD_BITS = (LONG_CYCLES <= 1) ? 1 : $clog2(LONG_CYCLES);
// 仅仿真检查；保持生产状态机和默认参数行为不变。
// synthesis translate_off
initial begin
    if (CLK_FREQ_HZ < 1000 || (CLK_FREQ_HZ % 1000) != 0 ||
        CHORD_WINDOW_MS < 1 || LONG_PRESS_MS < 1 ||
        (64'sd1 * (CLK_FREQ_HZ / 1000) * CHORD_WINDOW_MS) > 64'sd2147483647 ||
        (64'sd1 * (CLK_FREQ_HZ / 1000) * LONG_PRESS_MS) > 64'sd2147483647) begin
        $display("MEDIA_CONFIG_ERROR router %m: invalid clock/timing or cycle-count overflow");
        $finish;
    end
    // 保存后不能在松开时补发短组合：启用时原长按阈值不得晚于 3 秒。
    if ((ENABLE_SAVE_GESTURE != 0 && ENABLE_SAVE_GESTURE != 1) ||
        (ENABLE_SAVE_GESTURE && LONG_PRESS_MS > 3000)) begin
        $display("MEDIA_CONFIG_ERROR router save %m: boolean enable and long press <= 3000 ms required");
        $finish;
    end
end
// synthesis translate_on
wire [1:0] stable;
reg [1:0] stable_d;
wire [1:0] press_edge = stable_d & ~stable;
wire [1:0] release_edge = ~stable_d & stable;
wire [1:0] candidate;
wire [1:0] click_event;
wire [1:0] double_event;
wire [1:0] long_event;
reg chord_active;
reg chord_long;
reg repeat_overlap_lock;
reg [CHORD_BITS-1:0] chord_window_cnt;
reg [HOLD_BITS-1:0] chord_hold_cnt;

// 首个短按候选可升级为组合键；已发长按及第二击不追溯撤销。
wire chord_start = !chord_active && !repeat_overlap_lock && (stable == 2'b00) &&
    ((press_edge == 2'b11) ||
     ((chord_window_cnt < CHORD_CYCLES) &&
      ((press_edge[0] && candidate[1]) || (press_edge[1] && candidate[0]))));
// 连发模式下任何双键重叠都停止单键。晚到第二键不追溯升级为组合保存，
// 也不在部分松开后恢复旧连发；必须全部松开后重新识别。
wire cancel_single = chord_active || chord_start ||
    (ENABLE_LONG_REPEAT && ((stable == 2'b00) || repeat_overlap_lock));
always @(posedge clk or posedge rst) begin
    if (rst)
        repeat_overlap_lock <= 1'b0;
    else if (!ENABLE_LONG_REPEAT || stable == 2'b11)
        repeat_overlap_lock <= 1'b0;
    else if (stable == 2'b00)
        repeat_overlap_lock <= 1'b1;
end
generate if (ENABLE_SAVE_GESTURE) begin : g_save_gesture
    media_save_gesture #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .HOLD_MS(3000)) u_save_gesture (
        .clk(clk), .rst(rst), .key_stable(stable), .chord_start(chord_start),
        .save_event(save_event)
    );
end else begin : g_no_save_gesture
    assign save_event = 1'b0;
end endgenerate
assign key1_click_event  = click_event[0]  && !cancel_single;
assign key1_double_event = double_event[0] && !cancel_single;
assign key1_long_event   = long_event[0]   && !cancel_single;
assign key2_click_event  = click_event[1]  && !cancel_single;
assign key2_double_event = double_event[1] && !cancel_single;
assign key2_long_event   = long_event[1]   && !cancel_single;

media_key_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS)) u_key1_debounce (
    .clk(clk), .rst(rst), .button_in(key1), .button_stable(stable[0])
);
media_key_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .DEBOUNCE_MS(DEBOUNCE_MS)) u_key2_debounce (
    .clk(clk), .rst(rst), .button_in(key2), .button_stable(stable[1])
);
genvar k;
generate
    for (k = 0; k < 2; k = k + 1) begin : g_gesture
        media_key_gesture #(
            .CLK_FREQ_HZ(CLK_FREQ_HZ), .LONG_PRESS_MS(LONG_PRESS_MS),
            .DOUBLE_CLICK_MS(DOUBLE_CLICK_MS),
            .ENABLE_LONG_REPEAT(ENABLE_LONG_REPEAT), .REPEAT_MS(REPEAT_MS)
        ) u_gesture (
            .clk(clk), .rst(rst), .pressed(press_edge[k]),
            .released(release_edge[k]), .cancel(cancel_single),
            .chord_candidate(candidate[k]), .click_event(click_event[k]),
            .double_event(double_event[k]), .long_event(long_event[k])
        );
    end
endgenerate
always @(posedge clk or posedge rst) begin
    if (rst) begin
        stable_d <= 2'b11;
        chord_active <= 1'b0;
        chord_long <= 1'b0;
        chord_window_cnt <= 32'd0;
        chord_hold_cnt <= 32'd0;
        chord_click_event <= 1'b0;
    end else begin
        stable_d <= stable;
        chord_click_event <= 1'b0;
        if (stable == 2'b11)
            chord_window_cnt <= 32'd0;
        else if ((press_edge != 2'b00) && (stable != 2'b00))
            chord_window_cnt <= 32'd0;
        else if (chord_window_cnt < CHORD_CYCLES)
            chord_window_cnt <= chord_window_cnt + 32'd1;

        if (chord_start) begin
            chord_active <= 1'b1;
            chord_long <= 1'b0;
            chord_hold_cnt <= 32'd0;
        end else if (chord_active) begin
            // 两键全部松开才释放组合锁；组合长按无动作，不泄漏单键事件。
            if (stable == 2'b11) begin
                chord_active <= 1'b0;
                if (!chord_long && (chord_hold_cnt < LONG_CYCLES - 1))
                    chord_click_event <= 1'b1;
            end else if (chord_hold_cnt >= LONG_CYCLES - 1) begin
                chord_long <= 1'b1;
            end else begin
                chord_hold_cnt <= chord_hold_cnt + 32'd1;
            end
        end
    end
end
endmodule

// 两级同步 + 按下/松开对称消抖，不在这一层解释单击语义。
module media_key_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input wire clk,
    input wire rst,
    input wire button_in,
    output reg button_stable
);
localparam integer CYCLES_RAW = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;
localparam integer CYCLES = (CYCLES_RAW > 0) ? CYCLES_RAW : 1;
// 计数范围 0..CYCLES-1；即使阈值为 1，也保留一位寄存器。
localparam integer COUNTER_BITS = (CYCLES <= 1) ? 1 : $clog2(CYCLES);
// synthesis translate_off
initial begin
    if (CLK_FREQ_HZ < 1000 || (CLK_FREQ_HZ % 1000) != 0 || DEBOUNCE_MS < 1 ||
        (64'sd1 * (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS) > 64'sd2147483647) begin
        $display("MEDIA_CONFIG_ERROR debounce %m: invalid clock/timing or cycle-count overflow");
        $finish;
    end
end
// synthesis translate_on
reg button_sync0;
reg button_sync1;
reg [COUNTER_BITS-1:0] cnt;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0 <= 1'b1;
        button_sync1 <= 1'b1;
        button_stable <= 1'b1;
        cnt <= 32'd0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        if (button_sync1 == button_stable)
            cnt <= 32'd0;
        else if (cnt >= CYCLES - 1) begin
            button_stable <= button_sync1;
            cnt <= 32'd0;
        end else begin
            cnt <= cnt + 32'd1;
        end
    end
end
endmodule

module media_key_gesture #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer LONG_PRESS_MS = 1000,
    parameter integer DOUBLE_CLICK_MS = 300,
    parameter integer ENABLE_LONG_REPEAT = 0,
    parameter integer REPEAT_MS = 200
)(
    input wire clk,
    input wire rst,
    input wire pressed,
    input wire released,
    input wire cancel,
    output wire chord_candidate,
    output reg click_event,
    output reg double_event,
    output reg long_event
);
localparam integer LONG_RAW = (CLK_FREQ_HZ / 1000) * LONG_PRESS_MS;
localparam integer DOUBLE_RAW = (CLK_FREQ_HZ / 1000) * DOUBLE_CLICK_MS;
localparam integer LONG_CYCLES = (LONG_RAW > 0) ? LONG_RAW : 1;
localparam integer DOUBLE_CYCLES = (DOUBLE_RAW > 0) ? DOUBLE_RAW : 1;
localparam signed [63:0] REPEAT_RAW = 64'sd1 * (CLK_FREQ_HZ / 1000) * REPEAT_MS;
localparam integer REPEAT_CYCLES = (ENABLE_LONG_REPEAT && REPEAT_RAW >= 2 &&
    REPEAT_RAW <= 64'sd2147483647) ? REPEAT_RAW : 1;
// 三阶段复用计数器；关闭连发时保持旧位宽，不因未使用的默认间隔扩宽。
localparam integer BASE_CYCLES = (LONG_CYCLES > DOUBLE_CYCLES) ? LONG_CYCLES : DOUBLE_CYCLES;
localparam integer MAX_CYCLES = (BASE_CYCLES > REPEAT_CYCLES) ? BASE_CYCLES : REPEAT_CYCLES;
localparam integer COUNTER_BITS = (MAX_CYCLES <= 1) ? 1 : $clog2(MAX_CYCLES);
// synthesis translate_off
initial begin
    if (CLK_FREQ_HZ < 1000 || (CLK_FREQ_HZ % 1000) != 0 ||
        LONG_PRESS_MS < 1 || DOUBLE_CLICK_MS < 1 ||
        (64'sd1 * (CLK_FREQ_HZ / 1000) * LONG_PRESS_MS) > 64'sd2147483647 ||
        (64'sd1 * (CLK_FREQ_HZ / 1000) * DOUBLE_CLICK_MS) > 64'sd2147483647) begin
        $display("MEDIA_CONFIG_ERROR gesture %m: invalid clock/timing or cycle-count overflow");
        $finish;
    end
    // 至少间隔两拍，保证重复事件之间有低电平；未启用时不限制无效间隔。
    if ((ENABLE_LONG_REPEAT != 0 && ENABLE_LONG_REPEAT != 1) ||
        (ENABLE_LONG_REPEAT && (REPEAT_MS < 1 || REPEAT_RAW < 2 ||
                               REPEAT_RAW > 64'sd2147483647))) begin
        $display("MEDIA_CONFIG_ERROR gesture_repeat %m: boolean enable and repeat cycles 2..2147483647 required");
        $finish;
    end
end
// synthesis translate_on
localparam IDLE = 3'd0, HOLD = 3'd1, WAIT_SECOND = 3'd2,
           SECOND_HOLD = 3'd3, WAIT_RELEASE = 3'd4;
reg [2:0] state;
reg [COUNTER_BITS-1:0] cnt;
assign chord_candidate = (state == HOLD);
always @(posedge clk or posedge rst) begin
    if (rst) begin
        state <= IDLE;
        cnt <= 32'd0;
        click_event <= 1'b0;
        double_event <= 1'b0;
        long_event <= 1'b0;
    end else begin
        click_event <= 1'b0;
        double_event <= 1'b0;
        long_event <= 1'b0;
        if (cancel) begin
            state <= IDLE;
            cnt <= 32'd0;
        end else begin
            case (state)
                IDLE: begin
                    cnt <= 32'd0;
                    if (pressed)
                        state <= HOLD;
                end
                HOLD, SECOND_HOLD: begin
                    if (released) begin
                        cnt <= 32'd0;
                        if (state == SECOND_HOLD) begin
                            double_event <= 1'b1;
                            state <= IDLE;
                        end else begin
                            state <= WAIT_SECOND;
                        end
                    end else if (cnt >= LONG_CYCLES - 1) begin
                        // 第二击转长按取消短/双击候选，后续也按同一连发间隔处理。
                        long_event <= 1'b1;
                        cnt <= 32'd0;
                        state <= WAIT_RELEASE;
                    end else begin
                        cnt <= cnt + 32'd1;
                    end
                end
                WAIT_SECOND: begin
                    // 窗口最后一拍到达的按下仍属于第二击。
                    if (pressed) begin
                        state <= SECOND_HOLD;
                        cnt <= 32'd0;
                    end else if (cnt >= DOUBLE_CYCLES - 1) begin
                        click_event <= 1'b1;
                        state <= IDLE;
                        cnt <= 32'd0;
                    end else begin
                        cnt <= cnt + 32'd1;
                    end
                end
                WAIT_RELEASE: begin
                    // 松开/外层cancel优先于到期，停止后不补发短击或延期连发。
                    if (released) begin
                        state <= IDLE;
                        cnt <= 32'd0;
                    end else if (ENABLE_LONG_REPEAT) begin
                        if (cnt >= REPEAT_CYCLES - 1) begin
                            long_event <= 1'b1;
                            cnt <= 32'd0;
                        end else begin
                            cnt <= cnt + 32'd1;
                        end
                    end
                end
                default: begin
                    state <= IDLE;
                    cnt <= 32'd0;
                end
            endcase
        end
    end
end
endmodule
