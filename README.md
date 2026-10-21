<div align="center">
  <img src="./docs/logo.svg" alt="pmap logo" width="180">
  <h1>pmap</h1>
  <p>macOS 菜单栏 SSH 本地端口转发管理器</p>
  <p><a href="https://github.com/jiyeqian/pmap/releases">下载</a> · <a href="https://github.com/jiyeqian/pmap/issues">反馈</a> · <a href="./LICENSE">MIT License</a></p>
</div>

pmap 为现有系统 OpenSSH 环境提供图形控制面板：选择主机，输入 `8000` 或 `8000:80`，开启或停止本地到远程回环地址的端口转发。支持 macOS 14+，构建为 Intel 与 Apple Silicon 通用二进制。

当前改造分支为下一版 0.2.0 候选版本；`v0.1.5` 标签保留改造前基线。尚未完成正式 App Store 签名、上传或审核。

## 构建与启动

```bash
cd /Users/jiyeqian/Workspace/pmap
./test.sh
./build.sh
./scripts/verify-bundle.sh pmap.app
open /Users/jiyeqian/Workspace/pmap/pmap.app
```

需要完整 Xcode 工具链。启动新构建前先正常退出旧实例；构建脚本会拒绝替换检测到的运行中输出。图标或签名失败会阻断构建。普通本地包使用临时签名，没有 Apple 公证；这不等同于正式商店分发。

沙盒候选构建：

```bash
cd /Users/jiyeqian/Workspace/pmap
PMAP_SANDBOX=1 ./build.sh
PMAP_REQUIRE_SANDBOX=1 ./scripts/verify-bundle.sh pmap-sandbox.app
open /Users/jiyeqian/Workspace/pmap/pmap-sandbox.app
```

完整 Xcode 工程、真实 SSH 集成测试和人工验收方法见 [商店准备与验收](./docs/APP_STORE.md)。

## 首次使用

1. 在终端确认 `ssh 主机别名` 的主机指纹可信且认证可用；需要密码或私钥解锁时先在终端处理。
2. 点击菜单栏 pmap 图标，再点击齿轮打开“设置与帮助”。阅读并确认 SSH 配置信任说明。
3. 沙盒版通过文件选择器授权 `.ssh` 文件夹；外部 Include、密钥等文件需要分别授权。取消选择不会授权。
4. 刷新主机列表，选择主机开始连接；连接失败时面板显示错误原因。
5. 添加端口并用浏览器或客户端验证实际服务响应。

pmap 运行非交互式系统 SSH，强制严格主机校验，不自动信任新主机或接受变更的主机密钥。SSH Agent、系统钥匙串和外部命令在沙盒内可能受限，不能保证与终端完全一致。

## 操作与状态

| 操作 | 行为 |
| --- | --- |
| 输入 `8000` | 本地 `127.0.0.1:8000` → 远程 `127.0.0.1:8000` |
| 输入 `8000:80` | 本地 `127.0.0.1:8000` → 远程 `127.0.0.1:80` |
| 输入 `5432:5432#数据库` | 添加转发并显示备注 |
| 点击端口按钮 | 开启，或停止转发/重试 |
| 点击删除按钮 | 清理转发后删除规则；清理失败时保留规则与错误 |
| 主机菜单“断开并停止重试” | 断开当前主机及端口，取消待恢复状态 |
| 底部“中 / EN” | 切换并保存界面语言 |
| 设置 | 控制启动恢复、自动重连、通知和文件授权 |
| 退出 | 保存期望状态，异步释放受管 SSH 会话与监听 |

端口绿灯表示转发请求已建立，**不表示远端服务健康**；红灯表示失败；主机未连接时端口为灰。菜单栏圆点按端口顺序轮播，不能代替主机错误详情。端口按钮提供辅助功能名称和状态，长列表支持滚动。

自动重试仅用于可恢复故障；认证、主机密钥及明确禁止转发等错误需要用户处理。通知默认关闭，启用时才申请系统授权，不在通知里显示主机名或地址。

## 配置与兼容性

普通构建配置：`~/Library/Application Support/Pmap/config.json`。沙盒构建保存在对应应用容器内，应用支持目录由系统 API 确定；两种构建不自动互相迁移配置。

配置原子保存并校验端口。损坏或不支持的配置版本会提示错误并保留原文件，不会静默覆盖。`active` 字段保存用户期望恢复的端口，而不是声称这些端口在任何时刻都实际连通。

pmap 只读系统 SSH 配置和密钥。支持具体 Host 别名（包括含点别名）及有界递归 Include。User、HostName、Port、IdentityFile 和 ProxyJump 交给系统 OpenSSH 解析。配置里的 LocalCommand、Agent/X11 转发和额外端口映射被禁用，仅管理面板声明的本地转发。

ProxyCommand 和 Match exec 可能执行程序，因此仅在用户确认信任配置后运行，并仍受沙盒权限约束。完整边界见 [SSH 兼容契约](./docs/APP_STORE.md)。

## 隐私与发布

pmap 连接你指定的服务器，不向开发者发送遥测，不含广告或统计 SDK。密钥不复制到应用配置；诊断复制不含主机名、地址、路径和备注。完整说明见 [隐私政策](./docs/PRIVACY.md)，应用设置中也可阅读。

商店所需公开隐私政策 URL、发布主体、审核测试服务和加密出口申报仍需在正式提交前确认。现有文案为 [商店材料草案](./docs/STORE_METADATA.md)，不表示已上线。

## 测试与贡献

- 单元与生命周期测试：`./test.sh`。
- 隔离的本机真实 SSH 沙盒测试：`./scripts/integration-test.sh`，使用临时密钥和回环服务，不修改系统 SSH 配置。
- [贡献规范](./CONTRIBUTING.md)；[MIT License](./LICENSE)。
