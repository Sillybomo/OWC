package com.bomo.owc;

import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;

/**
 * OWC 亮屏快充 — 控制中心快捷开关
 *
 * 职责：纯粹的遥控器。点击 tile 时经 su 翻写状态文件
 *   /data/adb/owc/enabled（1=开 0=关），
 * 由 OWC Magisk 模块的 warp_charge.sh 守护读取并热切换（≤8s 生效）。
 * WARP 执行与全部安全栏（游戏暂停/电池46°C/CPU85°C/断充恢复）都在
 * 模块守护侧，App 不复制任何业务逻辑（防复制漂移，OPP v1.3.15/v1.3.24
 * 两次单位 bug 即复制漂移产物）。
 *
 * @author bomo
 */
public class OwcTileService extends TileService {

    private static final String STATE_DIR = "/data/adb/owc";
    private static final String STATE_FILE = "/data/adb/owc/enabled";
    private static final String MODULE_DIR = "/data/adb/modules/OWC";
    /** 守护脚本 tmp 运行副本（守护启动时由 service.sh 拷贝，与源同步） */
    private static final String DAEMON_SH = "/data/adb/modules/OWC/tmp/warp_charge.sh";

    /**
     * 事件驱动热切换（@author bomo v1.2）：写状态文件 + 直接推动作给守护，
     * 秒级生效，不等守护轮询。动作脚本不存在（守护未启动）时退化为仅写
     * 状态文件，由守护下一轮巡检兜底。
     */
    private void setEnabled(boolean on) {
        String v = on ? "1" : "0";
        String action = on ? "apply" : "restore";
        su("echo " + v + " > " + STATE_FILE + " && [ -f " + DAEMON_SH + " ]"
                + " && sh " + DAEMON_SH + " " + action);
    }

    /** 经 su 执行命令，返回退出码（KernelSU 首次会弹授权，授权后免弹窗） */
    private int su(String cmd) {
        try {
            Process p = Runtime.getRuntime().exec(new String[]{"su", "-c", cmd});
            p.waitFor();
            return p.exitValue();
        } catch (Exception e) {
            return -1;
        }
    }

    /** 经 su 执行命令并取 stdout（限 200 字节，仅读小文件用） */
    private String suOut(String cmd) {
        try {
            Process p = Runtime.getRuntime().exec(new String[]{"su", "-c", cmd});
            byte[] buf = new byte[200];
            int n = p.getInputStream().read(buf);
            p.waitFor();
            return n > 0 ? new String(buf, 0, n).trim() : "";
        } catch (Exception e) {
            return "";
        }
    }

    /** 模块是否安装（不存在则 tile 置灰不可用） */
    private boolean modulePresent() {
        return suOut("[ -d " + MODULE_DIR + " ] && echo yes").contains("yes");
    }

    /** 读取用户开关（文件缺失视为开，与守护 is_user_enabled 兜底语义一致） */
    private boolean readEnabled() {
        String v = suOut("cat " + STATE_FILE);
        return !"0".equals(v);
    }

    /** 按当前状态刷新 tile（模块未装=不可用；开=ACTIVE；关=INACTIVE） */
    private void updateTile() {
        Tile t = getQsTile();
        if (t == null) return;
        if (!modulePresent()) {
            t.setState(Tile.STATE_UNAVAILABLE);
            t.setSubtitle("模块未安装");
        } else if (readEnabled()) {
            t.setState(Tile.STATE_ACTIVE);
            t.setSubtitle("已开启");
        } else {
            t.setState(Tile.STATE_INACTIVE);
            t.setSubtitle("已关闭");
        }
        t.updateTile();
    }

    @Override
    public void onStartListening() {
        updateTile();
    }

    @Override
    public void onClick() {
        // @author bomo: 先按写入值刷新 tile（不等 su 回读，消除 UI 跳变），
        // 再执行热切换动作。
        boolean next = !readEnabled();
        setEnabled(next);
        Tile t = getQsTile();
        if (t != null) {
            t.setState(next ? Tile.STATE_ACTIVE : Tile.STATE_INACTIVE);
            t.setSubtitle(next ? "已开启" : "已关闭");
            t.updateTile();
        }
    }
}
