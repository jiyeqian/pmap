# pmap 商店准备与验收

## 产品范围

本分支采用方向二：系统 OpenSSH 的图形控制面板。保留用户的原配置和密钥，不导入复制私钥，不改写系统 SSH 配置。默认本地构建继续兼容现有使用方式；Xcode 工程和 `PMAP_SANDBOX=1` 构建启用 App Sandbox。两者共享连接与状态代码。

下一版候选营销版本为 0.2.0，候选构建号为 6，后续独立递增；未创建下一版发布标签。v0.1.5 是改造前基线。基线双架构编译和 40 项测试通过，但旧构建中的图标打包在受限执行环境失败后被静默忽略，因此该标签不应被描述为已通过完整发布验收。

## SSH 兼容契约

| 能力 | 当前行为 |
| --- | --- |
| Host、引号、注释 | 显示无点具体别名；排除通配、否定、明确指向本机及可能成为命令选项的名字；沿用 0.1.5 列表规则 |
| Include | 有界递归、glob 展开与循环去重；权限不足明确报错；不执行 Match exec 来发现主机 |
| User、HostName、Port、IdentityFile、ProxyJump | 交给系统 OpenSSH 处理；沙盒内相关文件需要授权 |
| 私钥密码、主机首次信任 | 在终端完成；pmap 强制 BatchMode 和严格主机校验，不自动接受新密钥 |
| known_hosts | 读取既有信任记录；pmap 不自动添加或修改 |
| LocalCommand、Agent/X11 转发 | 禁用，避免端口面板隐含其他动作 |
| 配置中的 LocalForward / RemoteForward / DynamicForward | 禁用；仅启用面板明确管理的本地转发 |
| ProxyCommand、Match exec、KnownHostsCommand | 检测到后请求执行确认；绑定展开 Include 后的内容摘要，变化后重新确认。仍受沙盒限制，不保证任意外部程序可执行 |
| SSH Agent、系统钥匙串、硬件密钥 | 普通构建沿用环境；沙盒访问和实际设备尚需逐项验收，不承诺完全等同终端 |
| 外部 Include、私钥或脚本 | 通过主面板错误旁的授权入口分别授权，当前只请求只读文件权限；文件写入类命令不支持 |
| 转发绿灯 | 表示转发请求已建立，不代表远端应用服务健康 |

终端确认必须核验可信渠道提供的主机指纹，不要为消除报错删除 known_hosts 条目或关闭主机密钥检查。

## 本地构建与启动

工作目录：`/Users/jiyeqian/Workspace/pmap`。

```bash
cd /Users/jiyeqian/Workspace/pmap
./test.sh
./build.sh
./scripts/verify-bundle.sh pmap.app
open /Users/jiyeqian/Workspace/pmap/pmap.app
```

替换已运行的应用前先正常退出旧版本。普通构建与沙盒构建使用不同应用标识和配置位置；沙盒版本不会自动读取普通版本的应用配置。主面板授权默认 `~/.ssh` 文件夹；文件访问授权与含命令配置的执行确认分开处理。

```bash
cd /Users/jiyeqian/Workspace/pmap
PMAP_SANDBOX=1 ./build.sh
PMAP_REQUIRE_SANDBOX=1 ./scripts/verify-bundle.sh pmap-sandbox.app
open /Users/jiyeqian/Workspace/pmap/pmap-sandbox.app
```

也可打开 `Pmap.xcodeproj`，使用共享 scheme `pmap`。无证书的本地构建：

```bash
cd /Users/jiyeqian/Workspace/pmap
./make_icon.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Pmap.xcodeproj -scheme pmap -configuration Debug \
  -derivedDataPath .build-store -destination 'generic/platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM='' \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
open /Users/jiyeqian/Workspace/pmap/.build-store/Build/Products/Debug/pmap.app
```

## 自动化验收

