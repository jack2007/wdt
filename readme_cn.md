# WDT 项目代码与功能分析

本文档记录 `https://github.com/jack2007/wdt` 仓库克隆到本地后的项目结构、构建配置、核心模块和主要功能分析。

## 基本信息

- 本地路径：`/home/jack/src/msquic/src/tools/wdt`
- 当前提交：`8e72c3f`
- 项目名称：WDT，Warp-speed Data Transfer
- 项目定位：高性能数据传输库和命令行工具
- 主要目标：让总传输时间尽量只受磁盘或网络硬件带宽限制，同时降低 CPU、内存和系统资源消耗

## 项目定位

WDT 是 Facebook 开源的高速数据传输项目，既可以作为 C++ 库嵌入其他服务，也可以通过命令行工具独立使用。

项目设计偏向轻量 C++ 库：

- 控制依赖数量，提升可移植性并减小二进制体积。
- 不使用异常，便于推理控制流并降低性能开销。
- 使用多线程阻塞式 I/O，减少 syscall 和用户态/内核态切换。
- 通过多端口、多线程并行传输提升吞吐。
- 支持目录树传输、manifest 文件清单传输、限速、校验、加密、断点续传和进度汇报。

典型用法：

```bash
# 接收端，指定目标目录
wdt -directory /data/dest

# 发送端，指定源目录和目标主机
wdt -directory /data/src -destination dest-host
```

### 经 SOCKS5 代理发送

WDT 支持 **发送端** 出站 TCP 经 SOCKS5 代理（RFC 1928 / RFC 1929）转发到接收端。接收端仍直接监听端口，不走代理。

| 参数 | 说明 |
|------|------|
| `-socks5_proxy=host:port` | 启用代理。IPv6 写 `[::1]:1080`。留空则直连（默认）。 |
| `-socks5_proxy_auth=user:password` | 可选用户名/密码认证。留空为无认证。密码可含 `:`（按第一个 `:` 分割）。 |

```bash
# 接收端（不变）
wdt -directory /data/dest -hostname=127.0.0.1

# 发送端经 SOCKS5
wdt -directory /data/src - \
  -socks5_proxy=127.0.0.1:1080 \
  -socks5_proxy_auth=testuser:sec:ret
```

管道/URL 模式下，代理参数只加在 **发送端** 进程上。

库 API：在调用 `wdtSend()` 前设置 `WdtOptions::socks5_proxy`，需要时设置 `WdtOptions::socks5_proxy_auth`。

说明：

- 仅支持 SOCKS5 `CONNECT`，不支持 HTTP CONNECT。
- 本地联调时接收端建议加 `-hostname=127.0.0.1`，避免代理 CONNECT 无法解析主机名。
- 实现位于 `util/Socks5Client.{h,cpp}`，由 `ClientSocket` 在 `connect()` 时选用；单元测试见 `test/Socks5ClientTest.cpp`。

接收端会生成连接 URL，发送端可以通过该 URL 获取端口、transfer id、加密信息等连接参数。

## 目录结构

```text
wdt/
├── CMakeLists.txt          # 主构建配置
├── wdtCmdLine.cpp          # 命令行工具入口
├── Wdt.h / Wdt.cpp         # 高层库 API 入口
├── Sender.*                # 发送端主对象
├── SenderThread.*          # 发送线程状态机
├── Receiver.*              # 接收端主对象
├── ReceiverThread.*        # 接收线程状态机
├── Protocol.*              # wire protocol 编解码和协议版本
├── WdtTransferRequest.*    # 传输请求和 URL 解析/生成
├── WdtOptions.*            # 全局和实例选项
├── WdtBase.*               # Sender/Receiver 公共基类
├── WdtResourceController.* # Sender/Receiver 资源控制器
├── Reporting.*             # 统计和传输报告
├── Throttler.*             # 限速模块
├── ErrorCodes.*            # 错误码体系
├── util/                   # socket、文件、目录队列、加密、日志等工具
├── test/                   # 单元测试、Python 测试、Shell E2E 测试
├── bench/                  # 数据生成和基准工具
└── build/                  # 构建脚本、CI 脚本、配置模板
```

### 顶层源码

顶层源码包含核心库入口、Sender/Receiver、协议、选项、节流、报告等模块，是 WDT 的主逻辑层。

### util/

`util/` 包含底层工具模块：

