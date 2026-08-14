# WeChatMover

微信数据外置硬盘迁移工具（macOS / SwiftUI）。把微信（官网 DMG 版）容器里最占空间的几个数据目录迁移到外置硬盘的任意文件夹，原位留下同名符号链接，微信无感使用；支持一键还原。

## 原理

微信（官网版）的数据存放在沙盒容器内：

```
~/Library/Containers/com.tencent.xinWeChat/Data
```

本工具只迁移以下三个子目录（存在且不是软链时）：

| 容器内路径 | 说明 |
| --- | --- |
| `Documents/xwechat_files` | 4.x 主力数据（聊天记录文件、图片视频等） |
| `Documents/app_data` | 4.x 应用数据 |
| `Library/Application Support/com.tencent.xinWeChat` | 3.x 兼容数据 |

迁移后数据实际位于 `<你选择的文件夹>/WeChatData/<子目录名>`，原位置是同名符号链接。

迁移流程：后台拷贝 → 大小校验 → 源目录改名为 `<原名>_backup`（**不删除**）→ 建软链 → 确认软链可达。任何一步失败都会自动回滚，不会丢数据。迁移完成后用 `codesign --sign - --force --deep /Applications/WeChat.app` 重签名（通过 osascript 弹系统密码框提权），因为数据位置变化会破坏原签名校验。

### 关于 `_backup` 备份

迁移成功后，原数据以 `xwechat_files_backup` 等形式保留在内置盘原位——这是一份保险，意味着**空间尚未释放**。确认微信在外置盘上运行正常后，点击「删除备份…」清理（工具会逐项检查软链有效才删，删除前显示可释放的空间并二次确认）。若软链失效（如外置盘未插），删除会被拒绝。

「一键还原」优先使用本地 `_backup`：删掉软链、把备份改名回原名即可秒还原（外置盘上的副本会保留不动）；若备份已被删除，则从外置盘完整拷回内置盘并校验。

若上次迁移中途失败留下残留（`_backup` 存在但源位不是软链），工具会红色警示并阻止再次迁移，按提示手工检查（一般把 `_backup` 改名回原名即可恢复）后再操作。

## 重要前提

- **只支持微信官网 DMG 版**（https://weixin.qq.com/ 下载）。App Store 版受沙盒限制，软链无效；本工具检测到 App Store 版会禁用迁移并引导你去官网下载。
- **目标卷强烈建议为 APFS**。exFAT / NTFS 等格式不支持符号链接与稀疏文件，会导致空间膨胀甚至失败。工具检测到非 APFS 会醒目警告，建议换盘或格式化为 APFS。
- 迁移前需要退出微信：点击「一键迁移」时若微信正在运行，工具会弹确认框引导退出（优先优雅退出，几秒后未退出则强制结束，无需管理员密码）。
- **外置盘未连接时不要打开微信**，否则微信会在原位新建空数据目录。工具启动时会检测软链可达性并红色警示。
- 迁移后 macOS 会重置微信的部分权限（屏幕录制、麦克风），首次使用时按工具内的指引重新授权。
- 微信大版本更新后签名会再次失效，工具检测到版本变化会提示一键重签名。

## 构建

无需 Xcode，仅需 Command Line Tools（Swift 6）：

```bash
bash Scripts/build_app.sh
```

产物在 `build/WeChatMover.app`（已 ad-hoc 签名），拖到「应用程序」或直接双击运行即可。

## 测试

```bash
# 装了完整 Xcode 的机器：
swift test

# 只有 Command Line Tools 的机器（SwiftPM 找不到 CLT 自带的 Testing.framework，需补参数）：
bash Scripts/test.sh
```

测试全部使用临时目录构造的假数据，不会触碰真实微信数据。

## 使用步骤

1. 打开 WeChatMover，确认状态面板识别到微信版本且不是 App Store 版。
2. 若提示无法读取微信数据目录，点击按钮跳转「完全磁盘访问权限」，授权后重启本 App。
3. 点击「选择文件夹…」，在外置硬盘上任选一个文件夹作为目标位置；留意卷格式与剩余空间。
4. 退出微信，点击「一键迁移…」，确认前置检查清单后开始。
5. 迁移过程中系统会弹密码框（用于重签名微信），输入开机密码。
6. 完成后按指引重新授权屏幕录制/麦克风权限。
7. 打开微信确认一切正常后，回到本工具点击「删除备份…」释放内置盘空间。

还原：点击「一键还原」。本地 `_backup` 还在时秒还原（改名回去即可）；备份已删则从外置盘完整拷回。完成后再次重签名。

## 常见问题

### 重签名失败：Operation not permitted

macOS Ventura 及以上有「App 管理」权限：修改其他 App 的包（含 codesign 重签名）必须显式授权，osascript 提权到 root 也绕不过。日志出现 `Operation not permitted` 时，工具会自动弹出指引：

1. 点指引里的按钮打开 系统设置 → 隐私与安全性 → **App 管理**，打开 WeChatMover 的开关（列表中没有就点「+」添加）；
2. 回到工具点「重试重签名」。

兜底方案：在「终端」里执行（终端通常已有该权限，一般能成功，指引弹窗里有「复制命令」按钮）：

```bash
sudo codesign --sign - --force --deep /Applications/WeChat.app
```

### 迁移失败：目标位置已存在数据

说明目标文件夹里已有 `WeChatData/<子目录>`，通常来自上次迁移中断或重复迁移。工具会弹确认框：选「删除旧数据并重新迁移」会删掉旧数据后自动重跑（删除前请确认旧数据无用）；选「取消」则可手工检查后重试。

## 项目结构

```
Sources/WeChatMover/
├── WeChatMoverApp.swift       # @main 入口
├── Models/
│   ├── Paths.swift            # 容器路径与目标路径映射
│   └── MigrationState.swift   # 状态枚举 + 视图模型
├── Services/
│   ├── WeChatDetector.swift   # 安装/版本/App Store 版/运行中/签名校验
│   ├── DiskProbe.swift        # 卷格式(APFS)、剩余空间、目录大小
│   ├── Migrator.swift         # 迁移/还原核心（拷贝→校验→源改名 _backup→建软链，带回滚）
│   ├── CodeSigner.swift       # codesign + osascript 提权
│   └── PermissionHelper.swift # TCC 检测与系统设置深链
└── Views/                     # SwiftUI 界面（简体中文）
Scripts/
├── build_app.sh               # 构建并组装 .app（ad-hoc 签名）
└── test.sh                    # CLT 环境下跑 Swift Testing 的包装脚本
```

## 免责声明

本工具与腾讯/微信无任何关联。操作涉及数据迁移，虽有多重校验与回滚，仍建议重要数据先备份。使用风险自负。

## 许可

MIT，见 [LICENSE](LICENSE)。
