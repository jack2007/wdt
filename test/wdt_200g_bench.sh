#!/usr/bin/env bash
# 200Gbps DGX↔DGX WDT benchmark orchestrator.
#
# Usage:
#   ./wdt_200g_bench.sh sync              # deploy binary to peer
#   ./wdt_200g_bench.sh env               # print environment
#   ./wdt_200g_bench.sh link              # iperf3 baseline on direct link
#   ./wdt_200g_bench.sh prepare-shm [GB]  # generate shm test data locally
#   ./wdt_200g_bench.sh network [runs]    # WDT skip_writes (network-only)
#   ./wdt_200g_bench.sh nvme [GB]         # end-to-end on NVMe (both sides)
#   ./wdt_200g_bench.sh all               # sync + link + network + report
#
# Override: REMOTE_HOST=169.254.59.196 NUM_PORTS=32 ./wdt_200g_bench.sh network
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wdt_200g_env.sh
source "${SCRIPT_DIR}/wdt_200g_env.sh"

RESULT_DIR="${RESULT_DIR:-${HOME}/wdt_200g_results/$(date +%Y%m%d_%H%M%S)}"
COMMON_OPTS="$(wdt_common_opts)"
WDT_WRAPPER="export LD_LIBRARY_PATH='${WDT_BUILD_DIR}:\${LD_LIBRARY_PATH:-}'; ${WDT_BIN}"

kill_wdt() {
  pkill -x wdt 2>/dev/null || true
  remote "pkill -x wdt 2>/dev/null || true" || true
  sleep 1
}

cmd_env() {
  cat <<EOF
LOCAL_HOST=${LOCAL_HOST}
REMOTE_HOST=${REMOTE_HOST}
REMOTE_SSH=${REMOTE_SSH}
LINK_IFACE=${LINK_IFACE} ($(ethtool "${LINK_IFACE}" 2>/dev/null | awk '/Speed/{print $2}'))
WDT_BIN=${WDT_BIN}
NUM_PORTS=${NUM_PORTS} (nproc=$(nproc))
BENCH_SHM=${BENCH_SHM}
BENCH_NVME=${BENCH_NVME}
COMMON_OPTS=${COMMON_OPTS}
RESULT_DIR=${RESULT_DIR}
EOF
}

cmd_sync() {
  "${SCRIPT_DIR}/wdt_200g_sync.sh"
}

cmd_link() {
  log_section "Phase 1: iperf3 on ${LINK_IFACE} -> ${REMOTE_HOST}"
  mkdir -p "${RESULT_DIR}"
  if ! command -v iperf3 >/dev/null; then
    echo "iperf3 not installed; run: sudo apt-get install -y iperf3" >&2
    exit 1
  fi
  local bind_ip
  bind_ip="$(ip -4 -o addr show dev "${LINK_IFACE}" | awk '{print $4}' | cut -d/ -f1)"
  for parallel in 1 8 16 32; do
    log_section "iperf3 -P ${parallel} (bind ${bind_ip})"
    remote "pkill -x iperf3 2>/dev/null || true"
    sleep 1
    remote "iperf3 -s -B ${REMOTE_HOST} -D --logfile /tmp/iperf3_server.log"
    sleep 1
    iperf3 -c "${REMOTE_HOST}" -t 20 -P "${parallel}" -B "${bind_ip}" \
      2>&1 | tee "${RESULT_DIR}/iperf3_P${parallel}.log" || true
    remote "pkill -x iperf3 2>/dev/null || true"
    sleep 1
  done
}

prepare_shm_data() {
  local gb="${1:-${SHM_DATA_GB}}"
  log_section "Prepare ${gb}GB shm data at ${BENCH_SHM}/src"
  mkdir -p "${BENCH_SHM}/src" "${BENCH_SHM}/dst"
  remote "mkdir -p '${BENCH_SHM}/src' '${BENCH_SHM}/dst'"

  # Mixed sizes (aligned with wdt_max_send_test.sh)
  for size in 64K 512K 1M 16M 256M 512M; do
    local base="inp${size}"
    dd if=/dev/zero of="${BENCH_SHM}/src/${base}.1" bs="${size}" count=1 status=none
    for i in $(seq 2 32); do
      cp "${BENCH_SHM}/src/${base}.1" "${BENCH_SHM}/src/${base}.${i}"
    done
  done

  # Pad to approximate target GB with large files
  local current_mb
  current_mb=$(du -sm "${BENCH_SHM}/src" | awk '{print $1}')
  local target_mb=$((gb * 1024))
  local idx=1
  while [[ "${current_mb}" -lt "${target_mb}" ]]; do
    local need=$((target_mb - current_mb))
    local chunk_mb=$((need > 4096 ? 4096 : need))
    [[ "${chunk_mb}" -lt 64 ]] && break
    dd if=/dev/zero of="${BENCH_SHM}/src/pad_${chunk_mb}M_${idx}" \
      bs=1M count="${chunk_mb}" status=none
    current_mb=$(du -sm "${BENCH_SHM}/src" | awk '{print $1}')
    idx=$((idx + 1))
  done
  du -sh "${BENCH_SHM}/src"
}

start_receiver_network() {
  log_section "Start receiver (skip_writes) on ${REMOTE_HOST}"
  remote "mkdir -p '${BENCH_SHM}/dst'; pkill -x wdt 2>/dev/null || true; \
    nohup bash -c \"${WDT_WRAPPER} \
    ${COMMON_OPTS} \
    -directory '${BENCH_SHM}/dst' \
    -run_as_daemon=true \
    -skip_writes=true \
    -transfer_id='${WDT_TRANSFER_ID}'\" \
    > /tmp/wdt_receiver.log 2>&1 </dev/null &"
  sleep 2
  remote "pgrep -xa wdt || (cat /tmp/wdt_receiver.log; exit 1)"
}

