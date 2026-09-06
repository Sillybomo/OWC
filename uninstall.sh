#!/system/bin/sh
# @author bomo
# OWC 卸载脚本 — 恢复系统状态 + 清除模块产生的所有文件
# 职责：
#   1. 杀守护（完整路径匹配，防误杀其他模块同名脚本）
#   2. 恢复 ORMS 服务与属性 + horae 正常模式（读启动时备份兜底）
#   3. cool_down 写 5 交还系统控制（防 SIGKILL 场景 trap 未执行时残留在 0）
#   4. 清扫电池类 emul_temp 残留（防御性，写 0 = 恢复真实温度）
#   5. 清除模块外产物：/data/adb/owc/（状态文件）
# 注：
#   - /proc/shell-temp 写过的伪装值无需手动清除——horae testmode false
#     后数据源切回真实传感器（与 OPP battery_spoof cleanup 行为一致）。
#   - 模块目录本身（含 tmp/ 日志）由管理器随 uninstall.sh 执行后整体删除。

MODDIR=${0%/*}
TMPDIR="$MODDIR/tmp"
STATE_DIR=/data/adb/owc
COOL_DOWN_NODE=/sys/class/oplus_chg/battery/cool_down

_log() {
    printf '[%s] [owc-uninstall] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "${TMPDIR:-/data/local/tmp}/owc_uninstall.log" 2>/dev/null
}

_log "开始恢复系统状态"

# 1. 停掉守护与 watchdog（cmdline 校验完整路径防误杀）
if [ -f "$MODDIR/vtools/lib_common.sh" ]; then
    . "$MODDIR/vtools/lib_common.sh"
    kill_verified "/data/adb/modules/OWC/tmp/warp_charge.sh" TERM 2>/dev/null
    kill_verified "/data/adb/modules/OWC/tmp/watchdog.sh" TERM 2>/dev/null
else
    for pid in $(pgrep -f "/data/adb/modules/OWC/tmp/warp_charge.sh" 2>/dev/null); do
        [ "$pid" != "$$" ] && kill -TERM "$pid" 2>/dev/null
    done
    for pid in $(pgrep -f "/data/adb/modules/OWC/tmp/watchdog.sh" 2>/dev/null); do
        [ "$pid" != "$$" ] && kill -TERM "$pid" 2>/dev/null
    done
fi
sleep 1

# 2. 恢复 ORMS + horae（读启动时备份；守护 trap cleanup 通常已恢复，此处兜底）
ORMS_SVC=""
ORMS_NAME=""
[ -f "$TMPDIR/orms_svc_backup" ] && ORMS_SVC=$(cat "$TMPDIR/orms_svc_backup" 2>/dev/null)
[ -f "$TMPDIR/orms_name_backup" ] && ORMS_NAME=$(cat "$TMPDIR/orms_name_backup" 2>/dev/null)

dumpsys horae testmode false 2>/dev/null
if [ -n "$ORMS_SVC" ]; then
    start "$ORMS_SVC" 2>/dev/null
    _log "已恢复 ORMS 服务: $ORMS_SVC"
fi
if [ -n "$ORMS_NAME" ]; then
    setprop persist.sys.orms.name "$ORMS_NAME"
    _log "已恢复 orms.name 属性"
fi

# 3. cool_down 交还系统控制（@author bomo v1.3.3: 守护被 SIGKILL 时 trap
#    cleanup 不会执行，cool_down 可能残留在 0——此处主动写 5 恢复系统默认
#    亮屏策略，与守护 restore_cool_down 语义一致）
if [ -f "$COOL_DOWN_NODE" ]; then
    echo 5 > "$COOL_DOWN_NODE" 2>/dev/null
    _log "cool_down 已写 5 (交还系统控制)"
fi

# 4. 清扫电池类 emul_temp 残留（防御性: 当前版本守护不写 emul, 但保留
#    清扫以防历史版本/手动实验残留致盲内核温控——借鉴 OPP sweep_emul_residue）
for z in /sys/class/thermal/thermal_zone*; do
    [ -f "$z/emul_temp" ] || continue
    t=$(cat "$z/type" 2>/dev/null)
    case "$t" in
        *batt*|*BATT*|*battery*|*Battery*|*chg*|*CHG*) echo 0 > "$z/emul_temp" 2>/dev/null ;;
    esac
done
_log "电池类 emul_temp 已清扫"

# 5. 清除模块外产物（@author bomo 模块规范：外部文件不留残留）
rm -rf "$STATE_DIR" 2>/dev/null
_log "已清除状态目录: $STATE_DIR"

_log "恢复完成"
exit 0
