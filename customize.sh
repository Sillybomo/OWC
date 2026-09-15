#!/system/bin/sh
# @author bomo
# OWC 安装兼容性检查 + 伴随 App 自动安装
# 1. 机型检查：非一加 15T (PLZ110) 时改用音量键显式确认是否继续
# 2. 充电类模块冲突检测：命中列出模块名并终止安装
# 3. 自动安装磁贴 App（zip 内 app/OWC-App.apk），失败给出手动兜底提示
#
# v1.4.0 (@author bomo) 两处修复：
#   ① 机型不符不再"提示 + sleep 5 静默继续"：改为音量键选择，
#      VOL+ 继续 / VOL- 取消 / 超时(10s) 默认取消（安全默认，宁可重刷）。
#   ② 冲突扫描由 `grep -r` 递归整目录改为有界 glob（仅模块目录 1~2 层的
#      *.sh）。原实现会顺着模块目录内的符号链接 / 运行期 bind-mount 递归
#      进巨型目录，扫描规模不可预期 —— 这正是"机型提示后卡住"的根因。
#      同时去掉对 basename 的依赖，扫描成本恒定。

SKIPUNZIP=0

ui_print " "
ui_print "  ***********************************"
ui_print  "          OWC 亮屏快充 v1.4.0"
ui_print  "        @author bomo · 仅供自用"
ui_print "  ***********************************"

# @author bomo
# 等待音量键选择。逐次阻塞读 1 个输入事件（/dev/input），超时兜底防死等。
# $1: 总超时秒数
# 返回: 0=音量上  1=音量下  2=超时或环境不支持读取
wait_vol_key() {
    local deadline="$1" t=0 ev
    while [ "$t" -lt "$deadline" ]; do
        # timeout 1 兜底：无按键时 getevent 会一直阻塞，绝不能裸调用
        ev=$(timeout 1 getevent -qlc 1 2>/dev/null)
        case "$ev" in
            *KEY_VOLUMEUP*)   return 0 ;;
            *KEY_VOLUMEDOWN*) return 1 ;;
        esac
        t=$((t + 1))
    done
    return 2
}

# ---------- 1. 机型检查（不符则音量键确认） ----------
DEV=$(getprop ro.product.device)
MODEL=$(getprop ro.product.model)
ui_print "- 设备: $MODEL ($DEV)"

# @author bomo v1.4.0: 机型识别改用 device+model+name+board 联合匹配（统一大写比较）。
# 本机 ro.product.device=OP64DDL1（PLZ110 是 ro.product.model, board=canoe），
# 此前只匹配 device 会把正版机型误判为"未验证"，安装时卡在按键确认超时。
DEVID=$(echo "$DEV $MODEL $(getprop ro.product.name) $(getprop ro.product.board)" | tr 'a-z' 'A-Z')
case "$DEVID" in
    *PLZ110*|*OP64DDL1*|*CANOE*)
        ui_print "- 已验证机型: 一加 15T (PLZ110) ✓"
        ;;
    *)
        # @author bomo: 机型白名单不做硬拦截——未验证机型由用户显式确认后继续，
        # 无效可到项目帖/issue 留言, 作者随缘更新。
        ui_print " "
        ui_print "⚠ 当前设备 ($DEV) 未经验证, 本模块仅在一加 15T (PLZ110) 测试过"
        ui_print "⚠ 原理依赖 oplus_chg/horae/cool_down 私有节点, 其他机型可能无效"
        ui_print "⚠ 无效可在项目帖留言反馈, 作者随缘更新"
        ui_print " "
        ui_print "  ┌─────────────────────────────────┐"
        ui_print "  │  [音量上] = 继续安装            │"
        ui_print "  │  [音量下] = 取消安装            │"
        ui_print "  │  10 秒无操作 = 自动取消         │"
        ui_print "  └─────────────────────────────────┘"
        ui_print "  等待按键..."
        wait_vol_key 10
        case $? in
            0) ui_print "- 已确认继续安装 (未验证机型, 风险自负)" ;;
            1) abort "已取消安装 (机型未验证)" ;;
            *) abort "按键超时, 已取消安装 (机型未验证; 如确需安装请重刷并选音量上)" ;;
        esac
        ;;
esac

# ---------- 2. 充电类模块冲突检测（命中即终止） ----------
CONFLICT=""
# @author bomo v1.4.0: 名单只列广扫描正则覆盖不到的同类模块；
# 直接写 cool_down / shell-temp / horae 等充电节点的模块由下面的广扫描兜住。
for m in AaTempSpoof; do
    [ -d "/data/adb/modules/$m" ] && CONFLICT="$CONFLICT $m"
done
# 广扫描: 已启用模块中脚本含充电节点写操作的
# @author bomo v1.4.0: 有界 glob 取代 grep -r —— 不递归、不跟随符号链接,
# 深度上限 2 层(模块根 + vtools/ 等子目录), 与原实现覆盖范围一致。
for f in /data/adb/modules/*/*.sh /data/adb/modules/*/*/*.sh; do
    [ -f "$f" ] || continue
    m=${f#/data/adb/modules/}
    m=${m%%/*}
    case "$m" in OWC|zygisksu|zygisk*|lsposed|riru|mountify|busybox*) continue ;; esac
    case " $CONFLICT " in *" $m "*) continue ;; esac
    if grep -lE "cool_down|oplus_chg.*temp|shell-temp|horae testmode|mmi_charging_enable" \
        "$f" >/dev/null 2>&1; then
        CONFLICT="$CONFLICT $m"
    fi
done

if [ -n "$CONFLICT" ]; then
    ui_print " "
    ui_print "! 检测到充电类模块冲突:$CONFLICT"
    ui_print "! OWC 直接写 cool_down/emul_temp/shell-temp 节点,"
    ui_print "! 与其他充电模块共存会互相覆盖(充电行为不可预期)"
    ui_print "! 请先禁用或卸载上述模块后再安装"
    abort "安装已终止"
fi

ui_print "- 机型与模块冲突检查通过"

# ---------- 3. 自动安装磁贴 App ----------
# @author bomo v1.3.2: APK 随模块分发, 刷入时自动安装(借鉴 LSPosed/Thanox 做法)。
# pm install 失败不终止模块安装, 给出手动兜底路径。
APK="$MODPATH/app/OWC-App.apk"
if [ -f "$APK" ]; then
    ui_print " "
    ui_print "- 正在安装控制中心磁贴 App..."
    if pm install -r "$APK" >/dev/null 2>&1; then
        ui_print "- 磁贴 App 已安装 ✓"
    else
        # 兜底: 复制到用户可访问位置再试一次
        cp -f "$APK" /data/local/tmp/OWC-App.apk 2>/dev/null
        chmod 644 /data/local/tmp/OWC-App.apk 2>/dev/null
        if pm install -r /data/local/tmp/OWC-App.apk >/dev/null 2>&1; then
            ui_print "- 磁贴 App 已安装 ✓"
            rm -f /data/local/tmp/OWC-App.apk
        else
            ui_print "! App 自动安装失败(不影响模块本体)"
            ui_print "! 请手动安装模块目录内 app/OWC-App.apk"
        fi
    fi
else
    ui_print "! 未找到内置 App(不影响模块本体), 可从 Release 手动下载"
fi

ui_print " "
ui_print "📌 安装后还需两步:"
ui_print "   1. 在管理器中给 OWC App 授予 root 权限"
ui_print "   2. 控制中心 → 编辑 → 添加「亮屏快充」磁贴"
ui_print " "
ui_print "- 重启后生效, 日志: 模块目录 tmp/warp_charge.log"
ui_print " "
