# herdr-lazygit

[English](README.md)

**一个键,召唤出贴在你工作区旁边的 git 侧边栏。** 它把 [lazygit](https://github.com/jesseduffield/lazygit) 装进 [herdr](https://herdr.dev) 的窗口系统:平时是一条 42 列的极简单栏,一个键展开完整 lazygit,AI commit pane 则在生成开始前就立刻出现。

## 用起来是什么样

按 `prefix+g`,当前目录旁边滑出一条窄窄的 git 侧栏(再按一次收起,永远不会开出第二个)。日常提交代码的完整动线:

1. **展开看改动**:侧栏里列着所有改动文件,带 M/A/D 状态色;先按 `U`,侧栏展开成完整 lazygit,原生 diff、历史、stash 与命令视图全部可用;
2. **挑要提交的**:`空格`(或双击)stage 文件;展开后按 `Enter` 进入选中文件,就能用 lazygit 原生界面逐块 stage;
3. **提交**:按 `C`,AI commit pane 立刻出现,先显示后端/模型与生成动画;候选出来后可以直接选、在输入框编辑,或自己写 message,回车提交;
4. **同步**:`p` pull、`P` push、`f` fetch,一个键一个动作。

想回到极简侧栏时再按一次 `U`。**`U` 现在表示「展开/收起 lazygit 本体」**——展开以后所有 lazygit 原生操作都正常可用,不再用插件专属查看器替换它们。

### 三个键就是全部

插件只新增三个键,一个动词一个键,其余全是 lazygit 原生操作(内置键位随时按 `?` 查):

| 键 | 动词 | 作用 |
| --- | --- | --- |
| `C` | **Commit** | 立即开 pane → AI 生成 → 选择/编辑/自写 → 提交 |
| `U` | **Expand 展开** | 在极简侧栏与完整 lazygit 布局之间切换 |
| `;` | **Settings** | 打开设置页,下面所有可调项都在里面 |

三个键都可以改(见下),鼠标也全程可用:单击选中、双击 stage、滚轮滚动。

### 设置页(`;`)

在 lazygit 任意面板按 `;`,侧栏旁边弹出设置页(fzf 驱动,键盘鼠标均可):

- **AI 后端**:claude / codex / opencode / gemini,谁装了用谁(默认 auto 自动探测);
- **AI 模型**:按后端分别设置——默认刻意用便宜快的档(claude 用 haiku),不会烧你 CLI 里配的贵档模型;
- **AI Prompt**:用 `$EDITOR` 打开编辑,想要中文 message、加 emoji、改格式都在这;
- **键位**:C / U / ; 三个键现场重映射,按下新键即可——如果撞上 lazygit 内置键会告诉你被谁占了并拒绝;
- **宽度**:侧栏、展开后的 lazygit、AI 提交窗列宽。

改完**切回 lazygit 的瞬间生效**——lazygit 在拿到焦点时热重载配置,不用重启。

### AI 提交需要什么

装了任意一个 AI CLI 并登录即可:`claude`、`codex`、`opencode`、`gemini`。不用配 API key——走的是你 CLI 本身的登录态。生成失败时 commit pane 会显示带原因的提示行(以 `(` 开头),按任意键关闭;生成过程中可按 `Ctrl-C` 终止后端进程。

## 安装

前置要求:herdr >= 0.7.0;`lazygit` 与 `fzf`(设置页和 AI commit pane 依赖)会在安装插件时自动检测,缺失时通过 Homebrew 安装。

```sh
# 从 GitHub 安装(herdr 接受 <owner>/<repo>[/subdir] 短格式,可选 --ref 指定分支/标签)
herdr plugin install <owner>/<repo>

# 或者本地开发时软链
herdr plugin link /path/to/herdr-lazygit
```

然后在 herdr 的 `config.toml` 中手动加快捷键:

```toml
[[keys.command]]              # lazygit:分屏打开
key = "prefix+g"
type = "shell"
command = "herdr plugin action invoke open --plugin herdr-lazygit"

[[keys.command]]              # lazygit:独立 tab 打开
key = "prefix+shift+g"
type = "shell"
command = "herdr plugin action invoke open-tab --plugin herdr-lazygit"
```

`herdr server reload-config` 后即可使用。`prefix+g` 的行为:未打开 → 分屏打开;已打开但未聚焦 → 聚焦;已聚焦 → 收起。

> **注意(herdr 平台行为)**:action 的上下文永远取自 herdr 当前 **UI 聚焦**的 pane,而不是发起调用的进程。如果从后台 pane 或脚本里执行 `herdr plugin action invoke …`,lazygit 会开在用户当前聚焦的 tab 里、紧挨其聚焦 pane,cwd 也取自那个 pane,并且会夺走焦点。请只通过前台键位绑定触发这两个 action,避免程序化/后台调用。

## 细节备查

### 键位细节

- `C` 只读取 **staged** 的内容——先 stage 再按;它覆盖了 files 面板低频的内置键「用 git editor 提交」(想找回可在 `lazygit-user.yml` 里重绑)。每个 tab 同时只会有一个 `GitCommit` pane。
- `U` 是全局键,把 `LAYOUT_MODE` 在 `sidebar` / `expanded` 间切换。展开宽度默认 110 列,最多占 tab 总宽减 20 列;收起回到配置的 42 列。关掉插件再打开永远从侧栏模式开始。
- `U` 与 `;` 是**空闲键分析**对 lazygit 0.63.0 全部内置键位算出来的默认值:候选 `Z` 被 `universal.redo` 占用,`Ctrl+S` / `O` 分别撞上过滤菜单和 PR 菜单,而 `U` 和 `;` 在所有面板零占用(完整占用矩阵见 [DESIGN.md](DESIGN.md) 附录 A)。选键铁律:**插件键不遮蔽 lazygit 常用内置键**——所以 `v`(范围选择)和 `V`(cherry-pick 粘贴)保持原生。
- 键位持久化在 `$HERDR_PLUGIN_CONFIG_DIR/keys.conf`。

### AI 后端配置文件

设置页之外也可以手动编辑 `$HERDR_PLUGIN_CONFIG_DIR/ai-backend.conf`(shell 可 source 格式)——比如 `custom` 后端必须手配:

```sh
# auto | claude | codex | opencode | gemini | custom
AI_BACKEND=auto

# AI_BACKEND=custom 时使用:命令从 stdin 读入 prompt+diff,stdout 输出 message
AI_CUSTOM_CMD=""
```

`detected` 只代表 CLI 已安装,不保证已登录/有使用资格;失败提示会带上后端名和一行 stderr 摘要(例如 gemini 的 `IneligibleTierError`)。

### 三层配置

插件通过 `LG_CONFIG_FILE` 加载三层 lazygit 配置(越靠后越优先):

1. 插件捆绑的基础层 `lazygit-config.yml`(出厂设置——请勿修改,插件更新会覆盖)
2. 生成层 `$HERDR_PLUGIN_CONFIG_DIR/generated.yml`(由键位与布局模式生成——机器生成,勿手改)
3. 用户覆盖层 `$HERDR_PLUGIN_CONFIG_DIR/lazygit-user.yml`(首次启动自动创建;永远排最后 = 永远赢)

普通字段按字段覆盖;`customCommands` 跨层追加,同 key + context 时靠后的文件赢——所以你可以在覆盖层整条替换插件的任何命令。生成层负责随模式变化的 `sidePanelWidth`,并固定 `expandFocusedSidePanel: true` / `portraitMode: never`;基础层只开鼠标、关随机 tip。两层都不假设你装了 Nerd Font(想要图标可在覆盖层里自行设置 `gui.nerdFontsVersion: "3"`)。

重映射**插件**键位:用设置页(存在 `keys.conf`)。重映射 **lazygit 内置**键位:在 `lazygit-user.yml` 里加 `keybinding` 段。

### 文件结构

```
herdr-plugin.toml            # 插件 manifest
lazygit-config.yml           # 捆绑的基础配置(出厂层)
DESIGN.md                    # 设计文档:三动词模型、选键铁律、三层配置
scripts/
  ensure-lazygit.sh          # 安装时检测/安装 lazygit
  ensure-fzf.sh              # 安装时检测/安装 fzf(设置页 + commit UI)
  run-lazygit.sh             # pane 入口:重新生成配置层后 exec lazygit
  open-lazygit.sh            # action:分屏打开(幂等 open/focus/toggle)
  open-lazygit-tab.sh        # action:tab 打开
  ai-commit-msg.sh           # AI commit message 生成 / 后端与模型管理
  open-ai-commit-pane.sh     # Commit handler:打开/还原 GitCommit pane
  ai-commit-pane.sh          # spinner + fzf message 编辑 + git commit UI
  toggle-expand.sh           # Expand handler:模式、几何与 focus-in 热重载
  open-settings-pane.sh      # 设置 handler:打开设置 pane
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

设计思想(三动词模型、lazygit=Git 交互本体 / herdr=窗口系统、选键铁律、能力边界)完整版见 [DESIGN.md](DESIGN.md)。
