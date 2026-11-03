// 只出视频的 DVI 符号核：控制段 + TMDS 视频段，无前导码、保护带和数据岛。
// DELAY 拍输入延迟 + 编码器 1 拍；top 取 DELAY 使输出与 hdmi_audio_symbol_core 逐拍对齐。
// 输出为常规 TMDS 位序（bit 0 先发），位序转换在 PHY 内完成。
module dvi_symbol_core #(
    parameter integer DELAY = 10
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [23:0] video_rgb,
    input  wire        video_hs,
    input  wire        video_vs,
    input  wire        video_de,
    output wire [9:0]  channel0_symbol,
    output wire [9:0]  channel1_symbol,
    output wire [9:0]  channel2_symbol
);
    wire [23:0] rgb;
    wire        hs, vs, de;

    generate if (DELAY == 0) begin : g_no_delay
        assign {de, vs, hs, rgb} = {video_de, video_vs, video_hs, video_rgb};
    end else begin : g_delay
        reg [26:0] pipe [0:DELAY-1];
        integer i;
        always @(posedge clk or posedge rst) begin
            if (rst) begin
                for (i = 0; i < DELAY; i = i + 1) pipe[i] <= {1'b0, 1'b1, 1'b1, 24'd0};
            end else begin
                pipe[0] <= {video_de, video_vs, video_hs, video_rgb};
                for (i = 1; i < DELAY; i = i + 1) pipe[i] <= pipe[i-1];
            end
        end
        assign {de, vs, hs, rgb} = pipe[DELAY-1];
    end endgenerate

    wire [2:0] mode = de ? 3'd1 : 3'd0;

    hdmi_symbol_encoder #(.CHANNEL(0)) u_ch0 (
        .clk(clk), .rst(rst), .mode(mode), .video_data(rgb[7:0]),
        .island_data(4'd0), .control_data({vs, hs}), .symbol(channel0_symbol)
    );
    hdmi_symbol_encoder #(.CHANNEL(1)) u_ch1 (
        .clk(clk), .rst(rst), .mode(mode), .video_data(rgb[15:8]),
        .island_data(4'd0), .control_data(2'd0), .symbol(channel1_symbol)
    );
    hdmi_symbol_encoder #(.CHANNEL(2)) u_ch2 (
        .clk(clk), .rst(rst), .mode(mode), .video_data(rgb[23:16]),
        .island_data(4'd0), .control_data(2'd0), .symbol(channel2_symbol)
    );
endmodule
