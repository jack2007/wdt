#!/usr/bin/env bash
# Shared environment for 200Gbps DGX ↔ DGX WDT benchmarks.
# Source this file or let wdt_200g_*.sh scripts source it automatically.

# --- Identity (override via env) ---
: "${LOCAL_USER:=jack}"
: "${REMOTE_USER:=jack}"
: "${LOCAL_HOST:=$(hostname -s)}"

# Direct 200G link peer (spark-1b6f ↔ spark-1619). Prefer link-local IP.
: "${REMOTE_HOST:=169.254.59.196}"
: "${REMOTE_SSH:=${REMOTE_USER}@${REMOTE_HOST}}"

# High-speed NIC on this machine (200000Mb/s)
: "${LINK_IFACE:=enp1s0f0np0}"

# WDT install layout (same path on both nodes after sync)
: "${WDT_BUILD_DIR:=/home/jack/src/msquic/src/tools/wdt-build}"
: "${WDT_BIN:=${WDT_BUILD_DIR}/_bin/wdt/wdt}"
: "${WDT_GEN_FILES:=${WDT_BUILD_DIR}/_bin/wdt/bench/wdt_gen_files}"

# Benchmark directories
: "${BENCH_SHM:=/dev/shm/wdt_bench}"
: "${BENCH_NVME:=/home/jack/wdt_nvme_bench}"

# Tunables
# Tuned default: 16 ports outperforms nproc/2 (10) on 20-core DGX (~12.2 vs ~10.2 GiB/s).
: "${NUM_PORTS:=16}"
: "${TEST_RUNS:=10}"
: "${SHM_DATA_GB:=64}"
: "${NVME_BIGFILE_GB:=100}"

# WDT throughput flags (MiB/s; 200Gbps ≈ 25000 MiB/s theoretical)
: "${WDT_AVG_MBPS:=30000}"
: "${WDT_MAX_MBPS:=30001}"

# Daemon multi-run tests: Receiver and Sender must share the same transfer id.
: "${WDT_TRANSFER_ID:=wdt200g_fixed}"
: "${WDT_NVME_TRANSFER_ID:=wdt200g_nvme}"

# Optional overrides for parameter sweeps
: "${WDT_BUFFER_SIZE:=4194304}"
: "${WDT_SEND_BUF_SIZE:=16777216}"
: "${WDT_RECV_BUF_SIZE:=16777216}"
: "${WDT_ODIRECT_READS:=false}"
: "${WDT_EXTRA_OPTS:=}"

export LD_LIBRARY_PATH="${WDT_BUILD_DIR}:${LD_LIBRARY_PATH:-}"

wdt_common_opts() {
  local odirect_opt=""
  [[ "${WDT_ODIRECT_READS}" == "true" ]] && odirect_opt="-odirect_reads"
  echo "-num_ports=${NUM_PORTS} \
-encryption_type=none \
-enable_checksum=false \
-skip_fadvise \
-sleep_millis=1 \
-max_retries=3 \
-avg_mbytes_per_sec=${WDT_AVG_MBPS} \
-max_mbytes_per_sec=${WDT_MAX_MBPS} \
-buffer_size=${WDT_BUFFER_SIZE} \
-send_buffer_size=${WDT_SEND_BUF_SIZE} \
-receive_buffer_size=${WDT_RECV_BUF_SIZE} \
${odirect_opt} \
${WDT_EXTRA_OPTS}"
}

remote() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "${REMOTE_SSH}" "$@"
}

remote_sudo() {
  local cmd="$*"
  ssh -o BatchMode=yes -o ConnectTimeout=10 "${REMOTE_SSH}" \
    "sudo -n env DEBIAN_FRONTEND=noninteractive bash -c $(printf '%q' "${cmd}")"
}

remote_has_wdt_runtime_libs() {
  remote "ldconfig -p 2>/dev/null | grep -q libglog.so && \
    ldconfig -p 2>/dev/null | grep -q libgflags.so && \
    ldconfig -p 2>/dev/null | grep -q libdouble-conversion.so"
}

log_section() {
  echo ""
  echo "========== $* =========="
  echo "$(date -Is)"
}