- `ClientSocket` / `ServerSocket` / `WdtSocket`：socket 封装。
- `Socks5Client`：发送端 SOCKS5 握手与 CONNECT（`util/Socks5Client.{h,cpp}`）。
- `DirectorySourceQueue`：目录扫描和待发送数据队列。
- `FileByteSource`：文件读取源。
- `FileCreator` / `FileWriter`：接收端文件创建和写入。
- `EncryptionUtils`：OpenSSL EVP 加密/解密支持。
- `TransferLogManager`：断点续传日志管理。
- `Stats` / `ThreadTransferHistory` / `ThreadsController`：统计、线程历史和线程协同。

### test/

`test/` 覆盖协议、URL、加密、文件读写、断点续传、限速、端口阻塞、长运行、端到端传输等场景。

### bench/

`bench/` 包含测试数据生成、统计生成和基准测试相关工具。

### build/

`build/` 包含构建说明、CI 脚本、配置模板和辅助脚本。

## 构建配置分析

项目使用 CMake 构建：

- `cmake_minimum_required(VERSION 3.2)`
- 项目版本：`1.32.1910230`
- C++ 标准：C++17
- 默认构建类型：Release
- 默认运行产物目录：`_bin/wdt`

主要构建目标：

- `wdt_min`：核心库，不包含命令行 flags 初始化相关逻辑。
- `wdt`：包含 `WdtFlags.cpp` 和 `Wdt.cpp`，用于 flags 到 options 的初始化。
- `wdtbin`：命令行工具，安装后运行名为 `wdt`。
- 测试目标：当 `BUILD_TESTING` 开启时，会构建协议、加密、URL、文件读写、资源控制等测试。

主要依赖：

- Boost system/filesystem
- Threads / pthread
- double-conversion
- glog
- gflags
- OpenSSL crypto
- Folly，既可使用系统 Folly，也可通过 `FOLLY_SOURCE_DIR` 引入源码树中的 Folly 子集
- GTest，仅测试需要

轻量验证执行过以下命令：

```bash
cmake -S . -B /tmp/wdt-cmake-check -DWDT_USE_SYSTEM_FOLLY=ON -DBUILD_TESTING=OFF
```

当前环境配置失败，原因是缺少 Boost 相关开发依赖：

```text
Could NOT find Boost (missing: Boost_INCLUDE_DIR system filesystem)
```

这属于本机依赖环境问题，不是源码结构问题。后续若要完整构建，需要安装 Boost、glog、gflags、double-conversion、OpenSSL、Folly 或配置 `FOLLY_SOURCE_DIR`。

## 核心入口

### Wdt

`Wdt.h` / `Wdt.cpp` 是高层库 API 入口，主要职责：

- 初始化 WDT 库和全局选项。
- 创建 Sender 或 Receiver。
- 提供阻塞式发送 API `wdtSend`。
- 提供接收生命周期 API `wdtReceiveStart` / `wdtReceiveFinish`。
- 管理 `WdtResourceController`。
- 绑定 abort checker、socket creator 和 progress reporter。

主要高层 API：

```cpp
Wdt& Wdt::initializeWdt(const std::string& appName);
ErrorCode Wdt::wdtSend(const WdtTransferRequest& req, ...);
ErrorCode Wdt::wdtReceiveStart(const std::string& wdtNamespace, WdtTransferRequest& req, ...);
ErrorCode Wdt::wdtReceiveFinish(const std::string& wdtNamespace, ...);
```

### wdtCmdLine.cpp

`wdtCmdLine.cpp` 是命令行工具入口。

命令行根据参数自动判断运行模式：

- 无 `-destination` 且无连接 URL：Receiver 模式。
- 有 `-destination` 或连接 URL：Sender 模式。
- `-parse_transfer_log`：传输日志解析模式。

Receiver 模式流程：

1. 创建 `WdtTransferRequest`。
2. 创建 `Receiver`。
3. 初始化端口、transfer id、加密和续传信息。
4. 输出连接 URL。
5. 启动接收线程。
6. 等待传输完成或进入 daemon 模式。

Sender 模式流程：

1. 从 `-destination` 或连接 URL 构造 `WdtTransferRequest`。
2. 可选读取 manifest 文件清单。
3. 调用 `wdt.wdtSend(req, ...)`。
4. 等待发送完成并返回错误码。

## 核心数据模型

### WdtTransferRequest

`WdtTransferRequest` 是创建 Sender/Receiver 的核心请求对象，包含：

- `transferId`：一次传输的唯一 id，发送端和接收端必须一致。
- `encryptionData`：加密类型和密钥信息。
- `protocolVersion`：协议版本。
- `ports`：接收端监听端口和发送端连接端口。
- `hostName`：接收端地址。
- `destIdentifier`：目标标识，用于区分同主机多个目标。
- `wdtNamespace`：命名空间。
- `directory`：源目录或目标目录。
- `fileInfo`：禁用目录遍历时的文件清单。
- `fileInfoGenerator`：批量生成文件清单的回调。
- `downloadResumptionEnabled`：是否启用下载断点续传。
- `tls`：TLS 标记，开源版本当前默认未启用。
- `ivChangeInterval`：加密 IV 变更间隔。

