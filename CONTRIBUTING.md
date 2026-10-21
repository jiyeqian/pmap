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

版本号的单一来源是 `build.sh` 中 `Info.plist` 的 `CFBundleVersion` 与 `CFBundleShortVersionString`（两者都写带 `v` 前缀的版本号），`Sources/Pmap.swift` 中 `appVersion` 的兜底默认值也必须同步为相同的 `v` 版本号。

升级版本时这三处要一起改，对应的 Git tag 也使用 `v` 前缀（如 `v0.1.4`）。CI 由 `v*` tag 触发发布流程。

## 构建与测试

```bash
./build.sh    # 编译并打包 pmap.app
./test.sh     # 运行单元测试
./make_icon.sh # 重新生成 App 图标
```

> 注意：`build.sh` 会删除并重建 `pmap.app`。请先退出正在运行的 pmap，否则运行中实例的 bundle 会失效，导致状态栏图标消失。

## 界面文案与国际化

- 所有界面文案集中在 `Sources/I18n.swift` 的 `L10n` 查表中（`zh` / `en` 两张表，键为 `L10n.Key`）。**不要在视图或逻辑层硬编码中英文案**，一律通过 `store.t(.key)` 或 `L10n.text(.key, lang)` 取值。
- 新增文案时必须同时补齐中英两表；`Tests/I18nTests.swift` 会校验「每个键在两种语言下都有非空条目」，漏译会导致测试失败。
- 带参数的文案用 `{0}`、`{1}` 占位符，中英模板占位符数量与顺序必须一致。
- 错误信息一律以结构化枚举（`Sources/PortError.swift` 的 `PortError`）保存，**不要把渲染好的字符串存进状态**：这样切换语言时已有错误才会即时变成新语言。`PortError.classify` 负责把 OpenSSH 英文原文归类，描述在渲染时翻译。
- 调试与自检输出（`--snapshot` / `--render` / `--list-hosts`、调试窗口标题）保持中文原文，不纳入双语范围。
- 开发期可用 `--lang zh|en` 配合 `--snapshot` / `--render` 渲染指定语言做目检。
