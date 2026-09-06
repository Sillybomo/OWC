#!/system/bin/sh
# @author bomo
# OWC 亮屏快充守护 — 自 OPP v1.3.29 vtools/battery_spoof.sh 分离（2026-09-06）
#
# 功能：充电时停止 ORMS 服务 + horae testmode + /proc/shell-temp 伪装 34°C，
#       使系统亮屏时不限充电功率（满功率快充 50W）。
# 原理：ColorOS 按壳温(/proc/shell-temp)限制亮屏充电功率，壳温伪装为 34°C
#       即绕过限功率策略；ORMS 是充电调度服务，停止后不做保守限速。
#
# 安全栏（继承自 OPP 8-13/8-15/8-19 热失控教训，不可删）：
#   1. 游戏运行中暂停 —— shell-temp 伪装也是骗温控，游戏中继续 = SoC 持续
#      升温而系统不知情（原 OPP 注释：游戏时继续亮屏快充 = 换条路继续骗温控）
#   2. 电池真实温度 >= SAFE_TEMP_CEILING(46°C) 暂停
#   3. CPU/SoC >= CPU_TEMP_CEILING(85°C) 暂停（防 PMIC 硬复位 95°C，留 10°C 余量）
#   4. 充电断开 / 进程退出 → 恢复 ORMS + horae（还原系统状态）
#
# 不包含（仍属 OPP battery_spoof）：电池温度伪装(emul_temp/oplus_chg)、
# 循环次数伪装。两模块同时安装时，OPP 侧有防双开检测自动关闭其 WARP。
#
# 运行模式与 OPP 一致：service.sh 将本脚本拷入 tmp/ 后运行，
# $MODDIR 即 tmp 目录，lib_common.sh / game_blacklist.txt 均在同目录。

MODDIR="$(dirname $(readlink -f "$0"))"
TMP_DIR="$MODDIR/../tmp"
LOG_FILE="$TMP_DIR/warp_charge.log"
LOCK_FILE="$TMP_DIR/warp_charge.lock"
BLACKLIST_FILE="$MODDIR/game_blacklist.txt"
FILTERED_LIST="$TMP_DIR/game_blacklist_f.txt"
# 公共函数库（is_charging / get_real_temp / get_cpu_temp / rotate_log_file /
# kill_verified），单一实现原则，防复制漂移（OPP v1.3.15/v1.3.24 两次单位 bug
# 均为复制漂移产物）
. "$MODDIR/lib_common.sh"

# ==================== 可配置参数 ====================
CHECK_INTERVAL=4                # 检测间隔（秒）。v1.1.1: 8→4，热开关灵敏度优化（用户连点会翻转状态，缩短守护响应窗口）
GAME_CHECK_CYCLE=4              # 每 N 轮检测一次游戏（约 32 秒）
WARP_REAPPLY_CYCLE=8            # 每 N 轮重新应用一次 horae testmode（约 64 秒）
# @author bomo: 阈值语义与 OPP battery_spoof 保持一致（拆分时原样继承）
SAFE_TEMP_CEILING=460           # 电池真实温度上限（0.1°C，460=46°C）
CPU_TEMP_CEILING=85000          # CPU/SoC 温度上限（m°C，85000=85°C，防 95°C 硬复位）
# ====================================================

# ==================== ORMS 全局变量（一次性检测） ====================
ORMS_SVC=""
ORMS_NAME=""

# @author bomo v1.1: 用户热开关（控制中心 tile / App 写入）。
# 文件缺失或 !=0 视为开启（默认开）；=0 时守护暂停 WARP 并恢复系统状态。
# 与安全栏的关系：本开关是"用户意愿"层，安全栏（游戏/温度/断充）是"安全"层，
# 两层独立生效——用户开着时安全栏照常暂停，用户关着时安全栏无动作对象。
ENABLED_FILE="/data/adb/owc/enabled"
is_user_enabled() {
    [ ! -f "$ENABLED_FILE" ] && return 0
    [ "$(cat "$ENABLED_FILE" 2>/dev/null | tr -d ' \r\n')" != "0" ]
}

_log() {
    printf '[%s] [warp_charge] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
    rotate_log_file "$LOG_FILE" 200 100
}

_log_status() {
    local current_state="$1"
    if [ "$current_state" != "$LAST_LOG_STATE" ]; then
        _log "$2"
        LAST_LOG_STATE="$current_state"
    fi
}

DUMP_TIMEOUT=3
safe_dumpsys() {
    timeout "$DUMP_TIMEOUT" dumpsys "$@" 2>/dev/null
}

