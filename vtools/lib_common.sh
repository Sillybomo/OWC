#!/system/bin/sh
# @author bomo
# lib_common.sh — OPP vtools 公共函数库（v1.3.28）
#
# 背景：get_cpu_temp 此前在 battery_spoof / charging_spoof / thermal_guard
# 三处各持有一份拷贝，历史上已发生两次复制漂移事故（v1.3.15 单位 bug、
# v1.3.24 charging 侧 900=0.9°C 单位 bug 瘫痪充电伪装）。参考 Wangshu
# (Aestas) 的"单一实现 + 全链路校验"哲学，收敛到本库统一维护。
#
# 使用方式（守护脚本头部）：
#   . "$MODDIR/lib_common.sh"
# 注意：脚本会被 init_vtools.sh 拷贝到 tmp/ 运行，$MODDIR 即脚本所在目录，
#       init_vtools.sh / watchdog.sh 必须把本库一并拷贝过去。
#
# 约定：所有温度统一内核标准单位 m°C（0.001°C）；
#       电池温度（power_supply/battery/temp）为 0.1°C 单位，函数内不换算，
#       调用方各自按既有阈值语义使用（保持与 v1.3.27 及之前行为一致）。

# @author bomo
# CPU/SoC 真实温度读取（m°C）。遍历 thermal_zone，仅匹配真正的处理器
# 温度传感区（cpu/soc/apcc/tsens/aoss），排除 trip 配置节点与恒定 95000
# 占位假值，取最大值。
# 历史依据（勿改轻率）：
#   - 不能用 >=90000 全过滤：8-19 软重启事件实测 SoC 可真实持续运行在
#     95-105°C，全过滤会在热失控最关键时刻致盲保护栏。
#   - 恒定 95000 是 PMIC 相邻区占位假值（v1.3.17 实测），真实温度是波动的。
#   - v1.3.27: trip 类节点（cpu-hw-trip-*）按 type 排除，与触发阈值解耦。
get_cpu_temp() {
    local max=0 t type
    for z in /sys/class/thermal/thermal_zone*; do
        [ -f "$z/temp" ] || continue
        type=$(cat "$z/type" 2>/dev/null)
        # 仅匹配真正的处理器温度传感区（排除 PMIC/功放/静默区）
        case "$type" in
            *cpu*|*CPU*|*soc*|*SoC*|*apcc*|*tsens*|*aoss*) ;;
            *) continue ;;
        esac
        # trip 类节点是配置占位（恒 95000），非实时温度，按 type 排除
        case "$type" in
            *trip*|*TRIP*) continue ;;
        esac
        t=$(cat "$z/temp" 2>/dev/null)
        case "$t" in
            ''|*[!0-9\-]*) continue ;;
        esac
        # 仅精确过滤恒定 95000 占位假值（与触发阈值解耦，见上）
        [ "$t" -eq 95000 ] 2>/dev/null && continue
        [ "$t" -gt "$max" ] 2>/dev/null && max="$t"
    done
    echo "$max"
}

# @author bomo
# 电池真实温度读取（0.1°C 单位）。优先 battery，回退 Battery（大小写因机型而异）。
get_real_temp() {
    local t
    t=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
    if [ -z "$t" ]; then
        t=$(cat /sys/class/power_supply/Battery/temp 2>/dev/null)
    fi
    case "${t:-0}" in
        ''|*[!0-9\-]*) echo "0" ;;
        *) echo "$t" ;;
    esac
}

# @author bomo
# 充电状态检测。uevent 优先（一次读取覆盖最全），status 节点兜底，
# 最后 usb/ac online 兜底。三个守护脚本原实现完全一致，收敛于此。
is_charging() {
    grep -q 'POWER_SUPPLY_STATUS=Charging\|POWER_SUPPLY_STATUS=Full' /sys/class/power_supply/battery/uevent 2>/dev/null && return 0
    local status
    status=$(cat /sys/class/power_supply/battery/status 2>/dev/null)
    case "$status" in
        Charging|Full) return 0 ;;
    esac
    cat /sys/class/power_supply/usb/online 2>/dev/null | grep -q 1 && return 0
    cat /sys/class/power_supply/ac/online 2>/dev/null | grep -q 1 && return 0
    return 1
}

# @author bomo
# 有界日志轮转（行数上限版）。超过 $2 行裁剪到最近 $3 行。
# 各守护脚本的 rotate_log 原实现一致（200 裁 100），收敛于此统一维护。
# 用法: rotate_log_file "$LOG_FILE" 200 100
rotate_log_file() {
    local file="$1" max="${2:-200}" keep="${3:-100}" line_count
    line_count=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
    if [ "${line_count:-0}" -gt "$max" ] 2>/dev/null; then
        tail -n "$keep" "$file" > "${file}.tmp" 2>/dev/null
        mv "${file}.tmp" "$file" 2>/dev/null
    fi
}

# @author bomo
# 带 cmdline 验证的安全杀进程（借鉴 Wangshu terminate 的防 PID 复用思想）。
# 逐 PID 校验 /proc/<pid>/cmdline 确实包含目标脚本名才发信号，
# 防止 pgrep -f 的模式串匹配到无关进程（如编辑器打开脚本文件）后误杀。
# 用法: kill_verified <脚本名> [信号]
kill_verified() {
    local name="$1" sig="${2:-TERM}" pid
    for pid in $(pgrep -f "$name" 2>/dev/null); do
        [ "$pid" != "$$" ] || continue
        if grep -q "$name" "/proc/$pid/cmdline" 2>/dev/null; then
            kill -"$sig" "$pid" 2>/dev/null
        fi
    done
}
