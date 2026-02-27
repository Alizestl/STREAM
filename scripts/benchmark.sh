#!/bin/bash -e
echo ""
cat << 'STREAM_BANNER'
 ________
< stream >
 --------
        \   ^__^
         \  (oo)\_______
            (__)\       )\/\
                ||----w |
                ||     ||
STREAM_BANNER
echo ""

# global variables
DTEST_MODE=""
DNTIMES=""
TARGET_CORE=""
DSTREAM_ARRAY_SIZE=""
NUMA_MODE="none"

SCRIPT_NAME=$(basename "$0")
LOG_FILE=""

show_help() {
    cat << EOF
STREAM Benchmark

用法: $SCRIPT_NAME [选项]

必选参数:
  --test-mode        single/multi
  --times            NTIMES(STREAM 重复次数)

可选参数:
  --target-core      绑定 CPU 核编号(single 必填,multi 忽略)
  --array-size       STREAM_ARRAY_SIZE数组大小。不填则自动计算,自动计算逻辑参考64行代码。
                        计算公式：{cpu最高级缓存MB}*1024*1024*4.1*{CPU路数}/8, 结果取整
                            --如何获取cpu最高级缓存(KB): cat /proc/cpuinfo | grep "cache size" | uniq | awk '{print \$4}'
                            --如何获取cpu路数: lscpu | grep Socket | awk '{print \$2}'
  --numa-mode        NUMA策略, 合法值: none/local0/local1/interleave/remote10/remote01
                            --none: 不做NUMA绑定(默认)
                            --local0/local1: CPU+MEM 绑定到 node0/node1
                            --interleave: 内存跨node交错分配
                            --remote10: CPU在node1但内存在node0(强制远端访问)
                            --remote01: CPU在node0但内存在node1(强制远端访问)
                
选项:
    -h, --help      显示此帮助信息

环境变量:
    LOG_FILE        指定日志文件路径。未设置则默认写入当前目录下 log/ 中的日志文件。
EOF
}

# 输出到终端并追加到日志文件
log() {
    local msg="$*"
    echo "$msg"
    [[ -n "$LOG_FILE" ]] && echo "$msg" >> "$LOG_FILE"
}

die() {
    echo "错误: $*" >&2
    exit 1
}

numa_check() {
    local sysfs="/sys/devices/system/node"
    local nodes=1

    if [[ -d "$sysfs" ]]; then
        nodes=$(ls -d "$sysfs"/node[0-9]* 2>/dev/null | wc -l)
        [[ "$nodes" -ge 1 ]] || nodes=1
    fi

    # 单 NUMA：不允许指定 NUMA_MODE（除了 none）
    [[ "$nodes" -ge 2 || "$NUMA_MODE" == "none" ]] || die "单NUMA模式下,无需指定NUMA_MODE"

    # 多 NUMA：必须显式指定 NUMA_MODE（不能是 none）
    [[ "$nodes" -le 1 || "$NUMA_MODE" != "none" ]] || die "多NUMA模式下,需要手动指定NUMA_MODE"

    # 只有当 NUMA_MODE 生效时才要求 numactl
    [[ "$NUMA_MODE" == "none" ]] || command -v numactl >/dev/null 2>&1 || die "启用 --numa-mode=$NUMA_MODE 需要安装 numactl"

    # 保险：指定了 NUMA_MODE 但 nodes<2 必须报错（理论上已被上面覆盖）
    [[ "$NUMA_MODE" == "none" || "$nodes" -ge 2 ]] || die "当前系统 NUMA nodes=$nodes（通过 $sysfs/node* 统计），无法启用 --numa-mode=$NUMA_MODE：需要至少 2 个 NUMA node"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            --test-mode)   [[ -n "${2:-}" ]] || die "--test-mode 缺少值"; DTEST_MODE="$2"; shift 2 ;;
            --test-mode=*) DTEST_MODE="${1#*=}"; shift ;;
            --times)       [[ -n "${2:-}" ]] || die "--times 缺少值"; DNTIMES="$2"; shift 2 ;;
            --times=*)     DNTIMES="${1#*=}"; shift ;;
            --target-core) [[ -n "${2:-}" ]] || die "--target-core 缺少值"; TARGET_CORE="$2"; shift 2 ;;
            --target-core=*) TARGET_CORE="${1#*=}"; shift ;;
            --array-size)  [[ -n "${2:-}" ]] || die "--array-size 缺少值"; DSTREAM_ARRAY_SIZE="$2"; shift 2 ;;
            --array-size=*) DSTREAM_ARRAY_SIZE="${1#*=}"; shift ;;
            --numa-mode)   [[ -n "${2:-}" ]] || die "--numa-mode 缺少值"; NUMA_MODE="$2"; shift 2 ;;
            --numa-mode=*) NUMA_MODE="${1#*=}"; shift ;;
            *)
                die "未知参数: $1 （用 --help 查看用法）"
                ;;
        esac
    done
}

