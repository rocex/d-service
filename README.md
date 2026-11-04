# Windows 服务守护程序

使用 D 和 Windows API 实现，不需要额外运行时。守护程序注册为一个 Windows 服务，管理配置中的多个普通后台程序，不会分别把这些程序注册为服务。

## 构建与测试

需要 Windows 和 D 工具链（DUB、LDC 或 DMD）。

```powershell
dub test
```

统一入口构建 `source-test` 中的 D 原生 `unittest`，每次运行测试前检查并构建或恢复正式程序 `.dub/dservice.exe`，生成：

- `.dub/dservice-unittest.exe`：测试程序。
- `.dub/dservice-demo-a.exe`、`.dub/dservice-demo-b.exe`：同一个测试 exe 的副本，无需独立项目、构建配置或启动参数。

两个 demo 按精确文件名识别，在运行任何 unittest 前进入持续等待，不会递归执行测试。另生成 `.dub/dservice-demo-exit.exe`，按独立文件名识别后立即退出，用于验证短命程序不会无限重启；它同样不执行 unittest。仅需正式程序时仍可执行 `dub build --build=release`。

`unittest` 配置的 `preRunCommands` 会在**每次运行测试前**执行 `dub build --config=application --build=release`，包括 unittest 构建命中缓存的情况；DUB 可复用发布构建缓存并恢复正式 `.dub/dservice.exe`，测试守护副本始终来自正式程序而不是 unittest 入口。

进程测试直接运行 `.dub` 中生成的两个 demo，不安装或操作系统服务。测试守护使用 `.dub/守护 test-<进程号>-<计时值>.exe`，其同名 `.ini` 和 `.log` 均在 `.dub` 中，控制台会打印本次日志路径。测试结束保留这些文件以供检查，不覆盖手工使用的 `dservice.ini` 和 `dservice.log`。守护记录和测试步骤合并写入同一个 `.log`，使用固定三位毫秒时间戳以及 `[守护]`、`[测试]`、`[日志]` 等两字日志头，不再生成 `.events.log`；已有历史文件不删除。

分别断言两个程序的启动、杀死后重启、另一程序不受影响、守护退出后保留、重新接管且不重复启动，以及测试结束时杀死并等待退出；同时覆盖 INI 默认值/指定上限/非法值、相对路径、数字编号排序、重复路径去重、中文及空格路径，以及无等待的预算状态测试。集成测试以 `maxRetries=2` 断言缺失程序和立即退出程序各尝试恰好三次后放弃，且健康 demo 仍能恢复，守护重启后预算重置。测试完成会终止测试进程，清理按完整路径核对，不按名称全局杀进程，也不只凭历史 PID 清理。历史测试文件可在测试停止后自行归档或删除。

### 手工验证两个 demo

运行 `dub test` 后，使用 `.dub/dservice.ini`：

```ini
[service]
maxRetries=5

[programs]
app1=dservice-demo-a.exe
app2=dservice-demo-b.exe
```

```powershell
.\.dub\dservice.exe --console
```

检查 `.dub/dservice.log` 中两个程序的“启动成功”或“接管已有程序”记录。在任务管理器中核对完整路径后结束其中一个 demo，守护应在下次轮询时重新启动它。Ctrl+C 仅停止守护；结束手工验证时，应先停止守护，再结束两个手工 demo。

**执行 `dub test` 前请先停止手工守护及两个 demo。** 测试会检查默认守护互斥锁，并在 demo 文件被占用时明确报错，不接管并杀死手工进程。测试期间不要通过其他改名的守护程序或手工启动这两个 demo。并行测试被互斥锁阻止。正式程序的预构建也可能因 `.dub/dservice.exe` 被占用而失败。测试不会修改已有 `.dub/dservice.ini`。

## GitHub Actions 编译与发布

工作流位于 `.github/workflows/d.yml`：

- 推送任意分支或 tag、提交 Pull Request，以及手动触发时，执行 Windows x64 发布构建和全部 `dub test`。
- 编译及测试成功后，在该次 Actions 运行页面的 **Artifacts** 中下载 `dservice-windows-x64`，包含 `dservice.exe`、`dservice.ini.example` 和 `README.md`。产物保留 30 天。
- 测试日志单独上传为 `dservice-test-logs`，即使测试失败也尝试保留已有日志，保留 14 天。
- 推送名称以 `release` 开头的 tag（例如 `release-1.0.0`）时，检出该 tag 对应的代码；构建和测试成功后，使用同一次构建的产物创建同名 GitHub Release，并上传上述三个文件。其他 tag 只编译测试，不发布。
- 发布任务单独申请 `contents: write`，普通构建任务只读。若仓库或组织策略限制 GitHub Actions 创建 Release，需要由管理员允许该权限。已存在的同名 Release 不会被自动覆盖。

发布包不包含测试 demo 或本机实际配置。部署时把 `dservice.ini.example` 复制为 `dservice.ini` 并填写真实程序路径。工作流仅在提交并推送到 GitHub 后运行，本地修改不会自动发布。

## 配置

在可执行文件同目录创建 `dservice.ini`，填写实际程序路径。直接运行 `.dub/dservice.exe` 时，配置必须放在 `.dub/dservice.ini`，而不是当前命令行目录。部署时建议把 exe 和配置一起放到固定目录；以下安装命令在该目录执行。

配置示例：

