# WDT 200Gbps 双 DGX 传输性能测试计划

本文档记录两台 DGX 通过 **200Gbps 直连线缆** 验证 WDT（Warp-speed Data Transfer）传输能力的测试方案、环境配置、执行步骤与结果解读标准。

**相关脚本**（同目录）：

| 文件 | 说明 |
|------|------|
| `wdt_200g_env.sh` | 环境变量与 WDT 公共参数 |
| `wdt_200g_sync.sh` | 依赖安装 + 二进制同步到对端 |
| `wdt_200g_bench.sh` | 分阶段 benchmark 编排 |

**WDT 构建产物**（本机编译，同步至对端相同路径）：

```text
/home/jack/src/msquic/src/tools/wdt-build/_bin/wdt/wdt
```

---

## 1. 测试目标

在 200Gbps 直连环境下，量化 WDT 的：

1. **网络吞吐上限**（Receiver 不落盘，排除磁盘瓶颈）
2. **端到端吞吐**（NVMe/shm → 网络 → 落盘）
3. **稳定性**（多轮重复、长时间运行）
4. **功能开销**（加密、校验对吞吐的影响，可选）

### 1.1 成功标准（建议）

| 层级 | 指标 | 参考阈值 |
|------|------|----------|
| 链路基线（最低可测） | iperf3 多流（-P 16/32） | ≥ 150 Gbps（约线速 75%），低于该值不进入 WDT 测试 |
| 链路基线（正式性能） | iperf3 多流（-P 16/32） | 建议 ≥ 180 Gbps；若低于该值，先完成链路/内核/网卡调优再做正式轮次 |
| WDT 纯网络 | `skip_writes=true`，数据在 `/dev/shm` | ≥ 15,000 MiB/s（约 120 Gbps）为良好；≥ 20,000 MiB/s 为优秀 |
| WDT 端到端 | NVMe → NVMe，大文件 | 受磁盘限制，记录绝对值并与 iowait 对照 |
| 正确性 | MD5 / 文件数一致 | NVMe/落盘场景 100% 通过；`skip_writes=true` 纯网络场景不适用 |
| 稳定性 | 连续 10 轮 | 吞吐波动 < ±10% |

> WDT 使用 **MiB/s**（1 MiB = 1024×1024 字节）。200 Gbps 理论峰值约 **25,000 MiB/s**。  
> 官方 `wdt_max_send_test.sh` 在本地 loopback 上目标约 22–26 GB/s；跨机测试需先确认 iperf3 多流基线。

---

## 2. 已确认的环境前提

| 项目 | 说明 | 状态 |
|------|------|------|
| 链路 | 200Gbps 直连专用链路，不经交换机/路由 | ✅ 确认 |
| SSH | 双向免密，用户 `jack` | ✅ 确认 |
| WDT | 本机编译，需 rsync 到对端相同路径 | ✅ 脚本已支持 |
| 测试数据 | `/dev/shm`（纯网络）+ NVMe（端到端） | ✅ 确认 |

---

## 3. 环境拓扑（实测）

| 项目 | 本机 Sender | 对端 Receiver |
|------|-------------|---------------|
| 主机名 | `spark-1619` | `spark-1b6f` |
| 用户 | `jack` | `jack` |
| 200G 网卡 | `enp1s0f0np0` @ **200000Mb/s** | 同架构双口 |
| 直连 IP | `169.254.250.230` | `169.254.59.196` |
| CPU | 20 核 → 默认 `num_ports=10` | 20 核 |
| 存储 | `nvme0n1` 3.7T（根分区在 NVMe 上） | 同架构 |
| 管理网 | `172.16.10.80/24` | `172.16.10.81/24` |

**架构示意：**

```text
┌─────────────────────┐     200Gbps 直连      ┌─────────────────────┐
│  spark-1619 (Sender)│ ◄──────────────────► │  spark-1b6f (Recv)  │
│  jack@169.254.250.230│   enp1s0f0np0        │  jack@169.254.59.196│
│  /dev/shm + NVMe    │                       │  /dev/shm + NVMe    │
└─────────────────────┘                       └─────────────────────┘
```

---

## 4. 测试路径（推荐：分层基准）