# Android 16 兼容的前台游戏检测（原样继承自 OPP battery_spoof）
is_game_running() {
    [ ! -f "$FILTERED_LIST" ] && return 1

    local pkg=""
    # 方案 A：使用 dumpsys activity
    pkg=$(safe_dumpsys activity activities | grep -E 'mResumedActivity|topResumedActivity' | head -1 | grep -oE '[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+' | head -1 | cut -d'/' -f1)
    # 方案 B：Fallback 到 dumpsys window
    if [ -z "$pkg" ]; then
        pkg=$(safe_dumpsys window | grep -E 'mCurrentFocus|mFocusedApp' | head -1 | grep -oE '[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+' | head -1 | cut -d'/' -f1)
    fi
    [ -z "$pkg" ] && return 1
    # 匹配黑名单
    echo "$pkg" | grep -qFf "$FILTERED_LIST" 2>/dev/null
}

# 游戏状态更新（原 OPP 共享权重文件 GAME_WEIGHT_FILE 供 thermal_guard 使用，
# OWC 无 thermal_guard，移除该共享；游戏检测节律与节流周期原样保留）
update_game_active() {
    if is_game_running; then
        [ "$GAME_ACTIVE" = "0" ] && _log "检测到游戏运行"
        GAME_ACTIVE=1
    else
        if [ "$GAME_ACTIVE" = "1" ]; then
            _log "游戏已退出"
            # 游戏退出后立即恢复亮屏快充(不等周期)。仅在充电状态下恢复,
            # 避免放电状态下误停 ORMS/写 shell-temp 伪装。
            if [ "$current_charging" = "1" ] && [ "$WARP_ACTIVE" = "0" ]; then
                apply_warp_charge
                _log "[亮屏快充] 游戏退出后已恢复"
            fi
        fi
        GAME_ACTIVE=0
    fi
}

# ==================== 亮屏快充核心（原样继承自 OPP battery_spoof.sh） ====================

# 检测并记录ORMS服务状态（启动时一次）
init_warp_charge() {
    # 检测ORMS服务名
    for svc in vendor.oplus.ormsHalService-aidl-default vendor.oplus.orms-hal-default; do
        if service check "$svc" 2>/dev/null; then
            ORMS_SVC="$svc"
            _log "[亮屏快充] 检测到ORMS服务: $svc"
            break
        fi
    done

    # 保存原始属性（供卸载恢复）
    ORMS_NAME=$(getprop persist.sys.orms.name)
    echo "$ORMS_NAME" > "$TMP_DIR/orms_name_backup" 2>/dev/null
    echo "$ORMS_SVC" > "$TMP_DIR/orms_svc_backup" 2>/dev/null
    _log "[亮屏快充] 已备份ORMS状态 (svc=$ORMS_SVC, name=$ORMS_NAME)"
}

# @author bomo v1.3: 亮屏降流对抗。
# 实测（2026-09-06 PLZ110/ColorOS16）：ColorOS 亮屏时写 cool_down=5（降流档，
# 22-33W），此为"亮屏慢充"的直接开关；写 0 后 1 秒内恢复满功率（79W）。
# 系统会在亮屏策略刷新时重写 5，守护每轮对抗。restore 时写 5 交还控制权。
COOL_DOWN_NODE=/sys/class/oplus_chg/battery/cool_down
apply_cool_down_override() {
    [ -f "$COOL_DOWN_NODE" ] || return 0
    [ "$(cat "$COOL_DOWN_NODE" 2>/dev/null)" = "0" ] && return 0
    echo 0 > "$COOL_DOWN_NODE" 2>/dev/null
    _log "[亮屏快充] cool_down=$(cat "$COOL_DOWN_NODE" 2>/dev/null) 已归零（对抗系统亮屏降流）"
}

# 恢复系统默认亮屏策略（安全暂停/用户关闭时交还降流控制权）
restore_cool_down() {
    [ -f "$COOL_DOWN_NODE" ] || return 0
    echo 5 > "$COOL_DOWN_NODE" 2>/dev/null
}

# 应用亮屏快充（停止ORMS + horae testmode，shell伪装34°C）
apply_warp_charge() {
    # 停止ORMS服务
    if [ -n "$ORMS_SVC" ]; then
        stop "$ORMS_SVC" 2>/dev/null
    fi
    setprop persist.sys.orms.name ""

    # 使用 dumpsys horae testmode（保持服务存活，仅切换数据源为shell-temp）
    dumpsys horae testmode 2>/dev/null
    # shell温度传感器伪装为34°C
    for i in 0 1 2; do
        echo "$i 34000" > /proc/shell-temp 2>/dev/null
    done

    # 亮屏降流对抗（ColorOS 亮屏写 cool_down=5 限 22-33W）
    apply_cool_down_override

    WARP_ACTIVE=1
}