```ini
[service]
maxRetries=5

[programs]
app1=dservice-demo-a.exe
app2=..\apps\demo-b.exe
app3="D:\后台程序\含空格 目录\ProgramC.exe"
```

- 配置为 UTF-8 INI，支持 BOM、空行、以 `;` 或 `#` 开头的整行注释、中文及空格路径、可选的路径双引号。不支持行尾注释、命令行参数或批处理脚本。
- `[programs]` 键必须为从 `app1` 开始的连续正整数编号；不允许重复、断号、`app0`、`app01` 或任意名称。按数字顺序启动，即使配置行乱序，`app10` 也不会先于 `app2`。
- 相对路径以 **INI 所在目录** 为基准，与启动守护的工作目录无关；支持 `..`。绝对路径保持其目标位置，不接受 `C:app.exe` 这类驱动器相对路径。
- 路径规范化后忽略大小写和分隔符差异去重，一个路径对应一个受监控实例；禁止配置守护程序自身。不解析符号链接等文件身份别名。
- `[service]` 和 `maxRetries` 可省略，默认重试上限为 **5**。显式值必须是 `0` 到 `4294967295` 的十进制整数；空值、负数、非数字及溢出均为配置错误，不会悄悄回退默认值。未知节、未知服务设置和重复设置也会报错。
- 仅读取同名 `.ini`，不再读取旧的逐行 `.conf`。本项目原有 demo `.conf` 保留供参考，根目录和 `.dub` 已各自提供对应 INI；根目录 INI 使用 `.dub\...` 相对路径。

### 重试与放弃

- 每个程序有独立预算，检查间隔为 3 秒。初次启动允许尝试一次；若失败，最多额外重试 `maxRetries` 次。因此一直启动失败时总尝试次数最多为 `1 + maxRetries`。
- 已经稳定运行的程序退出后，最多尝试恢复 `maxRetries` 次。`maxRetries=0` 允许初次启动，但不允许失败重试或退出后的恢复。
- 创建进程成功或接管成功**不会立即重置预算**。只有到下一次检查时确认进程仍然存活，才恢复完整重试预算；在此之前退出的短命程序持续消耗同一预算，避免无限重启。
- 预算耗尽后，在下一次检查记录一次“放弃重启”，不再尝试该程序；其他程序继续监控。重新启动守护会重新读取配置并重置所有预算。
- 配置在守护启动时读取，修改后重启服务。移除某个路径只会停止监控，不会终止该程序。
- 启动的程序以自身所在目录为工作目录，使用服务账户及其环境，不会显示控制台窗口。
- 文件名跟随可执行文件名：例如改名为 `worker-guard.exe` 后，读取 `worker-guard.ini`，写入 `worker-guard.log`，服务名为 `worker-guard`。

## 安装和启动

把可执行文件和配置放在固定目录，在**管理员 PowerShell** 中执行：

```powershell
.\dservice.exe --install
sc.exe start dservice
sc.exe query dservice
```

安装时设置为 Windows 自动启动服务，默认使用 LocalSystem 账户。安装不会立即启动；上面的 `sc.exe start` 用于首次启动。也可以在 Windows 服务管理器中设置专用服务账户，建议只授予所需权限。

**安全要求：** 可执行文件、配置文件、被启动程序及其目录必须仅允许可信管理员修改，否则修改配置或替换程序的用户可能获得服务账户权限。服务账户需能读取配置、访问和运行目标程序，并在守护程序目录写日志。

Windows 服务在会话 0 运行，不适合需要交互桌面、用户输入或映射网络盘的程序。

## 停止、重启与接管

```powershell
sc.exe stop dservice
# 等 sc.exe query dservice 显示 STOPPED 后再启动。
sc.exe start dservice
```

**停止服务只停止监控，不终止它启动的程序，也不终止这些程序的子进程。** 守护程序意外退出时，已启动的程序同样可以继续运行；停机期间没有自动重启保障。

守护重新启动时，枚举当前进程并核对可执行文件完整路径：

- 找到相同路径的存活进程：接管其进程句柄继续监控，不重复启动。
- 未找到：启动新进程。
- 已接管进程退出：记录退出码，再查找同路径实例；不存在则重新启动。
- 同名进程因权限不足无法核对：记录错误并稍后重试，不冒险重复启动。

接管按完整路径而非父子关系识别，因此手动启动的同路径程序也可能被接管；若已有多个同路径实例，仅监控其中一个，不清理其他实例。不支持通过短路径、符号链接等不同路径别名识别同一个程序。建议始终使用同一条标准绝对路径和同一服务账户，不要由多个不同守护服务管理相同路径。

服务停止、卸载以及从配置移除路径都不会停止业务程序，需要时由管理员单独停止。

## 日志与调试

日志默认追加到同目录 `dservice.log`，包含时间、启动成功及 PID、接管事件、退出码、启动错误和守护启停。当前不做日志轮转，应按运维策略定期归档，避免长期增长。

```powershell
.\dservice.exe --console
```

控制台模式按 Ctrl+C 停止监控，业务程序继续运行。同名服务和控制台实例不可同时运行。

## 卸载

```powershell
sc.exe stop dservice
# 等服务完全停止后执行。
.\dservice.exe --uninstall
```

卸载不删除配置、日志或停止已有业务程序。

## 验证范围

已通过发布构建、配置解析及实际进程生命周期的 D unittest。进程测试通过终止测试守护进程验证保留与接管；未自动执行需要修改系统配置的服务安装、开机启动和服务管理器停止流程，这些需在部署环境中验证。
