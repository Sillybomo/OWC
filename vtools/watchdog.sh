#!/system/bin/sh
# @author bomo
# OWC watchdog — 防止 warp_charge 守护被系统杀掉后无人拉起
# （SIGKILL/内存回收等场景）。机制：
# 每 120s 检查存活，死亡自动拉起，连续 5 次失败冷却 300s。
# OWC 只有一个业务守护，per-script 计数退化为单计数。
#
# @author bomo v1.4.10（2026-09-16）：**运行位置统一到 vtools/**。
#   watchdog 自身跑在 vtools/，被拉起的 warp_charge.sh 也在 vtools/ 原地运行，
#   不再往 tmp/ 拷贝副本（消除"双份相同脚本、无法判断哪个在跑"的歧义）。
#   lib_common.sh 由 warp_charge.sh 以其 $MODDIR 引入（MODDIR=vtools），故此处
#   也无需再往 tmp/ 拷 lib。
#   TMPDIR 仍指向 tmp/ —— 那是**运行时产物**（日志/锁/过滤名单）的唯一住处。

BASEDIR="$(dirname $(readlink -f "$0"))"
MODDIR="$(dirname "$BASEDIR")"
TMPDIR="$MODDIR/tmp"

_log() {
    printf '[%s] [owc-watchdog] %s\n' "$(date '+%m-%d %H:%M:%S')" "$1" >> "$TMPDIR/watchdog.log" 2>/dev/null
}

FAIL_FILE="$TMPDIR/watchdog_fail_warp_charge"

# 冷却判定（连续失败 >= 5 进入 300s 冷却，mtime 为失败时间锚）
cooldown_active() {
    [ -f "$FAIL_FILE" ] || return 1
    local fail
    fail=$(cat "$FAIL_FILE" 2>/dev/null)
    [ "$fail" -ge 5 ] 2>/dev/null
}

cooldown_expired() {
    [ -f "$FAIL_FILE" ] || return 0
    local mtime now age
    mtime=$(stat -c %Y "$FAIL_FILE" 2>/dev/null)
    [ -n "$mtime" ] || { rm -f "$FAIL_FILE"; return 0; }
    now=$(date +%s)
    age=$(( now - mtime ))
    if [ "$age" -ge 300 ]; then
        _log "冷却结束 (${age}s), 重新纳入检查"
        rm -f "$FAIL_FILE"
        return 0
    fi
    return 1
}

# 日志轮转（256KB 裁 64KB）
if [ -f "$TMPDIR/watchdog.log" ] && [ "$(wc -c < "$TMPDIR/watchdog.log")" -gt 262144 ]; then
    tail -c 65536 "$TMPDIR/watchdog.log" > "${TMPDIR}/watchdog.log.tmp" 2>/dev/null
    mv "${TMPDIR}/watchdog.log.tmp" "$TMPDIR/watchdog.log" 2>/dev/null
fi

while true; do
    sleep 120

    if cooldown_active; then
        cooldown_expired || true
    elif ! pgrep -f "warp_charge.sh" > /dev/null 2>&1; then
        _log "⚠ warp_charge 不在运行, 尝试拉起"
        # @author bomo v1.4.10: 原地拉起（vtools/），不再拷贝到 tmp/
        chmod 755 "$BASEDIR/warp_charge.sh" 2>/dev/null
        rm -f "$TMPDIR/warp_charge.sh" "$TMPDIR/lib_common.sh" 2>/dev/null
        nohup sh "$BASEDIR/warp_charge.sh" > /dev/null 2>&1 &
        sleep 3
        if pgrep -f "warp_charge.sh" > /dev/null 2>&1; then
            _log "✓ warp_charge 已恢复 (PID=$(pgrep -f warp_charge.sh | head -1))"
            rm -f "$FAIL_FILE"
        else
            local_fail=0
            [ -f "$FAIL_FILE" ] && local_fail=$(cat "$FAIL_FILE" 2>/dev/null)
            case "$local_fail" in ''|*[!0-9]*) local_fail=0 ;; esac
            local_fail=$(( local_fail + 1 ))
            echo "$local_fail" > "$FAIL_FILE" 2>/dev/null
            _log "✗ warp_charge 拉起失败 ($local_fail/5)"
        fi
    else
        rm -f "$FAIL_FILE"
    fi
done