| 方案 | 思路 | 适用场景 |
|------|------|----------|
| A. 快速验证 | iperf3 + 单次 WDT 传输 | 1 小时内连通性检查 |
| **B. 分层基准（推荐）** | 链路 → WDT 纯网络 → NVMe 端到端 → 调参 | 完整性能评估（1–2 天） |
| C. 生产仿真 | 目录树 + 加密 + 断点续传 | 功能验证，非吞吐上限 |

---

## 5. 分阶段测试计划

### 阶段 0：部署与同步

**目的**：本机构建 WDT，安装运行时依赖，将二进制与 `.so` 同步到对端。

```bash
cd /home/jack/src/msquic/src/tools/wdt/test

./wdt_200g_sync.sh
./wdt_200g_bench.sh env
```

**同步内容**：

- `wdt` 可执行文件
- `libwdt_min.so*`、`libfolly4wdt.so`
- `wdt_gen_files`（NVMe 测试数据生成，可选）

**对端运行时依赖**（脚本自动 apt 安装）：glog、gflags、double-conversion、Boost、OpenSSL、iperf3。

**部署后快照**（建议写入 `RESULT_DIR/env_snapshot.txt`）：

```bash
hostname -f
/home/jack/src/msquic/src/tools/wdt-build/_bin/wdt/wdt --version || true
ldd /home/jack/src/msquic/src/tools/wdt-build/_bin/wdt/wdt
ethtool enp1s0f0np0 | egrep 'Speed|Duplex|Auto-negotiation|Link detected'
ip -4 addr show dev enp1s0f0np0
ip route get 169.254.59.196
numactl --hardware || true
```

**关键注意**：`run_as_daemon=true` 模式下 Receiver 会持有初始化时的 `transfer_id`。如果 Receiver 未显式设置 `-transfer_id`，它会自动生成一个 id；Sender 每轮再传入不同 `-transfer_id` 会触发 `ID_MISMATCH`。因此多轮 daemon 测试必须采用以下任一策略：

1. Receiver 和所有 Sender 使用同一个固定 `-transfer_id`。
2. 每轮重启 Receiver，并让 Receiver 与 Sender 使用同一个 `-transfer_id`。
3. 使用 README 管道模式，由 Receiver 输出 URL 给 Sender，避免手工维护 id。

---

### 阶段 1：链路基线 — iperf3

**目的**：验证 200G 线缆/网卡/驱动正常，与 WDT 无关。

```bash
./wdt_200g_bench.sh link
```

日志默认写入：`~/wdt_200g_results/<timestamp>/iperf3_P{1,8,16,32}.log`。

**注意**：

- **单 TCP 流**通常无法吃满 200G（冒烟测试单流约 19 Gbps 属正常）。
- 以 **`-P 16` / `-P 32` 多流** 的 `[SUM]` Bitrate 为准。
- 若多流低于 150 Gbps，先完成第 7 节 sysctl 调优，不进入 WDT 测试。
- 若多流处于 150–180 Gbps，只能作为连通性/冒烟结果；正式性能评估建议继续调优到 ≥180 Gbps 后再开始。

---

### 阶段 2：WDT 纯网络吞吐

**目的**：Receiver `skip_writes=true` 不落盘，数据在 `/dev/shm`，隔离磁盘瓶颈。

```bash
./wdt_200g_bench.sh network
SHM_DATA_GB=16 TEST_RUNS=3 ./wdt_200g_bench.sh network
```

**流程概要**：

1. 本机 `prepare-shm`：混合文件尺寸（64K–512M）+ 填充至目标容量。
2. 检查 `/dev/shm` 可用空间大于 `SHM_DATA_GB`，避免数据准备不完整。
3. 检查 WDT 目的地址实际经由 200G 网卡：`ip route get <对端直连 IP>`。
4. 对端启动 Receiver：`-run_as_daemon=true -skip_writes=true -transfer_id=<固定ID>`。
5. 本机 Sender：`-destination <对端直连 IP> -transfer_id=<同一个固定ID>`，多轮执行。
6. 保存 `sar/vmstat/pidstat/ethtool` 监控日志，汇总 `Total sender throughput` 至 `network_summary.txt`。

**纯网络阶段说明**：Receiver 不落盘，不能做 MD5/文件数正确性校验；本阶段只验证 WDT 网络吞吐上限和连接稳定性。