check_params() {

    [[ -n "$DTEST_MODE" ]] || die "缺少 --test-mode"
    [[ "$DTEST_MODE" == "single" || "$DTEST_MODE" == "multi" ]] || die "--test-mode 非法, 合法值: single/multi"

    [[ -n "$DNTIMES" ]] || die "缺少 --times"
    [[ "$DNTIMES" =~ ^[0-9]+$ ]] || die "--times 必须是整数"

    if [[ "$DTEST_MODE" == "single" ]]; then
        [[ -n "$TARGET_CORE" ]] || die "single 模式缺少 --target-core"
        [[ "$TARGET_CORE" =~ ^[0-9]+$ ]] || die "--target-core 必须是整数"
    else
        # multi 模式下 target-core 不需要，传了就忽略并提示
        if [[ -n "$TARGET_CORE" ]]; then
            echo "提示: multi 模式下 --target-core 会被忽略"
            TARGET_CORE=""
        fi
    fi

    if [[ -n "$DSTREAM_ARRAY_SIZE" ]]; then
        [[ "$DSTREAM_ARRAY_SIZE" =~ ^[0-9]+$ ]] || die "--array-size 必须是整数（元素个数）"
    fi

    case "$NUMA_MODE" in
        none|local0|local1|interleave|remote10|remote01) ;;
        *) die "--numa-mode 非法, 合法值: none/local0/local1/interleave/remote10/remote01" ;;
    esac
    numa_check

    # 如果未指定数组大小,则自动计算数组大小
    if [ -z "$DSTREAM_ARRAY_SIZE" ]; then
        echo "未指定数组大小,自动计算数组大小..."
        CPU_CACHE_SIZE=$(cat /proc/cpuinfo | grep "cache size" | uniq | awk '{print $4}')
        CPU_SOCKETS=$(lscpu | grep Socket | awk '{print $2}')
        echo "CPU 最高级缓存(KB): $CPU_CACHE_SIZE, CPU路数: $CPU_SOCKETS"
        echo "CPU 最高级缓存(MB): $((CPU_CACHE_SIZE / 1024))"
        echo "自动计算数组大小..."
        DSTREAM_ARRAY_SIZE=$(echo "$CPU_CACHE_SIZE" | awk -v sockets="$CPU_SOCKETS" '{
        raw = int($1 * 1024 * 4.1 * sockets / 8 + 0.5)
        d = length(raw)
        mag = 1; for (i = 1; i < d; i++) mag = mag * 10
        print int((raw + mag - 1) / mag) * mag
        }')
        echo "数组大小: $DSTREAM_ARRAY_SIZE"
    fi

}

prepare_stream() {
    if [ -f "stream.c" ]; then
        echo "发现 STREAM 源码,跳过下载"
    else
        echo "未发现 STREAM 源码,下载中..."
        if ! wget -q https://www.cs.virginia.edu/stream/FTP/Code/stream.c; then
            echo "错误: 下载失败,请检查网络连接"
            exit 1
        fi
        echo "下载完成"
    fi

    echo "编译 STREAM..."
    if [ "$DTEST_MODE" == "multi" ]; then
        gcc -O0 -fopenmp -DSTREAM_ARRAY_SIZE=$DSTREAM_ARRAY_SIZE -DNTIMES=$DNTIMES -mcmodel=large stream.c -o stream
    else
        gcc -O0 -DSTREAM_ARRAY_SIZE=$DSTREAM_ARRAY_SIZE -DNTIMES=$DNTIMES -mcmodel=large stream.c -o stream
    fi
    if [ $? -ne 0 ]; then
        echo "STREAM 编译失败"
        exit 1
    fi
    echo "STREAM 编译完成。"
    echo "================================================"
}

benchmark() {

    # 根据NUMA_MODE设置numa_prefix
    numa_prefix=""
    if [[ "$NUMA_MODE" != "none" ]]; then
        case "$NUMA_MODE" in
            local0)     numa_prefix="numactl --cpunodebind=0 --membind=0" ;;
            local1)     numa_prefix="numactl --cpunodebind=1 --membind=1" ;;
            interleave) numa_prefix="numactl --interleave=all" ;;
            remote10)   numa_prefix="numactl --cpunodebind=1 --membind=0" ;;
            remote01)   numa_prefix="numactl --cpunodebind=0 --membind=1" ;;
        esac
    fi


    if [ "$DTEST_MODE" == "single" ]; then
        echo "单核测试, 绑定到核心 $TARGET_CORE, 开始测试..."
        # 管道会使被运行的程序使用全缓冲,输出会等缓冲区满或程序结束才显示。
        # 使用 stdbuf -o0 将 stdout 设为无缓冲,输出会实时显示：
        stdbuf -o0 ${numa_prefix} taskset -c $TARGET_CORE ./stream 2>&1 | tee -a "$LOG_FILE"
    else
        echo "多核测试, 全核跑测, 开始测试..."
        stdbuf -o0 ${numa_prefix} ./stream 2>&1 | tee -a "$LOG_FILE"
    fi
    [[ ${PIPESTATUS[0]} -ne 0 ]] && { log "stream 执行失败"; exit 1; }
}


main() {
    parse_args "$@"

    # 未指定时使用默认路径；可通过环境变量 LOG_FILE 指定日志路径
    if [[ -z "$LOG_FILE" ]]; then
        mkdir -p log
        LOG_FILE="log/stream-benchmark-$(date +%Y%m%d-%H-%M-%S).log"
    else
        mkdir -p "$(dirname "$LOG_FILE")"
    fi

    check_params

    START_TIME=$(date +%s)
    log "=========================================="
    log "Benchmark 开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
    log "------------------------------------------"
    log "测试参数:"
    log "- 测试模式: $DTEST_MODE"
    if [ "$DTEST_MODE" == "single" ]; then
        log "- 绑定核心: $TARGET_CORE"
    fi
    log "- 测试重复次数: $DNTIMES"
    log "- 测试数组大小: $DSTREAM_ARRAY_SIZE"
    log "- NUMA_MODE: $NUMA_MODE"
    log "------------------------------------------"
    sleep 2

    prepare_stream
    benchmark

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    log "=========================================="
    log "Benchmark 结束时间: $(date '+%Y-%m-%d %H:%M:%S')"
    log "耗时: ${DURATION} 秒"
    log "=========================================="
    echo "日志已保存: $LOG_FILE"

    echo "清理临时文件..."
    rm -f ./stream
    [[ $? -ne 0 ]] && { echo "清理失败"; exit 1; }
    echo "完成!"
    echo "=========================================="
}

main "$@"
