#!/system/bin/sh
# @author bomo
# OWC 亮屏快充守护（2026-09-06）
#
# 功能：充电时停止 ORMS 服务 + horae testmode + /proc/shell-temp 伪装 34°C，
#       使系统亮屏时不限充电功率（满功率快充 50W）。
# 原理：ColorOS 按壳温(/proc/shell-temp)限制亮屏充电功率，壳温伪装为 34°C
#       即绕过限功率策略；ORMS 是充电调度服务，停止后不做保守限速。
#
# 安全栏（源自 8-13/8-15/8-19 热失控教训，不可删）：
#   ★ v1.4.7 起语义 = **保险丝**，非调速器：不到阈值一律不干涉，一到阈值立即熔断。
#   四传感器独立熔断（任一撞线即熔断，完全交还系统）：
#     1. 电池真实温度 >= TRIP_BATT(45°C)
#     2. CPU/SoC       >= TRIP_CPU(92°C)
#     3. GPU           >= TRIP_GPU(92°C)   （gpuss-*，与 CPU 节点零重叠）
#     4. 壳温          >= TRIP_SHELL(48°C) （shell_front/frame/back）
#   阈值全局统一，**不再区分游戏/非游戏**（用户 2026-09-16 拍板）。
#   历史阈值（46/85）与滞回恢复线（v1.4.3~v1.4.6 的 TEMP_RESUME_* / CPU_RESUME_DROP）
#   已随"保险丝语义"一并撤除。
#
# @author bomo v1.4.2（2026-09-15 用户要求）：安全栏由「场景驱动」改成「温度驱动」。
#   原第 1 条「游戏运行中暂停」已撤除——它会在温度完全正常时（实测 38.3°C 电池 /
#   73.3°C CPU）仅因检测到游戏就停掉亮屏快充，与"游戏与温度须同时满足才限制"的
#   预期不符。原设计意图保留在此作历史依据：shell-temp 伪装本身就是骗温控，游戏中
#   继续快充 = SoC 持续升温而系统不知情；现在改由上面两条温度线把关（守护每 4s
#   轮询真实温度，超限即停），游戏信息仍进日志便于回溯。
#   若日后觉得游戏场景需要更严余量，可另加游戏专属门槛（如电池 42°C / CPU 78°C）
#   并在 warp_temp_hot 内按 GAME_ACTIVE 切换。
#   4. 充电断开 / 进程退出 → 恢复 ORMS + horae（还原系统状态）
#      ↑ 条目编号沿用原文档（原第 1 条撤除后不再重排），便于与历史记录对照。
#
# @author bomo v1.4.3（2026-09-15）：温度滞回防抖 + 恢复确认 + 游戏独立阈值。
#   背景：v1.4.2 单阈值无状态——温度在 85°C 线上每跳一次就 restore/apply 一次，
#   实测 22:36~22:40 开机+充电场景 4 分钟内暂停/恢复抖动 3 次。
#   ① 滞回：暂停线不变（电池 46°C / CPU 85°C），恢复线独立（电池 ≤42°C /
#      CPU ≤78°C），死区内保持原状态不翻转。
#   ② 恢复确认：回落恢复线以下后须连续 RESUME_CONFIRM 次采样达标才恢复，
#      防单次尖刺。
#   ③ 日志：暂停/恢复记录温度、暂停持续时长、本小时切换次数。
#   ④ 游戏态电池暂停线放宽到 48°C（游戏本身发热大，避免正常游戏温度误伤
#      快充体验）；CPU 线不动——那是防 PMIC 95°C 硬复位的安全余量，不让步。
#
# @author bomo v1.4.7（2026-09-16 安全阀重构 · 用户拍板）：保险丝语义 + 四传感器统一阈值。
#   用户定的最终形态：
#     「开启磁贴亮屏快充 + 打游戏时，尽可能保证快充且不影响游戏；同时有一个严格的安全阈值
#       防止游戏+充电导致物理损坏，超限则自动临时解除亮屏快充、由系统接管。这个阈值的意义
#       在于：如果运行低负载游戏或用散热器，能做到边玩边充且温度不到阈值，快充就不该被接管。」
#   ① 语义：安全栏 = **保险丝**（不到阈值不干涉，一到阈值即熔断并完全交还），非调速器。
#      故删除全部为"精细调速"服务的参数：TEMP_RESUME_BATT / TEMP_RESUME_CPU /
#      CPU_RESUME_DROP / PAUSE_TEMP_CPU / GAME_TEMP_CEILING。
#   ② 四传感器独立熔断（任一撞线即熔断）：CPU 92°C / GPU 92°C / 电池 45°C / 壳温 48°C。
#      新增 get_gpu_temp() / get_shell_temp()（lib_common.sh），实测确认 gpuss-0~10 与
#      cpu-* 节点零重叠 —— 只盯 CPU 会漏掉 GPU 先行过热。
#   ③ 熔断动作 = **完全交还系统**（撤销 v1.4.5 的 cpu_hot 分级：曾保持 cool_down=0
#      以治 15W 事故，但用户要求熔断即完全交还，不做降档折中）。
#   ④ 阈值全局统一，**不区分游戏/非游戏**——用户原话「并不需要单独区分，就按照92°的
#      阈值即可，全部统一」。高负载游戏（异环/鸣潮）撞线熔断属预期行为。
#   ⑤ 复归：四路全部回落 + 连续 RESUME_CONFIRM(3) 次确认（防抖，非调速）。
#   实测依据：游戏态 CPU 最热核 76~89°C 剧烈抖动、GPU 独立升温、壳温决定握持体感。
#
# 不包含：电池温度伪装(emul_temp/oplus_chg)、循环次数伪装。
#
# 运行模式：service.sh 将本脚本拷入 tmp/ 后运行，
# $MODDIR 即 tmp 目录，lib_common.sh / game_blacklist.txt 均在同目录。

