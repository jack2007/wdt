# WDT 200G 调优与复测结果（2026-06-07）

结果目录：`~/wdt_200g_results/20260607_093813_tuning/`

---

## 1. iperf3 线速排查

### 环境发现
| 项目 | 结论 |
|------|------|
| 网卡 | 双口 NVIDIA ConnectX-7（mlx5_core），各 200000Mb/s，MTU 9000 |
| 测试链路 | `enp1s0f0np0`（PCIe 0000:01:00.0, Gen5 x4）↔ 对端同架构 |
| 第二口 | `enP2p1s0f0np0` 同为 200G，但 ring buffer 仅 1024（测试口为 8192） |
| 路由 | 已设 host route `169.254.59.196/32 dev enp1s0f0np0 metric 50`（双向） |
| IRQ | 20 个 `mlx5_comp` 队列，各绑定独立 CPU（1–19） |
| RPS/XPS | 调优前全 0；调优后设为 `fffff`（20 核全掩码） |
| NUMA | 单节点，20 核 ARM |

### 已应用调优
- `net.core.rmem_max/wmem_max = 512MB`
- `tcp_rmem/wmem` 上限 512MB
- `netdev_max_backlog = 250000`
- `tcp_mtu_probing = 1`
- RPS/XPS 全 CPU 掩码（本机 + 对端）

### iperf3 复测（调优后，30s，bind 169.254.250.230）
| 并行流 | 调优前 | 调优后 |
|--------|--------|--------|
| P16 | ~105 Gbps | **~104 Gbps** |
| P32 | ~105 Gbps | **~104 Gbps** |

**结论**：RPS/IRQ/路由调优**未提升** iperf3 吞吐。观察到 `rx_pause_ctrl_phy` 持续增长，存在流控背压。在当前单线缆 200G 直连拓扑下，**有效 TCP 线速天花板约 104 Gbps（~52% 标称 200G）**，瓶颈更可能在物理链路/光模块协商速率或单口 TCP 栈极限，而非路由错误。

---

## 2. WDT 参数扫描（纯网络，16GB，1 轮/配置）

| 配置 | NUM_PORTS | buffer | sock buf | 吞吐 (MiB/s) | Gbps 等效 |
|------|-----------|--------|----------|-------------|-----------|
| baseline | 10 | 4M | 16M | 10,215 | 79.8 |
| **ports16** | **16** | 4M | 16M | **12,200** | **95.3** |
| ports32 | 32 | 4M | 16M | 12,067 | 94.3 |
| buf8M | 10 | 8M | 16M | 9,827 | 76.8 |
| sock32M | 10 | 4M | 32M | 9,465 | 73.9 |
| **ports32_buf8M** | **32** | **8M** | 16M | **12,222** | **95.5** |

**最优配置**：`NUM_PORTS=16` 或 `32`（差异 <1%），`buffer_size=4M` 优于 8M（单独使用时）；增大 socket buffer 至 32M **降低** 吞吐。

**推荐生产参数**：
```bash
NUM_PORTS=16   # 或 32，视 CPU 负载
WDT_BUFFER_SIZE=4194304
WDT_SEND_BUF_SIZE=16777216
WDT_RECV_BUF_SIZE=16777216
```

---

## 3. NVMe 端到端复测（20GB，NUM_PORTS=16）

> **独立分区**：机器无单独 NVMe 测试分区；数据路径为根分区 `nvme0n1p2`（Samsung 3.7T）上的 `/home/jack/wdt_nvme_bench/`。

| 场景 | drop cache | odirect_reads | 吞吐 (MiB/s) | MD5 |
|------|------------|---------------|-------------|-----|
| 首次测试（上次） | 否 | 否 | 1,718 | PASS |
| dropcache_baseline | **是** | 否 | **1,732** | PASS |
| dropcache_odirect | **是** | **是** | 1,663 | PASS |

**结论**：
- drop cache 后略提升至 ~1.73 GB/s，仍远低于纯网络 ~12 GB/s → **磁盘为瓶颈**
- `-odirect_reads` 在本环境**未改善**（略降 4%），可能因单大文件顺序读已接近 page cache 效率
- 如需进一步提速：需独立 NVMe 分区、XFS/ext4 `nobarrier`、或 `-odirect_reads` 配合 `-open_files_during_discovery`

---

## 4. 综合建议

1. **接受 ~100 Gbps 链路上限**，或更换/确认光模块与线缆是否协商到 200G FEC
2. **WDT 网络**：将默认 `NUM_PORTS` 从 10 提升到 **16**
3. **WDT NVMe**：保持默认 buffer；drop cache 用于公平基准；odirect 可选但不必须
4. **可选进阶**：双口 bond/LACP（若线缆支持）、`ethtool -C` 中断合并调参、远端独立 NVMe mount point

### 脚本增强（本次）
- `wdt_200g_env.sh` 新增：`WDT_BUFFER_SIZE`、`WDT_SEND_BUF_SIZE`、`WDT_RECV_BUF_SIZE`、`WDT_ODIRECT_READS`、`WDT_EXTRA_OPTS`
