# BatteryCore 原生 CLI

Swift 实现的 `batteryctl` 和系统后台服务 `batteryd`，复用仓库 `dist/smc`。
运行要求 Apple Silicon、macOS 15 或更高版本；远程安装使用预编译程序，无需 Swift/Xcode。
从源码构建才需要 Swift 6 工具链。现有 Bash/Electron 文件不受影响。

**本版本尚未完成真实充电验证。随包硬件验证表为空，安装后默认关闭限充；未知机型或系统构建号只提供诊断。**
读取到 SMC 控制项并不代表充电控制已经生效。不要在未完成下述验收前填写验证记录。

## 构建与测试

```sh
./native/scripts/swift.sh build
./native/scripts/swift.sh test
python3 native/scripts/test-package.py
python3 native/scripts/test-remote-install.py
./native/.build/debug/batteryctl --help
./native/.build/debug/batteryctl diagnose --offline --json
./native/scripts/build-release.sh
```

所有 Swift 缓存和构建结果位于 `native/.build/`，远程分发文件位于 `native/out/`。
测试使用 Swift Testing、假电池和假硬件，无需完整 Xcode 的 XCTest；进程测试仅启动 `sleep`、`yes` 和参数回显，不运行 SMC、安装或变更电源状态。

如果 Command Line Tools 的 `PackageDescription` 私有接口仍为 Swift 5、动态库却为 Swift 6，
可为上述构建命令添加 `BATTERYCORE_FIX_MANIFEST_INTERFACE=1`。脚本仅在 `.build/toolchain/` 中建立修正副本，
不修改系统工具链。如果受限环境阻止 SwiftPM 的子进程隔离，可额外传入 `--disable-sandbox`。

## 安装与使用

先按 [迁移说明](docs/migration.md) 停止并移除旧控制器。通过远程命令下载、校验并安装，不使用 `.pkg`：

```sh
curl -fsSL --proto '=https' --proto-redir '=https' -L \
  https://github.com/halocloud/battery/releases/download/native-v0.1.0/install.sh | /bin/bash
```

**上面的命令需要先将本分支及发布文件发布到 `halocloud/battery` 的 `native-v0.1.0` Release。
当前代码构建不会自动推送、创建 Release 或上传文件，未发布前该地址不可用于安装。**

安装脚本以普通用户下载预编译程序和 SHA-256 文件，检查摘要、归档结构、架构及代码签名后才请求 `sudo`。
授权后在 root 私有目录重新复制、校验和解包，再安装系统 LaunchDaemon 与 `/usr/local/bin/batteryctl` 快捷入口。
升级使用相同命令，保留目标和暂停状态；失败时尝试恢复旧服务，恢复失败会保留备份位置。
原 `.pkg` 测试版使用同一安装目录，可以直接升级。

只检查远程下载，不安装或操作 SMC：

```sh
curl -fsSL --proto '=https' --proto-redir '=https' -L \
  https://github.com/halocloud/battery/releases/download/native-v0.1.0/install.sh | /bin/bash -s -- --check-only
```

发布前也可用本地构建文件验证或安装：

```sh
archive=native/out/BatteryCore-0.1.0-macos-arm64.tar.gz
digest=$(shasum -a 256 "$archive" | awk '{print $1}')
bash native/install.sh --archive "$archive" --sha256 "$digest" --check-only
# 完成校验后，如需实际安装，去掉 --check-only；会请求管理员授权。
```

SHA-256 文件与程序来自同一 GitHub Release，用于检查下载完整性。也可通过 `--sha256` 传入另行核对的摘要进行固定校验。

```sh
batteryctl diagnose
batteryctl status --json
batteryctl limit 80       # 仅在当前机型/系统构建号完成硬件验证后可用
batteryctl pause
batteryctl resume
batteryctl topup
batteryctl disable
batteryctl uninstall     # 通过 sudo 请求管理员授权，只执行固定的已安装卸载程序
```

上限范围 50–100%，默认 80%；达到上限禁充，降至上限减 5 个百分点时恢复。
首次启动或重启后，低于上限允许充电。插电时高于目标只会禁充，不主动放电。
暂停状态跨重启保留；`disable` 关闭限充但保留目标。`resume` 使用保存目标重新启用。
`topup` 需要限充已启用且接入外部电源，到 100%、断开电源或 12 小时后结束；重启不恢复临时任务。
“允许充电”表示本工具不阻止充电，实际是否充电仍由系统、电池温度和电源决定。

