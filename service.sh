#!/system/bin/sh
# @author bomo
# OWC 亮屏快充模块 service.sh — 拉起 warp_charge 守护 + watchdog
# 模式与 OPP init_vtools 一致：脚本拷入 tmp/ 后运行（守护的 MODDIR 指向 tmp），
# lib_common.sh / game_blacklist.txt 随行拷贝（守护 source 依赖）。

# 等待开机完成（有界等待 300s，借鉴 OPP v1.3.28：无超时会在系统异常时永久挂起）
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

# 公共函数库（kill_verified 等）
if [ -f "$BASEDIR/lib_common.sh" ]; then
    cp -af "$BASEDIR/lib_common.sh" "$TMPDIR/lib_common.sh"
    . "$BASEDIR/lib_common.sh"
fi

# @author bomo: 启动守护统一入口（cmdline 验证查杀 + lib 随行拷贝，
# 与 OPP v1.3.28 launch_daemon 同源）
launch_daemon() {
    local name="$1" script="$2"
    kill_verified "$script" TERM
    sleep 1
    [ -f "$BASEDIR/lib_common.sh" ] && cp -af "$BASEDIR/lib_common.sh" "$TMPDIR/lib_common.sh"
    cp -af "$BASEDIR/$script" "$TMPDIR/$script"
    chmod 755 "$TMPDIR/$script"
    nohup sh "$TMPDIR/$script" > /dev/null 2>&1 &
    _log "已启动 $name (script=$script)"
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
