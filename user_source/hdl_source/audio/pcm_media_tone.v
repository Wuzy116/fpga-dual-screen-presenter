// 媒体状态在本模块前完成 CDC；音符计时只统计已交接样本，不统计像素周期。
module pcm_media_tone #(
    parameter integer BLIP_SAMPLES = 4800,
    parameter integer NOTE_SAMPLES = 12000
)(
    input wire clk, rst, enable,
    input wire [1:0] media_id,
    input wire media_valid,
    output wire sample_valid,
    input wire sample_ready,
    output wire signed [15:0] sample_left, sample_right
);
reg [1:0] active_id;
reg active_valid;
reg [2:0] note_index;
reg [31:0] blip_remaining, note_count;
wire signed [15:0] sine_left, sine_right;
wire [31:0] phase_inc;
// 48 kHz / 32 位 DDS；讲义的 20 位增量不能直接用到 32 位相位累加器。
function [31:0] note_inc;
    input [1:0] id;
    input [2:0] index;
    begin
        case ({id,index})
            0,9,13,16,25: note_inc=32'd46797248; // 523 Hz
            1,5,10,12,18,27: note_inc=32'd58966322; // 659 Hz
            2,4,19,29: note_inc=32'd70151133; // 784 Hz
            3,21: note_inc=32'd93594496; // 1046 Hz
            8: note_inc=32'd39370534; // 440 Hz
            11,20: note_inc=32'd78741067; // 880 Hz
            17: note_inc=32'd52523871; // 587 Hz
            24: note_inc=32'd23443363; // 262 Hz
            26: note_inc=32'd29527900; // 330 Hz
            28: note_inc=32'd35075566; // 392 Hz
            default: note_inc=32'd46797248;
        endcase
        // round(hz * 2^32 / 48000)，常量预计算，避免综合出运行时除法器。
    end
endfunction
assign phase_inc = !active_valid ? 32'd0 :
    (blip_remaining != 0 ? 32'd134217728 : note_inc(active_id,note_index));
pcm_test_tone u_sine (
    .clk(clk), .rst(rst), .enable(enable), .phase_inc(phase_inc),
    .sample_valid(sample_valid), .sample_ready(sample_ready),
    .sample_left(sine_left), .sample_right(sine_right)
);
assign sample_left = active_valid ? sine_left : 16'sd0;
assign sample_right = active_valid ? sine_right : 16'sd0;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        active_id <= 0; active_valid <= 0; note_index <= 0;
        blip_remaining <= 0; note_count <= 0;
    end else if (!enable) begin
        active_id <= 0; active_valid <= 0; note_index <= 0;
        blip_remaining <= 0; note_count <= 0;
    end else if (sample_valid && sample_ready) begin
        // 先交付旧样本，再应用最新媒体状态，背压时输出必须保持。
        if (media_valid != active_valid || (media_valid && media_id != active_id)) begin
            active_id <= media_id; active_valid <= media_valid;
            blip_remaining <= media_valid ? BLIP_SAMPLES : 0;
            note_index <= 0; note_count <= 0;
        end else if (active_valid) begin
            if (blip_remaining != 0) blip_remaining <= blip_remaining - 1'b1;
            else if (note_count == NOTE_SAMPLES-1) begin
                note_count <= 0;
                note_index <= note_index == 5 ? 0 : note_index + 1'b1;
            end else note_count <= note_count + 1'b1;
        end
    end
end
endmodule