修改策略要求本地管理员账号，但日常命令不用 `sudo`。状态、诊断允许普通用户通过已安装的签名 CLI 读取。
从构建目录直接运行的 CLI 可用于帮助和离线诊断；XPC 客户端身份以已安装、root 管理的程序为准。

## 运行结构与恢复

- `BatteryCore/Policy.swift`：纯限充策略及上下阈值记忆。
- `BatteryCore/Controller.swift`：单一控制器，处理配置、临时充满、错误恢复及持久化控制记录。
- `BatteryCore/SMCExecutor.swift`：固定控制项白名单、字节解析、有限重试及写入回读。
- `BatteryCore/ProcessRunner.swift`：无 shell 的调用，2 秒单次超时、输出上限、终止与进程回收。
- `BatteryCore/IPC.swift`：串行队列、XPC 协议、双向签名约束及管理员校验。

服务使用电源变化通知、睡眠/唤醒通知和 30 秒定时检查，不阻止正常休眠。
配置在 `/Library/Application Support/BatteryCore/` 中由 root 管理，以原子替换保存。
写禁充前先持久化 `ownership.json`；释放且回读确认后才清除。
SIGKILL 或断电无法执行清理，重启时依据该记录尝试释放，再评估保存策略。

连续三次失败或电池数据超过 90 秒未更新时进入故障状态，尝试释放控制；需要 `resume` 重新检查。
如果 SMC 自身不可访问，释放也可能失败，服务保留控制记录并明确报告错误。
如果系统更新导致当前验证记录不再匹配，服务不猜测新控制项，需完成新构建号的验证。
硬件验证通过前，不承诺休眠过程中或所有系统版本上都能保持指定上限。

状态 JSON 是版本化的 `Response`：包含 `status`，失败时还包含 `errorCode` 和 `error`。
`status` 包含 `protocolVersion`、配置、采样时间、门控状态、是否持有控制、工作模式及最近错误。
查询成功的退出码为 0，即使查询到 `fault` 模式；自动化需同时检查 `status.mode`。
命令错误退出码：2 参数、3 服务不可用、4 权限、5 不支持、6 硬件、7 状态文件。
请求超时不等于服务取消了请求，重试前先查询状态。

日志：

```sh
log show --last 1h --predicate 'subsystem == "local.batterycore.daemon"'
```

## 真机验证与发布

按 [硬件验收清单](docs/hardware-validation.md) 验证后，管理员才可安装精确匹配机型、构建号的记录。
记录修改后重启服务读取。首版只有 legacy `CH0B/CH0C` 后端，不会按系统版本自动尝试其他写入。
新版 macOS 的系统限充与其他限充程序必须在验收时一并检查，避免多个控制器互相覆盖。

构建输出 `BatteryCore-0.1.0-macos-arm64.tar.gz`、同名 `.sha256` 和独立的 `install.sh`。
按 [远程发布步骤](docs/remote-release.md) 将三个文件上传到 `native-v0.1.0` Release。
默认使用 ad-hoc 签名用于本地验收，不代表已通过 Developer ID 签名或公证。
正式构建可指定钥匙串中的 Developer ID Application 身份：

```sh
BATTERYCORE_APP_IDENTITY='Developer ID Application: …' \
./native/scripts/build-release.sh
```

构建时固定校验仓库原始 SMC 的 SHA-256，签名后重新生成安装清单；后台校验实际安装 SMC 的摘要。
客户端与服务互相使用 root 管理程序的 designated requirement 校验身份；本地 ad-hoc 构建会固定代码哈希，
因此更新二进制应重新构建、安装整套发布文件。正式发行的程序标识和签名身份应保持稳定。
后台服务和卸载程序不联网；安装入口只从固定的 GitHub HTTPS Release 下载，不在管理员进程中下载。
`build-package.sh` 仅保留为早期测试安装包的兼容构建入口，默认分发方式为远程命令安装。

`smc` 的来源和 GPL 许可证随包保存在 `SMC-SOURCE.md`、`SMC-LICENSE`；发行前需确认对应源码的获取方式。