MODDIR="$(dirname $(readlink -f "$0"))"
TMP_DIR="$MODDIR/../tmp"
LOG_FILE="$TMP_DIR/warp_charge.log"
LOCK_FILE="$TMP_DIR/warp_charge.lock"
BLACKLIST_FILE="$MODDIR/game_blacklist.txt"
FILTERED_LIST="$TMP_DIR/game_blacklist_f.txt"
# 公共函数库（is_charging / get_real_temp / get_cpu_temp / rotate_log_file /
# kill_verified），单一实现原则，防复制漂移（历史两次单位 bug 均为复制漂移产物）
. "$MODDIR/lib_common.sh"

# ==================== 可配置参数 ====================
CHECK_INTERVAL=4                # 检测间隔（秒）。v1.1.1: 8→4，热开关灵敏度优化（用户连点会翻转状态，缩短守护响应窗口）
GAME_CHECK_CYCLE=4              # 每 N 轮检测一次游戏（约 32 秒）
WARP_REAPPLY_CYCLE=8            # 每 N 轮重新应用一次 horae testmode（约 64 秒）
# @author bomo: 阈值语义在拆分时原样继承，保持不变
# @author bomo v1.4.7（2026-09-16 安全阀重构 · 用户拍板）：
#   语义再澄清 —— **OWC 的安全栏是"保险丝"，不是"调速器"**。
#   用户原话：「在我开启磁贴里的亮屏快充按钮时处于打游戏下，尽可能保证快充的前提下，
#   不影响游戏，然后同时也有一个严格的安全阈值，用于防止游戏+充电造成的温度过高导致
#   物理损坏，自动临时解除亮屏快充，由系统接管……比如我运行一些低负载的游戏，或者
#   我有散热器，能够做到边玩游戏边充电，且温度不到阈值，那我这个快充就不应该被系统所接管」
#   ⇒ 保险丝逻辑：**不到阈值一律不干涉**（哪怕在打游戏），**一到阈值立即熔断**
#     （完全交还系统，不做降档折中）。
#
#   相对 v1.4.3~v1.4.6 的变化（**全部删除**，见下）：
#     - 删 TEMP_RESUME_BATT / TEMP_RESUME_CPU / CPU_RESUME_DROP / PAUSE_TEMP_CPU：
#       恢复线 + 回落幅度是为"调速器"准备的精细控制，保险丝不需要——熔断后由系统接管，
#       快充是否重新生效由温度自然决定，不靠守护去"争取"。
#     - 删 GAME_TEMP_CEILING：用户明确「并不需要单独区分，就按照92°的阈值即可，全部统一」。
#       游戏态与非游戏态共用同一套阈值（全局保险丝，非场景驱动）。
#     - 保留 RESUME_CONFIRM：不是调速，是**防抖**（防单次采样尖刺造成熔断-复归抖振）。
#
#   实测依据：游戏态 CPU 最热核 76~89°C 剧烈抖动（15s 可跳 10°C），GPU 独立升温，
#   只盯 CPU 会漏掉 GPU 先行过热；且机身壳温决定握持体感，器件未临界也可能烫手。
#   ⇒ 四传感器独立熔断：CPU / GPU / 电池 / 壳温，**任一撞线即熔断**。
#   ★ 阈值统一 92°C（CPU=GPU），用户拍板原话：
#     「像异环/鸣朝这种本身高负载的游戏，就不应该亮屏快充吧，2选一没问题，
#       但我觉得并不需要单独区分，就按照92°的阈值即可，全部统一」
#     §高负载游戏（异环/鸣潮）撞线熔断属**预期行为**，非 bug——用户已认可"快充与高负载二选一"。
TRIP_CPU=92000                  # CPU/SoC 熔断线（m°C，92000=92°C）
TRIP_GPU=92000                  # GPU 熔断线（m°C，92000=92°C）—— 与 CPU 统一值
TRIP_BATT=450                   # 电池熔断线（0.1°C，450=45°C）
TRIP_SHELL=48000                # 壳温熔断线（m°C，48000=48°C）—— 握持体感线
# 兼容别名：主循环与 restore 分级仍按旧名引用，保持最小侵入（语义 = 对应熔断线）
SAFE_TEMP_CEILING="$TRIP_BATT"
CPU_TEMP_CEILING="$TRIP_CPU"
# @author bomo v1.4.8（2026-09-16 游戏态实测后的修正）：**复归死区**（hysteresis）。
#   实测证据（异环 + 亮屏快充，00:18~00:21）：CPU 在 **90.7~94.2°C** 之间每 6 秒振荡，
#   熔断线 92°C 正压在这段振荡带的**中心**。于是状态机反复走
#     「复归确认中 1/3（CPU=91.5）→ 熔断持续（CPU=93.8）→ 复归确认中 1/3…」
#   —— 5 次「1/3」、**0 次攒满 3/3**，RESUME_CONFIRM 被完全穿透，状态机空转、日志刷屏。
#   ★ 修法：复归线不再等于熔断线，而是**熔断线下方留出死区**（本轮前它俩是同一个数，
#     所以"连续采样确认"对振荡带毫无防御力——采样永远等不到 3 连达标的窗口）。
#   死区取 3°C：实测振荡带宽度约 3.5°C，死区 ≥ 振荡带宽才能在带内稳定不翻转；
#   同时 3°C 足够小，真冷却（退游戏 / 上散热器）时能快速复归，不会拖成"熔断后不恢复"。
#   （v1.4.4→v1.4.6 三次"调恢复线"失败，是因当时把恢复线当"调速"去追温度；
#     现在恢复线只是**状态机的复归闸门**，不承担任何"争取快充"的语义。）
TRIP_RESUME_GAP=3000            # 复归死区（m°C）= 3°C（电池侧按 0.1°C 单位单列，见下）
TRIP_RESUME_CPU=$(( TRIP_CPU - TRIP_RESUME_GAP ))     # 89000
TRIP_RESUME_GPU=$(( TRIP_GPU - TRIP_RESUME_GAP ))     # 89000
TRIP_RESUME_BATT=$(( TRIP_BATT - 30 ))                # 420（0.1°C 单位，=42°C，同样 3°C 死区）
TRIP_RESUME_SHELL=$(( TRIP_SHELL - TRIP_RESUME_GAP )) # 45000
RESUME_CONFIRM=3                # 复归确认：连续 3 次（≈12s）全部低于**复归线**才复归，防抖
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

