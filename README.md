# WeChatMover · 微信离线备份

macOS / SwiftUI 的**微信数据离线整包备份与恢复工具**。完全退出微信后，把微信在本机的全部数据容器打包成带校验的时间戳快照写入移动硬盘（含 exFAT），随时可列表、验证、查看详情，并在需要时按计划安全恢复。

项目主页：[agnostic-ap/WeChatMover-OfflineBackup](https://github.com/agnostic-ap/WeChatMover-OfflineBackup)

> 使用者请直接看 [使用指南](使用指南.md)（面向普通用户）；本 README 面向开发者。

本项目自 2.0 起从「软链接外置迁移工具」全面改造为「离线备份/恢复应用」：

- **不再**给微信重签名（不碰 `codesign`）、**不再**建符号链接、**不再**要求日常使用时插着外置硬盘。备份完成后硬盘即可拔下。
- 旧版软链接迁移流程及相关文案已全部移除。

## 备份哪些数据

完全退出微信后，工具在当前系统用户的 home 下发现并备份微信全家（存在才备）：

| 类别 | 路径（相对 `~`） | 说明 |
| --- | --- | --- |
| 主容器 | `Library/Containers/com.tencent.xinWeChat` | 聊天记录、文件、账号数据 |
| 分享扩展容器 | `Library/Containers/com.tencent.xinWeChat.WeChatMacShare` | 分享扩展 |
| 文件提供扩展容器 | `Library/Containers/com.tencent.xinWeChat.WeChatFileProviderExtension` | 访达文件集成 |
| 共享群组容器 | `Library/Group Containers/5A4RE8SF68.com.tencent.xinWeChat` | 跨进程共享数据 |
| 自动化脚本目录 | `Library/Application Scripts/com.tencent.xinWeChat*`、`…/5A4RE8SF68.com.tencent.xinWeChat*` | Application Scripts 授权目录 |
| 微信应用本体（可选） | `/Applications/WeChat.app` | 勾选后归档同版本安装包；**恢复时绝不自动覆盖「应用程序」** |

发现规则：三个父目录下、名称等于微信主 ID / 群组 ID 或以其加 `.` 开头的直接子目录（前缀白名单，自动覆盖未来新增的微信扩展容器）。

## 快照格式

外置盘上的布局（目录与文件名全为 exFAT 安全的 ASCII）：

```
<你选择的文件夹>/WeChatBackups/
  WeChatBackup-20260830-153000/
    container-com.tencent.xinWeChat.tar
    container-com.tencent.xinWeChat.WeChatMacShare.tar
    …
    manifest.json          # 清单
    COMPLETE               # 完成标记（内容 = manifest.json 的 SHA-256）
```

- **归档**：系统 bsdtar（`tar -cf … --mac-metadata`）。tar 单文件以 AppleDouble 机制封装 macOS 扩展属性与资源叉，因此**裸目录永不直接落上 exFAT**，元数据不丢；解包 `tar -xpf --mac-metadata` 自动还原，且 libarchive 默认拒绝绝对路径与 `..` 穿越条目。不用 ditto ZIP：ditto 对 >4GB 归档写不出标准 ZIP64（实测 45GB 归档被 zipinfo/bsdtar 判为损坏），且 tar 免压缩打包快约 8 倍（微信数据多为已压缩媒体，ZIP 也压不动）。
- **manifest.json** 记录：格式版本、创建时间、工具版本、微信版本/build、macOS 版本，以及每个归档的源相对路径、文件数、逻辑大小、归档大小、SHA-256。
- **完成标记**：所有归档与清单落盘后才写 `COMPLETE`；标记缺失或与清单哈希不符的快照显示为「未完成/损坏」，禁止用于恢复。备份过程写在 `*.inprogress` 目录中，成功后才改名。
- **仓库位置防呆**：备份仓库不得与任何源组件目录相同、位于其内部或包含源目录（比较时解析符号链接），否则直接拒绝，杜绝递归归档或把源写进仓库。
- **竞态防护**：备份在第一次写盘前和每个组件归档前都会复查微信确实未运行，防止「自动退出后又被立即重开」导致归档不一致。

## 恢复流程的安全设计

1. **默认只出计划**：展示每项的目标路径、大小、是否会让位现有数据，以及微信版本/磁盘空间检查结果；版本不一致必须勾选知情确认。
2. **二次确认**：计划页确认后还有最终 destructive 确认。
3. **清单白名单校验**：manifest 的 `archiveName` 必须是快照目录内的安全直接文件名，`relativePath` 必须精确映射到微信组件白名单（拒绝重复目标、重复归档名、空自动恢复项）——恶意或损坏的清单无法把恢复引导到白名单之外。
4. **先验证再动手**：逐归档校验条目路径安全（拒绝绝对路径、`..`、越出顶层目录）与 SHA-256；再检查磁盘空间。全部通过前不写一个字节；落位前还会最后复查微信未运行。
5. **先解压后落位**：全部解压到目标同级的 `*.wcm-staging-*` 暂存目录（同卷，落位仅是改名）。
6. **原数据只改名，绝不静默删除**：现有目录改名为 `<原名>.wcm-rollback-<时间戳>` 保留原位；确认无误后由用户手动删除。
7. **失败自动回滚，回滚失败不掩盖**：任一步失败，已落位的新数据改名让位（`.wcm-failed-*`），回滚副本改回原名。若回滚本身也出错，工具不会谎称已恢复：抛出明确的严重错误，逐条列出原数据所在的 `.wcm-rollback-*` 路径与失败副本路径，且保证全程未删除任何数据。
8. **路径白名单**：一切危险操作（改名、落位、清理暂存）只允许发生在三个微信父目录下、微信家族名（含 `.wcm-*` 派生名）的直接子目录上，杜绝路径穿越；快照删除只允许 `WeChatBackups` 下的 `WeChatBackup-*` 目录。

## 适用边界（务必阅读）

- **最可靠**：同一台 Mac、同一 macOS 用户、同版本微信、同一微信账号的「备份 → 恢复」。
- **跨 Mac 恢复属实验性质**：微信可能要求重新登录、部分数据可能不被识别，成功率不保证。
- **不能替代官方备份**：请与微信官方「聊天记录备份与迁移」并存使用，重要记录多一份保险。
- 本工具不修改微信、不重签名，微信不需要重新签名即可正常使用。

## 构建与测试

```bash
bash Scripts/test.sh        # 单元测试（Swift Testing；全部使用临时目录 fixture，绝不触碰真实微信数据）
bash Scripts/build_app.sh   # 出 arm64 + x86_64 通用 WeChatMover.app（ad-hoc 签名的是本工具自身）
```

代码结构：

```
Sources/WeChatMover/
  Models/     BackupComponents（组件发现 + PathGuard 白名单）、BackupManifest、AppViewModel、Presentation
  Services/   Archiver（bsdtar tar + --mac-metadata）、Checksum（SHA-256）、VaultStore（快照仓库）、
              BackupEngine、RestoreEngine、WeChatDetector、WeChatQuitter、DiskProbe、PermissionHelper
  Views/      SwiftUI 中文界面（备份区、快照列表、恢复计划、快照详情、日志）
```

## 许可与署名

MIT 许可证，见 [LICENSE](LICENSE)。

本项目基于上游 [pipipiper/WeChatMover](https://github.com/pipipiper/WeChatMover)（MIT）改造而来，感谢原作者的探索与代码基础；2.0 的备份/恢复形态与上游的软链接迁移形态定位不同，请按各自 README 使用。
