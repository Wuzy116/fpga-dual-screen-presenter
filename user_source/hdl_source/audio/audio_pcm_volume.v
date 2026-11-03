// 单时钟域、16 位有符号立体声 PCM 音量；volume 必须已在本域完成原子 CDC。
// 工程缩放约定（不是讲义规定的公式）：0 静音，255 逐位旁路；
// 1..254 为 sample*volume/256，向零截断，避免负样本算术右移的负向偏置。
// 16 位无符号幅值可表示 abs(-32768)，24 位乘积不溢出；无除法器或饱和器。
// 输入握手沿采样两声道及同一个 volume；同沿外部寄存器更新取沿前音量。
// 一拍寄存输出、一个弹性槽；背压保持已承诺输出，音量变化不重算旧样本。
// 不改变 sample_tick、不插入静音样本；rst 取消缓存，复位释放由上层同步。
module audio_pcm_volume (
    input wire clk, rst,
    input wire [7:0] volume,
    input wire input_valid,
    output wire input_ready,
    input wire signed [15:0] input_left, input_right,
    output reg sample_valid,
    input wire sample_ready,
    output reg signed [15:0] sample_left, sample_right
);
wire room = !sample_valid || sample_ready;
assign input_ready = !rst && room;
function [15:0] scale_pcm;
    input [15:0] pcm;
    input [7:0] gain;
    reg [15:0] magnitude, scaled;
    reg [23:0] product;
    begin
        magnitude = pcm[15] ? (~pcm + 16'd1) : pcm;
        product = magnitude * gain;
        scaled = product[23:8];
        if (gain == 8'd255) scale_pcm = pcm;
        else scale_pcm = pcm[15] ? (~scaled + 16'd1) : scaled;
    end
endfunction
always @(posedge clk or posedge rst) begin
    if (rst) begin
        sample_valid <= 1'b0;
        sample_left <= 16'sd0;
        sample_right <= 16'sd0;
    end else if (room) begin
        sample_valid <= input_valid;
        if (input_valid) begin
            sample_left <= scale_pcm(input_left, volume);
            sample_right <= scale_pcm(input_right, volume);
        end
    end
end
endmodule