### WdtUri

`WdtUri` 负责解析和生成 `wdt://host?...` 形式的连接 URL。

它支持：

- 设置和获取 host、port。
- 设置和获取 query 参数。
- URL escape / unescape。
- 从 URL 构造 `WdtTransferRequest`。
- 生成可传递给发送端的连接 URL。

### WdtOptions

`WdtOptions` 管理 WDT 的行为配置，重要选项包括：

- 网络：IPv4/IPv6、DSCP、端口范围、连接/读写/accept 超时、重试次数。
- SOCKS5 代理（仅发送端）：`socks5_proxy`（`host:port` 或 `[ipv6]:port`）、`socks5_proxy_auth`（`user:password`，空为无认证）。
- 并发：默认端口数 `num_ports=8`。
- Buffer：默认 `buffer_size=256 * 1024`。
- 限速：平均速率、峰值速率、bucket limit。
- 文件发现：include/exclude/prune 正则、是否跟随软链接。
- 块传输：默认 `block_size_mbytes=16`。
- 磁盘：fsync、disk sync interval、O_DIRECT 读取。
- 校验：checksum。
- 续传：download resumption、transfer log、目录树恢复。
- 进度：progress reporter 间隔、吞吐更新间隔。

### ErrorCodes

`ErrorCodes.h` 定义完整错误码体系，包括：

- `OK`
- `ERROR`
- `ABORT`
- `CONN_ERROR`
- `SOCKET_READ_ERROR`
- `SOCKET_WRITE_ERROR`
- `BYTE_SOURCE_READ_ERROR`
- `FILE_WRITE_ERROR`
- `PROTOCOL_ERROR`
- `VERSION_MISMATCH`
- `CHECKSUM_MISMATCH`
- `QUOTA_EXCEEDED`
- `FEWER_PORTS`
- `URI_PARSE_ERROR`
- `INVALID_LOG`
- `INVALID_CHECKPOINT`
- `NO_PROGRESS`
- `ENCRYPTION_ERROR`
- `AUTH_ERROR`

## 发送流程

发送流程由 `Wdt::wdtSend`、`Sender`、`SenderThread`、`DirectorySourceQueue` 和 `FileByteSource` 共同完成。

整体流程：

1. `Wdt::wdtSend` 创建 Sender。
2. `Sender::init` 协商协议并校验请求。
3. `Sender::transfer` 调用 `start` 并在随后 `finish`。
4. `Sender::start` 创建目录扫描队列。
5. `DirectorySourceQueue` 异步扫描源目录或读取 `fileInfo`。
6. Sender 为每个端口创建一个 `SenderThread`。
7. 每个 SenderThread 连接对应 ReceiverThread。
8. SenderThread 发送 settings、文件 header、数据 block、footer、done 命令。
9. 传输完成后聚合线程统计、文件统计和失败列表，生成 `TransferReport`。

`SenderThread` 是状态机，主要状态包括：

- `CONNECT`
- `READ_LOCAL_CHECKPOINT`
- `SEND_SETTINGS`
- `SEND_BLOCKS`
- `SEND_DONE_CMD`
- `SEND_SIZE_CMD`
- `CHECK_FOR_ABORT`
- `READ_FILE_CHUNKS`
- `READ_RECEIVER_CMD`
- `PROCESS_DONE_CMD`
- `PROCESS_WAIT_CMD`
- `PROCESS_ERR_CMD`
- `PROCESS_ABORT_CMD`
- `PROCESS_VERSION_MISMATCH`

发送端的文件读取抽象：

- `ByteSource`：待发送数据源接口。
- `FileByteSource`：文件数据源实现，按文件名、大小、offset 读取数据块。
- `DirectorySourceQueue`：递归发现目录中的普通文件，并按大小优先提供给发送线程。

## 接收流程

接收流程由 `Wdt::wdtReceiveStart`、`Receiver`、`ReceiverThread`、`FileCreator` 和 `FileWriter` 完成。

整体流程：

1. `Wdt::wdtReceiveStart` 创建 Receiver。
2. `Receiver::init` 校验请求、准备目标目录、初始化 transfer log、协议协商、加密参数和端口。
3. Receiver 为每个端口创建一个 `ReceiverThread`。
4. 每个 ReceiverThread 监听一个端口。
5. SenderThread 连接后发送 settings 和文件数据。
6. ReceiverThread 读取协议命令并处理文件 header、数据块、footer 和 done。
7. `FileCreator` 创建目录和文件。
8. `FileWriter` 写入数据、sync、close。
9. Receiver 汇总所有线程统计，修复并关闭 transfer log，生成 `TransferReport`。

