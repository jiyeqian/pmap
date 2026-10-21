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
