# pmap 商店文案与审核准备

## 中文文案草案

名称：pmap

副标题：菜单栏 SSH 本地端口转发

简介：在 macOS 菜单栏管理 SSH 本地端口转发。选择现有 SSH 主机，添加本地与远程端口，一键开启或停止转发。

描述：pmap 为已有 SSH 环境提供简洁的图形控制面板。它使用系统 OpenSSH、你授权的配置与密钥，支持主机选择、端口备注、自动重连、启动恢复和中英文切换。你可以在设置中控制恢复行为、通知和文件访问。

使用前请在终端确认主机指纹和认证可用。pmap 采用非交互认证，不自动信任新主机。沙盒权限可能限制 SSH Agent、外部命令和配置引用的文件；具体兼容范围见应用内帮助。转发状态表示隧道建立，不保证远端服务健康。

关键词草案：SSH,端口转发,隧道,菜单栏,开发工具

## English Draft

Name: pmap

Subtitle: SSH Local Port Forwarding

Description: Manage SSH local port forwards from the macOS menu bar. Choose an existing SSH host, add local and remote ports, and start or stop forwarding. pmap uses system OpenSSH with configuration and keys you authorize. Features include port notes, optional reconnect and launch restore, local notifications, and Chinese/English interfaces.

Verify host fingerprints and authentication in Terminal before connecting. pmap uses noninteractive authentication and never automatically trusts new hosts. Sandbox permissions may limit SSH Agent access, external commands, and referenced files. An established forward does not guarantee remote service health.

## 审核说明草案

应用是 LSUIElement 菜单栏工具，无常驻 Dock 图标。启动后从菜单栏 pmap 图标打开面板，从齿轮进入设置。需要审核专用 SSH 服务器与可用测试密钥，服务端应允许本地 TCP 转发，并提供可访问的 HTTP 测试服务。

送审时提供完整的主机地址、端口、审核用户名、认证材料传递方式、可信主机指纹、本地/远端端口及预期 HTTP 响应。不得使用开发者日常服务器或生产密钥。先按应用提示授权所需文件，再确认配置信任；应用不请求 root 权限，不安装后台服务，不在登录时自动启动。

推荐审核流程：启动 → 打开设置并授权测试配置 → 核验主机指纹与认证 → 选择测试主机 → 添加测试端口 → 浏览器验证响应 → 停止转发 → 退出并确认端口释放。

## 提交前待确认字段

- 个人或组织发布主体、团队、正式 Bundle ID、支持联系方式。
- 支持 URL 与已部署并验证可访问的隐私政策 URL。
- 审核专用服务器、凭据、指纹和完整操作说明。
- 实际产品截图；开发用虚构主机渲染只能辅助设计验收，不替代真实功能证明。
- App Privacy 问卷、年龄分级、类别、定价与地区。
- 根据实际 OpenSSH 使用方式回答加密出口问卷，保留判断依据。

这些材料为草案，不表示已提交、已托管隐私政策或已获得审核批准。
