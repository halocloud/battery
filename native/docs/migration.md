# 从旧 battery 迁移

新命令为 `batteryctl`，不接管旧 `battery` 命令，也不自动导入旧配置。
新旧控制器不能同时工作。安装器检查旧 sudoers 文件、各用户旧 LaunchAgent，以及常见旧 CLI 进程。

1. 在旧菜单栏应用中关闭限充并退出应用，停止登录自动启动。
2. 在安装旧工具的用户会话中运行 `battery maintain stop`，确认恢复正常供电和允许充电。
3. 用旧工具的 `battery uninstall` 移除其后台任务、程序和免密码授权。
4. 多用户机器逐个检查旧用户的 `~/Library/LaunchAgents/com.battery.app.plist`。
5. 确认旧工具未运行，再安装 BatteryCore，运行 `batteryctl diagnose`。

此前代码审查发现旧卸载、进程终止流程可能留下子任务。若旧工具无法清理，
应人工核对旧进程、LaunchAgent 和 `/private/etc/sudoers.d/battery`，先恢复正常充电再处理残留。
安装器会报出冲突，不会以 root 自动运行旧脚本，也不会直接删除其他用户的数据。

记录原先目标电量，待新硬件后端通过验证后使用 `batteryctl limit 原目标`。
旧版电压控制、强制放电、校准、适配器开关和 MagSafe 灯功能不迁移。

卸载通过 `batteryctl uninstall` 进行。它只有在后台确认已释放所持控制后才删除服务及状态。
如果服务不可用或硬件不可访问，卸载会中止，需先恢复服务或完成硬件恢复。

系统安装及真机验收不会由代码构建流程自动执行。