**WDT 推荐参数**（已写入 `wdt_200g_env.sh`）：

```text
-num_ports=<nproc/2>
-encryption_type=none
-enable_checksum=false
-skip_fadvise
-avg_mbytes_per_sec=30000
-max_mbytes_per_sec=30001
-buffer_size=4194304
-send_buffer_size=16777216
-receive_buffer_size=16777216
```

**可选参数扫描**：`num_ports`（8/16/32）、`buffer_size`、`two_phases` true/false。参数扫描建议一次只改变一个变量，以便归因。

---

### 阶段 3：WDT 端到端 — NVMe

**目的**：读盘 → 网络 → 写盘，模拟生产路径。

```bash
./wdt_200g_bench.sh nvme
NVME_BIGFILE_GB=20 ./wdt_200g_bench.sh nvme
```

**数据路径**（两台相同）：

- SHM：`/dev/shm/wdt_bench/{src,dst}`
- NVMe：`/home/jack/wdt_nvme_bench/{src,dst}`（位于 NVMe 根分区）

**执行要求**：

- 每轮传输前清理目标目录：`rm -rf /home/jack/wdt_nvme_bench/dst/*`。
- 如需比较多轮绝对磁盘性能，记录是否执行 drop cache；不执行时需在结果中标注可能受 page cache 影响。
- 传输后执行文件数、总大小和 MD5 校验，校验日志保存到 `RESULT_DIR`。
- 测试期间在对端采集：`iostat -x 1`、`vmstat 1`、`pidstat -t -p $(pgrep -x wdt) 1`。

---

### 阶段 4：工作负载矩阵（可选）

| 场景 | 文件特征 | 数据量 | 关注点 |
|------|----------|--------|--------|
| S1 超大单文件 | 1×100GB | 100GB | 持续高吞吐 |
| S2 中等并行 | 32×4GB | 128GB | 多连接均衡 |
| S3 小文件风暴 | 10000×1MB | ~10GB | header / 元数据开销 |
| S4 目录树 | depth=4 | ~50GB | `-two_phases` 影响 |
| S5 混合尺寸 | 参考 `wdt_max_send_test.sh` | 64GB | 与上游基准对齐 |

---

### 阶段 5：功能开销对比（可选）

在最优 `num_ports` / buffer 配置下对比：

| 配置 | 预期 |
|------|------|
| `encryption_type=none`, `enable_checksum=false` | 吞吐上限 |
| `encryption_type=aes128_gcm` | CPU 开销，吞吐下降 |
| `enable_checksum=true` | 轻微下降 |
| 两者均开启 | 生产近似配置 |

---

### 阶段 6：稳定性（可选）

- 连续 **10 轮** S2 场景，记录均值与标准差。
- **1 小时**循环传输，监控内存、网卡 drop、`dmesg`。

---

## 6. 一键执行

```bash
cd /home/jack/src/msquic/src/tools/wdt/test

./wdt_200g_bench.sh all
./wdt_200g_bench.sh nvme
```

---

## 7. 测试前系统调优

**两台 DGX 均建议执行**（需 sudo）：

```bash
sudo sysctl -w net.core.rmem_max=134217728
sudo sysctl -w net.core.wmem_max=134217728
sudo sysctl -w net.ipv4.tcp_rmem="4096 87380 134217728"
sudo sysctl -w net.ipv4.tcp_wmem="4096 65536 134217728"
sudo sysctl -w net.core.netdev_max_backlog=250000
```

若两端均支持且已配置 **Jumbo Frame**，可统一 MTU（需双方一致）：

```bash
sudo ip link set enp1s0f0np0 mtu 9000
```

---

## 8. 监控与数据采集

**传输期间建议后台采集并写入 `RESULT_DIR`**：

```bash
sar -n DEV 1 > "$RESULT_DIR/sar_net.log" &

while true; do date -Is; ethtool -S enp1s0f0np0 | grep -Ei 'drop|error|timeout|discard'; sleep 1; done \
  > "$RESULT_DIR/ethtool_drops.log" &

vmstat 1 > "$RESULT_DIR/vmstat.log" &
iostat -x 1 > "$RESULT_DIR/iostat.log" &
pidstat -t -p $(pgrep -x wdt | paste -sd, -) 1 > "$RESULT_DIR/pidstat_wdt.log" &
```

