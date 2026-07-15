# herdr-lazygit

[English](README.md)

在 [herdr](https://herdr.dev) 里一键打开 [lazygit](https://github.com/jesseduffield/lazygit) 的插件,并内置 AI 生成 commit message 的自定义命令。

- 分屏或独立 tab 打开 lazygit,自动定位到当前聚焦 pane 的目录
- 幂等启动:重复触发时自动 聚焦 / 收起,不会开出一堆重复 pane
- 按 `C` 让 AI 读取 staged diff,生成 3 个 conventional commit 候选,选一个直接提交
- 按 `KEY_ZOOM` 把选中的文件 / commit / stash 条目放大到一个宽 herdr pane 里查看
- 按 `KEY_SETTINGS` 打开插件设置页(AI 后端 / 模型 / prompt、键位重映射、面板宽度)

设计思想(三动词模型、选键铁律、三层配置)见 [DESIGN.md](DESIGN.md)。

## 安装

前置要求:herdr >= 0.7.0;`lazygit` 与 `fzf`(设置页依赖)会在安装插件时自动检测,缺失时通过 Homebrew 安装。

```sh
# 从 GitHub 安装(herdr 接受 <owner>/<repo>[/subdir] 短格式,可选 --ref 指定分支/标签)
herdr plugin install <owner>/<repo>

# 或者本地开发时软链
herdr plugin link /path/to/herdr-lazygit
```

推荐在 herdr 的 `config.toml` 中加一个快捷键(注意:请自己手动加,格式如下):

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

之后 `prefix+g` 的行为:未打开 → 分屏打开;已打开但未聚焦 → 聚焦;已聚焦 → 收起。

> **注意(herdr 平台行为)**:action 的上下文永远取自 herdr 当前 **UI 聚焦**的 pane,而不是发起调用的进程。如果从后台 pane 或脚本里执行 `herdr plugin action invoke …`,lazygit 会开在用户当前聚焦的 tab 里、紧挨其聚焦 pane,cwd 也取自那个 pane,并且会夺走焦点。请只通过前台键位绑定触发这两个 action,避免程序化/后台调用。

## 键位速查

插件只新增三个键——一个动词一个键;其余全部是 lazygit 原生键位(完整列表在 lazygit 里按 `?` 查看):

| 键 | 面板 | 作用 |
| --- | --- | --- |
| `C` | 文件 | **AI 生成 commit message**:读取 staged diff,弹出候选菜单,回车即提交(覆盖了 files 面板低频的默认键「用 git editor 提交」) |
| `KEY_ZOOM`\* | 文件 / 提交 / 贮藏 | **放大**:把选中文件的 diff、选中 commit、或选中 stash 条目放进一个宽 herdr pane |
| `KEY_SETTINGS`\* | 全局 | **设置**:打开插件设置页 |
| `空格` | 文件 | stage / unstage 当前文件 |
| `d` | 文件 | 丢弃当前文件的改动 |
| `v` | 文件/列表 | 范围选择(lazygit 内置) |
| `V` | 提交 | 粘贴 cherry-pick 的 commit(lazygit 内置) |
| `o` | 文件 | 用系统默认程序打开文件 |
| `e` | 文件 | 用编辑器打开文件 |
| `f` | 文件 | fetch |
| `p` | 全局 | pull |
| `P` | 全局 | push |
| `z` | 全局 | 撤销上一步操作(基于 reflog) |
| `?` | 全局 | 打开键位帮助菜单 |

\* `KEY_ZOOM` / `KEY_SETTINGS` 是占位符——最终默认键由集成阶段的空闲键分析确定(放大键候选顺序 `Z` > `U` > `X`;设置键候选顺序 `Ctrl+S` > `O` > `;` > `,`,见 DESIGN.md 附录 A),届时回填本表。三个插件键都可以在设置页里重映射,持久化在 `$HERDR_PLUGIN_CONFIG_DIR/keys.conf`。

### 使用 `C`(AI commit)的注意事项

- 先用 `空格` stage 好要提交的文件,再按 `C`。
- 候选菜单弹出前会调用 AI CLI,可能需要几秒钟。
- 如果没有 staged 改动、没有可用的 AI 后端、或生成超时,菜单里会显示一条以 `(` 开头的中文提示行;选中这类提示行**不会**真的执行 commit,只会把提示回显到 command log,可放心回车关闭。
- 生成的 message 为 conventional commit 格式(`feat:` / `fix:` / `chore:` …),英文,单行。
- AI 后端、模型、prompt 都在设置页(`KEY_SETTINGS`)里配置。

### 使用 `KEY_ZOOM`(放大)

放大会在 lazygit 侧栏右侧打开一个宽 pane 展示选中对象,装了 [delta](https://github.com/dandavison/delta) 时用 delta 渲染(否则用 `less`)。按 `q` 关闭 pane,侧栏自动恢复到配置宽度。同一时刻只有一个放大 pane。

- **files 面板**:选中文件的 diff(staged + unstaged;未跟踪文件对 `/dev/null` 做 diff)
- **commits / sub-commits / reflog 面板**:选中 commit 的 `git show`
- **stash 面板**:选中 stash 条目的补丁内容

### 使用 `KEY_SETTINGS`(设置页)

在 lazygit 任意面板按 `KEY_SETTINGS`,侧栏旁边会打开一个 fzf 驱动的设置页。依赖 `fzf`(插件安装步骤会自动装;缺失时设置页会打印 `brew install fzf` 指引)。

- 菜单项:AI 后端 / AI 模型 / AI prompt(`$EDITOR`)/ 键位:Commit / 键位:Zoom / 键位:Settings / 侧栏宽度 / 放大窗宽度
- preview 列显示每项的当前值;回车(或双击)进入修改;`Esc`/`q` 退出
- 改键位时会提示「按下新键」,若与 lazygit 内置键冲突会显示占用方并拒绝
- 改动立即写入配置,**切回 lazygit pane 的瞬间生效**——lazygit 在获得焦点时热重载配置文件,无需重启

## AI 后端配置

`C` 命令依赖任意一个已安装的 AI CLI:`claude`、`codex`、`opencode`、`gemini`。

- 默认 `auto` 模式,按 `claude > codex > opencode > gemini` 的顺序自动探测第一个可用的。
- 后端 / 模型都在设置页里切换。`detected` 只代表 CLI 已安装,不保证已登录/有使用资格;若生成失败,提示行会带上后端名和一行 stderr 摘要(例如 gemini 的 `IneligibleTierError`),按提示处理登录问题或换后端。
- 配置持久化在 `$HERDR_PLUGIN_CONFIG_DIR/ai-backend.conf`(shell 可 source 格式),也可以手动编辑——比如 `custom` 后端需要手动配置 `AI_CUSTOM_CMD`:

```sh
# auto | claude | codex | opencode | gemini | custom
AI_BACKEND=auto

# AI_BACKEND=custom 时使用:命令从 stdin 读入 prompt+diff,stdout 输出 message
AI_CUSTOM_CMD=""
```

## 自定义 lazygit 配置

插件通过 `LG_CONFIG_FILE` 加载三层配置(越靠后越优先):

1. 插件捆绑的基础层 `lazygit-config.yml`(出厂设置——请勿修改,插件更新会覆盖)
2. 生成层 `$HERDR_PLUGIN_CONFIG_DIR/generated.yml`(设置页/生成器写入——机器生成,勿手改)
3. 用户覆盖层 `$HERDR_PLUGIN_CONFIG_DIR/lazygit-user.yml`(首次启动自动创建;永远排最后 = 永远赢)

普通字段按字段覆盖;`customCommands` 跨层追加,同 key + context 时靠后的文件赢——所以你可以在覆盖层整条替换插件的任何命令。基础层刻意保持克制(只开鼠标支持、关随机 tip),也不假设你装了 Nerd Font(想要图标可在覆盖层里自行设置 `gui.nerdFontsVersion: "3"`)。

重映射**插件**键位:用设置页(存在 `keys.conf`)。重映射 **lazygit 内置**键位(例如想把被 `C` 覆盖的「用 git editor 提交」绑回某个键):在 `lazygit-user.yml` 里加 `keybinding` 段。

## 文件结构

```
herdr-plugin.toml            # 插件 manifest
lazygit-config.yml           # 捆绑的基础配置(出厂层)
DESIGN.md                    # 设计文档:三动词模型、选键铁律、三层配置
scripts/
  ensure-lazygit.sh          # 安装时检测/安装 lazygit
  ensure-fzf.sh              # 安装时检测/安装 fzf(设置页依赖)
  run-lazygit.sh             # pane 入口:重新生成配置层后 exec lazygit
  open-lazygit.sh            # action:分屏打开(幂等 open/focus/toggle)
  open-lazygit-tab.sh        # action:tab 打开
  ai-commit-msg.sh           # AI commit message 生成 / 后端与模型管理
  show-diff-pane.sh          # 放大 handler:文件 / commit / stash 的宽 pane
  open-settings-pane.sh      # 设置 handler:打开设置 pane
  settings-fzf.sh            # 设置 pane 里的 fzf 循环菜单
  gen-config-layer.sh        # keys.conf -> generated.yml(机器生成层)
  free-keys.py               # 键位占用分析 / 冲突校验
  layout-helper.py           # 经 herdr socket 的绝对 pane 几何
```

用户态数据在 `$HERDR_PLUGIN_CONFIG_DIR`(回退 `~/.config/herdr-lazygit`):

```
keys.conf                    # 插件键位:KEY_COMMIT / KEY_ZOOM / KEY_SETTINGS
panel.conf                   # 宽度:SIDEBAR_COLS / DIFF_COLS / SETTINGS_COLS
ai-backend.conf              # AI 后端 / 各后端模型
prompt.txt                   # 自定义 AI commit prompt
generated.yml                # 机器生成的 lazygit 配置层——勿手改
lazygit-user.yml             # 你的 lazygit 覆盖层——永远赢
```
