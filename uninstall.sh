#!/system/bin/sh
# @author bomo
# OWC 卸载脚本 — 恢复系统状态 + 清除模块产生的所有文件
# 职责：
#   1. 杀守护（完整路径匹配，防误杀其他模块同名脚本）
#   2. 恢复 ORMS 服务与属性 + horae 正常模式（读启动时备份兜底）
#   3. 清除模块外产物：/data/adb/owc/（状态文件）
# 注：
#   - /proc/shell-temp 写过的伪装值无需手动清除——horae testmode false
#     后数据源切回真实传感器（与 OPP battery_spoof cleanup 行为一致）。
#   - 模块目录本身（含 tmp/ 日志）由管理器随 uninstall.sh 执行后整体删除。

MODDIR=${0%/*}
TMPDIR="$MODDIR/tmp"
STATE_DIR=/data/adb/owc

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

# 3. 清除模块外产物（@author bomo 模块规范：外部文件不留残留）
rm -rf "$STATE_DIR" 2>/dev/null
_log "已清除状态目录: $STATE_DIR"

_log "恢复完成"
exit 0
