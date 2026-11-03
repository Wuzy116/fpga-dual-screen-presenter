`timescale 1ns/1ps
// 控制域拨码解码 + 画面参数（D18）。拨码拨上为 1：sw[0]=SW1 … sw[3]=SW4。
// SW1：参数修改开关（param_mode，拨下锁定）。SW2/SW3 选调节对象 param_sel：
//   SW2 下 SW3 下 = 0 周期，SW2 上 SW3 下 = 1 音量，SW2 上 SW3 上 = 2 亮度，SW2 下 SW3 上 = 3 对比度。
// SW4：拨上 = 按键控制观众屏，拨下 = 提词屏（prompter_mode=1）。
// 拨码两拍同步后需连续稳定 STABLE_CYCLES 拍才采用；复位值：锁定、周期、观众屏。
// 亮度/对比度：increase/decrease_event 由上游只在参数模式下给出，这里按 param_sel 作用于亮度或对比度，
// 步长 1，复位为 128（原图），饱和不回绕，增减同拍抵消；本模块不写 Flash。
// restore_write（Flash 开机恢复，单拍）优先于同拍增减，装入 restore_brightness/contrast。
// ENABLE_DIRECT=1：另有 bright_inc/dec、contrast_inc/dec（红外遥控 3/7、4/8），不看 SW1/SW2/SW3，与拨码事件同拍时合并。
module media_picture_adjust #(
    parameter integer STABLE_CYCLES = 1_000_000,
    parameter ENABLE_DIRECT = 0
) (
    input  wire       clk,
    input  wire       rst,
    input  wire [3:0] sw,
    input  wire       increase_event,
    input  wire       decrease_event,
    input  wire       bright_inc,
    input  wire       bright_dec,
    input  wire       contrast_inc,
    input  wire       contrast_dec,
    input  wire       restore_write,
    input  wire [7:0] restore_brightness,
    input  wire [7:0] restore_contrast,
    output reg        param_mode,
    output reg  [1:0] param_sel,
    output reg  [7:0] brightness,
    output reg  [7:0] contrast,
    output reg        prompter_mode
);
    // synthesis translate_off
    initial begin
        if (STABLE_CYCLES < 1 || STABLE_CYCLES > 1_048_575) begin
            $display("MEDIA_CONFIG_ERROR picture_adjust %m: STABLE_CYCLES must be 1..1048575");
            $finish;
        end
    end
    // synthesis translate_on
    localparam [1:0] SEL_BRIGHT = 2'd2;
    localparam [1:0] SEL_CONTRAST = 2'd3;

    wire b_inc = (param_mode && param_sel == SEL_BRIGHT && increase_event) || (ENABLE_DIRECT && bright_inc);
    wire b_dec = (param_mode && param_sel == SEL_BRIGHT && decrease_event) || (ENABLE_DIRECT && bright_dec);
    wire c_inc = (param_mode && param_sel == SEL_CONTRAST && increase_event) || (ENABLE_DIRECT && contrast_inc);
    wire c_dec = (param_mode && param_sel == SEL_CONTRAST && decrease_event) || (ENABLE_DIRECT && contrast_dec);

    (* ASYNC_REG="TRUE" *) reg [3:0] sw_s1, sw_s2;
    reg [3:0] sw_cand;
    reg [19:0] stable_count;

    function [7:0] adjust;
        input [7:0] value;
        input inc, dec;
        begin
            if (inc && !dec)
                adjust = (value == 8'd255) ? value : value + 8'd1;
            else if (dec && !inc)
                adjust = (value == 8'd0) ? value : value - 8'd1;
            else
                adjust = value;
        end
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sw_s1 <= 4'd0;
            sw_s2 <= 4'd0;
            sw_cand <= 4'd0;
            stable_count <= 20'd0;
            param_mode <= 1'b0;
            param_sel <= 2'd0;
            prompter_mode <= 1'b0;
            brightness <= 8'd128;
            contrast <= 8'd128;
        end else begin
            sw_s1 <= sw;
            sw_s2 <= sw_s1;
            if (sw_s2 != sw_cand) begin
                sw_cand <= sw_s2;
                stable_count <= 20'd0;
            end else if (stable_count < STABLE_CYCLES - 1) begin
                stable_count <= stable_count + 1'b1;
            end else begin
                param_mode <= sw_cand[0];
                param_sel <= {sw_cand[2], sw_cand[1] ^ sw_cand[2]};
                prompter_mode <= !sw_cand[3];
            end
            if (restore_write) begin
                brightness <= restore_brightness;
                contrast <= restore_contrast;
            end else begin
                brightness <= adjust(brightness, b_inc, b_dec);
                contrast <= adjust(contrast, c_inc, c_dec);
            end
        end
    end
endmodule
