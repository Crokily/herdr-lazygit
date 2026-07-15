# DESIGN — herdr-lazygit 统一设计思想

> 本文档是插件的"宪法":新增功能、改键位、动配置结构之前,先对照这里。
> 与实现冲突时,以本文档裁决;要推翻本文档,先改本文档再改代码。

## 1. 三动词模型

用户在 lazygit 里只需要记住三个动词,其余一切都是 lazygit 原生键位,插件不抢:

| 动词 | 默认键 | context | handler | 语义 |
| --- | --- | --- | --- | --- |
| **Commit** | `C` | `files` | `ai-commit-msg.sh`(menuFromCommand) | 把 staged 改动变成 commit:AI 读 diff → 弹候选菜单 → 回车提交 |
| **Zoom** | `KEY_ZOOM`(候选 Z > U > X,见附录 A) | `files` / `commits, subCommits, reflogCommits`¹ / `stash` | `show-diff-pane.sh file/commit/stash` | 把当前选中对象放进宽 pane 看清楚:文件 diff / commit 全文 / stash 内容 |
| **Settings** | `KEY_SETTINGS`(候选 `<c-s>` > O > `;` > `,`,见附录 A) | `global` | `open-settings-pane.sh` | 改插件自己的一切行为:AI 后端/模型/prompt、三动词键位、面板宽度 |

¹ reflog 面板的 context 名以集成阶段在临时 repo 实测为准(疑为 `reflogCommits`)。

设计推论(为什么旧的 B/m/E/v/V 全部删除):

- `B`(切后端)、`m`(选模型)、`E`(改 prompt)本质都是 **Settings 动词**伪装成顶层键——
  它们消耗稀缺的键位空间,还会被面板内置键遮蔽(B 在 commits 面板踩过雷)。
  全部收编进设置页。
- `v`/`V`(放大 diff)是 **Zoom 动词**,但键选错了:遮蔽了 lazygit 的高频内置键
  (v = 范围选择,V = cherry-pick 粘贴),违反选键铁律,归还 lazygit,换 `KEY_ZOOM`。

任何新功能先问:它属于哪个动词?不属于任何一个 → 大概率不该做(见第 6 节)。

## 2. 职责分界:lazygit = 数据引擎,herdr = 窗口系统

| | lazygit 负责 | herdr 负责 |
| --- | --- | --- |
| 拥有什么 | git 状态、列表导航、"当前选中了什么" | pane 几何、宽内容展示、设置界面 |
| 对外接口 | customCommands 会话模板(SessionState) | `pane split/run/close` + `layout-helper.py` 直连 socket |
| 我们消费 | `{{.SelectedPath}}`(files)、`{{.SelectedCommit.Hash}}`(commits/subCommits/reflog)、`{{.SelectedStashEntry.Index}}`(stash) | `place-diff` / `set-width` / `set-region-width`(绝对列宽) |

关键事实(实测):SessionState **没有"当前面板"字段**,所以 Zoom 必须按 context
分别声明三条 customCommands(可用逗号合并同模板的 context,如 `'commits, subCommits'`),
不能写一条"全局 Zoom"再在脚本里判断来源。

几何形态(用户拍板,不迁 overlay):Zoom 与 Settings 都是**并排三列**——

```
┌──────────────┬────────┬──────────────────────┐
│   工作区      │ 侧栏    │  宽内容窗             │
│ (用户的活)    │ lazygit │  diff / commit /      │
│              │ 42 列   │  stash / 设置页        │
└──────────────┴────────┴──────────────────────┘
```

- 宽内容窗从工作区借宽度(`layout-helper.py place-diff`),退出前 `set-region-width`
  还原侧栏宽度;pane 内跑 `cmd; exit`,q 退出 pager = pane 消失。
- 同一时刻同类 pane 只有一个(按 label 找旧的先关:`GitDiff` / `GitSettings`)。
- 宽度可配:`panel.conf` 的 `SIDEBAR_COLS` / `DIFF_COLS` / `SETTINGS_COLS`。

