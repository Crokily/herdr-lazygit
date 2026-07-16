# DESIGN — herdr-lazygit 统一设计思想

> 本文档是插件的"宪法":新增功能、改键位、动配置结构之前,先对照这里。
> 与实现冲突时,以本文档裁决;要推翻本文档,先改本文档再改代码。

## 1. 三动词模型

用户在 lazygit 里只需要记住三个动词,其余一切都是 lazygit 原生键位,插件不抢:

| 动词 | 默认键 | context | handler | 语义 |
| --- | --- | --- | --- | --- |
| **Commit** | `C` | `files` | `open-ai-commit-pane.sh` | 即刻打开 GitCommit pane:显示生成进度 → 选择/编辑 message → 提交 |
| **Expand** | `U`(变量名保留 `KEY_ZOOM` 兼容旧配置) | `global` | `toggle-expand.sh` | 在 sidebar / expanded 两种布局间切换 lazygit 本体 |
| **Settings** | `;`(候选 `<c-s>` > O > `;` > `,`,分析见附录 A) | `global` | `open-settings-pane.sh` | 改插件自己的一切行为:AI 后端/模型/prompt、三动词键位、面板宽度 |

设计推论(为什么旧的 B/m/E/v/V 与对象级 Zoom 全部删除):

- `B`(切后端)、`m`(选模型)、`E`(改 prompt)本质都是 **Settings 动词**伪装成顶层键——
  它们消耗稀缺的键位空间,还会被面板内置键遮蔽(B 在 commits 面板踩过雷)。
  全部收编进设置页。
- `v`/`V` 归还 lazygit(v = 范围选择,V = cherry-pick 粘贴);`KEY_ZOOM` 保留变量名
  兼容已有 keys.conf,用户语义改为 **Expand**。
- 旧 Zoom pane 退役:展开后的 lazygit 原生 diff、commit、stash 浏览与全部原生操作
  已覆盖「把选中内容拿到旁边看」的需求,不再维护三套对象模板与独立 pager 生命周期。

Commit 迁移到独立 pane 不是视觉偏好,而是反馈模型修复:`menuFromCommand` 会在菜单
出现前同步执行 AI 命令,生成耗时 5–10 秒时 lazygit 没有任何进度 UI。GitCommit pane
先出现再后台生成,可立即显示后端/模型、spinner 与 Ctrl-C;生成后同一个 fzf 输入框
既能选候选,也能编辑或自写 message。

任何新功能先问:它属于哪个动词?不属于任何一个 → 大概率不该做(见第 6 节)。

## 2. 职责分界:lazygit = Git 交互本体,herdr = 窗口系统

| | lazygit 负责 | herdr 负责 |
| --- | --- | --- |
| 拥有什么 | git 状态、diff/历史/贮藏浏览、stage/commit/sync 原生交互 | pane 几何、AI commit UI、设置界面 |
| 对外接口 | `customCommands` + focus-in 配置热重载 | `pane split/run/close/send-text` + `layout-helper.py` 直连 socket |
| 我们消费 | files context 的 Commit 入口、global 的 Expand / Settings 入口 | `place-diff` / `set-width` / `set-region-width`(绝对列宽) |

常态有两种布局,状态写在 `panel.conf` 的 `LAYOUT_MODE`:

```
sidebar                                  expanded
┌──────────────────────┬────────┐        ┌──────────────┬──────────────────┐
│       工作区          │lazygit│   U    │    工作区     │ lazygit 本体      │
│                      │ 42 列  │  ⇄     │              │ 默认 110 列       │
└──────────────────────┴────────┘        └──────────────┴──────────────────┘
```

- sidebar 强制 `sidePanelWidth: 0.99`,把 lazygit 挤成 1–5 面板单栏;expanded 恢复
  `0.3333`,原生主视图与全部原生交互重新可见。两种模式都固定
  `portraitMode: never`,避免高 pane 下 auto 布局突变。
- `U` 先改状态并重生成 gui,再 `set-width`,最后向 lazygit 注入 CSI focus-in,
  所以布局与键位在同一次按键内热重载。
- AI Commit / Settings 仍是侧栏右侧的临时宽 pane:显示期间把 lazygit 暂时摆成
  `SIDEBAR_COLS`,退出前恢复触发时的 sidebar/expanded 宽度,随后 `exit` 自动关 pane。
- 同一时刻同类 pane 只有一个(按 label 找旧的先关:`GitCommit` / `GitSettings`)。
- 宽度可配:`SIDEBAR_COLS` / `EXPAND_COLS` / `COMMIT_COLS` / `SETTINGS_COLS`。

一句话:**lazygit 负责 Git 交互,herdr 负责它此刻该占多宽、辅助 UI 开在哪里。**

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
所以 global 键(KEY_ZOOM / KEY_SETTINGS)必须在**全部列表面板**都空闲才能用。

已裁决的键位:

- **`v` / `V` 全部归还 lazygit**(v = 范围选择,V = cherry-pick 粘贴)。旧绑定删除。
- **`C` 保留**(files 面板):遮蔽的是低频的"用 git editor 提交"
  (`commitChangesWithEditor`),语义高度吻合、代价可接受——这是铁律 1 里
  "常用"一词的边界案例,特此记录在案。仍需要原功能的用户:
  在设置页把 Commit 换键,或在 `lazygit-user.yml` 的 keybinding 段给内置动作换键。
- **KEY_ZOOM 默认候选顺序 Z > U > X**(变量名为兼容保留),
  以空闲键分析验证为准。分析结果:Z 被 `universal.redo` 占用,**最终默认 `U`**
  (全面板空闲,见附录 A)。
