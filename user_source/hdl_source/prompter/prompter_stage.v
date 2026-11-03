// 演讲时期（D18，控制域）：phase 0 预备（开机）↔ 1 演讲。
// KEY4（已消抖电平，key_down=1 为按下）：按住满 LONG_PRESS_MS 时切换时期（每次按住只切一次）；
// 未满即松开为短按，在松开时发出 key_short（缩略图 / 选页）。ready=0 时不切换、不发短按。
// phase_enter 在时期改变的那一拍为 1，phase 已是新值。
module prompter_stage #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer LONG_PRESS_MS = 1000
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       ready,
    input  wire       key_down,
    output reg        phase,
    output reg        phase_enter,
    output reg        key_short
);
    localparam integer LONG_CYCLES = CLK_FREQ_HZ / 1000 * LONG_PRESS_MS;
    localparam integer CW = $clog2(LONG_CYCLES + 1);
    reg [CW-1:0] held;
    reg          down_q, long_done;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            phase <= 1'b0; phase_enter <= 1'b0; key_short <= 1'b0;
            held <= {CW{1'b0}}; down_q <= 1'b0; long_done <= 1'b0;
        end else begin
            phase_enter <= 1'b0;
            key_short <= 1'b0;
            down_q <= key_down;
            if (key_down) begin
                if (held != LONG_CYCLES[CW-1:0]) held <= held + 1'b1;
                if (held == LONG_CYCLES[CW-1:0] - 1'b1 && !long_done) begin
                    long_done <= 1'b1;
                    if (ready) begin phase <= !phase; phase_enter <= 1'b1; end
                end
            end else begin
                held <= {CW{1'b0}};
                long_done <= 1'b0;
                if (down_q && !long_done && ready) key_short <= 1'b1;
            end
        end
    end
endmodule