一句话:**lazygit 告诉我们"用户选了什么",herdr 决定"在哪里、多大地展示它"。**
两边都只用官方接口,中间没有任何解析/注入类的胶水。

## 3. 选键铁律

用户原则,三条,无例外:

1. **插件键位不得遮蔽 lazygit 常用内置键。**
2. **发生冲突一律换键**(换插件的键,不动 lazygit 的)。
3. **所有插件键都可通过设置页重映射**(持久化在 `keys.conf`)。

支撑铁律的按键优先级事实(源码级实测,记死):

```
同面板 custom  >  同面板内置  >  global custom  >  global 内置
```

推论:`context: 'global'` 的自定义键会被**任何一个面板**的同键内置遮蔽。
案例:global custom `S` 在 files 面板按下弹的是内置 stash 菜单,不是我们的命令。
所以 global 键(KEY_SETTINGS)必须在**全部列表面板**都空闲才能用;
面板级键(KEY_ZOOM)必须在它声明的每个面板(files/commits/subCommits/reflog/stash)都空闲。

已裁决的键位:

- **`v` / `V` 全部归还 lazygit**(v = 范围选择,V = cherry-pick 粘贴)。旧绑定删除。
- **`C` 保留**(files 面板):遮蔽的是低频的"用 git editor 提交"
  (`commitChangesWithEditor`),语义高度吻合、代价可接受——这是铁律 1 里
  "常用"一词的边界案例,特此记录在案。仍需要原功能的用户:
  在设置页把 Commit 换键,或在 `lazygit-user.yml` 的 keybinding 段给内置动作换键。
- **KEY_ZOOM 默认候选顺序 Z > U > X**(Z 有 zoom 语义,最优先),
  以空闲键分析验证为准。
- **KEY_SETTINGS 不用 S**(见上方踩雷案例),候选顺序 `<c-s>` > O > `;` > `,`,
  同样以空闲键分析为准。

空闲键分析是**机器活不是人肉活**:`scripts/free-keys.py` 解析 `lazygit --config`
输出的完整默认 keybinding 段(167 个动作全部可重映射,随包 schema/config.json
交叉验证),输出候选键 × 面板的占用矩阵;子命令 `check KEY context...` 供生成层
与设置页改键时实时校验冲突。分析结论回填在附录 A。

## 4. 三层配置模型

```
  ①  lazygit-config.yml            出厂层 — 插件仓库自带,随插件更新覆盖。
      (插件根目录)                  只留 gui 段;customCommands 已全部迁出。
            │
            │  LG_CONFIG_FILE 从左到右合并
            ▼
  ②  generated.yml                 生成层 — gen-config-layer.sh 依据 keys.conf
      ($HERDR_PLUGIN_CONFIG_DIR)    生成;设置页改键后立即重生成。
                                    文件头标注 machine-generated,勿手改。
            │
            ▼
  ③  lazygit-user.yml              用户层 — 手写,永远排最后 = 永远赢。
      ($HERDR_PLUGIN_CONFIG_DIR)    个性化配置、内置键重映射都写这里。
```

合并语义(实测,决定了分层能否成立):

- 普通字段:后文件按字段覆盖前文件。
- `customCommands` 数组:**跨文件追加**;同 key + context 时后文件赢
  (所以用户层可以整条覆盖生成层的某个键)。
- **文件缺失 = lazygit 启动硬错误**。因此 `run-lazygit.sh` 必须在拼
  `LG_CONFIG_FILE` 之前先调用 `gen-config-layer.sh`(幂等、毫秒级)确保
  ②③ 都存在,再 `exec lazygit`。

各配置文件的分工(全部在 `$HERDR_PLUGIN_CONFIG_DIR`,回退 `~/.config/herdr-lazygit`):