# Android 16 兼容的前台游戏检测
# @author bomo v1.4.2: 两处健壮性修复（与 ohzd 同日的同类坑）
#   ① 方案 A 补 `ResumedActivity` 标记——ColorOS 16 / PLZ110 实测 `dumpsys activity
#      activities` 里既没有 `topResumedActivity=` 也没有 `mResumedActivity:`，
#      只有 `ResumedActivity:`，沿用旧标记会恒取不到包名。
#   ② 方案 B 把 `head -1` 移到 grep -oE 之后——原写法只看第一条匹配行，而通知栏
#      / 输入法这类窗口的 mCurrentFocus 不带"包名/Activity"，会直接把整条链掐断，
#      即使下一行 mFocusedApp 里有包名也读不到。改为取第一条**含包名**的焦点行。
is_game_running() {
    [ ! -f "$FILTERED_LIST" ] && return 1

    local pkg=""
    # 方案 A：使用 dumpsys activity
    pkg=$(safe_dumpsys activity activities | grep -E 'mResumedActivity|topResumedActivity|ResumedActivity' | head -1 | grep -oE '[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+' | head -1 | cut -d'/' -f1)
    # 方案 B：Fallback 到 dumpsys window
    if [ -z "$pkg" ]; then
        pkg=$(safe_dumpsys window | grep -E 'mCurrentFocus|mFocusedApp' | grep -oE '[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+' | head -1 | cut -d'/' -f1)
    fi
    [ -z "$pkg" ] && return 1
    # 匹配黑名单
    echo "$pkg" | grep -qFf "$FILTERED_LIST" 2>/dev/null
}

