# WDT 200G 双 DGX 基准测试报告索引

测试环境：spark-1619 ↔ spark-1b6f，200Gbps 直连（`enp1s0f0np0`），WDT v1.32.1910230。

| 报告 | 说明 |
|------|------|
| [20260607_baseline_RESULTS.md](20260607_baseline_RESULTS.md) | 首次分层基准（iperf3 + WDT 网络 + NVMe） |
| [20260607_tuning_TUNING_RESULTS.md](20260607_tuning_TUNING_RESULTS.md) | 链路调优、NUM_PORTS 扫描、NVMe 复测 |
| [20260607_netem_BBR_RESULTS.md](20260607_netem_BBR_RESULTS.md) | netem 100ms+5% 丢包，TCP **BBR** |
| [20260607_netem_CUBIC_PARTIAL_RESULTS.md](20260607_netem_CUBIC_PARTIAL_RESULTS.md) | 相同 netem，TCP **CUBIC**（提前终止） |

执行脚本见同目录上级：`wdt_200g_env.sh`、`wdt_200g_sync.sh`、`wdt_200g_bench.sh`。  
完整原始日志位于各测试机 `~/wdt_200g_results/<timestamp>/`（未纳入 git，体积过大）。