| 文件 | 写入方 | 内容 |
| --- | --- | --- |
| `keys.conf` | 设置页 | **仅**三动词的键:`KEY_COMMIT` / `KEY_ZOOM` / `KEY_SETTINGS`(shell 可 source;缺失 = 默认值)。内置键重映射**不进**这个文件——那是用户层 `lazygit-user.yml` 的事 |
| `panel.conf` | 设置页 | `SIDEBAR_COLS` / `DIFF_COLS` / `SETTINGS_COLS` |
| `ai-backend.conf` | 设置页 | `AI_BACKEND` / `AI_CUSTOM_CMD` / 各后端模型 |
| `prompt.txt` | 设置页($EDITOR) | AI commit 的自定义 prompt |
| `generated.yml` | `gen-config-layer.sh` | 三动词的 customCommands;仅当所选键与某面板内置键冲突时按需 `<disabled>`(正常情况下空闲键分析已保证无冲突,此段应为空) |
| `lazygit-user.yml` | 用户手写 | 任意 lazygit 配置,永远赢 |

## 5. 热重载生效模型

lazygit 0.63.0 在终端 **focus-in** 时 stat 全部配置文件,发现 mtime 变化即整体
热重载(含 `resetKeybindings` 重建键位表)。herdr 里实测:外部改 YAML + 切走再
切回 pane = 免重启生效。这就是设置页的全部生效机制——**文件系统即总线,没有
IPC,没有信号,没有重启**:

```
设置页改动
  → 写 keys.conf / panel.conf / ai-backend.conf
  → 立即调 gen-config-layer.sh 重写 generated.yml
  → 用户切回 lazygit pane(focus-in)
  → lazygit stat 到变化,热重载
  → 新键位/配置生效
```

两个配套约定:

- 设置页界面顶部常驻提示"改动在切回 lazygit 时自动生效(热重载)",
  管理用户预期。
- `run-lazygit.sh` 在 `exec` 前也跑一遍 gen(幂等),保证冷启动与热重载
  看到的是同一份生成层——生成逻辑只有一个入口,不存在两套真相。

## 6. 战略边界与停手信号

**不做清单**(lazygit 路线不可达,做了就是伪集成):

- hover 悬停交互——lazygit 没有 hover 事件模型。
- 自定义鼠标语义(拖拽、右键菜单、点击某行触发插件逻辑)——鼠标事件由
  lazygit 内部消费,customCommands 挂不上钩。
- 画布内自绘 commit graph / 任何图形叠加——我们不拥有 lazygit 的渲染循环。

**停手信号**(出现任何一条,立即停手,不找 workaround):

1. 某功能需要**抓屏解析 lazygit 的界面内容**才能拿到状态——这是最明确的
   停手信号。抓屏 = 脆弱的伪集成,lazygit 一升级就碎。
2. SessionState 模板给不到的数据。模板字段就是插件能力的天花板,
   缺字段去上游提 issue,不在本地绕。
3. 需要 fork / patch lazygit 才能实现。
4. 设置页开始想"常驻、状态机、自己画 UI 框架"——它永远只是一个 fzf 循环菜单。

判据一句话:**我们只消费 lazygit 的官方出口(customCommands 模板、配置文件、
CLI 输出)和 herdr 的官方出口(CLI、socket RPC)。任何一侧需要非官方通道,
这个功能就不属于本插件。**

---

## 附录 A:空闲键分析(集成阶段回填)

> **占位**:本附录由集成阶段运行 `scripts/free-keys.py` 后回填。
> 数据源:`lazygit --config` 打印的完整默认 keybinding 段 + 随包
> `schema/config.json` 交叉验证。
>
> 回填内容必须包含:
>
> 1. 候选键 × 面板(universal / files / commits / subCommits / reflog /
>    stash / branches)的占用矩阵;
> 2. `KEY_ZOOM` 最终默认值,及各候选(Z > U > X)的采用/淘汰理由;
> 3. `KEY_SETTINGS` 最终默认值,及各候选(`<c-s>` > O > `;` > `,`)的
>    采用/淘汰理由;
> 4. reflog 面板 context 名的实测结论(`reflogCommits`?);
> 5. 分析所用的 lazygit 版本号与日期——键位表随版本漂移,lazygit 升级后
>    需复跑 `free-keys.py` 并更新本附录。
