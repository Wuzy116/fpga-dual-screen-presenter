// 同控制域的组合保存手势；输入必须来自现有路由器，不能直接接异步按键。
// key_stable 为消抖后的低有效电平；chord_start 是路由器认可的组合起点。
// 从采到合法起点后等待完整 HOLD_MS；中途任一键松开即取消，不累计、不重新计时。
// 触发或取消后两键全部松开才重装；保持按住只发一次单拍 save_event。
// 复位取消旧候选；复位后只有新的 chord_start 能启动计时。
// 本模块不解释单键/组合短按、不重复消抖、不排队，也不操作 Flash。
module media_save_gesture #(
    parameter integer CLK_FREQ_HZ = 50000000,
    parameter integer HOLD_MS = 3000
)(
    input wire clk, rst,
    input wire [1:0] key_stable,
    input wire chord_start,
    output reg save_event
);
localparam [63:0] HOLD_RAW = 64'd1 * (CLK_FREQ_HZ / 1000) * HOLD_MS;
localparam [63:0] HOLD_CYCLES = (HOLD_RAW > 0) ? HOLD_RAW : 64'd1;
localparam integer COUNT_BITS = (HOLD_CYCLES <= 1) ? 1 : $clog2(HOLD_CYCLES);
localparam [COUNT_BITS-1:0] HOLD_LAST = HOLD_CYCLES - 1'b1;
// synthesis translate_off
initial begin
    if (CLK_FREQ_HZ < 1000 || (CLK_FREQ_HZ % 1000) != 0 || HOLD_MS < 1 ||
        HOLD_RAW > 64'd2147483647) begin
        $display("MEDIA_CONFIG_ERROR save_gesture %m: invalid clock/hold or cycle-count overflow");
        $finish;
    end
end
// synthesis translate_on
localparam IDLE=2'd0, HOLD=2'd1, WAIT_RELEASE=2'd2;
reg [1:0] state;
reg [COUNT_BITS-1:0] hold_count;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        state <= IDLE;
        hold_count <= 0;
        save_event <= 1'b0;
    end else begin
        save_event <= 1'b0;
        case (state)
            IDLE: begin
                hold_count <= 0;
                if (chord_start && key_stable == 2'b00)
                    state <= HOLD;
            end
            HOLD: begin
                // 松开优先于到期；单键维持或再次凑齐双键不能续上旧计时。
                if (key_stable != 2'b00) begin
                    state <= WAIT_RELEASE;
                    hold_count <= 0;
                end else if (hold_count == HOLD_LAST) begin
                    save_event <= 1'b1;
                    state <= WAIT_RELEASE;
                    hold_count <= 0;
                end else begin
                    hold_count <= hold_count + 1'b1;
                end
            end
            WAIT_RELEASE: begin
                if (key_stable == 2'b11)
                    state <= IDLE;
            end
            default: begin
                state <= WAIT_RELEASE;
                hold_count <= 0;
            end
        endcase
    end
end
endmodule