`ReceiverThread` 是状态机，主要状态包括：

- `LISTEN`
- `ACCEPT_FIRST_CONNECTION`
- `ACCEPT_WITH_TIMEOUT`
- `SEND_LOCAL_CHECKPOINT`
- `READ_NEXT_CMD`
- `PROCESS_FILE_CMD`
- `PROCESS_SETTINGS_CMD`
- `PROCESS_DONE_CMD`
- `PROCESS_SIZE_CMD`
- `SEND_FILE_CHUNKS`
- `SEND_GLOBAL_CHECKPOINTS`
- `SEND_DONE_CMD`
- `SEND_ABORT_CMD`
- `WAIT_FOR_FINISH_OR_NEW_CHECKPOINT`
- `FINISH_WITH_ERROR`

Receiver 支持两种运行模式：

- 单次传输模式：`transferAsync` 后调用 `finish` 等待完成。
- 长驻模式：`runForever`，用于持续接收后续传输，但不支持 download resumption。

## 协议机制

`Protocol.h` / `Protocol.cpp` 定义 wire protocol 的命令、协议版本、特性版本和编解码函数。

主要命令：

- `DONE_CMD`：传输完成。
- `FILE_CMD`：文件块 header。
- `WAIT_CMD`：等待。
- `ERR_CMD`：错误。
- `SETTINGS_CMD`：发送端配置。
- `ABORT_CMD`：中止。
- `CHUNKS_CMD`：已接收文件块列表。
- `ACK_CMD`：确认。
- `SIZE_CMD`：总大小。
- `FOOTER_CMD`：checksum 或加密 tag。
- `ENCRYPTION_CMD`：加密参数。
- `HEART_BEAT_CMD`：心跳。

协议支持特性版本控制：

- receiver progress reporting
- checksum
- download resumption
- settings flags
- checkpoint offset / seq id
- encryption
- incremental tag verification
- delete command
- varint change
- heartbeat
- periodic encryption IV change

典型协议交互：

1. Sender 连接 Receiver。
2. Sender 发送 `SETTINGS_CMD`，包含超时、transfer id、checksum、是否请求已接收 chunks、是否启用 heartbeat。
3. Receiver 校验 transfer id 和协议兼容性。
4. Sender 发送文件 block 的 header 和数据。
5. Receiver 写入并记录 checkpoint。
6. Sender 发送 footer，用于 checksum 或 tag 校验。
7. Sender 发送 done。
8. Receiver 返回确认或错误。

## 可靠性与断点续传

WDT 的可靠性主要依赖线程级 checkpoint、传输历史和接收端 transfer log。

### 线程级 checkpoint

每个 SenderThread 维护传输历史。连接中断后：

1. SenderThread 重新连接 ReceiverThread。
2. ReceiverThread 返回本地 checkpoint。
3. SenderThread 根据 checkpoint 判断哪些 block 已经成功接收。
4. 未确认数据重新放回队列或继续发送。

这可以减少连接中断导致的重复传输。

### Download Resumption

`TransferLogManager` 管理接收端 `.wdt.log`，支持两种续传方式：

1. 基于日志的续传：记录文件创建、block 写入、文件 resize、文件失效等事件；下次传输前解析日志，得到已接收文件块列表。
2. 基于目录树的续传：遍历目标目录，根据目标文件大小推断已接收部分。

日志条目类型包括：

- `HEADER`
- `FILE_CREATION`
- `BLOCK_WRITE`
- `FILE_INVALIDATION`
- `FILE_RESIZE`
- `DIRECTORY_INVALIDATION`

断点续传启用后，Receiver 会把已接收 chunks 发给 Sender，Sender 只发送缺失部分。

## 性能特性

WDT 的性能设计点包括：

- 多端口并行传输：默认 8 个端口，每个端口一个发送线程和接收线程。
- 异步目录扫描：文件发现和网络传输可以并行进行。
- 大文件分块：默认 16 MiB block，便于并行、续传和失败恢复。
- 大文件优先：目录队列倾向优先发送较大文件，提高吞吐。
- 阻塞式线程 I/O：降低 syscall 和调度开销。
- 全局限速器：token bucket + 平均速率控制。
- 支持 O_DIRECT、fsync、sync_file_range、posix_fadvise 等磁盘 I/O 优化。
- 支持 progress reporter 和 perf stat，用于传输过程观测。

## 限速模块

