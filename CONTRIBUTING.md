# 贡献指南

## 提交信息规范

本项目采用 [Conventional Commits](https://www.conventionalcommits.org/) 风格，格式为：

```
<type>(<scope>): <subject>
```

### type（必填，取自白名单）

| type | 用途 |
| --- | --- |
| `feat` | 新增功能 |
| `fix` | 缺陷修复 |
| `refactor` | 重构／结构调整，不改变外部行为 |
| `style` | 纯外观与格式调整（颜色、圆角、间距等） |
| `perf` | 性能优化 |
| `docs` | 文档改动 |
| `test` | 测试相关 |
| `build` | 构建、打包、依赖与版本号 |
| `chore` | 杂项（脚本、杂务） |
| `ci` | CI 配置 |

### scope（可省略）

本项目常用 scope：`ui`（界面）、`icon`（图标）、`lights`（状态灯）、`ports`（端口）、`ssh`（连接与隧道）、`readme`（README）、`build`（构建与发布）。

scope 省略时写成 `chore: 版本号升至 v0.1.4`。

### subject（必填）

- 使用简体中文描述「做了什么」，不使用句号结尾；
- 长度 ≤ 50 字符；
- `:` 后必须有且只有一个空格。

### 示例

```
feat(lights): 三层状态灯规则落地，灰色统一系统灰
fix(icon): App 图标恢复圆角（squircle）
refactor(ui): 面板底部合并为单栏三块（版本号/中英预留/退出）
docs(readme): README 头部改为居中 logo + 徽章 + 链接排版
chore: 版本号升至 v0.1.4
```

反例：

```
随便改一下                     ← 缺少 type
feat(ui) 面板底部改版           ← 缺少冒号
feat(ui): 面板底部改版。         ← subject 结尾多余句号
```

### 本地校验

仓库中已安装 `.git/hooks/commit-msg` 钩子，提交信息不符合上述格式时会被拦截并给出提示。确需跳过时使用 `git commit --no-verify`。

自查命令：

```bash
git log --oneline -20
```

## 版本号与发布

普通构建的默认营销版本在 `build.sh`，Xcode 工程的 `MARKETING_VERSION` 保持一致。`CFBundleShortVersionString` 使用不带 `v` 的三段数字，例如 `0.2.0`；`CFBundleVersion` 使用独立递增的数字构建号，通过 `PMAP_BUILD_NUMBER` 或 Xcode `CURRENT_PROJECT_VERSION` 设置。

Git 标签保留 `v` 前缀，例如 `v0.1.5`；CI 会移除前缀后写入营销版本，并使用工作流运行号作为构建号。界面优先读取 Info.plist。版本升级时同步脚本、Xcode 工程和相关文档。

推送 `v*` 标签会触发 GitHub Release；创建本地标签不等于授权推送或正式商店发布。商店归档使用 `scripts/archive-store.sh`，必须明确配置开发者团队、正式 Bundle ID 和构建号。

## 构建与测试

需要完整 Xcode 工具链。普通版与沙盒版均生成 Intel / Apple Silicon 通用二进制；本地默认临时签名，未公证。

```bash
./test.sh
./build.sh
./scripts/verify-bundle.sh pmap.app

PMAP_SANDBOX=1 ./build.sh
PMAP_REQUIRE_SANDBOX=1 ./scripts/verify-bundle.sh pmap-sandbox.app

PMAP_SANDBOX=0 ./scripts/integration-test.sh
PMAP_SANDBOX=1 ./scripts/integration-test.sh
```

集成测试使用临时密钥与回环 SSH/HTTP 服务，不修改 `~/.ssh`。构建脚本先完成暂存包及签名校验，再替换输出；图标或签名失败会阻断构建，输出包运行中时拒绝替换。

Xcode 构建与商店归档见[商店准备](./docs/APP_STORE.md)，当前候选版与验证边界见[验收记录](./docs/ACCEPTANCE.md)，历史行为变化见[版本差异](./docs/VERSION_COMPARISON.md)。

## 界面与运行策略

- 主面板中英文统一 220 pt；低频操作收在省略号菜单。
- 菜单栏端口灯按端口顺序轮播：红 2 秒、绿 1.5 秒、灰 0.5 秒，状态变化重置计时。
- 可恢复的初次连接失败按 3、6、12、24、30 秒退避；端口失败按 5、10、20、30 秒退避。认证、指纹及禁止转发等错误不自动重试。
- 启动恢复与自动重连固定开启。配置原子保存，`active` 表示期望恢复的端口，不等同于实时连通状态。

## 界面文案与国际化

- 所有界面文案集中在 `Sources/I18n.swift` 的 `L10n` 查表中（`zh` / `en` 两张表，键为 `L10n.Key`）。**不要在视图或逻辑层硬编码中英文案**，一律通过 `store.t(.key)` 或 `L10n.text(.key, lang)` 取值。
- 新增文案时必须同时补齐中英两表；`Tests/I18nTests.swift` 会校验「每个键在两种语言下都有非空条目」，漏译会导致测试失败。
- 带参数的文案用 `{0}`、`{1}` 占位符，中英模板占位符数量与顺序必须一致。
- 错误信息一律以结构化枚举（`Sources/PortError.swift` 的 `PortError`）保存，**不要把渲染好的字符串存进状态**：这样切换语言时已有错误才会即时变成新语言。`PortError.classify` 负责把 OpenSSH 英文原文归类，描述在渲染时翻译。
- 调试与自检输出（`--snapshot` / `--render` / `--list-hosts`、调试窗口标题）保持中文原文，不纳入双语范围。
- 开发期可用 `--lang zh|en` 配合 `--snapshot` / `--render` 渲染指定语言做目检。
