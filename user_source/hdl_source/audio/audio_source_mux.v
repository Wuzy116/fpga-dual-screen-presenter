// 0=测试音，1=TF 卡 PCM（wav_active 时选 PCM，否则回退媒体音调），2=媒体音调，3=静音。
// wav_active 期间 PCM 暂无样本（预填充/欠载）时输出槽留空，由下游适配器补零，不插入回退音源。
// 选择请求仅在输出槽可用时生效，背压期间绝不覆盖已经承诺的 PCM；ready 只给当前被选源。
module audio_source_mux (
    input wire clk, rst, enable,
    input wire [1:0] source_sel,
    input wire test_valid,
    output wire test_ready,
    input wire signed [15:0] test_left, test_right,
    input wire media_valid,
    output wire media_ready,
    input wire signed [15:0] media_left, media_right,
    input wire wav_active,
    input wire wav_valid,
    output wire wav_ready,
    input wire signed [15:0] wav_left, wav_right,
    output reg sample_valid,
    input wire sample_ready,
    output reg signed [15:0] sample_left, sample_right
);
wire room=!sample_valid || sample_ready;
wire pick_test=enable && source_sel==0;
wire pick_wav=enable && source_sel==1 && wav_active;
wire pick_media=enable && (source_sel==2 || (source_sel==1 && !wav_active));
assign test_ready=!rst && room && pick_test;
assign wav_ready=!rst && room && pick_wav;
assign media_ready=!rst && room && pick_media;
always @(posedge clk or posedge rst) begin
    if(rst) begin sample_valid<=0; sample_left<=0; sample_right<=0; end
    else if(room) begin
        if(pick_test) begin
            sample_valid<=test_valid;
            sample_left<=test_left; sample_right<=test_right;
        end else if(pick_wav) begin
            sample_valid<=wav_valid;
            sample_left<=wav_left; sample_right<=wav_right;
        end else if(pick_media) begin
            sample_valid<=media_valid;
            sample_left<=media_left; sample_right<=media_right;
        end else begin
            sample_valid<=1; sample_left<=0; sample_right<=0;
        end
    end
end
endmodule