`Throttler` 使用两类限制：

1. 平均速率限制：避免整体传输速率长期超过目标值。
2. token bucket 峰值限制：允许短时突发，但受 bucket rate 和 bucket limit 控制。

重要参数：

- `avg_rate_per_sec`
- `max_rate_per_sec`
- `throttler_bucket_limit`
- `single_request_limit`
- `throttler_log_time_millis`

`single_request_limit` 用于将过大的资源请求拆分，避免单个线程申请大量 token 导致其他线程饥饿。

## 加密与安全

加密由 `EncryptionUtils` 基于 OpenSSL EVP 实现。

支持的加密类型：

- `ENC_NONE`
- `ENC_AES128_CTR`
- `ENC_AES128_GCM`

安全相关特性：

- GCM 模式支持认证 tag。
- 支持加密 IV 周期性变更。
- 加密 secret 可以通过 URL 安全字符串传递。
- 日志输出使用 log-safe 字符串，避免直接泄露 secret。
- `Wdt::isTlsEnabled()` 当前返回 `false`，开源版本中 TLS 标注为暂不支持。

## 统计与报告

`Reporting.h` / `Reporting.cpp` 负责统计和报告。

核心统计对象：

- `TransferStats`：记录 header bytes、data bytes、有效 bytes、文件数、块数、失败次数、本地错误、远端错误、加密类型等。
- `TransferReport`：聚合线程统计、文件统计、失败列表、总耗时、吞吐等。
- `ProgressReporter`：周期性输出传输进度和当前吞吐。

Sender 和 Receiver 在 `finish` 阶段都会聚合线程统计并生成最终报告。

## 资源控制

`WdtResourceController` 管理 Sender 和 Receiver 的创建、释放和配额。

它支持：

- 全局 sender/receiver 数量限制。
- 按 namespace 管理资源。
- 通过 namespace + identifier 查询或释放 Sender/Receiver。
- 释放 stale sender/receiver。
- 共享 throttler。

这使 WDT 可以被嵌入服务中，用 namespace 区分不同业务或 shard。

## 测试覆盖

项目包含较完整的测试集合：

- 协议测试：`ProtocolTest.cpp`
- SOCKS5 解析测试：`Socks5ClientTest.cpp`
- URL 测试：`WdtUrlTest.cpp`
- 加密测试：`EncryptionTest.cpp`
- 文件读写测试：`FileReaderTest.cpp` / `FileWriterTest.cpp`
- 统计测试：`Stats_test.cpp`
- 资源控制测试：`WdtResourceControllerTest.cpp`
- 限速测试：`ThrottlerTest.cpp`
- 端到端测试：`wdt_e2e_simple_test.sh` / `wdt_e2e_test.sh`
- 断点续传测试：`wdt_download_resumption_test.sh` / `wdt_dl_resume_test*.py`
- 端口阻塞、坏服务器、长运行、覆盖写、协议协商等 Python/Shell 测试

## 当前验证结果

已完成的验证：

- 仓库成功克隆到 `/home/jack/src/msquic/src/tools/wdt`。
- Git 状态干净。
- 当前提交为 `8e72c3f`。
- 文件结构可正常枚举，源码、测试、构建脚本均存在。
- CMake 配置验证执行成功启动，但因当前环境缺少 Boost 依赖而失败。

CMake 失败信息：

```text
Could NOT find Boost (missing: Boost_INCLUDE_DIR system filesystem)
```

后续构建建议：

1. 安装 Boost system/filesystem 开发包。
2. 安装 glog、gflags、double-conversion、OpenSSL 开发包。
3. 准备系统 Folly，或在 `wdt` 同级目录克隆 `facebook/folly` 并配置 `FOLLY_SOURCE_DIR`。
4. 重新运行 CMake。
5. 构建完成后运行协议测试和简单 E2E 测试验证功能。

## 总结

WDT 是一个面向高吞吐、低开销文件/目录传输的 C++ 项目。它的核心架构是：

```text
目录/文件发现 -> ByteSource -> SenderThread 多端口发送 -> Protocol -> ReceiverThread 接收 -> FileWriter 落盘
```

核心优势：

- 多端口并行传输，适合高带宽网络。
- 支持大文件分块和目录树批量传输。
- 支持连接失败后的 checkpoint 恢复。
- 支持基于日志或目录树的下载断点续传。
- 支持加密、checksum、限速和进度报告。
- 发送端可选经 SOCKS5 代理出站（`-socks5_proxy` / `-socks5_proxy_auth`）。
- 可作为命令行工具使用，也可作为库嵌入服务。

当前主要阻塞点不是代码本身，而是本地构建依赖尚未安装完整。
