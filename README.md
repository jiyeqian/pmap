# pmap

macOS 菜单栏端口映射（SSH 端口转发）管理器。用一个极简的弹出面板，点选主机、开关端口，秒级建立 / 断开本地到远程的端口转发，无需记忆 `ssh -L` 命令。

> 基于 SSH ControlMaster 连接复用：首次连接后，之后的开 / 关端口都走同一条已建立的连接，几乎零延迟。

## 特性

- 菜单栏图标 + 极简下拉面板（无 Dock 图标，纯状态栏应用）
- 主机通过下拉菜单选择，选中即连接；文字与颜色随状态切换（断开 / 连接中 / 连通 / 故障）
- 端口一行一个，小圆点表示状态：**绿 = 通，灰 = 不通，红 = 故障**
  - 单击端口：开启 / 关闭转发
  - 单击行尾删除图标：删除端口（同时停掉该端口的映射服务）
- 万能输入框：`port` 或 `port:port` 一键添加端口
- 自动保存：端口列表、选中主机、端口开启状态全部持久化；重启后自动重连主机并恢复转发
- 退出时自动断开全部映射；重启后恢复退出前的状态
- **绝不修改 `~/.ssh/config`** —— 只读取，不写入

## 系统要求

- macOS 14.0 (Sonoma) 及以上
- Intel (x86_64) 与 Apple Silicon (arm64) 通用二进制
- 本机的 `~/.ssh/config` 里需要有至少一个 Host 条目（主机的认证需已配置好，如密钥登录）

## 安装

### 方式一：下载 DMG（推荐）

从 [Releases](https://github.com/jiyeqian/pmap/releases) 下载最新 `pmap.dmg`，打开后把 `pmap.app` 拖入「应用程序」即可。

### 方式二：从源码构建

```bash
git clone https://github.com/jiyeqian/pmap.git
cd pmap
./build.sh
open pmap.app
```

构建产物 `pmap.app` 是 Intel + Apple Silicon 通用二进制。

> 构建依赖 Xcode 工具链（macOS 自带 CommandLineTools 6.4 缺少 SwiftUI 宏插件，`build.sh` 会自动检测并加载 Xcode 里的 `libSwiftUIMacros.dylib`）。
>
> GitHub Actions 的 release 构建使用 `macos-26` runner（带 macOS 26/27 SDK 的新版 SwiftUI），与本机 macOS 26+ SDK 构建的 UI 渲染效果一致。

### 首次打开的安全提示

pmap 未做 Apple 公证（无付费开发者证书），首次打开时 macOS 会提示 **"pmap" Not Opened**（Apple could not verify...）。这是 Gatekeeper 对所有未经公证应用的统一拦截，不代表软件有问题。两种放行方式任选其一：

**方式 A：系统设置放行（推荐）**

1. 点弹窗的 **Done** 关闭提示
2. 打开 **系统设置 → 隐私与安全性**，拉到底部
3. 找到 "pmap" was blocked... 一行，点 **Open Anyway** → 再点 **Open**

**方式 B：终端一条命令**

```bash
xattr -cr /Applications/pmap.app
```

放行一次后，之后打开不再有任何提示。

## 使用

1. 点击菜单栏的「双向箭头」图标，弹出面板。
2. **选择主机**：点击顶部下拉框，选一台主机即自动连接（连接成功后文字变绿）。
3. **添加端口**：在底部输入框输入 `8000` 或 `8000:80`，回车。有主机已连接时会自动开启转发。
4. **开关端口**：单击端口行切换开启 / 关闭。
5. **删除端口**：单击端口行右侧的 `×` 图标（会同时停掉该端口的映射）。
6. **退出**：面板底部 `Quit`（⌘Q）。退出时会断开全部映射并保存状态。

### 端口格式

| 输入 | 含义 |
|------|------|
| `8000` | 本地 8000 ↔ 远程 8000 |
| `8000:80` | 本地 8000 → 远程 80 |

- 本地端口不能重复（同一本地端口只能映射一次）；远端端口可以重复。
- 本地端口冲突时，输入框会红字提示「本地端口已映射」。

### 状态颜色约定

| 颜色 | 主机 | 端口 |
|------|------|------|
| 绿色 | 已连通 | 转发已开启 |
| 灰色 | 断开 / 未连接 | 未开启 |
| 红色 | 连接故障 | 转发失败 |

## 配置文件

### 程序配置（pmap 自身）

pmap 会在启动时读取、退出时保存以下文件：

```
~/Library/Application Support/Pmap/config.json
```

这是一个 JSON 文件，保存了：

| 字段 | 含义 |
|------|------|
| `host` | 上次选中的主机别名 |
| `adhoc` | 端口列表（每项含 `local` 与 `remote` 端口） |
| `active` | 退出前已开启的本地端口列表（重启后据此恢复转发） |

示例：

```json
{
  "host": "myserver",
  "adhoc": [
    { "local": 8000, "remote": 8000 },
    { "local": 3000, "remote": 80 }
  ],
  "active": [ 8000 ]
}
```

- 重启 pmap 后，会自动连接 `host` 并恢复 `active` 中列出的端口转发。
- 该文件由程序自动管理，无需手动编辑；如需重置，删除该文件后重启即可。

### SSH 配置（只读引用）

pmap **读取**你本机的 `~/.ssh/config` 来获取主机列表（Host 别名），但**绝不会写入或修改**它。

- 主机的地址、端口、用户名、密钥、跳板机（ProxyJump）等参数均由 `~/.ssh/config` 定义。
- 需要新增 / 修改主机时，请直接编辑 `~/.ssh/config`，然后重启 pmap 即可看到变化。
- 主机认证（密钥、密码）沿用你 SSH 的既有配置。

#### 哪些主机会显示

pmap 只显示 `~/.ssh/config` 中满足以下条件的 Host 别名：

| 规则 | 是否显示 | 示例 |
|------|---------|------|
| 不含点号、不含通配符的别名 | ✅ 显示 | `mbp16`、`pi4`、`myserver` |
| 含点号（域名/地址） | ❌ 不显示 | `bitbucket.org`、`github.com` |
| 含通配符（`*` `?` `!`） | ❌ 不显示 | `Host *.example.com` |
| 指向本机（`localhost` / `127.0.0.1` / `::1`） | ❌ 不显示 | `Host localhost` |

> 设计意图：含点的 Host 通常是 Git 托管等域名的访问入口，而非需要开端口隧道的远程主机。
> 若某个含点主机确实需要通过 pmap 管理，给它加一个无点别名即可，例如：
>
> ```
> Host bitbucket
>     HostName altssh.bitbucket.org
>     User git
>     Port 443
>     IdentityFile ~/.ssh/id_ed25519
> ```

### 连接复用（ControlPath）

pmap 使用独立的 ControlPath 目录，不依赖 `~/.ssh/config` 中是否启用了 ControlMaster：

```
~/.ssh/pmap-control/<主机别名>
```

这是 pmap 实现「秒级开关端口」的关键。退出时 pmap 会主动断开这些复用连接（`ssh -O exit`）。

## 隐私与安全

- pmap 是本地工具，不联网、不收集任何数据。
- 不会修改 `~/.ssh/config`，只读取主机列表。
- 端口转发通过本机 `ssh` 完成，复用你既有的 SSH 认证。

## License

本项目当前未指定开源许可证（Private 仓库，仅供个人使用）。
