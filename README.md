# herdr-lazygit

在 [herdr](https://herdr.dev) 里一键打开 [lazygit](https://github.com/jesseduffield/lazygit) 的插件,并内置 AI 生成 commit message 的自定义命令。

- 分屏或独立 tab 打开 lazygit,自动定位到当前聚焦 pane 的目录
- 幂等启动:重复触发时自动 聚焦 / 收起,不会开出一堆重复 pane
- 按 `C` 让 AI 读取 staged diff,生成 3 个 conventional commit 候选,选一个直接提交
- 按 `B` 在多个 AI CLI 后端(claude / codex / opencode / gemini)之间切换

## 安装

前置要求:herdr >= 0.7.0;lazygit 会在安装插件时自动检测,缺失时通过 Homebrew 安装。

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

前两个是本插件新增的自定义命令,其余是 lazygit 自带常用键位(完整列表在 lazygit 里按 `?` 查看):

| 键 | 面板 | 作用 |
| --- | --- | --- |
| `C` | 文件 | **AI 生成 commit message**:读取 staged diff,弹出候选菜单,回车即提交(覆盖了 files 面板默认的「用 git editor 提交」) |
| `B` | 全局* | **切换 AI 后端**:列出已检测到的 AI CLI,选中即生效 |
| `空格` | 文件 | stage / unstage 当前文件 |
| `d` | 文件 | 丢弃当前文件的改动 |
| `o` | 文件 | 用系统默认程序打开文件 |
| `e` | 文件 | 用编辑器打开文件 |
| `f` | 文件 | fetch |
| `p` | 全局 | pull |
| `P` | 全局 | push |
| `z` | 全局 | 撤销上一步操作(基于 reflog) |
| `?` | 全局 | 打开键位帮助菜单 |

\* `B` 的「全局」有一个例外:lazygit 中**面板级默认键位优先于 global 自定义命令**。在 commits 面板按 `B` 触发的是 lazygit 默认的「标记 rebase base commit」(有实际副作用,commit 行会出现 ↑↑↑ 标记,可再按一次 `B` 选 Reset 取消),不会弹出 AI 后端菜单。请在 files 等没有 `B` 默认键位的面板使用。同理,`C` 是对 files 面板默认键位(用 git editor 提交)的覆盖;如仍需要该功能,可在用户覆盖层给它绑定其他键。

### 使用 `C`(AI commit)的注意事项

- 先用 `空格` stage 好要提交的文件,再按 `C`。
- 候选菜单弹出前会调用 AI CLI,可能需要几秒钟。
- 如果没有 staged 改动、没有可用的 AI 后端、或生成超时,菜单里会显示一条以 `(` 开头的中文提示行;选中这类提示行**不会**真的执行 commit,只会把提示回显到 command log,可放心回车关闭。
- 生成的 message 为 conventional commit 格式(`feat:` / `fix:` / `chore:` …),英文,单行。

## AI 后端配置

`C` 命令依赖任意一个已安装的 AI CLI:`claude`、`codex`、`opencode`、`gemini`。

- 默认 `auto` 模式,按 `claude > codex > opencode > gemini` 的顺序自动探测第一个可用的。
- 在 lazygit 里按 `B` 可以查看各后端状态(`detected` / `missing` / `current`)并切换。`detected` 只代表 CLI 已安装,不保证已登录/有使用资格;若生成失败,提示行会带上后端名和一行 stderr 摘要(例如 gemini 的 `IneligibleTierError`),按提示处理登录问题或按 `B` 换后端。
- 配置持久化在 `$HERDR_PLUGIN_CONFIG_DIR/ai-backend.conf`(shell 可 source 格式),也可以手动编辑:

```sh
# auto | claude | codex | opencode | gemini | custom
AI_BACKEND=auto

# AI_BACKEND=custom 时使用:命令从 stdin 读入 prompt+diff,stdout 输出 message
AI_CUSTOM_CMD=""
```

## 自定义 lazygit 配置

插件通过 `LG_CONFIG_FILE` 加载两层配置(后者覆盖前者):

1. 插件捆绑的基础层 `lazygit-config.yml`(请勿直接修改,插件更新会覆盖)
2. 用户覆盖层 `$HERDR_PLUGIN_CONFIG_DIR/lazygit-user.yml`(首次启动自动创建,个性化配置写这里)

基础层刻意保持克制:只开启了鼠标支持、关闭随机 tip、添加 `C` / `B` 两个自定义命令,不做其他键位改动,也不假设你装了 Nerd Font(想要图标可在覆盖层里自行设置 `gui.nerdFontsVersion: "3"`)。注意 `C` 会覆盖 files 面板默认的「用 git editor 提交」;`B` 在有同名默认键位的面板(如 commits)会被默认键位遮蔽,详见上文键位表说明。

## 文件结构

```
herdr-plugin.toml            # 插件 manifest
lazygit-config.yml           # 捆绑的 lazygit 配置(customCommands 在这里)
scripts/
  ensure-lazygit.sh          # 安装时检测/安装 lazygit
  run-lazygit.sh             # pane 入口:组装配置后 exec lazygit
  open-lazygit.sh            # action:分屏打开(幂等 open/focus/toggle)
  open-lazygit-tab.sh        # action:tab 打开
  ai-commit-msg.sh           # AI commit message 生成 / 后端管理
```