# 恢复亮屏快充（恢复ORMS + horae正常模式）
restore_warp_charge() {
    # 恢复horae温控HAL（退出测试模式）
    dumpsys horae testmode false 2>/dev/null

    # 恢复ORMS服务
    if [ -n "$ORMS_SVC" ]; then
        start "$ORMS_SVC" 2>/dev/null
    fi
    if [ -n "$ORMS_NAME" ]; then
        setprop persist.sys.orms.name "$ORMS_NAME"
    fi

    # 交还亮屏降流控制权（恢复系统默认策略，让真实温度重新生效）
    restore_cool_down

    WARP_ACTIVE=0
    _log "[亮屏快充] 已恢复 ORMS + horae"
}

# ==================== CLI 单次动作模式 ====================
# @author bomo v1.2: 事件驱动热开关——App/tile 点击时经 su 直接调用：
#   sh warp_charge.sh apply    （开：安全检查通过后立即应用 WARP）
#   sh warp_charge.sh restore  （关：立即恢复 ORMS + horae）
# 秒级生效，不再依赖主循环轮询（轮询仅作为安全栏巡检与状态兜底）。
# 并发安全：用户关(restore)与守护周期 apply 撞车时，restore 后守护下一轮
# 读到 enabled=0 不再应用，最终状态正确。
case "$1" in
    apply)
        # 单次安全检查（与主循环同条件）：充电中 + 非游戏 + 双温度未超标
        if ! is_charging; then exit 0; fi
        if [ -f "$FILTERED_LIST" ] && is_game_running; then exit 0; fi
        rt=$(get_real_temp); ct=$(get_cpu_temp)
        [ "$rt" -ge "$SAFE_TEMP_CEILING" ] 2>/dev/null && exit 0
        [ "$ct" -ge "$CPU_TEMP_CEILING" ] 2>/dev/null && exit 0
        apply_warp_charge
        exit 0
        ;;
    restore)
        restore_warp_charge
        exit 0
        ;;
esac

# ==================== 主逻辑 ====================

# 防重复启动（PID + cmdline 双验证，防 PID 复用误判——继承 OPP 模式）
if [ -f "$LOCK_FILE" ]; then
    old_pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        if grep -q "warp_charge" "/proc/$old_pid/cmdline" 2>/dev/null; then
            _log "已有实例运行中(PID=$old_pid)"
            exit 0
        else
            _log "检测到 PID=$old_pid 已被系统复用给其他进程，清理旧锁并接管"
            rm -f "$LOCK_FILE"
        fi
    else
        _log "检测到残留死锁文件(旧PID=$old_pid)，自动清理并重启"
        rm -f "$LOCK_FILE"
    fi
fi
echo $$ > "$LOCK_FILE"

cleanup() {
    _log "守护进程退出，恢复所有系统状态"
    restore_warp_charge
    rm -f "$LOCK_FILE" "$FILTERED_LIST"
    exit 0
}
trap cleanup EXIT INT TERM

_log "OWC 亮屏快充守护进程启动 (PID=$$)"

# 等待系统就绪（有界等待，借鉴 OPP v1.3.28 修复：无超时会在系统异常时永久挂起）
BOOT_WAIT_MAX=60   # 60 次 × 3s = 180s
BOOT_WAIT_N=0
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 3
    BOOT_WAIT_N=$(( BOOT_WAIT_N + 1 ))
    if [ "$BOOT_WAIT_N" -ge "$BOOT_WAIT_MAX" ]; then
        _log "⚠ 等待开机超时(180s)，带病继续（守护自身锁与安全栏已就绪）"
        break
    fi
done
_log "系统就绪"

# 游戏黑名单（去除 \r、注释、空行）
if [ -f "$BLACKLIST_FILE" ]; then
    sed 's/\r$//; /^#/d; /^$/d' "$BLACKLIST_FILE" > "$FILTERED_LIST" 2>/dev/null
    _log "游戏黑名单已加载 ($(wc -l < "$FILTERED_LIST" 2>/dev/null | tr -d ' ') 条)"
else
    _log "游戏黑名单文件不存在，跳过游戏检测"
fi

# 亮屏快充初始化（一次性检测 ORMS）
init_warp_charge

LAST_LOG_STATE="init"
GAME_ACTIVE=0
PREV_CHARGING=0
loop_count=0

