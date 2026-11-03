`timescale 1ns/1ps
// 第 10 课图片转场：像素域拦截目标槽号，决定 reader 本帧读哪个 bank，并对图片层做 alpha 衰减。
// 手动切换（target_manual=1）：淡出 FADE_FRAMES 帧（最后一帧全黑）-> 换槽 -> 淡入 FADE_FRAMES-1 帧。
// 自动轮播（target_manual=0）：从上到下 Wipe，前 split_words 个字读新图 bank，其余读旧图 bank，
// 每帧仍只读一整帧字数，不增加 SDRAM 带宽。
// 状态只在 frame_tick（与 reader 同一门控 frame_start）更新；reader/frame_slot_q 在下一拍采样，
// 一帧内 read_index/split_words/alpha 恒定。转场中的新目标在淡出结束时取最新值，
// 淡入/Wipe 中到达的目标留到回 IDLE 后再触发下一次转场。
// playing=0（首帧提交前或故障）时直接跟随目标，FADE_FRAMES=0 整体旁路为硬切。
// 第 15 课：目标为 {target_sheet, target_slot}，总览页 bank 与各背景图同为转场目标（D19：槽号 3 位，0..4）；
// 进入/退出总览页及从总览页确认均走淡出 -> 换 bank -> 淡入（不用 Wipe），read_sheet 与 read_index 同拍切换。
// audio_alpha 只在槽号真正改变的淡变中跟随 alpha，仅进出总览页（同槽）时音量不变。
// D22 左右滑动（ENABLE_SLIDE=1）：手动换图（不涉及总览页）改为推入——下一张从右往左推入、上一张从左往右推入，
//   SLIDE_FRAMES 帧完成，每帧推进 FRAME_WIDTH/SLIDE_FRAMES 列。reader 每行分两段读：前 slide_cols 列一个 bank、其余另一个，
//   slide_left=1 时前段读旧图（alt）、后段读新图（read），=0 时相反；每帧仍读一整帧字数。方向由槽号推断：目标 = 显示槽 - 1，
//   或显示槽为 0 且目标不是 1（从首张回绕到末张）时为“上一张”，否则为“下一张”。滑动开始即 read_index = 新槽，音乐随之淡入。
module video_transition_ctrl #(
    parameter integer FADE_FRAMES  = 16,
    parameter integer IMAGE_WORDS  = 307200,
    parameter integer FRAME_HEIGHT = 480,
    parameter integer BURST_SIZE   = 128,
    parameter integer ADDR_WIDTH   = 21,
    parameter integer ENABLE_SLIDE = 0,
    parameter integer FRAME_WIDTH  = 640,
    parameter integer SLIDE_FRAMES = 32
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  frame_tick,
    input  wire                  playing,
    input  wire [2:0]            target_slot,
    input  wire                  target_sheet,
    input  wire                  target_manual,
    input  wire [23:0]           rgb_in,
    output wire [2:0]            read_index,
    output wire                  read_sheet,
    output wire [2:0]            alt_index,
    output wire [ADDR_WIDTH:0]   split_words,
    output wire [7:0]            alpha,
    output wire [7:0]            audio_alpha,
    output wire                  active,
    output wire                  wipe_active,
    output wire                  fading,
    output wire                  slide_active,
    output wire                  slide_left,
    output wire [9:0]            slide_cols,
    output wire [23:0]           rgb_out
);
    generate
        if (FADE_FRAMES == 0) begin : g_bypass
            assign read_index  = target_slot;
            assign read_sheet  = target_sheet;
            assign alt_index   = target_slot;
            assign split_words = IMAGE_WORDS;
            assign alpha       = 8'd255;
            assign audio_alpha = 8'd255;
            assign active      = 1'b0;
            assign wipe_active = 1'b0;
            assign fading      = 1'b0;
            assign slide_active = 1'b0;
            assign slide_left  = 1'b1;
            assign slide_cols  = FRAME_WIDTH;
            assign rgb_out     = rgb_in;
        end else begin : g_transition
            localparam integer STEP       = 256 / FADE_FRAMES;
            localparam integer STEP_WORDS = IMAGE_WORDS / FADE_FRAMES;
            localparam integer CNT_W      = (FADE_FRAMES <= 2) ? 1 : $clog2(FADE_FRAMES);
            localparam [CNT_W-1:0] RAMP_LAST = FADE_FRAMES - 1;

            localparam [2:0] S_IDLE  = 3'd0;
            localparam [2:0] S_OUT   = 3'd1;
            localparam [2:0] S_IN    = 3'd2;
            localparam [2:0] S_WIPE  = 3'd3;
            localparam [2:0] S_SLIDE = 3'd4;
            localparam integer SLIDE_STEP = FRAME_WIDTH / SLIDE_FRAMES;
            localparam integer SLIDE_ASTEP = 256 / SLIDE_FRAMES;

            // synthesis translate_off
            initial begin
                if (FADE_FRAMES < 2 || (256 % FADE_FRAMES) != 0 ||
                    (FRAME_HEIGHT % FADE_FRAMES) != 0 ||
                    (IMAGE_WORDS % FADE_FRAMES) != 0 ||
                    (STEP_WORDS % BURST_SIZE) != 0) begin
                    $display("MEDIA_CONFIG_ERROR video_transition_ctrl %m: FADE_FRAMES must divide 256, height and image into whole bursts");
                    $finish;
                end
                if (ENABLE_SLIDE && (SLIDE_FRAMES < 2 || SLIDE_FRAMES > 63 || (256 % SLIDE_FRAMES) != 0 ||
                    (FRAME_WIDTH % SLIDE_FRAMES) != 0 || (SLIDE_STEP % 4) != 0 || FRAME_WIDTH > 1023)) begin
                    $display("MEDIA_CONFIG_ERROR video_transition_ctrl %m: SLIDE_FRAMES must divide 256 and width into 4-word steps");
                    $finish;
                end
            end
            // synthesis translate_on

            reg [2:0]          state;
            reg [5:0]          slide_k;     // 已推进的步数 1..SLIDE_FRAMES-1
            reg                slide_dir;   // 1 = 下一张（向左推入）
            reg [2:0]          slide_slot;
            reg [CNT_W-1:0]    ramp;
            reg [2:0]          shown_slot;
            reg                shown_sheet;
            reg                fade_slot;   // S_IN：本次淡变是否换了槽
            reg [2:0]          wipe_slot;
            reg [ADDR_WIDTH:0] split_q;

            assign fading = (state == S_OUT) || (state == S_IN);
            wire [CNT_W+8:0] ramp_alpha = ramp * STEP;

            assign read_index  = (state == S_WIPE) ? wipe_slot : (state == S_SLIDE) ? slide_slot : shown_slot;
            assign read_sheet  = shown_sheet;
            assign alt_index   = shown_slot;
            assign split_words = (state == S_WIPE) ? split_q : IMAGE_WORDS;
            assign alpha       = fading ? ramp_alpha[7:0] : 8'd255;
            wire   slot_fading = (state == S_OUT) ? (target_slot != shown_slot) : (state == S_IN) && fade_slot;
            wire [13:0] slide_audio = slide_k * SLIDE_ASTEP;
            assign audio_alpha = slot_fading ? ramp_alpha[7:0] : (state == S_SLIDE) ? slide_audio[7:0] : 8'd255;
            wire   target_change = (target_slot != shown_slot) || (target_sheet != shown_sheet);
            wire   use_fade = target_manual || target_sheet || shown_sheet;
            wire   use_slide = ENABLE_SLIDE && target_manual && !target_sheet && !shown_sheet;
            wire   go_prev = (target_slot + 3'd1 == shown_slot) || (shown_slot == 3'd0 && target_slot != 3'd1);
            wire [15:0] slide_off = slide_k * SLIDE_STEP;   // 已推入的列数
            assign slide_active = (state == S_SLIDE);
            assign slide_left   = slide_dir;
            assign slide_cols   = slide_dir ? FRAME_WIDTH - slide_off[9:0] : slide_off[9:0];
            assign active      = (state != S_IDLE);
            assign wipe_active = (state == S_WIPE);

            // alpha=255 透传原像素，避免常态画面被 >>8 整体压暗 1 LSB。
            wire [15:0] mul_r = rgb_in[23:16] * alpha;
            wire [15:0] mul_g = rgb_in[15:8]  * alpha;
            wire [15:0] mul_b = rgb_in[7:0]   * alpha;
            assign rgb_out = fading ? {mul_r[15:8], mul_g[15:8], mul_b[15:8]} : rgb_in;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    state      <= S_IDLE;
                    ramp       <= {CNT_W{1'b0}};
                    shown_slot <= 3'd0;
                    shown_sheet <= 1'b0;
                    fade_slot  <= 1'b0;
                    slide_k    <= 6'd0;
                    slide_dir  <= 1'b1;
                    slide_slot <= 3'd0;
                    wipe_slot  <= 3'd0;
                    split_q    <= {(ADDR_WIDTH+1){1'b0}};
                end else if (!playing) begin
                    state      <= S_IDLE;
                    ramp       <= {CNT_W{1'b0}};
                    shown_slot <= target_slot;
                    shown_sheet <= target_sheet;
                end else if (frame_tick) begin
                    case (state)
                        S_IDLE: if (target_change) begin
                            if (use_slide) begin
                                state      <= S_SLIDE;
                                slide_k    <= 6'd1;
                                slide_dir  <= !go_prev;
                                slide_slot <= target_slot;
                            end else if (use_fade) begin
                                state <= S_OUT;
                                ramp  <= RAMP_LAST;
                            end else begin
                                state     <= S_WIPE;
                                ramp      <= {{(CNT_W-1){1'b0}}, 1'b1};
                                wipe_slot <= target_slot;
                                split_q   <= STEP_WORDS;
                            end
                        end
                        S_OUT: if (ramp == {CNT_W{1'b0}}) begin
                            state      <= S_IN;
                            ramp       <= {{(CNT_W-1){1'b0}}, 1'b1};
                            shown_slot <= target_slot;
                            shown_sheet <= target_sheet;
                            fade_slot  <= target_slot != shown_slot;
                        end else begin
                            ramp <= ramp - 1'b1;
                        end
                        S_IN: if (ramp == RAMP_LAST)
                            state <= S_IDLE;
                        else
                            ramp <= ramp + 1'b1;
                        S_SLIDE: if (slide_k == SLIDE_FRAMES - 1) begin
                            state      <= S_IDLE;
                            shown_slot <= slide_slot;
                        end else begin
                            slide_k <= slide_k + 6'd1;
                        end
                        default: if (ramp == RAMP_LAST) begin
                            state      <= S_IDLE;
                            shown_slot <= wipe_slot;
                        end else begin
                            ramp    <= ramp + 1'b1;
                            split_q <= split_q + STEP_WORDS;
                        end
                    endcase
                end
            end
        end
    endgenerate
endmodule
