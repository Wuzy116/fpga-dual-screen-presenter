// 单样本预取缓冲：按 sample_tick 提交，欠载补零；时间基准不受音源停顿影响。
module m06_pcm_contract_adapter (
    input wire clk,
    input wire rst,
    input wire sample_tick,
    input wire sample_valid,
    output wire sample_ready,
    input wire signed [15:0] sample_left,
    input wire signed [15:0] sample_right,
    output reg pcm_commit,
    output reg signed [15:0] pcm_left,
    output reg signed [15:0] pcm_right,
    output reg underrun
);
reg pending;
reg signed [15:0] pending_left, pending_right;
assign sample_ready = !rst && (!pending || sample_tick);
always @(posedge clk or posedge rst) begin
    if (rst) begin
        pending <= 1'b0;
        pending_left <= 16'sd0;
        pending_right <= 16'sd0;
        pcm_commit <= 1'b0;
        pcm_left <= 16'sd0;
        pcm_right <= 16'sd0;
        underrun <= 1'b0;
    end else begin
        pcm_commit <= sample_tick;
        underrun <= 1'b0;
        if (sample_tick) begin
            pcm_left <= pending ? pending_left : (sample_valid ? sample_left : 16'sd0);
            pcm_right <= pending ? pending_right : (sample_valid ? sample_right : 16'sd0);
            underrun <= !pending && !sample_valid;
            // 有旧样本时输出旧样本、预取新样本；空缓冲时新样本直接提交。
            pending <= pending && sample_valid;
            if (pending && sample_valid) begin
                pending_left <= sample_left;
                pending_right <= sample_right;
            end
        end else if (sample_valid && sample_ready) begin
            pending <= 1'b1;
            pending_left <= sample_left;
            pending_right <= sample_right;
        end
    end
end
endmodule