# ==================== 守护循环 ====================
while true; do
    current_charging=0

    # ---- 游戏检测（循环顶层, 充电/放电均实时更新；OPP v1.3.27 教训：
    #      埋进 is_charging 分支会导致放电场景状态陈旧）----
    if [ $(( loop_count % GAME_CHECK_CYCLE )) -eq 0 ]; then
        update_game_active
    fi

    if is_charging; then
        current_charging=1

        # ---- 用户热开关（tile/App）关闭时：恢复并跳过 WARP，仅保留安全栏观察 ----
        # 注意：不修改 PREV_CHARGING——用户重新打开后，下一轮即走"充电接入立即
        # 响应"路径，8 秒内生效（否则要等 64s 周期重应用）。
        if ! is_user_enabled; then
            if [ "$WARP_ACTIVE" = "1" ]; then
                restore_warp_charge
            fi
            _log_status "user_off" "亮屏快充已由用户关闭（充电中仍持续待命）"
            loop_count=$(( loop_count + 1 ))
            sleep "$CHECK_INTERVAL"
            continue
        fi

        # ---- 充电接入立即响应 ----
        if [ "$PREV_CHARGING" = "0" ]; then
            PREV_CHARGING=1
            _log "检测到充电接入"
            # 充电接入时立即检测游戏, 消除 32 秒周期窗口内伪装开跑的风险
            update_game_active
            # 首次充电：仅非游戏时立即应用亮屏快充
            if [ "$GAME_ACTIVE" = "0" ]; then
                apply_warp_charge
                _log "[亮屏快充] 已激活（充电接入）"
            fi
        fi

        if [ "$GAME_ACTIVE" = "1" ]; then
            # 游戏中: 停亮屏快充（shell-temp 伪装骗温控 → SoC 升温危险）
            if [ "$WARP_ACTIVE" = "1" ]; then
                restore_warp_charge
                _log "游戏运行中，亮屏快充已暂停(系统温控接管)"
            fi
        else
            real_temp=$(get_real_temp)
            cpu_temp=$(get_cpu_temp)

            if [ "$real_temp" -gt 0 ] && [ "$real_temp" -ge "$SAFE_TEMP_CEILING" ] 2>/dev/null; then
                # 电池过热保护
                if [ "$WARP_ACTIVE" = "1" ]; then
                    restore_warp_charge
                    _log "⚠ 安全保护：电池温度 ${real_temp} >= ${SAFE_TEMP_CEILING}，亮屏快充已暂停"
                fi
                _log_status "safe_stop" "亮屏快充已暂停 (电池温度=${real_temp})"
            elif [ "$cpu_temp" -gt 0 ] && [ "$cpu_temp" -ge "$CPU_TEMP_CEILING" ] 2>/dev/null; then
                # CPU/SoC 过热保护（防 PMIC 硬复位）
                if [ "$WARP_ACTIVE" = "1" ]; then
                    restore_warp_charge
                fi
                _log "⚠ 安全保护：CPU/SoC温度 ${cpu_temp} >= ${CPU_TEMP_CEILING}，亮屏快充已暂停"
                _log_status "cpu_safe_stop" "CPU过热已暂停 (CPU=${cpu_temp})"
            else
                # 正常: 周期性重应用（防 horae testmode 被系统重置）
                if [ $(( loop_count % WARP_REAPPLY_CYCLE )) -eq 0 ]; then
                    apply_warp_charge
                fi
                # cool_down 每轮对抗（系统亮屏策略刷新会重写 5）
                apply_cool_down_override
            fi
        fi

    else
        # 未充电
        if [ "$PREV_CHARGING" = "1" ]; then
            PREV_CHARGING=0
            _log "充电断开"
            restore_warp_charge
            _log "[亮屏快充] 已恢复（充电断开）"
        fi
        if [ "$GAME_ACTIVE" = "1" ]; then
            GAME_ACTIVE=0
        fi
    fi

    if [ $(( loop_count % 75 )) -eq 0 ]; then
        if [ "$current_charging" = "1" ]; then
            _log "[心跳] 充电中 | 亮屏快充=${WARP_ACTIVE} | 用户开关=$(is_user_enabled && echo 开 || echo 关) | 电池=${real_temp:-$(get_real_temp)} | CPU=${cpu_temp:-$(get_cpu_temp)} | 游戏=${GAME_ACTIVE}"
        else
            _log "[心跳] 未充电 | 亮屏快充=${WARP_ACTIVE} | 用户开关=$(is_user_enabled && echo 开 || echo 关) | 游戏=${GAME_ACTIVE}"
        fi
    fi

    loop_count=$(( loop_count + 1 ))
    sleep "$CHECK_INTERVAL"
done
