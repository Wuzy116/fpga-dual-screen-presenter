


`define   DATA_WIDTH                        32
`define   ADDR_WIDTH                        21
`define   DM_WIDTH                          4

`define   ROW_WIDTH                        11
`define   BA_WIDTH                        2

// 必须与 sys_pll_promax_40 C1/C2 一致；括号避免嵌套宏展开后连除变为 0。
`define   SDR_CLK_FREQ_HZ                   40000000
`define   SDR_CLK_PERIOD                    (1000000000 / `SDR_CLK_FREQ_HZ)
`define   SELF_REFRESH_INTERVAL             (64000000 / `SDR_CLK_PERIOD / (2**(`ROW_WIDTH)))