# 游戏状态更新（本模块无跨脚本共享权重文件；游戏检测节律与节流周期原样保留）
update_game_active() {
    if is_game_running; then
        [ "$GAME_ACTIVE" = "0" ] && _log "检测到游戏运行"
        GAME_ACTIVE=1
    else
        if [ "$GAME_ACTIVE" = "1" ]; then
            _log "游戏已退出"
            # 游戏退出后立即恢复亮屏快充(不等周期)。仅在充电状态下恢复,
            # 避免放电状态下误停 ORMS/写 shell-temp 伪装。
            # @author bomo v1.4.2: 补温度守卫——过热暂停期间不得被本路径绕过。
            if [ "$current_charging" = "1" ] && [ "$WARP_ACTIVE" = "0" ] && ! warp_temp_hot; then
                apply_warp_charge
                _log "[亮屏快充] 游戏退出后已恢复"
            fi
        fi
        GAME_ACTIVE=0
    fi
}

# ==================== 亮屏快充核心 ====================

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
# @author bomo v1.4.5: 曾新增 $1 控制「是否交还亮屏降流控制权(cool_down)」——背景是
#   2026-09-15 23:28 实测发现无条件交还会让 CPU 过热暂停时充电头只剩 15W。
# @author bomo v1.4.7（2026-08-16 用户拍板）：**撤销分级，统一完全交还**。
#   用户定调"熔断 = 完全交还系统，由系统接管"（保险丝语义），故不再有 cpu_hot 分支。
#   $1 形参保留仅作向后兼容（旧调用点传参不再有语义差异）。
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

    # 亮屏降流控制权：熔断即**完全交还系统**（用户 v1.4.7 拍板：保险丝语义，
    # 不做"CPU 过热保持 cool_down=0"这种降档折中）。
    # @author bomo v1.4.7: 保留 $1 形参仅为向后兼容旧调用点，语义统一为完全交还。
    #   历史沿革：v1.4.5 曾按来源分级（cpu_hot 保持满功率通路）以治 15W 事故，
    #   但用户最终要求"熔断 = 完全交还系统"，故撤销分级。
    restore_cool_down
    _log "[亮屏快充] 已交还 cool_down 降流控制权（来源=${WARP_GUARD_SRC:-unknown}）"

    WARP_ACTIVE=0
    _log "[亮屏快充] 已恢复 ORMS + horae"
}

