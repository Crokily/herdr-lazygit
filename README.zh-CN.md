# herdr-lazygit

[English](README.md)

一个 [herdr](https://herdr.dev) 插件:在窄侧栏 pane 里运行 [lazygit](https://github.com/jesseduffield/lazygit),内置 AI 生成 commit message。一个键打开侧栏,一个键展开成完整 lazygit 布局,一个键用 AI 写好的 message 提交。

![herdr-lazygit 演示](docs/media/demo.gif)

<sub>演示 GIF 由 Fable 5 使用 [promo-gif](https://github.com/Crokily/colys-agent-lab/tree/main/skills/promo-gif) skill 自动录制。</sub>

## 日常工作流

按 `prefix+g`,当前目录旁边打开一条 42 列的 git 侧栏;再按一次关闭。启动器是幂等的,不会开出第二个。

一次典型的提交:

1. **暂存**:侧栏列出所有改动文件,带 M/A/D 状态色。`空格`(或双击)stage 文件——不需要展开;
2. **提交**:按 `C`,commit pane 立即打开,显示后端与模型,AI 读取 staged diff 期间显示进度动画,然后列出 3 条候选 message,下方同时展示选中候选的完整内容、一行改动统计、以及 delta 渲染的完整 staged diff。选一条候选、在输入行编辑它、或直接输入自己的 message,回车提交;
3. **同步**:`p` pull、`P` push、`f` fetch。

日常提交,窄侧栏就够了。想深入查看时——完整 diff 视图、历史、stash、按 `Enter` 逐块 stage——按 `U` 展开成完整 lazygit 布局,再按 `U` 收回。

![U 展开与收起](docs/media/expand.gif)

## 插件的三个键

插件只新增三个键位,其余全部是 lazygit 原生操作(在 lazygit 里按 `?` 查看内置键位表):

| 键 | 动词 | 作用 |
| --- | --- | --- |
| `C` | **Commit** | 打开 AI commit pane:生成、选择或编辑、提交 |
| `U` | **Expand** | 在窄侧栏与完整 lazygit 布局之间切换 |
| `;` | **Settings** | 打开设置页 |

三个键都可以在设置页重映射。鼠标全程可用:单击选中、双击 stage、滚轮滚动。

## 设置页(`;`)

在 lazygit 任意面板按 `;`,侧栏旁边打开设置页(fzf 驱动,键盘鼠标均可):

- **AI 后端**:claude / codex / opencode / gemini,默认按此顺序自动探测第一个已安装的;
- **AI 模型**:按后端分别设置。默认使用各家便宜快速的档位(claude 用 haiku),不会用昂贵的默认模型生成 commit message;
- **AI Prompt**:用 `$EDITOR` 打开 prompt 文件,修改它可以改变生成 message 的语言和格式;
- **键位**:按下新键即可重映射 C / U / ;。与 lazygit 内置键冲突时会被拒绝,并显示被哪个绑定占用;
- **宽度**:侧栏、展开布局、commit pane 的列宽。

改动在 lazygit pane 重新获得焦点时生效——lazygit 在 focus 时热重载配置文件,无需重启。

![设置页](docs/media/settings.png)

## AI 提交的前置条件

安装并登录以下任意一个 CLI:`claude`、`codex`、`opencode`、`gemini`。不需要配置 API key,插件调用 CLI 的非交互模式,使用你已有的登录态。生成失败时 commit pane 显示以 `(` 开头的提示行,包含后端名和错误摘要,按任意键关闭;生成过程中 `Ctrl-C` 取消。

![AI commit pane](docs/media/commit-pane.png)

## 安装

要求 herdr >= 0.7.0,并确保 `bash`、`git`、Python >= 3.7(`python3`)在 `PATH` 上。通过 GitHub 安装时,插件会下载固定版本的私有 lazygit 0.63.0 与 fzf 0.74.0,用仓库内固定的 SHA-256 校验值验证后存入 Herdr 管理的插件 `bin/` 目录。安装过程不会调用 Homebrew、系统包管理器或 `sudo`。构建阶段还需要 `curl` 或 `wget`、`tar`,以及 `sha256sum` 或 `shasum`。

```sh
herdr plugin install crokily/herdr-lazygit

# 本地开发:plugin link 不执行 [[build]],所以先准备私有 runtime
cd /path/to/herdr-lazygit
/bin/sh scripts/install-runtime.sh
herdr plugin link "$PWD"
```

然后在 herdr 的 `config.toml` 里添加快捷键:

```toml
[[keys.command]]              # lazygit:分屏打开
key = "prefix+g"
type = "plugin_action"
command = "herdr-lazygit.open"

[[keys.command]]              # lazygit:独立 tab 打开
key = "prefix+shift+g"
type = "plugin_action"
command = "herdr-lazygit.open-tab"
```

执行 `herdr server reload-config` 后生效。`prefix+g` 的行为:未打开 → 分屏打开;已打开但未聚焦 → 聚焦;已聚焦 → 关闭。

> **注意(herdr 平台行为)**:action 的上下文永远取自 herdr 当前 **UI 聚焦**的 pane,而不是后台进程。它会把 lazygit 开在用户聚焦 pane 旁边、使用该 pane 的 cwd,并聚焦新 pane。只通过前台键位绑定触发这两个 action。

## 细节备查

### 键位细节

- `C` 只读取 **staged** 内容——先 stage 再按。它覆盖了 files 面板内置的「用 git editor 提交」键位;如果需要该功能,在 `lazygit-user.yml` 里重新绑定。每个 tab 同时只有一个 `GitCommit` pane。
- `U` 是全局键位,在 `sidebar` 和 `expanded` 之间切换 `LAYOUT_MODE`。展开宽度默认 110 列,上限为 tab 总宽减 20。重新打开插件时总是从侧栏模式开始。
- `U` 和 `;` 是对 lazygit 0.63.0 全部内置键位做空闲键分析得出的默认值:候选 `Z` 被 `universal.redo` 占用;`Ctrl+S` 和 `O` 分别与过滤菜单、PR 菜单冲突;`U` 和 `;` 在所有面板均无绑定(完整占用矩阵见 [DESIGN.md](DESIGN.md) 附录 A)。选键规则:插件键位不遮蔽 lazygit 常用内置键。`v`(范围选择)和 `V`(cherry-pick 粘贴)因此保持原生。
- 键位持久化在 `$HERDR_PLUGIN_CONFIG_DIR/keys.conf`。

### AI 后端配置文件

设置页写入 `$HERDR_PLUGIN_CONFIG_DIR/ai-backend.conf`(shell 可 source 格式),也可以手动编辑——`custom` 后端必须手动配置:

```sh
# auto | claude | codex | opencode | gemini | custom
AI_BACKEND=auto

# AI_BACKEND=custom 时使用:命令从 stdin 读入 prompt+diff,stdout 输出 message
AI_CUSTOM_CMD=""
```

设置页里的 `detected` 表示 CLI 已安装,不保证已登录或有使用资格。失败提示会包含后端名和一行 stderr 摘要。

### 三层配置

插件通过 `LG_CONFIG_FILE` 加载三层 lazygit 配置,越靠后优先级越高:

1. 插件捆绑的基础层 `lazygit-config.yml`(出厂设置——请勿修改,插件更新会覆盖)
2. 生成层 `$HERDR_PLUGIN_CONFIG_DIR/generated.yml`(由键位与布局模式生成——机器生成,勿手改)
3. 用户覆盖层 `$HERDR_PLUGIN_CONFIG_DIR/lazygit-user.yml`(首次启动自动创建;永远排最后,永远赢)

普通字段按字段覆盖;`customCommands` 跨层累加,同 key + context 时靠后的文件赢,所以覆盖层可以整条替换插件的任何命令。生成层负责随模式变化的 `sidePanelWidth`,并固定 `expandFocusedSidePanel: true` 和 `portraitMode: never`;基础层开启鼠标支持、关闭随机 tip。两层都不设置 Nerd Font(需要图标时在覆盖层加 `gui.nerdFontsVersion: "3"`)。

重映射插件键位:用设置页(存储在 `keys.conf`)。重映射 lazygit 内置键位:在 `lazygit-user.yml` 里加 `keybinding` 段。

### 文件结构

```
herdr-plugin.toml            # 插件 manifest
lazygit-config.yml           # 捆绑的基础配置(出厂层)
DESIGN.md                    # 设计文档:三动词模型、选键规则、三层配置
THIRD_PARTY_NOTICES.md       # 下载的 lazygit/fzf 二进制许可证
bin/                         # 构建生成的私有 lazygit + fzf runtime(不提交)
scripts/
  install-runtime.sh         # 安装时下载并校验私有 runtime
  runtime-versions.sh        # 固定的 lazygit/fzf 版本
  runtime-env.sh             # 用绝对路径解析 runtime 工具
  run-lazygit.sh             # pane 入口:重新生成配置层后 exec lazygit
  open-lazygit.sh            # action:分屏打开(幂等 open/focus/toggle)
  open-lazygit-tab.sh        # action:tab 打开
  ai-commit-msg.sh           # AI commit message 生成 / 后端与模型管理
  open-ai-commit-pane.sh     # Commit handler:打开 GitCommit pane
  ai-commit-pane.sh          # 进度动画 + fzf 候选/预览 UI + git commit
  toggle-expand.sh           # Expand handler:模式、几何、focus-in 热重载
  open-settings-pane.sh      # Settings handler:打开设置 pane
  settings-fzf.sh            # 设置 pane 里的 fzf 循环菜单
  gen-config-layer.sh        # keys.conf -> generated.yml(机器生成层)
  free-keys.py               # 键位占用分析 / 冲突校验
  layout-helper.py           # 经 herdr socket 的绝对 pane 几何
```

用户态数据在 `$HERDR_PLUGIN_CONFIG_DIR`(回退 `~/.config/herdr-lazygit`):

```
keys.conf                    # 插件键位:KEY_COMMIT / KEY_ZOOM / KEY_SETTINGS
panel.conf                   # 各 pane 宽度 + LAYOUT_MODE(sidebar/expanded)
ai-backend.conf              # AI 后端 / 各后端模型
prompt.txt                   # 自定义 AI commit prompt
generated.yml                # 机器生成的 lazygit 配置层——勿手改
lazygit-user.yml             # 你的 lazygit 覆盖层——永远赢
```

设计文档 [DESIGN.md](DESIGN.md) 记录了完整的设计依据:三动词模型、lazygit 负责 git 交互 / herdr 负责窗口管理的分工、选键规则、以及能力边界。
