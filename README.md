# 基于安路 FPGA 的双屏演讲系统 —— 源码说明

- 器件：安路 EG4S20BG256（HX4S20C 开发板）
- 开发工具：TangDynasty 6.2.1（6.2.168116）
- 顶层模块：`top`（`user_source/hdl_source/top_tf_hdmi_audio.v`）
- 本源码与板上运行版本一致：LUT 19155/19600（97.73%），建立余量 +0.324 ns，保持余量 +0.024 ns

## 编译

1. 用 TD 打开 `td_project/HDMI1.4b_Transmitter_v1.0.al`。
2. 直接点“编译”（Run All）。工程已设置好综合策略（area_prior、pack_effort high）和布局布线参数（opt_timing high、seed 9、routability）。
3. 比特流生成在 `td_project/HDMI1.4b_Transmitter_v1.0_Runs/best_result/`。

注意：工程开启了 Multi-Seed（只有 seed 9 一个）。器件 Slice 占用超过 90% 后，布线器会跳过自带的保持时间修复；
TD 只有在 Multi-Seed 流程中才会在布线后单独执行 `fix_hold`。关闭 Multi-Seed 会出现保持时间违例，请保留该设置。

## 目录

```
td_project/HDMI1.4b_Transmitter_v1.0.al     TD 工程文件（源文件列表、约束、综合与布局布线参数）
user_source/
  constraints_source/
    pin.adc                                 引脚约束
    timing.sdc                              时序约束
  hdl_source/
    top_tf_hdmi_audio.v                     顶层：时钟复位、两路视频流水线、音频、各子系统连接
    hdmi_phy_warpper.v, lane_lvds_10_1.v    TMDS 10:1 DDR 串行化（两路共用）
    audio_arc_calculate.v                   HDMI 音频 ACR（CTS 计数）
    IP/       sys_pll_promax_40.v           PLL：25 / 40 / 40(相移) / 125 MHz
              afifo_32_16_256.*             异步 FIFO IP（.ipc 配置、.v 生成文件、.tcl 时序约束）
    include/  sdr_*.enc.v, global_def.v     安路 SDRAM 控制器（厂商加密源码）
    common/   sync_2ff.v, reset_sync.v      跨时钟域两级同步、复位同步
    SD/       （控制域、存储域、观众屏像素域）
      sd_card_*.v, spi_master.v             SD 卡 SPI 驱动与扇区读写
      fat32_*.v, sd_sector_adapter.v        FAT32 扫描与文件流
      bmp_read.v, media_image_scaler.v      BMP 解析、任意尺寸双线性缩放
      sd_card_bmp.v                         存储与播放子系统顶层（预加载、播放控制、按键路由、讲稿装载）
      media_*.v                             预加载、轮播、缩略图、转场、黑场、价格揭晓、SDRAM 读写与仲裁、特效
      brightness_contrast_adjust.v          亮度对比度
      promax_text_overlay.v, subtitle_rom.v 滚动字幕
      qr_overlay.v, qr_rom.v                二维码
      promax_audio_waveform.v, osd_*.v      音乐波形、OSD
      w25q64_*.v, config_*.v, player_config_persistence.v, spi_byte_engine.v
                                            W25Q64 参数日志（双槽记录 + CRC）
      seg_*.v                               数码管
      dual_key_chord_router.v               按键单击 / 双击 / 长按 / 同按识别
    prompter/ （提词屏）
      prompter_script_*.v                   讲稿装载、写入与按行读取
      prompter_window_ctrl.v, prompter_nav.v, prompter_scroll_pace.v
                                            翻页、匀速 / 声控滚动
      prompter_timer_bar.v                  计时条
      prompter_mic_meter.v                  话筒电平条
      prompter_line_mirror.v                可选整行镜像（分光玻璃用）
      dvi_symbol_core.v                     提词屏 DVI 编码
      ir_nec_remote.v                       红外遥控 NEC 解码
    audio/    （音频）
      wav_stream_player.v                   TF 卡 PCM 流播放
      audio_pcm_volume.v, audio_*_cdc.v     音量、跨时钟域
      mic_voice_duck.v                      INMP441 接收、语音检测、背景音乐闪避
      media_shutter_click.v                 快门声
      hdmi_*.v                              HDMI 数据岛（音频包、ACR、InfoFrame、BCH、TERC4/TMDS 编码）
      HDMI_REFERENCE_LICENSE.txt            HDMI 封包参考实现的 MIT 许可声明
```

## TF 卡内容（根目录）

| 文件 | 格式 | 说明 |
|---|---|---|
| PIC1.BMP ~ PIC5.BMP | 24 位 BMP，任意尺寸 | 观众屏背景页，自动等比缩放到 640×480 |
| MUS1.PCM ~ MUS5.PCM | 48 kHz、16 位、单声道、无文件头 | 每张背景页对应的音乐 |
| SnPmm.BMP | 640×480、1 位 BMP | 提词屏讲稿，n 为节号，mm 为页号 |

## 外接模块

- INMP441 数字麦克风：J1-29 3.3 V、J1-30 GND（L/R 接 GND）、J1-31 SCK、J1-32 WS、J1-33 SD
- VS1838B 红外接收：J1-11 5 V、J1-12 GND、OUT 经 10 kΩ/20 kΩ 分压接 J1-34

## 第三方代码

- `include/sdr_*.enc.v`：安路 SDRAM 控制器，厂商提供的加密源码。
- `IP/afifo_32_16_256.*`：由 TD IP 生成器生成；`IP/sys_pll_promax_40.v`：由 TD IP 生成器生成后手工调整了 SDRAM 时钟相位。
- HDMI 数据岛封包参考了 hdl-util/hdmi（MIT 许可），许可声明见 `audio/HDMI_REFERENCE_LICENSE.txt`。