纯网络阶段至少保存 `sar_net.log`、`ethtool_drops.log`、`vmstat.log`、`pidstat_wdt.log`；NVMe 阶段额外保存 `iostat.log`。测试结束后停止后台采集进程，并将启动/停止时间写入结果目录。

**必存日志**：

| 来源 | 关键字段 | 默认路径 |
|------|----------|----------|
| 环境快照 | WDT 版本、ldd、ethtool、ip route、numactl | `env_snapshot.txt` |
| iperf3 | `[SUM] ... Gbits/sec` | `~/wdt_200g_results/*/iperf3_P*.log` |
| WDT Sender | `Total sender throughput`、`Total sender time` | `sender_run*.log` |
| WDT Receiver | daemon 日志 | `receiver.log` / 对端 `/tmp/wdt_receiver.log` |
| 网卡监控 | 吞吐、drop、error | `sar_net.log`、`ethtool_drops.log` |
| CPU/进程 | usr/sys/iowait、WDT 线程 CPU | `vmstat.log`、`pidstat_wdt.log` |
| 磁盘监控 | util、await、iowait | `iostat.log` |
| 正确性 | 文件数、总大小、MD5 diff | `correctness_*.log` |

**吞吐汇总示例**：

```bash
awk 'match($0,/Total sender throughput = ([0-9.]+)/,a){print a[1]}' \
  ~/wdt_200g_results/*/sender_run*.log
```

---

## 9. 环境变量参考

可在执行前 `export` 覆盖默认值（定义见 `wdt_200g_env.sh`）：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `REMOTE_HOST` | `169.254.59.196` | 对端直连 IP |
| `REMOTE_USER` | `jack` | SSH 用户 |
| `LINK_IFACE` | `enp1s0f0np0` | 200G 网卡 |
| `WDT_BUILD_DIR` | `.../wdt-build` | 构建目录 |
| `NUM_PORTS` | `nproc/2` | WDT 并行端口数 |
| `SHM_DATA_GB` | `64` | shm 测试数据量 (GB) |
| `NVME_BIGFILE_GB` | `100` | NVMe 单文件大小 (GB) |
| `TEST_RUNS` | `10` | 网络测试轮数 |
| `WDT_AVG_MBPS` | `30000` | 限速均值 (MiB/s) |
| `WDT_MAX_MBPS` | `30001` | 限速峰值 (MiB/s) |
| `WDT_TRANSFER_ID` | `wdt200g_fixed` | daemon 多轮测试使用的固定 transfer id；Receiver/Sender 必须一致 |
| `RESULT_DIR` | `~/wdt_200g_results/<timestamp>` | 结果输出目录 |

---

## 10. 建议日程

| 时间 | 任务 | 产出 |
|------|------|------|
| 准备日 | `sync` + sysctl 调优 + 环境快照 | 双机 WDT 就绪 |
| D1 上午 | `link` 全量（P1/8/16/32） | iperf3 基线报告 |
| D1 下午 | `network` 正式 10 轮 | WDT 纯网络吞吐报告 |
| D2 | `nvme` + 加密/校验对比 | 端到端与功能开销 |
| D3 | 10 轮重复 + 长稳（可选） | 稳定性报告 |

**冒烟命令（建议首次运行）**：

```bash
cd /home/jack/src/msquic/src/tools/wdt/test
./wdt_200g_sync.sh
SHM_DATA_GB=16 TEST_RUNS=3 ./wdt_200g_bench.sh network
```

---

## 11. 故障排查

| 现象 | 可能原因 | 处理 |
|------|----------|------|
| iperf3 单流 ~20G | 单 TCP 流限制 | 看 `-P 32` 汇总；非故障 |
| iperf3 多流仍低 | sysctl / 防火墙 / 错网卡 | 确认 `-B` 绑定直连 IP；第 7 节调优 |
| iperf3 高、WDT 低 | `num_ports` 不足、限速未关、未走直连网卡 | 增大 `NUM_PORTS`，检查 `avg/max_mbytes_per_sec`，保存 `ip route get <REMOTE_HOST>` 与 `sar -n DEV` |
| WDT 报 `ID_MISMATCH` | Receiver daemon 与 Sender 的 `transfer_id` 不一致 | 使用固定 `WDT_TRANSFER_ID`；或每轮重启 Receiver 并保持 id 一致；或改用 URL 管道模式 |
| 纯网络高、NVMe 低 | 磁盘瓶颈 | `iostat`，考虑 `-odirect_reads` |
| 连接失败 | 端口/防火墙/hostname/路由错误 | 使用直连 IP 而非管理网，确认 `ip route get <REMOTE_HOST>` 指向 200G 网卡 |
| 对端 `wdt: not found` | 未 sync | 运行 `./wdt_200g_sync.sh` |
| 对端 `libglog.so not found` | 运行时依赖缺失 | sync 脚本会自动 apt 安装 |

