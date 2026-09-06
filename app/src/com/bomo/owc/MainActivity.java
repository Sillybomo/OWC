package com.bomo.owc;

import android.app.Activity;
import android.graphics.Color;
import android.graphics.Typeface;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * OWC 亮屏快充 — 状态页（可选入口）
 * 显示当前开关状态 + 一键切换（与 tile 同一状态文件）+ 简要说明。
 * 编程式 UI，无 layout xml（保持构建链最简）。
 *
 * @author bomo
 */
public class MainActivity extends Activity {

    private TextView statusView;
    private Button toggleBtn;

    private int su(String cmd) {
        try {
            Process p = Runtime.getRuntime().exec(new String[]{"su", "-c", cmd});
            p.waitFor();
            return p.exitValue();
        } catch (Exception e) {
            return -1;
        }
    }

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

    private boolean readEnabled() {
        return !"0".equals(suOut("cat /data/adb/owc/enabled"));
    }

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER);
        root.setPadding(48, 48, 48, 48);

        TextView title = new TextView(this);
        title.setText("OWC 亮屏快充");
        title.setTextSize(26);
        title.setTypeface(null, Typeface.BOLD);
        title.setGravity(Gravity.CENTER);
        root.addView(title);

        statusView = new TextView(this);
        statusView.setTextSize(18);
        statusView.setGravity(Gravity.CENTER);
        statusView.setPadding(0, 32, 0, 32);
        root.addView(statusView);

        toggleBtn = new Button(this);
        toggleBtn.setText("切换");
        toggleBtn.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                // @author bomo v1.2: 事件驱动——写状态文件后直接推动作给守护
                // （秒级生效），UI 按写入值即时刷新，不等守护轮询也不回读。
                boolean next = !readEnabled();
                String val = next ? "1" : "0";
                String action = next ? "apply" : "restore";
                su("echo " + val + " > /data/adb/owc/enabled"
                        + " && [ -f /data/adb/modules/OWC/tmp/warp_charge.sh ]"
                        + " && sh /data/adb/modules/OWC/tmp/warp_charge.sh " + action);
                statusView.setText(next ? "亮屏快充：已开启" : "亮屏快充：已关闭");
                statusView.setTextColor(next ? Color.rgb(0, 128, 0) : Color.GRAY);
            }
        });
        root.addView(toggleBtn, new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        TextView hint = new TextView(this);
        hint.setText("\n说明：\n· 开关经控制中心磁贴或本页热切换，≤8 秒生效\n· 模块守护负责执行与安全栏（游戏/过热自动暂停）\n· 需在 KernelSU 中授予本机 Root 授权");
        hint.setTextSize(13);
        hint.setTextColor(Color.GRAY);
        root.addView(hint);

        setContentView(root);
    }

    @Override
    protected void onResume() {
        super.onResume();
        refresh();
    }

    private void refresh() {
        boolean installed = suOut("[ -d /data/adb/modules/OWC ] && echo yes").contains("yes");
        if (!installed) {
            statusView.setText("模块状态：未安装");
            statusView.setTextColor(Color.RED);
            toggleBtn.setEnabled(false);
            return;
        }
        boolean on = readEnabled();
        statusView.setText(on ? "亮屏快充：已开启" : "亮屏快充：已关闭");
        statusView.setTextColor(on ? Color.rgb(0, 128, 0) : Color.GRAY);
        toggleBtn.setEnabled(true);
    }
}
