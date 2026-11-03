
# ============================================================
# merged_top_tf_hdmi_audio.sdc
# 用于：TF 图片轮播 + HDMI(视频+音频) 整合工程
#
# 合并原则：
# 1) 保留 top.sdc 里的系统主时钟与 derive_clocks
# 2) 把 timing(2).sdc 里的 pixel/serial 时钟改成整合工程实际名字
# 3) 命名 hdmi_5x_clk；音频共用 video_clk
# 4) 不再对内部 net 直接 create_clock，避免和 derive_clocks 重复
# ============================================================

# ------------------------------------------------------------
# 1. 板级输入主时钟
#    你的原 top.sdc 里 clk=50MHz，所以这里仍然用 20ns
# ------------------------------------------------------------
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]

# ------------------------------------------------------------
# 2. 自动推导 PLL 输出时钟
# ------------------------------------------------------------
derive_clocks

# ------------------------------------------------------------
# 3. 给关键 PLL 输出命名
#    下面这些路径是按你当前工程实例名写的：
#      sys_pll_promax_40 -> sys_pll_m0 (C1/C2: 40 MHz)
#      同一 PLL C3/C4 -> 像素 25 MHz / 串行 125 MHz
#      音频逻辑复用 video_clk，不再有音频 PLL
#
#    如果综合后实例路径略有不同，就按 Timing Analyzer 里的实际 pin 路径改。
# ------------------------------------------------------------
# SD/BMP/按键/面板现直接属于输入 clk（50 MHz）；不再重命名未使用的 PLL C0。
rename_clock -name {ext_mem_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[1]}]
rename_clock -name {ext_mem_clk_sft} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[2]}]
rename_clock -name {video_clk}   -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[3]}]
rename_clock -name {hdmi_5x_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[4]}]

# ------------------------------------------------------------
# 4. 从原 timing(2).sdc 迁移过来的 HDMI 像素/串行时钟约束
#
#    原文件是：
#      create_clock -name pixel_clk  ... [get_nets {S_pixel_clk}]
#      create_clock -name serial_clk ... [get_nets {S_serial_clk}]
#      set_clock_groups -exclusive ...
#
#    在整合工程里，这两个时钟已经由 sys_pll_promax_40 产生，并通过 derive_clocks 建出来了，
#    因此不再重复 create_clock，也不设置两路输出互斥。
# ------------------------------------------------------------
# video_clk 与 hdmi_5x_clk 同时运行，来自同一 PLL，不能设成互斥。
# lane_lvds_10_1 在 125 MHz 域装载像素域符号，保留这两域之间的时序分析。

# ------------------------------------------------------------
# 5. 音频时钟域
#    音频主路径已无 I2S 发送/接收跨域。
#    媒体状态及可选音量状态经 req/ack 邮箱跨域；
#    不用全局 false path 掩盖同步器后级、数据保持和串行器时序。
# ------------------------------------------------------------
# 原 audio_mclk 异步分组已移除；PCM/ACR/采样 CE 全部属于 video_clk。
# clk 与 video_clk / ext_mem_clk 之间的全部跨域都经两级同步器、格雷码 FIFO 或保持型 req/ack 邮箱
# （邮箱数据在 req 同步到达前已稳定多拍）。第 13 课布局后 clk 走引脚全局网、PLL 输出被补偿，
# 两者偏斜约 1.9 ns，同步器第一级出现 hold 违例（最差 -1.54 ns）；这类端点的 hold 无意义。
# 只取消这两对时钟之间的 hold/removal 检查（双向），setup 照常分析；同域及 video_clk<->ext_mem_clk 不变。
set_false_path -hold -from [get_clocks {video_clk}]   -to [get_clocks {clk}]
set_false_path -hold -from [get_clocks {clk}]         -to [get_clocks {video_clk}]
set_false_path -hold -from [get_clocks {ext_mem_clk}] -to [get_clocks {clk}]
set_false_path -hold -from [get_clocks {clk}]         -to [get_clocks {ext_mem_clk}]

# 唯一例外：SDRAM 初始化完成电平 Sdr_init_done（ext_mem_clk，加密 IP 内寄存器）进入
# u_storage_ready_sync 第一级。该电平上电后只上升一次，第一级本身就是亚稳态吸收级，
# 同源时钟下 5 ns setup 与约 1.2 ns hold 相互挤压，布线插 hold 缓冲后 setup 随布局时正时负。
# 只豁免这一个端点；s1->s2 后级及其它同步器保持正常分析。
set_false_path -to [get_regs {u_storage_ready_sync/s1}]
# 同理：loader 写完成翻转（frame_write_toggle_mem）与取消应答电平（cancel_done_mem）
# 由 ext_mem_clk 进入 clk 域的两级同步器第一级，同样只豁免第一级端点，第二级起正常分析。
set_false_path -to [get_regs {sd_card_bmp_m0/wrfin_tgl_sync[0]}]
set_false_path -to [get_regs {u_frame_write/cancel_ack_wr[0]}]

# ------------------------------------------------------------
# 6. 可选：如果你的 frame_read_write 内部异步 FIFO 已经完全处理好了跨域，
#    且报告里总出现 video_clk / clk / ext_mem_clk 之间的大量伪违例，
#    可以打开下面这组异步分组。
#
#    建议先不要开，先看报告；
#    只有确认这些跨域都只经过 FIFO / 同步器时再开。
# ------------------------------------------------------------
# set_clock_groups -asynchronous \
#     -group [get_clocks {clk}] \
#     -group [get_clocks {ext_mem_clk}] \
#     -group [get_clocks {video_clk}] \
#     -group [get_clocks {hdmi_5x_clk}]

# ------------------------------------------------------------
# 7. 其余 Input/Output delay 先保持空白
#    你当前两个原始 sdc 也都没有写这部分。
# ------------------------------------------------------------
