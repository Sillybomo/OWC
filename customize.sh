#!/system/bin/sh
# @author bomo
# OWC 安装兼容性检查 + 伴随 App 自动安装
# 1. 机型提示（仅提示不拦截）：仅一加 15T (PLZ110) 验证过
# 2. 充电类模块冲突检测：命中列出模块名并终止安装
# 3. 自动安装磁贴 App（zip 内 app/OWC-App.apk），失败给出手动兜底提示

SKIPUNZIP=0

ui_print " "
ui_print "  ***********************************"
ui_print  "          OWC 亮屏快充 v1.3.2"
ui_print  "        @author bomo · 仅供自用"
ui_print "  ***********************************"

# ---------- 1. 机型提示（不拦截） ----------
DEV=$(getprop ro.product.device)
MODEL=$(getprop ro.product.model)
ui_print "- 设备: $MODEL ($DEV)"

case "$DEV" in
    plz110|PLZ110)
        ui_print "- 已验证机型: 一加 15T (PLZ110) ✓"
        ;;
    *)
        # @author bomo: 机型白名单仅做提示不拦截——未验证机型自行承担,
        # 无效可到项目帖子/issue 留言, 作者随缘更新。
        ui_print " "
        ui_print "⚠ 当前设备 ($DEV) 未经验证, 本模块仅在一加 15T (PLZ110) 测试过"
        ui_print "⚠ 原理依赖 oplus_chg/horae/cool_down 私有节点, 其他机型可能无效"
        ui_print "⚠ 无效可在项目帖留言反馈, 作者随缘更新; 继续安装..."
        sleep 5
        ;;
esac

# ---------- 2. 充电类模块冲突检测（命中即终止） ----------
CONFLICT=""
for m in OPP AaTempSpoof OPP_v1.3.7 charging_spoof; do
    [ -d "/data/adb/modules/$m" ] && CONFLICT="$CONFLICT $m"
done
# 更广扫描: 已启用模块中脚本含充电节点写操作的
for d in /data/adb/modules/*/; do
    m=$(basename "$d")
    case "$m" in OWC|zygisksu|zygisk*|lsposed|riru|mountify|busybox*) continue ;; esac
    if grep -rlsE "cool_down|oplus_chg.*temp|shell-temp|horae testmode|mmi_charging_enable" \
        "$d" 2>/dev/null | grep -qE "\.sh$"; then
        case " $CONFLICT " in *" $m "*) ;; *) CONFLICT="$CONFLICT $m";; esac
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
