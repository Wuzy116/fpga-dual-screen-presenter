// 持续供样的 16 点 DDS 正弦音源；采样速度由下游 ready 控制。
// enable=0 取消当前音源并复位相位，不能用 enable 代替握手背压。
module pcm_test_tone (
    input wire clk,
    input wire rst,
    input wire enable,
    input wire [31:0] phase_inc,
    output wire sample_valid,
    input wire sample_ready,
    output wire signed [15:0] sample_left,
    output wire signed [15:0] sample_right
);
reg [31:0] phase;
function signed [15:0] sine_sample;
    input [3:0] index;
    begin
        case (index)
            0: sine_sample = 0;
            1: sine_sample = 4592;
            2: sine_sample = 8485;
            3: sine_sample = 11087;
            4: sine_sample = 12000;
            5: sine_sample = 11087;
            6: sine_sample = 8485;
            7: sine_sample = 4592;
            8: sine_sample = 0;
            9: sine_sample = -4592;
            10: sine_sample = -8485;
            11: sine_sample = -11087;
            12: sine_sample = -12000;
            13: sine_sample = -11087;
            14: sine_sample = -8485;
            default: sine_sample = -4592;
        endcase
    end
endfunction
assign sample_valid = enable && !rst;
assign sample_left = sample_valid ? sine_sample(phase[31:28]) : 16'sd0;
assign sample_right = sample_left;
always @(posedge clk or posedge rst) begin
    if (rst) phase <= 32'd0;
    else if (!enable) phase <= 32'd0;
    else if (sample_valid && sample_ready) phase <= phase + phase_inc;
end
endmodule
