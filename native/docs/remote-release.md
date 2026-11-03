# 远程命令安装与发布

## 构建

```sh
native/scripts/swift.sh test
native/scripts/build-release.sh
python3 native/scripts/test-package.py
python3 native/scripts/test-remote-install.py
```

如工具链存在 README 所述问题，在构建命令前设置 `BATTERYCORE_FIX_MANIFEST_INTERFACE=1`；
受限开发环境可为 Swift 命令和发布构建添加 `--disable-sandbox`。
发布构建固定为 arm64，并复用经固定摘要检查的仓库 `dist/smc`。

输出三个文件：

- `native/out/install.sh`：独立安装入口。
- `native/out/BatteryCore-0.1.0-macos-arm64.tar.gz`：预编译 CLI、服务、SMC、安装辅助文件及许可证。
- `native/out/BatteryCore-0.1.0-macos-arm64.tar.gz.sha256`：归档摘要。

## 发布

构建脚本不执行任何远程写入。审核后，将实现提交到当前分支，推送相应提交，
以该提交创建 `native-v0.1.0` Release，上传以上三个文件。
发布新版本时同步更新 `Models.swift`、`stage-release.sh`、兼容构建脚本和 `install.sh` 的版本常量，
并使用对应 `native-v版本号` 标签。安装脚本的 `--version` 参数可选择其他已经发布的版本。

脚本和二进制使用同一个 Release 来源。第一次发布前不要将示例远程命令表述为已经可用。
发布产物默认是开发用 ad-hoc 签名；正式 Developer ID 签名与 Apple 公证需要单独的发布验收，不能用 SHA-256 代替。

## 安装流程

1. 普通用户从固定 GitHub HTTPS 地址下载归档及摘要，网络失败、HTTP 错误或摘要不符直接退出。
2. 检查归档只包含规定的 13 个普通文件；拒绝路径穿越、符号链接、硬链接、重复条目、缺失文件和额外文件。
3. 检查 arm64 程序、代码签名、服务定义和 SMC 摘要；`--check-only` 到此结束。
4. 请求 `sudo`，将归档复制到 root 私有临时目录，再次检查摘要和内容；不执行用户可写临时目录中的程序。
5. 检查旧控制器冲突和安装路径，准备新目录。升级时先释放旧服务控制，再停止服务。
6. 备份旧程序、替换程序和服务定义，保留 root 管理的配置及硬件验证记录，启动新服务。
7. 失败时恢复旧程序和服务；若无法恢复，明确输出并保留 root 私有备份目录供排查。

后台服务不负责下载更新。卸载命令仍为 `batteryctl uninstall`，兼容先前 `.pkg` 安装留下的收据清理。
