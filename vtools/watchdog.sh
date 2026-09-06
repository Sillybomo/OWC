#!/system/bin/sh
# @author bomo
# OWC watchdog — 防止 warp_charge 守护被系统杀掉后无人拉起
# （SIGKILL/内存回收等场景）。机制与 OPP watchdog.sh 同源：
# 每 120s 检查存活，死亡自动拉起，连续 5 次失败冷却 300s。
# OWC 只有一个业务守护，per-script 计数退化为单计数。

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

# 日志轮转（256KB 裁 64KB，与 OPP watchdog 一致）
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
        [ -f "$BASEDIR/lib_common.sh" ] && cp -af "$BASEDIR/lib_common.sh" "$TMPDIR/lib_common.sh"
        cp -af "$BASEDIR/warp_charge.sh" "$TMPDIR/warp_charge.sh" 2>/dev/null
        cp -af "$BASEDIR/game_blacklist.txt" "$TMPDIR/game_blacklist.txt" 2>/dev/null
        chmod 755 "$TMPDIR/warp_charge.sh" 2>/dev/null
        nohup sh "$TMPDIR/warp_charge.sh" > /dev/null 2>&1 &
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
