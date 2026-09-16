#!/system/bin/sh
# @author bomo
# OWC 亮屏快充模块 service.sh — 拉起 warp_charge 守护 + watchdog
# @author bomo v1.4.10（2026-09-16）：**运行位置统一到 vtools/**，tmp/ 只放运行时产物。
#   背景：原设计把脚本拷入 tmp/ 再运行，导致 tmp/ 与 vtools/ 各存一份**内容相同**的
#   warp_charge.sh。实测核查时无法一眼判断"哪个才是真正在跑的"，且曾因"改了一份、
#   跑的是另一份"造成版本号滞后（module.prop 显示 v1.4.8 而脚本已是 v1.4.9）。
#   warp_charge.sh 内的路径逻辑本就兼容两种位置：
#     MODDIR="$(dirname $(readlink -f "$0"))" → 在 vtools/ 下即 vtools
#     TMP_DIR="$MODDIR/../tmp"                → 仍正确指向 tmp/
#   故本次**只改启动方**，脚本零改动（最小侵入）。
#   lib_common.sh 用 `. "$MODDIR/lib_common.sh"` 引入 —— MODDIR=vtools 时同目录命中，
#   亦无需再往 tmp/ 拷贝。

# 等待开机完成（有界等待 300s：无超时会在系统异常时永久挂起）
BOOT_WAIT_MAX=60   # 60 次 × 5s = 300s
BOOT_WAIT_N=0
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    BOOT_WAIT_N=$(( BOOT_WAIT_N + 1 ))
    if [ "$BOOT_WAIT_N" -ge "$BOOT_WAIT_MAX" ]; then
        break
    fi
    sleep 5
done

MODDIR=${0%/*}
BASEDIR="$MODDIR/vtools"
TMPDIR="$MODDIR/tmp"
mkdir -p "$TMPDIR"
chmod 755 "$TMPDIR" 2>/dev/null

_log() {
    printf '[%s] [owc-service] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$TMPDIR/owc_service.log" 2>/dev/null
    # @author bomo: 有界日志（500 裁 200，保留跨启动历史尾部）
    local line_count
    line_count=$(wc -l < "$TMPDIR/owc_service.log" 2>/dev/null | tr -d ' ')
    if [ "${line_count:-0}" -gt 500 ] 2>/dev/null; then
        tail -n 200 "$TMPDIR/owc_service.log" > "${TMPDIR}/owc_service.log.tmp" 2>/dev/null
        mv "${TMPDIR}/owc_service.log.tmp" "$TMPDIR/owc_service.log" 2>/dev/null
    fi
}

# @author bomo v1.4.10: 公共函数库（kill_verified 等）——
#   改为**直接从 vtools/ 引入**（不再拷到 tmp/ 再引入），与"脚本原地运行"保持一致。
if [ -f "$BASEDIR/lib_common.sh" ]; then
    . "$BASEDIR/lib_common.sh"
fi

# @author bomo v1.4.10: 启动守护统一入口——**直接在 vtools/ 原地运行**，
#   不再拷贝到 tmp/（消除双份副本与版本歧义）。
#   lib_common.sh 由脚本自身以 $MODDIR/lib_common.sh 引入，同级即可命中。
launch_daemon() {
    local name="$1" script="$2"
    kill_verified "$script" TERM
    sleep 1
    chmod 755 "$BASEDIR/$script" 2>/dev/null
    # 清理历史遗留的 tmp/ 脚本副本（v1.4.9 及更早版本会拷进去）
    rm -f "$TMPDIR/$script" "$TMPDIR/lib_common.sh" 2>/dev/null
    nohup sh "$BASEDIR/$script" > /dev/null 2>&1 &
    _log "已启动 $name (script=$BASEDIR/$script)"
}

# 用户热开关状态目录（控制中心 tile / OWC App 通过 su 写入 0/1）
# @author bomo v1.1: 默认开启；文件缺失时守护同样视为开启（is_user_enabled 兜底），
# 此处初始化只为让 App 首次读取有确定值。
OWC_STATE_DIR=/data/adb/owc
mkdir -p "$OWC_STATE_DIR" 2>/dev/null
if [ ! -f "$OWC_STATE_DIR/enabled" ]; then
    echo 1 > "$OWC_STATE_DIR/enabled" 2>/dev/null
fi

# 主守护：亮屏快充
if [ -f "$BASEDIR/warp_charge.sh" ]; then
    cp -af "$BASEDIR/game_blacklist.txt" "$TMPDIR/game_blacklist.txt" 2>/dev/null
    launch_daemon "warp_charge" "warp_charge.sh"
fi

# watchdog 保活（防 SIGKILL/内存回收后无人拉起）
if [ -f "$BASEDIR/watchdog.sh" ]; then
    launch_daemon "owc-watchdog" "watchdog.sh"
fi