---

## 12. 手工命令参考（不通过脚本）

**Receiver（对端，纯网络）**：

```bash
export LD_LIBRARY_PATH=/home/jack/src/msquic/src/tools/wdt-build:$LD_LIBRARY_PATH
/home/jack/src/msquic/src/tools/wdt-build/_bin/wdt/wdt \
  -directory /dev/shm/wdt_bench/dst \
  -run_as_daemon=true -skip_writes=true \
  -transfer_id=wdt200g_fixed \
  -num_ports=10 -encryption_type=none -enable_checksum=false \
  -avg_mbytes_per_sec=30000 -max_mbytes_per_sec=30001
```

**Sender（本机）**：

```bash
export LD_LIBRARY_PATH=/home/jack/src/msquic/src/tools/wdt-build:$LD_LIBRARY_PATH
/home/jack/src/msquic/src/tools/wdt-build/_bin/wdt/wdt \
  -directory /dev/shm/wdt_bench/src \
  -destination 169.254.59.196 \
  -transfer_id=wdt200g_fixed \
  -num_ports=10 -encryption_type=none -enable_checksum=false \
  -avg_mbytes_per_sec=30000 -max_mbytes_per_sec=30001
```

**README 管道模式**（单次交互传输）：

```bash
ssh jack@169.254.59.196 \
  'export LD_LIBRARY_PATH=/home/jack/src/msquic/src/tools/wdt-build:$LD_LIBRARY_PATH; \
   /home/jack/src/msquic/src/tools/wdt-build/_bin/wdt/wdt \
     -directory /dev/shm/wdt_bench/dst' | \
  bash -lc 'export LD_LIBRARY_PATH=/home/jack/src/msquic/src/tools/wdt-build:$LD_LIBRARY_PATH; \
    /home/jack/src/msquic/src/tools/wdt-build/_bin/wdt/wdt \
      -directory /dev/shm/wdt_bench/src -'
```

---

## 13. 结果记录模板

测试完成后可填写：

```markdown
### 测试元数据
- 日期：
- 执行人：
- WDT 版本：1.32.1910230
- 本机 / 对端：spark-1619 / spark-1b6f
- num_ports：
- transfer_id：
- SHM 数据量：
- 直连路由：
- 200G 网卡速率：

### iperf3
| 并行流 | Bitrate (Gbps) | 备注 |
|--------|----------------|------|
| P1     |                |      |
| P8     |                |      |
| P16    |                |      |
| P32    |                |      |

### WDT 纯网络 (skip_writes)
| 轮次 | Throughput (MiB/s) | 时间 (s) |
|------|-------------------|----------|
| 1    |                   |          |
| ...  |                   |          |
| 平均 |                   |          |
| 最大 |                   |          |

### WDT NVMe 端到端
- 数据量 (GB)：
- Throughput (MiB/s)：
- 文件数校验：
- 总大小校验：
- MD5 校验：
- 磁盘 iowait：
- NVMe util/await：

### 监控摘要
- 200G 网卡平均吞吐：
- 200G 网卡 drop/error：
- WDT CPU 使用：
- 内存/Swap：

### 结论
- 是否达到成功标准：
- 瓶颈判断（网络 / 磁盘 / CPU）：
- 后续优化建议：
```

---

## 14. 修订历史

| 日期 | 说明 |
|------|------|
| 2026-06-07 | 初版：环境确认、脚本落地、测试计划成文 |
| 2026-06-07 | 合入评审意见：补充链路门槛、daemon transfer_id 一致性、正确性校验、路由检查、监控归档与故障排查 |