- **KEY_SETTINGS 不用 S**(见上方踩雷案例),候选顺序 `<c-s>` > O > `;` > `,`,
  同样以空闲键分析为准。分析结果:`<c-s>`、O 均被内置键占用,**最终默认 `;`**
  (全段空闲,见附录 A)。

空闲键分析是**机器活不是人肉活**:`scripts/free-keys.py` 解析 `lazygit --config`
输出的完整默认 keybinding 段(167 个动作全部可重映射,随包 schema/config.json
交叉验证),输出候选键 × 面板的占用矩阵;子命令 `check KEY context...` 供生成层
与设置页改键时实时校验冲突。分析结论回填在附录 A。

## 4. 三层配置模型

```
  ①  lazygit-config.yml            出厂层 — 插件仓库自带,随插件更新覆盖。
      (插件根目录)                  只留不随模式变化的 gui 段;customCommands 已迁出。
            │
            │  LG_CONFIG_FILE 从左到右合并
            ▼
  ②  generated.yml                 生成层 — gen-config-layer.sh 依据 keys.conf
      ($HERDR_PLUGIN_CONFIG_DIR)    与 panel.conf 生成;设置页/布局切换后立即重生成。
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
| `panel.conf` | 设置页 / Expand handler | `SIDEBAR_COLS` / `EXPAND_COLS` / `COMMIT_COLS` / `SETTINGS_COLS` / `LAYOUT_MODE` |
| `ai-backend.conf` | 设置页 | `AI_BACKEND` / `AI_CUSTOM_CMD` / 各后端模型 |
| `prompt.txt` | 设置页($EDITOR) | AI commit 的自定义 prompt |
| `generated.yml` | `gen-config-layer.sh` | 模式对应的 gui 段 + 三动词 customCommands;头部 marker 同时记录 keys 与 layout |
| `lazygit-user.yml` | 用户手写 | 任意 lazygit 配置,永远赢 |

## 5. 热重载生效模型

lazygit 0.63.0 在终端 **focus-in** 时 stat 全部配置文件,发现 mtime 变化即整体
热重载(含 `resetKeybindings` 重建键位表)。herdr 里实测:外部改 YAML + 切走再
切回 pane = 免重启生效。这就是设置页的全部生效机制——**文件系统即总线,没有
IPC,没有信号,没有重启**:

```
设置页改动 / U 切布局
  → 写 keys.conf / panel.conf / ai-backend.conf
  → 立即调 gen-config-layer.sh 重写 generated.yml
  → 用户切回 lazygit pane,或 U handler 注入 CSI focus-in
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
4. 设置页开始想"常驻、状态机、自己画 UI 框架"——它永远只是一个 fzf 循环菜单;
   AI commit pane 也只负责一次生成/编辑/提交生命周期。

判据一句话:**我们只消费 lazygit 的官方出口(customCommands 模板、配置文件、
CLI 输出)和 herdr 的官方出口(CLI、socket RPC)。任何一侧需要非官方通道,
这个功能就不属于本插件。**

---

## 附录 A:空闲键分析(lazygit 0.63.0,2026-07 集成阶段实测)

数据源:`lazygit --config` 打印的完整默认 keybinding 段(185 行 / 11 段),
由 `scripts/free-keys.py` 解析,随包 `schema/config.json` 交叉验证。
键位表随 lazygit 版本漂移——升级后运行 `python3 scripts/free-keys.py`
即可复现下述矩阵,并据此更新本附录。

### 候选键 × 面板占用矩阵

`-` = 该段无内置绑定。subCommits / reflogCommits 与 commits 共用
`keybinding.commits` 段,故并入 commits 列。

| 键 | universal | files | commits(含 subCommits/reflogCommits) | stash | branches |
| --- | --- | --- | --- | --- | --- |
| `Z` | redo | - | - | - | - |
| `U` | - | - | - | - | - |
| `X` | - | - | - | - | - |
| `<c-s>` | confirmInEditor-alt, filteringMenu | - | - | - | - |
| `O` | - | - | - | - | viewPullRequestOptions |
| `;` | - | - | - | - | - |
| `,` | prevPage | - | - | - | - |
| `C` | - | commitChangesWithEditor | cherryPickCopy | - | - |
| `v` | toggleRangeSelect | - | - | - | - |
| `V` | - | - | pasteCommits | - | - |

### 结论

1. **KEY_ZOOM(现为 Expand)最终默认 = `U`**(候选 Z > U > X,context: global):
   - `Z` ✗ —— 被 `universal.redo` 占用。zoom 语义虽最贴切,但铁律 1 优先,淘汰。
   - `U` ✓ —— universal/files/commits/stash/branches 全部零占用,采用。
   - `X` 未用到(亦全空闲,留作用户重映射的天然备选)。
2. **KEY_SETTINGS 最终默认 = `;`**(候选 `<c-s>` > O > `;` > `,`):
   - `<c-s>` ✗ —— 被 `universal.filteringMenu` 与 `universal.confirmInEditor-alt` 占用。
   - `O` ✗ —— 被 `branches.viewPullRequestOptions` 占用(global 键必须全部面板空闲,
     一个面板占用即出局)。
   - `;` ✓ —— 全段零占用,采用。
   - `,` 未用到(被 `universal.prevPage` 占用,即便轮到也会淘汰)。
3. **`C` 保留**:仅遮蔽 `files.commitChangesWithEditor`(已接受的例外,理由见第 3 节)。
   `commits.cherryPickCopy` 虽同为 C,但 KEY_COMMIT 只声明在 `files` context,不受影响。
4. **global 键推论**:KEY_ZOOM / KEY_SETTINGS 都会被面板级同键内置遮蔽,所以设置页
   按 global context 校验;默认 `U` / `;` 全段空闲。KEY_SETTINGS 对手写配置仍保留
   生成层的按需 `<disabled>` 兼容逻辑。