`./test.sh` 覆盖解析、持久化、进程执行、连接状态与操作竞态。`PMAP_SANDBOX=0 ./scripts/integration-test.sh` 验证普通版，`PMAP_SANDBOX=1 ./scripts/integration-test.sh` 验证沙盒版；使用隔离的临时密钥、本机 sshd 与 HTTP 服务，验证沙盒内系统 SSH、实际 HTTP 数据穿透、取消/关闭释放监听、拒绝未知主机，并检查 Store 管理的连接中断重连、记录恢复、删除和撤销释放端口。它需要本机允许执行 sshd 和监听回环端口；不需要开启系统“远程登录”，不修改 `~/.ssh`。固定测试端口 39227–39229 必须空闲。

集成测试会构建含临时测试密钥的 `pmap-probe.app`，退出时删除测试包和临时密钥；发布检查拒绝包含 TestFixture 的应用。禁止将此包作为用户安装包。

## 人工验收

1. 正常退出旧版，分别启动普通版和沙盒版，确认只有一个菜单栏图标。
2. 未授权时仅显示授权与退出。点击授权定位 `~/.ssh`，取消不应保存授权；允许后读取主机。外部符号链接需要时接续授权，取消不循环弹框。
3. 在终端验证主机指纹和认证；普通配置直接连接，含本机命令的配置才请求确认。重新打开面板读取配置变化，命令配置变化需重新确认。
4. 添加测试 HTTP 转发，用浏览器确认响应。占用端口时错误可见，释放后自动恢复；停止重试后不可自行重开。
5. 切换主机、删除转发、快速开关，检查旧连接清理和端口释放。
6. 断网恢复、睡眠唤醒后检查重连；正常退出再启动恢复上次主机与期望端口。启动恢复和自动重连固定开启，无开关。
7. 沙盒重启确认目录及关联文件授权仍有效。撤销授权默认取消；确认后断开主机与端口，保留列表和描述，不修改 SSH 文件。
8. 验证 220 pt 面板、`65535:65535`、长描述、中文输入法、描述回车/失焦保存与 Esc 取消，编辑不可触发开关。
9. 中英、深浅色、长列表、小屏与多显示器；Tab/Space、VoiceOver；三处信息/确认框布局一致且正文可选中复制。
10. 运行信息不泄露真实别名、路径、地址、端口、备注或 SSH 原文。通知显示由系统设置控制。
11. 强制终止、系统崩溃、关机与正常退出不同，单独实机验证；不可用单元测试或双架构编译替代这些测试。

## 正式分发阻碍

目前没有开发者会员、团队 ID、注册的 Bundle ID、分发证书或描述文件，因此没有完成正式签名、归档分发验证、TestFlight 和商店上传；临时签名通过不等于这些步骤通过。

获得账号后设置团队、正式标识、新的构建号与 `PMAP_PRIVACY_POLICY_URL`（已经部署的 HTTPS 隐私政策地址），再运行 `scripts/archive-store.sh`。脚本缺少这些值时直接失败；不默认启用自动申请证书或上传。

仍需确认：发布主体及支持联系方式、公开可访问且与应用内容一致的隐私政策 URL、商店截图、年龄分级、分发地区与加密出口问卷。使用系统 SSH 不能自动等同于无需申报加密；不得未经判断设置豁免键。

真实密钥的文件选择/重启授权、SSH Agent/钥匙串/ProxyJump、最低支持 macOS 14、Intel 实机、VoiceOver 和多显示器属于尚需实际环境验收的项目。双架构编译不替代这些测试。

## 官方依据

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)：沙盒、后台进程、打包、隐私与完整性。
- [Configuring the macOS App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)：网络与文件权限。
- [Accessing files from App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)：用户选择的目录与持久书签。
- [Apple Developer Program](https://developer.apple.com/programs/)：正式分发所需会员。

与 0.1.5 的恢复项目、保留差异和迁移步骤见 [版本差异](./VERSION_COMPARISON.md)。

当前构建固定使用用户的 `~/.ssh`：未授权时仅显示授权入口和退出；授权后检查 config 与主机验证文件，外部符号链接实际被拒绝才补充授权。文件缺失和不可读不伪装为未授权，known_hosts 错误不清空主机列表。完整新流程见 README。