# @author bomo v1.4.2: 温度安全栏——**唯一的暂停依据**。
# 返回 0 = 已过热（必须停 WARP）；返回 1 = 正常（可继续亮屏快充）。
# 超限原因写入全局 WARP_GUARD_REASON 供日志使用（避免各处重复取温度）。
# 游戏运行状态不参与暂停触发（用户要求：游戏与温度须同时满足才限制，
# 而温度未到时游戏不应单独触发暂停）。
#
# @author bomo v1.4.3: 改为带状态机（治 85°C 线上 4 分钟抖 3 次的实测问题）。
# @author bomo v1.4.7（2026-09-16 安全阀重构 · 保险丝语义）：
#   **四传感器独立熔断，任一撞线立即熔断**（完全交还系统）。
#     - CPU  TRIP_CPU=92000   全 SoC 最热核
#     - GPU  TRIP_GPU=92000   gpuss-0~10 最热核（与 CPU 节点零重叠，实测确认）
#     - BATT TRIP_BATT=450    电池真实温度（0.1°C 单位）
#     - SHELL TRIP_SHELL=48000 shell_front/frame/back 最热面
#   熔断来源写入 WARP_GUARD_SRC（cpu/gpu/batt/shell），供调用方分级处理。
#   复归：四路**全部**回落到各自**复归线**（熔断线 − TRIP_RESUME_GAP）以下，
#         连续 RESUME_CONFIRM 次才复归（防抖）。
#   未熔断(OVERHEAT=0)：任一撞线即熔断。**不再区分游戏/非游戏**（用户要求全局统一）。
#   CLI apply 单次调用时 OVERHEAT 初值 0，行为退化为单次熔断线检查，语义兼容。
#
# @author bomo v1.4.8（2026-09-16 游戏态实测后的修正）：**熔断/复归分线**（死区）。
#   实测（异环，00:18~00:21）CPU 在 90.7~94.2°C 每 6s 振荡，熔断线 92 正压带中心 →
#   v1.4.7 的"回落到熔断线以下算达标"每次都只攒到 1/3 就被打回，**0 次攒满**，
#   状态机空转刷日志。现在：
#     熔断判定用 TRIP_*（原值不变，92/92/450/48000）—— 保险丝行为零变化；
#     复归判定用 TRIP_RESUME_*（89/89/420/45000）—— 振荡带整个落在死区内，
#       任一采样都到不了 89 ⇒ 稳定保持熔断，不再空转；
#       真冷却（退游戏/上散热器）时才可能连攒 3 次，干净复归。
warp_temp_hot() {
    WARP_GUARD_REASON=""
    local rt ct gt st
    rt=$(get_real_temp)
    ct=$(get_cpu_temp)
    gt=$(get_gpu_temp)
    st=$(get_shell_temp)
    # 传感器读数异常时按"未回复归线"处理（保守，不误恢复）
    [ "$rt" -gt 0 ] 2>/dev/null || rt=9999
    [ "$ct" -gt 0 ] 2>/dev/null || ct=9999999
    [ "$gt" -gt 0 ] 2>/dev/null || gt=9999999
    [ "$st" -gt 0 ] 2>/dev/null || st=9999999

    # 熔断判定：四路独立越线（>= 熔断线，1 = 已越线）
    local batt_hot=0 cpu_hot=0 gpu_hot=0 shell_hot=0
    [ "$rt" -ge "$TRIP_BATT" ] 2>/dev/null && batt_hot=1
    [ "$ct" -ge "$TRIP_CPU" ] 2>/dev/null && cpu_hot=1
    [ "$gt" -ge "$TRIP_GPU" ] 2>/dev/null && gpu_hot=1
    [ "$st" -ge "$TRIP_SHELL" ] 2>/dev/null && shell_hot=1
    local any_hot=0
    if [ "$batt_hot" = "1" ] || [ "$cpu_hot" = "1" ] || [ "$gpu_hot" = "1" ] || [ "$shell_hot" = "1" ]; then
        any_hot=1
    fi

    # 复归判定：四路是否**全部**降到复归线以下（v1.4.8 死区，与熔断判定分开）
    local any_above_resume=0
    [ "$rt" -gt "$TRIP_RESUME_BATT" ] 2>/dev/null && any_above_resume=1
    [ "$ct" -gt "$TRIP_RESUME_CPU" ] 2>/dev/null && any_above_resume=1
    [ "$gt" -gt "$TRIP_RESUME_GPU" ] 2>/dev/null && any_above_resume=1
    [ "$st" -gt "$TRIP_RESUME_SHELL" ] 2>/dev/null && any_above_resume=1

    # 统一温度快照串，供日志/原因复用（避免各处重复拼装）
    local snap="电池=${rt}｜CPU=${ct}｜GPU=${gt}｜壳温=${st}"

    # ---- 已熔断：四路全部落回复归线以下 + 连续确认才复归 ----
    if [ "$OVERHEAT" = "1" ]; then
        if [ "$any_hot" = "0" ] && [ "$any_above_resume" = "0" ]; then
            TEMP_CONFIRM=$(( TEMP_CONFIRM + 1 ))
            if [ "$TEMP_CONFIRM" -ge "$RESUME_CONFIRM" ]; then
                OVERHEAT=0
                TEMP_CONFIRM=0
                return 1
            fi
            WARP_GUARD_REASON="复归确认中 ${TEMP_CONFIRM}/${RESUME_CONFIRM}（${snap}）"
        else
            TEMP_CONFIRM=0
            if [ "$any_hot" = "1" ]; then
                WARP_GUARD_REASON="熔断持续（${snap}）"
            else
                # 未越熔断线但仍在死区内（熔断线 > 温度 > 复归线）——状态保持熔断，不计数
                WARP_GUARD_REASON="死区内待冷却（需 ≤${TRIP_RESUME_CPU}｜${snap}）"
            fi
        fi
        return 0
    fi

    # ---- 未熔断：任一撞线即熔断（全局统一，不区分游戏） ----
    if [ "$any_hot" = "1" ]; then
        # 优先级：电池 > 壳温 > CPU > GPU（电池/壳温是器件与体感安全，优先作为归因）
        local src="" reason=""
        if [ "$batt_hot" = "1" ]; then
            src="battery"; reason="电池温度 ${rt} >= ${TRIP_BATT}"
        elif [ "$shell_hot" = "1" ]; then
            src="shell"; reason="壳温 ${st} >= ${TRIP_SHELL}"
        elif [ "$cpu_hot" = "1" ]; then
            src="cpu"; reason="CPU/SoC温度 ${ct} >= ${TRIP_CPU}"
        else
            src="gpu"; reason="GPU温度 ${gt} >= ${TRIP_GPU}"
        fi
        WARP_GUARD_REASON="${reason}（${snap}）"
        WARP_GUARD_SRC="$src"
        OVERHEAT=1
        TEMP_CONFIRM=0
        return 0
    fi
    return 1
}

