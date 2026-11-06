# Codex Drive Migrator

给系统盘腾出空间：把 Codex 的用户数据、技能和运行组件迁移到其他本地磁盘的 Windows 桌面工具。

**预览版 v0.1.0 · Windows 10/11 x64 · 中文界面 · MIT 开源**

## 下载与运行

从本仓库的 **Releases** 下载 `CodexDriveMigrator.exe`，双击即可使用，不需要另装 Python。`SHA256SUMS.txt` 提供文件校验值。当前发布包未做代码签名。

1. 选择目标文件夹，例如 `D:\Codex`，点击“扫描目录”。扫描只读取目录和进程信息。
2. 确认列表中的源目录、目标目录与状态。默认保留原始备份。
3. 点击“开始迁移”，完全退出 Codex，包括托盘。保持迁移工具打开。
4. 工具完成同步、SHA-256 校验和目录联接切换后，会显示结果。之后可以重新打开 Codex。
5. 核验迁移结果后，可通过“清理已验证备份”删除本工具记录的旧副本。清理前会再次比较文件；若内容已经变化，工具会保留备份并报告原因。

迁移期间如仍在等待 Codex 退出，可以点击“取消等待”。开始处理文件后请等待结果再关闭工具。

## 迁移范围

| 内容 | 常见原位置 | 目标子目录 |
| --- | --- | --- |
| 聊天记录、配置、插件等 | `%USERPROFILE%\.codex` | `data` |
| 个人技能 | `%USERPROFILE%\.agents` | `agents` |
| 下载的运行环境 | `%USERPROFILE%\.cache\codex-runtimes` | `runtimes` |
| 程序运行组件 | `%LOCALAPPDATA%\OpenAI\Codex` | `engine` |
| 本地与界面缓存 | Codex 的 Local / Roaming 目录或 MSIX 隔离目录 | `local` / `roaming` |

原路径会保留 Windows 目录联接（Junction），用于兼容已有绝对路径。成功切换用户数据目录后，工具会将用户级 `CODEX_HOME` 设置为目标的 `data` 子目录。

Windows 已经重定向到目标盘的应用缓存会单独记录并跳过。工具不迁移整个 Windows Temp 目录，不修改系统 TEMP/TMP，不注册计划任务或服务，不强制终止 Codex。

“尝试通过 Windows 移动主程序”是可选功能，默认关闭。它使用 Windows 的应用迁移接口；**框架包会标记为系统管理并跳过**。因此本工具不保证将所有 Windows 管理的 Codex 依赖移出 C 盘。

## 文件与恢复

- 工作记录保存在目标文件夹的 `.migration` 目录，包括状态、事务记录、复制日志。
- 默认将原目录重命名为带有 `.codex-migration-` 的备份，并保留它。
- 只有迁移事务记录匹配、原路径正确指向目标、文件校验通过，才允许清理备份。
- 发现未识别的目标目录、意外目录联接或校验失败时停止处理。
- UTF-8 读写覆盖中文用户名；校验与备份清理使用 Windows 扩展路径，避免备份名加长后超过 260 字符。
- SQLite 的数据库及 `-wal` 文件必须保留并校验；可重建的 `-shm` 索引不迁移。
- 中途失败时保留事务记录和备份，使用同一目标目录重新扫描、运行。已有的匹配目录联接会跳过。

本工具不上传本机数据。仓库和发布包不包含任何聊天、登录凭据、个人配置、真实迁移记录或本机日志。

## 从源码运行

需要 Windows、Python 3.12 和可用的 Tkinter。迁移目标须为 C 盘以外的本地 NTFS 目录。

```powershell
python app.py
```

## 测试与构建

```powershell
python -m unittest discover -s tests -v
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-Engine.ps1
python app.py --self-test self-test-result.json
python app.py --ui-smoke-test

python -m pip install -r requirements-build.txt
./build.ps1
```

构建结果在 `dist` 目录。测试使用临时样本，覆盖文件变化、SQLite WAL/SHM、中文长路径、备份保留与清理、续跑、损坏检测和路径拒绝，不对真实 Codex 数据执行迁移。

GitHub Actions 会在 Windows runner 上执行测试并生成可下载的构建产物。

## 参考资料

- [Codex 配置与状态目录](https://learn.chatgpt.com/docs/config-file/config-advanced#config-and-state-locations)
- [SQLite WAL / SHM 文件说明](https://www.sqlite.org/walformat.html)
- [PyInstaller 打包选项](https://pyinstaller.org/en/stable/usage.html)

本项目由社区维护，与 OpenAI 无隶属关系。
