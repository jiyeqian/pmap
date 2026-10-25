# pmap 隐私政策 / Privacy Policy

生效日期 / Effective date: 2026-10-22

## 中文

pmap 是系统 OpenSSH 的本地端口转发控制面板。它连接你指定的 SSH 服务器并传输你通过本地转发端口发送的数据，不含广告、分析 SDK、跟踪或向开发者发送数据的遥测。

主机别名、端口、备注、语言、连接偏好与文件访问书签仅保存在本机应用支持目录中。私钥不复制到 pmap 配置；系统 OpenSSH 使用你授权的原文件。现有 SSH 配置中的 ProxyCommand、Match exec 等指令可能执行程序或连接第三方服务，其行为由你信任的配置决定。pmap 禁用 LocalCommand、Agent/X11 转发和配置内额外端口映射。

pmap 不自动信任新主机或接受主机密钥变化。首次连接与密钥解锁需要你在终端确认。应用内诊断复制只包含版本、系统版本、计数、固定错误类别、状态和恢复建议，不包含主机名、地址、密钥、备注、文件路径或原始 SSH 输出。界面上的错误信息可能含 OpenSSH 返回的目标信息，请在分享截图前检查。

通知由 macOS 在本机发送，默认关闭，不包含主机名或地址。打开项目主页会调用系统浏览器，后续访问适用该网站的隐私政策。

可在主面板菜单选择“撤销 SSH 访问…”以清除保存的文件授权与配置信任；此操作不会删除原 SSH 文件。要删除应用数据，退出应用后删除其应用支持目录中的 Pmap 文件夹；沙盒构建的数据位于相应应用容器内。不要在公开问题中粘贴私钥、密码或未脱敏的配置。

隐私问题请通过项目的 [GitHub Issues](https://github.com/jiyeqian/pmap/issues) 联系维护者。正式商店提交前需要确认发布主体、支持联系渠道，并提供此政策的公开可访问 URL。

## English

pmap is a local graphical controller for system OpenSSH port forwarding. It connects to SSH servers you specify and carries traffic sent through your local forwarded ports. It includes no advertising, analytics SDKs, tracking, or telemetry sent to the developer.

Host aliases, ports, notes, language, connection preferences, and file-access bookmarks are stored locally in application support. Private keys are not copied into pmap configuration; system OpenSSH reads authorized original files. ProxyCommand and Match exec in trusted SSH configuration may execute programs or contact third-party services. pmap disables LocalCommand, agent/X11 forwarding, and additional forwards declared in SSH configuration.

pmap never automatically trusts new hosts or accepts changed host keys. Verify hosts and unlock keys in Terminal. Copied diagnostics contain only version, operating-system version, counts, fixed error categories, status flags, and recovery guidance, omitting host names, addresses, keys, notes, paths, and raw SSH output. Visible errors may include target information returned by OpenSSH; review screenshots before sharing them.

macOS notifications are local, off by default, and omit host names and addresses. Opening the project homepage launches your browser; the destination website's privacy policy applies.

Revoke saved SSH file access and configuration trust from the main-panel menu without deleting original SSH files. To delete application data, quit pmap and remove its Pmap application-support folder; sandbox builds store data in their corresponding app container. Never post private keys, passwords, or unredacted configuration in public issues.

Contact maintainers through [GitHub Issues](https://github.com/jiyeqian/pmap/issues). Before store submission, confirm the publishing entity and support contact, and host this policy at a publicly accessible URL.