# @author bomo v1.4.3: 本小时状态切换计数（暂停/恢复各记一次，供日志观察防抖效果）。
# 跨小时自动归零；小时串作为状态存 TOGGLE_HOUR，无需落盘。
count_toggle() {
    local h
    h=$(date '+%Y-%m-%d %H')
    if [ "$h" != "$TOGGLE_HOUR" ]; then
        TOGGLE_HOUR="$h"
        TOGGLE_COUNT=0
    fi
    TOGGLE_COUNT=$(( TOGGLE_COUNT + 1 ))
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
        # 单次安全检查（与主循环同条件）：充电中 + 温度未超标。
        # @author bomo v1.4.2: 原「非游戏」条件撤除（游戏不再是单独暂停条件）。
        if ! is_charging; then exit 0; fi
        if warp_temp_hot; then exit 0; fi
        apply_warp_charge
        exit 0
        ;;
    restore)
        restore_warp_charge
        exit 0
        ;;
esac

# ==================== 主逻辑 ====================

# 防重复启动（PID + cmdline 双验证，防 PID 复用误判）
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

# 等待系统就绪（有界等待：无超时会在系统异常时永久挂起）
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
# @author bomo v1.4.2: 补初始化——此前 WARP_ACTIVE 未赋值，导致心跳里
# "亮屏快充=" 打印为空，且「游戏退出后立即恢复」因条件 `= "0"` 不成立被静默跳过。
WARP_ACTIVE=0
# @author bomo v1.4.3: 滞回状态机与日志计数初始化
OVERHEAT=0            # 1 = 处于过热暂停（滞回死区内不恢复）
TEMP_CONFIRM=0        # 恢复线以下连续采样计数
WARP_GUARD_SRC=""     # @author bomo v1.4.5: 过热来源（cpu/gpu/battery/shell），决定是否交还 cool_down
                      # v1.4.7: 新增 gpu / shell 两种来源（四传感器熔断）
