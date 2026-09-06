# OWC — ColorOS 亮屏快充模块

> ⚡ 解锁 ColorOS 亮屏充电限速，控制中心一键热切换，边玩边满功率快充
>
> @author bomo · Inspired by AaTempSpoof & OPP 官方全局扩展

[![Version](https://img.shields.io/badge/version-v1.3.0-blue)]()
[![Platform](https://img.shields.io/badge/platform-ColorOS%2016%20%2F%20Android%2016-green)]()
[![Root](https://img.shields.io/badge/root-Magisk%20%7C%20KernelSU-orange)]()

---

## 这是什么

一加 / OPPO / realme（ColorOS / OxygenOS）的"亮屏降速充电"是系统的**有意行为**：亮屏时充电内核写入降流档，功率直接砍半以上（实测一加 15T：熄屏 78W → 亮屏 22W）。

OWC（OP WarpCharge）按通用模块设计，把这套限流完整解开，并提供**控制中心磁贴**随时热切换：

> ⚠️ **目前仅一加 15T 实测确认。其他机型请自测，适配随缘更新。**

| 场景 | 磁贴关闭 | 磁贴开启 |
| --- | --- | --- |
| 熄屏充电 | 78 W | 78 W |
| **亮屏充电** | **22~33 W** | **≈78 W（满功率）** |

**事件驱动**：点击磁贴 → App 经 `su` 直接触发模块动作，秒级生效，无轮询等待。

## 工作原理

亮屏慢充由三层限流叠加，OWC 全部拆解（缺一则功率打折）：

| 层 | 系统行为 | OWC 对策 |
| --- | --- | --- |
| 壳温 | `horae` 读取壳温限制充电功率 | `dumpsys horae testmode` 切换数据源 + `/proc/shell-temp` 伪装 34°C |
| 电池温度 | 充电算法读取电池 `thermal_zone`（实测 43°C 时降流 16%） | 电池类 zone `emul_temp` 伪装 30°C |
| **亮屏降流** | **亮屏时写 `oplus_chg/battery/cool_down=5`（降流档）** | 归零 + 守护每轮对抗系统重写 |

> `cool_down` 为本项目实测发现：ColorOS 16 上亮屏时系统写入 5（降流档），
> 写 0 后 1 秒内恢复满功率。常见"亮屏快充"实现（停 ORMS 等）在此平台已过时——
> 实测 `vendor.oplus.ormsHalService` 服务不存在，停了也没有效果。

## 架构

```
┌─ 控制中心磁贴 / App（Java，零依赖）──────────────────┐
│  onClick → su -c "写状态文件 + 调用守护 CLI 动作"      │
└──────────────────┬────────────────────────────────┘
                   │ /data/adb/owc/enabled (0/1)
┌──────────────────▼────────────────────────────────┐
│  Magisk/KernelSU 模块守护 warp_charge.sh            │
│  · apply/restore CLI 单次动作（事件驱动，秒级生效）  │
│  · 每轮巡检：cool_down 对抗 + horae 重应用（4s）     │
│  · 安全栏（见下）                                    │
└────────────────────────────────────────────────────┘
```

App 只是遥控器，全部业务逻辑在 shell 守护中（单一实现，防复制漂移）。

## 安全栏（不可关闭，随守护常驻）

实测充电热失控风险真实存在，以下保护**优先级高于一切开关**：

- 🎮 **游戏运行中自动暂停**（壳温伪装会致盲系统温控，游戏中继续 = SoC 热失控）
- 🔋 电池真实温度 ≥ **46°C** 自动暂停
- 🖥️ CPU/SoC ≥ **85°C** 自动暂停（防 PMIC 95°C 硬复位，留 10°C 余量）
- 🔌 充电断开 / 守护退出 → 完整恢复系统状态（ORMS + horae + cool_down）
- ⏱️ 开机有界等待 + PID/cmdline 双验证锁 + watchdog 保活

> ⚠️ 注意：满功率亮屏充电发热明显是物理现实。安全栏只是兜底，不是免死金牌。

## 安装

### 模块（必需）

1. 下载 [Releases](../../releases) 中的模块 zip（或自行打包本仓库根目录）
2. Magisk / KernelSU 管理器刷入，重启

### App（可选，用于控制中心磁贴）

```bash
cd app
bash build.sh   # 需要 JDK17 + Android SDK (build-tools 35, platform 36)
adb install owc-app-debug.apk
```

然后在 KernelSU 中授予 App root，控制中心 → 编辑 → 添加"亮屏快充"磁贴。

> 不装 App 也可以：手动 `su -c "echo 1/0 > /data/adb/owc/enabled"` 同样热切换。

## 兼容性

> **本项目按通用模块设计，但目前仅在一加 15T 上实测确认可用。**
> 其他机型理论兼容（依赖 oplus_chg / horae 通用节点），但节点路径与充电策略
> 因机型/系统版本而异，**请自行测试**，效果随缘。作者仅随缘更新适配，
> 欢迎提交 PR / issue 反馈其他机型的实测情况（附 `warp_charge.log` 与机型信息）。

| 项目 | 状态 | 说明 |
| --- | --- | --- |
| 一加 15T · ColorOS 16 · Android 16 | ✅ **唯一实测** | 双电芯 SuperVOOC，亮屏 22W → 78W |
| 其他一加 / OPPO / realme（ColorOS 系） | ⚠️ 自测 | 理论兼容，随缘适配 |
| 非 OPlus 系统 | ❌ | 依赖 oplus_chg / horae 私有节点，无法使用 |

**自测要点**：确认 `/sys/class/oplus_chg/battery/cool_down`、
`/proc/shell-temp`、`/sys/class/thermal/thermal_zone*/emul_temp` 节点存在，
再看 `warp_charge.log` 中激活后电流是否上升。

## 项目结构

```
├── module.prop / service.sh / uninstall.sh   模块骨架
├── META-INF/…                                Magisk 安装模板
├── vtools/
│   ├── warp_charge.sh        核心：WARP + cool_down 对抗 + 安全栏
│   ├── watchdog.sh           守护保活（120s 巡检 / 5 次失败冷却）
│   ├── lib_common.sh         公共函数库（温度读取/充电检测/日志轮转）
│   └── game_blacklist.txt    游戏名单（前缀 ^ / 精确 = / 子串 * 规则）
└── app/                                      控制中心磁贴 App（纯 Java）
    ├── src/…/OwcTileService.java             QS 磁贴
    ├── src/…/MainActivity.java               状态页
    └── build.sh                              零 gradle 手工构建链
```

## 免责声明

本项目通过伪装系统温度传感器解除充电限制，**可能加速电池老化、增加发热**，
由此产生的任何硬件损耗、安全事故与作者无关。请在通风环境使用，勿覆盖床上
充电。游戏场景已自动暂停保护，但请理解风险后使用。

## 致谢

- [AaTempSpoof](https://github.com/) — 温度伪装思路与 watchdog 模式来源
- [OPP 官方全局扩展](https://github.com/) — 调度与温控体系启发
- [Wangshu (Aestas)](https://github.com/) — 有界等待 / 单一实现 / 防误杀哲学
- [GKD](https://github.com/gkd-li/gkd) — TileService 注册控制中心参考

## License

MIT © bomo