run_sender_network() {
  local runs="${1:-${TEST_RUNS}}"
  mkdir -p "${RESULT_DIR}"
  log_section "WDT network-only: ${runs} runs -> ${REMOTE_HOST}"
  local run
  for run in $(seq 1 "${runs}"); do
    local two_phase=""
    if (( run % 2 == 0 )); then
      two_phase="-two_phases"
    fi
    echo "--- run ${run}/${runs} ---"
    /usr/bin/time -f "wall=%e user=%U sys=%S" \
      bash -c "${WDT_WRAPPER} ${COMMON_OPTS} ${two_phase} \
        -directory '${BENCH_SHM}/src' \
        -destination '${REMOTE_HOST}' \
        -transfer_id='${WDT_TRANSFER_ID}'" \
      2>&1 | tee "${RESULT_DIR}/sender_run${run}.log"
  done
  remote "cat /tmp/wdt_receiver.log" > "${RESULT_DIR}/receiver.log" || true
  summarize_throughput "${RESULT_DIR}"/sender_run*.log | tee "${RESULT_DIR}/network_summary.txt"
}

summarize_throughput() {
  awk '
    FNR==1 { fname=FILENAME }
    match($0, /Total sender throughput = ([0-9.]+)/, a) {
      print fname, a[1], "MiB/s"
      vals[++n]=a[1]+0
    }
    END {
      if (n==0) { print "No throughput lines found"; exit 1 }
      sum=0; max=0
      for (i=1;i<=n;i++) { sum+=vals[i]; if (vals[i]>max) max=vals[i] }
      printf "\nRuns=%d avg=%.1f max=%.1f MiB/s (max=%.1f Gbps equiv)\n",
        n, sum/n, max, max*8/1024
    }' "$@"
}

cmd_network() {
  local runs="${1:-${TEST_RUNS}}"
  [[ -x "${WDT_BIN}" ]] || { echo "Build WDT first"; exit 1; }
  kill_wdt
  prepare_shm_data "${SHM_DATA_GB}"
  start_receiver_network
  run_sender_network "${runs}"
  kill_wdt
  log_section "Results in ${RESULT_DIR}"
}

prepare_nvme_data() {
  local gb="${1:-${NVME_BIGFILE_GB}}"
  log_section "Prepare NVMe dataset ${gb}GB at ${BENCH_NVME}/src"
  mkdir -p "${BENCH_NVME}/src" "${BENCH_NVME}/dst"
  remote "mkdir -p '${BENCH_NVME}/src' '${BENCH_NVME}/dst'"

  # dd is more portable than wdt_gen_files (needs bigram stats file).
  dd if=/dev/zero of="${BENCH_NVME}/src/bigfile" bs=1M count="$((gb * 1024))" status=none
  du -sh "${BENCH_NVME}/src"
}

start_receiver_nvme() {
  log_section "Start receiver (writes to NVMe) on ${REMOTE_HOST}"
  remote "mkdir -p '${BENCH_NVME}/dst'; rm -rf '${BENCH_NVME}/dst'/*; pkill -x wdt 2>/dev/null || true; \
    nohup bash -c \"${WDT_WRAPPER} \
    ${COMMON_OPTS} \
    -directory '${BENCH_NVME}/dst' \
    -run_as_daemon=true \
    -transfer_id='${WDT_NVME_TRANSFER_ID}'\" \
    > /tmp/wdt_receiver_nvme.log 2>&1 </dev/null &"
  sleep 2
}

cmd_nvme() {
  local gb="${1:-${NVME_BIGFILE_GB}}"
  mkdir -p "${RESULT_DIR}"
  kill_wdt
  prepare_nvme_data "${gb}"
  start_receiver_nvme
  log_section "Single NVMe end-to-end transfer"
  /usr/bin/time -f "wall=%e user=%U sys=%S" \
    bash -c "${WDT_WRAPPER} ${COMMON_OPTS} \
      -directory '${BENCH_NVME}/src' \
      -destination '${REMOTE_HOST}' \
      -transfer_id='${WDT_NVME_TRANSFER_ID}'" \
    2>&1 | tee "${RESULT_DIR}/nvme_transfer.log"
  remote "cat /tmp/wdt_receiver_nvme.log" > "${RESULT_DIR}/receiver_nvme.log" || true
  summarize_throughput "${RESULT_DIR}/nvme_transfer.log" | tee "${RESULT_DIR}/nvme_summary.txt"
  kill_wdt
}

cmd_all() {
  cmd_sync
  cmd_link
  cmd_network "${TEST_RUNS}"
  echo ""
  echo "Optional NVMe test: $0 nvme ${NVME_BIGFILE_GB}"
}

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \?//'
}

main() {
  local cmd="${1:-help}"
  shift || true
  case "${cmd}" in
    sync) cmd_sync "$@" ;;
    env) cmd_env ;;
    link) cmd_link "$@" ;;
    prepare-shm) prepare_shm_data "${1:-${SHM_DATA_GB}}" ;;
    network) cmd_network "${1:-${TEST_RUNS}}" ;;
    nvme) cmd_nvme "${1:-${NVME_BIGFILE_GB}}" ;;
    all) cmd_all "$@" ;;
    help|-h|--help) usage ;;
    *) echo "Unknown command: ${cmd}" >&2; usage; exit 1 ;;
    esac
}

main "$@"