PAUSE_SINCE=0         # 本次过热暂停起始时间戳（秒），0=未暂停
TOGGLE_HOUR=""        # 切换计数所在小时
TOGGLE_COUNT=0        # 该小时内 暂停/恢复 切换次数
loop_count=0

# ==================== 守护循环 ====================
while true; do
    current_charging=0

    # ---- 游戏检测（循环顶层, 充电/放电均实时更新：埋进 is_charging
    #      分支会导致放电场景状态陈旧）----
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
            # 充电接入时立即检测游戏（游戏态仅入日志，不再作为暂停条件）
            update_game_active
            # 首次充电：温度正常即立即应用亮屏快充
            if ! warp_temp_hot; then
                apply_warp_charge
                _log "[亮屏快充] 已激活（充电接入｜游戏=${GAME_ACTIVE}）"
            fi
        fi

        # @author bomo v1.4.2: 暂停与否只看温度——原「游戏运行中一律暂停」已撤除，
        # 改为游戏与温度共同决定（游戏态只影响日志，温度线与非游戏一致）。
        real_temp=$(get_real_temp)
        cpu_temp=$(get_cpu_temp)

        if warp_temp_hot; then
            # 温度超限保护（四传感器任一撞线即熔断）
            if [ "$WARP_ACTIVE" = "1" ]; then
                # @author bomo v1.4.7: 熔断 = **完全交还系统**（保险丝语义，不做分级折中）。
                # 历史：v1.4.5 曾对 CPU 过热传 cpu_hot 保持 cool_down=0（治 15W 事故），
                # 但用户最终拍板"熔断即完全交还"，故统一为无参调用。
                restore_warp_charge
                PAUSE_SINCE=$(date +%s)
                count_toggle
                _log "⚠ 安全熔断：${WARP_GUARD_REASON}，亮屏快充已交给系统接管（来源=${WARP_GUARD_SRC}｜本小时第 ${TOGGLE_COUNT} 次切换｜游戏=${GAME_ACTIVE}）"
            fi
            # @author bomo v1.4.3: 状态串带确认计数——复归确认每次递增都会落一条日志，
            # 便于观察状态机是否生效（v1.4.2 的 _log_status 只在状态翻转时记）。
            # @author bomo v1.4.5: 追加熔断来源，避免多种来源共用同一状态串而漏记。
            _log_status "fuse_${WARP_GUARD_SRC}_c${TEMP_CONFIRM}" "亮屏快充已熔断（${WARP_GUARD_REASON}｜游戏=${GAME_ACTIVE}）"
        else
            # @author bomo v1.4.3: 熔断后的复归——确认通过即立即恢复并记录
            # 熔断时长（原逻辑要等 WARP_REAPPLY_CYCLE 周期重应用，最长 64s）。
            if [ "$WARP_ACTIVE" = "0" ] && [ "$PREV_CHARGING" = "1" ]; then
                now=$(date +%s)
                pause_dur=0
                [ "$PAUSE_SINCE" -gt 0 ] 2>/dev/null && pause_dur=$(( now - PAUSE_SINCE ))
                apply_warp_charge
                count_toggle
                _log "✔ 温度已回落至复归线以下（电池=${real_temp}｜CPU=${cpu_temp}｜熔断持续 ${pause_dur}s｜复归线 CPU≤${TRIP_RESUME_CPU}），亮屏快充已恢复（本小时第 ${TOGGLE_COUNT} 次切换）"
                PAUSE_SINCE=0
                WARP_GUARD_SRC=""
            fi
            # 正常：游戏中也保持亮屏快充（温度未到即不限）
            _log_status "warp_on" "亮屏快充运行中（游戏=${GAME_ACTIVE}｜电池=${real_temp}｜CPU=${cpu_temp}）"
            # 周期性重应用（防 horae testmode 被系统重置）
            if [ $(( loop_count % WARP_REAPPLY_CYCLE )) -eq 0 ]; then
                apply_warp_charge
            fi
            # cool_down 每轮对抗（系统亮屏策略刷新会重写 5）
            apply_cool_down_override
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
