# WDT netem 测试 — TCP BBR

## 测试条件

| 项目 | 配置 |
|------|------|
| netem（发送端 spark-1619 `enp1s0f0np0`） | `delay 100ms loss 5% limit 1000000` |
| TCP 拥塞算法 | **bbr**（系统默认） |
| WDT | `NUM_PORTS=16`，8GB shm，`skip_writes=true`，`transfer_id=wdt200g_fixed` |
| 超时 | `connect_timeout=30s`，`read/write_timeout=120s`，`max_retries=10` |
| 并发连接 | **16** 条 TCP（端口 22356–22371） |

### netem 应用命令

```bash
sudo tc qdisc replace dev enp1s0f0np0 root netem delay 100ms loss 5% limit 1000000
```

## 结果（3 轮完成）

| 轮次 | Throughput (MiB/s) | 耗时 |
|------|-------------------|------|
| 1 | 1272.63 | ~20s |
| 2 | 1254.90 | ~20s |
| 3 | 1223.27 | ~21s |
| **平均** | **1250.3** | **≈9.9 Gbps** |

- 3 轮均 **OK**，无 `ID_MISMATCH` / `CONN_ERROR`
- netem 统计：`overlimits 0`（limit 1000000 无队列溢出丢包）
- 对比无 netem 基准（~12,200 MiB/s）：吞吐降至约 **10%**，WDT 在恶劣网络下仍可完成传输

## 对比参考

| 场景 | 平均吞吐 (MiB/s) |
|------|-----------------|
| 无 netem（NUM_PORTS=16） | ~12,200 |
| netem + BBR | **1,250** |
| netem + CUBIC（见 CUBIC 报告） | **8.82**（部分，终止） |

原始日志：`~/wdt_200g_results/20260607_105326_netem/`
