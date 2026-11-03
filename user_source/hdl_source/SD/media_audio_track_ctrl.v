`timescale 1ns/1ps
// 曲目控制（控制域）：实际显示文件对应的 MUSn.PCM 从头循环播放。
// 换文件/停播：先 stop 读取器至空闲，再保持 flush FLUSH_CYCLES 拍清空播放缓冲，然后从新文件开头开始；
// 期间 track_active 保持，空档由播放器输出静音，不夹杂回退音源。新显示无音乐文件时 flush 后撤销 active。
// 读取出错/被拒：立即撤销 active（回退媒体音调）并 flush，直到显示文件变化才重试。
// stream_restart 与每次 audio_start 同拍，供写侧复位字节对齐。
module media_audio_track_ctrl #(
    parameter integer FLUSH_CYCLES = 64
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       enable,
    input  wire       display_valid,
    input  wire [2:0] display_file,
    input  wire [4:0] audio_valid,
    input  wire       audio_busy,
    input  wire       audio_done,
    input  wire [7:0] audio_error,
    output reg        audio_start,
    output reg  [2:0] audio_file_idx,
    output wire       audio_stop,
    output reg        stream_restart,
    output wire       stream_flush,
    output reg        track_active
);
localparam [2:0] S_IDLE = 3'd0, S_ARM = 3'd1, S_PLAY = 3'd2, S_STOP = 3'd3,
                 S_FLUSH = 3'd4, S_FAIL = 3'd5;
localparam integer FLUSH_N = (FLUSH_CYCLES < 1) ? 1 : FLUSH_CYCLES;
localparam integer FLUSH_W = (FLUSH_N <= 1) ? 1 : $clog2(FLUSH_N);

reg [2:0] state;
reg [FLUSH_W-1:0] flush_count;
reg fail;
wire want = enable && display_valid && display_file <= 3'd4 && audio_valid[display_file];
wire changed = !want || (display_file != audio_file_idx);

assign audio_stop = (state == S_STOP);
assign stream_flush = (state == S_FLUSH);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state <= S_IDLE;
        flush_count <= 0;
        fail <= 1'b0;
        audio_start <= 1'b0;
        audio_file_idx <= 3'd0;
        stream_restart <= 1'b0;
        track_active <= 1'b0;
    end else begin
        audio_start <= 1'b0;
        stream_restart <= 1'b0;
        case (state)
            S_IDLE: if (want && !audio_busy) begin
                audio_file_idx <= display_file;
                audio_start <= 1'b1;
                stream_restart <= 1'b1;
                track_active <= 1'b1;
                state <= S_ARM;
            end
            // 读取器在 start 次拍才置 busy。
            S_ARM: if (audio_busy) state <= S_PLAY;
            S_PLAY: if (changed) begin
                state <= S_STOP;
            end else if (audio_done && audio_error == 8'd0) begin
                audio_start <= 1'b1;
                stream_restart <= 1'b1;
                state <= S_ARM;
            end else if (audio_done || !audio_busy) begin
                track_active <= 1'b0;
                fail <= 1'b1;
                flush_count <= 0;
                state <= S_FLUSH;
            end
            S_STOP: if (!audio_busy) begin
                fail <= 1'b0;
                flush_count <= 0;
                state <= S_FLUSH;
            end
            S_FLUSH: if (flush_count == FLUSH_N - 1) begin
                if (fail) begin
                    state <= S_FAIL;
                end else if (want) begin
                    audio_file_idx <= display_file;
                    audio_start <= 1'b1;
                    stream_restart <= 1'b1;
                    state <= S_ARM;
                end else begin
                    track_active <= 1'b0;
                    state <= S_IDLE;
                end
            end else begin
                flush_count <= flush_count + 1'b1;
            end
            S_FAIL: if (changed) state <= S_IDLE;
            default: begin
                track_active <= 1'b0;
                state <= S_IDLE;
            end
        endcase
    end
end
endmodule
