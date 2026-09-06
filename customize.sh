#!/system/bin/sh
# @author bomo
# OWC 安装兼容性检查
# 1. 机型白名单：仅一加 15T (PLZ110)，其他设备直接拒绝安装
# 2. 充电类模块冲突检测：OWC 直接改写充电内核节点(cool_down/emul_temp)，
#    与其他充电伪装/调度模块共存会互相覆盖甚至打架，检测到即拒绝。

SKIPUNZIP=0

ui_print " "
ui_print "  ***********************************"
ui_print  "          OWC 亮屏快充 v1.3.1"
ui_print  "        @author bomo · 仅供自用"
ui_print "  ***********************************"

# ---------- 1. 机型白名单 ----------
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

# ---------- 2. 充电类模块冲突 ----------
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
ui_print " "
