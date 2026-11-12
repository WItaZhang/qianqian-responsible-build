# qianqian-responsible-build

一套用 agent 开发软件的 Claude Code 配置。代码由 agent 写，算不算做完由它没法糊弄过去的检查来判定。

[English](README.md)

```
/spec 加涨幅报警               问一两个问题，给一页 spec，你回"可以"
/build                        写测试 → 锁住 → 实现 → 独立审查 → 交付报告
解锁、提交、/retro             这次犯的错，变成下次的规矩
```

## 为什么做这个

coding agent 反复出现三类问题：理解错你的意思，改得比你要的多，没做完却说做完了。把 prompt 写得更好，对前两类有帮助，对第三类几乎没用，因为干活的模型和告诉你"做完了"的是同一个模型。

所以每类问题各设一道关，放在最难绕过的位置：

| 问题 | 关卡 | 由谁把关 |
|---|---|---|
| 理解错意图 | `/spec`：验收例子和摆在明面上的默认假设，写代码之前由你确认 | 你 |
| 改得太多 | spec 里写明范围和"这次不做"；审查员专门检查越界改动 | 另一个模型，然后是你 |
| 说做完了其实没有 | 实现之前锁住测试；agent 每次想结束，停止钩子都重跑一遍测试 | 代码 |

## 一个功能怎么做出来

**1. `/spec`。** agent 先读相关代码，复述现在的逻辑，然后最多问 5 个问题，尽量是选择题并标出推荐项。一个问题要同时满足三条才问：答案会改变做法，代码里查不到，猜错代价大。其余的都写成"默认假设"，你划掉不同意的就行。最后得到的 spec 一屏能看完：目标、风险档、范围、关键决定、验收例子、默认假设、变更记录。

**2. 新开一个对话，输入 `/build`。** agent 先确认测试命令本身能跑，再把验收例子写成测试，确认新测试会失败，而且失败原因是功能还没实现。接下来：

- 低风险：直接锁住测试，往下做。
- 中、高风险：停下来给你看一张对照表，spec 的每一条对应哪个测试。你回"可以"它才锁。

然后它写实现，直到项目的 `.claude/verify.sh` 通过，再让只读的审查员对照 spec 审这次改动，最后交一份固定格式的报告：测试输出、审查结论、改了哪些文件、测试替 spec 做了哪些解释，以及按风险档你该重点看什么。

**3. 你解锁、提交，再跑 `/retro`。** 一个错第一次出现，写进项目 `CLAUDE.md`；再出现，说明文字管不住，就升级成测试、lint 规则，或者写进 `verify.sh`。

修 bug 不用写 spec：先写一个能复现的失败测试，锁住，再修。琐碎改动什么都不用走。

**新项目**走 `idea-kickoff`：一轮把问题列全，接着生成 10–20 个样例给你审，再出一份方案，把工作拆成模块、按依赖分成几波。主会话担任编排者：先定接口，给每个模块开一个 git worktree、分给一个 agent，合并之前自己重跑每个模块的测试。各模块按 `/build` 的方式开发，但写完测试不停下来等你，因为这些测试来自你审过的样例。

## 设计取舍

下面这些决定，放到设计评审上我都能讲清理由。

### "做完了"由 harness 检查，不由模型自己说

测试通过和代码正确是两回事。METR 让人审查 Claude 3.7 Sonnet 在真实 issue 上提交的 PR，结论是 "none of them are mergeable as-is"，通过了测试的那些也一样（[METR](https://metr.org/blog/2025-08-12-research-update-towards-reconciling-slowdown-with-time-horizons/)）。Anthropic 观察到，让 agent 评价自己的产出时，它往往 "confidently praising the work—even when, to a human observer, the quality is obviously mediocre"（[Anthropic](https://www.anthropic.com/engineering/harness-design-long-running-apps)）。所以"完成"由两个不是实现者的角色来判定：一个是重跑 `verify.sh` 的停止钩子，一个是从没看过实现过程的审查员。

### 不能有例外的规矩写进钩子，不写进 prompt

Anthropic 的官方文档说，`CLAUDE.md` 里某条规矩如果 agent 总是不听，往往因为它是 "a rule that can't have exceptions, in which case it belongs in a hook"（[文档](https://code.claude.com/docs/en/best-practices)）。我在测试这套配置时亲眼看到了原因：审查员的 prompt 写明了只读，可父 agent 让它跑 `touch` 时，它照样去执行了，是钩子把它拦下的。在 prompt 里要求它只读，它并不会因此就只读；真正起作用的是钩子。这也是每一道关卡的分界线：怎么实现由模型决定，什么不能碰由代码强制。

### 在"出题"和"答题"之间把测试锁住

ImpossibleBench 故意给 agent 测试和需求互相矛盾的任务：GPT-5 有 54% 走了捷径，Claude Opus 4.1 是 50%；Claude 系列的捷径里，79% 以上是去改测试（[arXiv 2510.20270](https://arxiv.org/html/2510.20270v1)）。美团技术团队的做法是给 AI 定文字规矩：Red 阶段只能改 `src/test/`，Green 阶段不得改动测试（[美团](https://tech.meituan.com/2025/12/05/AI-Coding-Unit-Testing.html)）。这里把这条规矩做成了机制：上锁时给每个测试文件记下指纹；锁存在期间，`PreToolUse` 守卫拦住对测试的修改；每次停下时重新计算指纹，这样连通过 shell 命令偷改的也能查出来，这类改法任何守卫都没法事先列全。只有人能解锁。

### 给 agent 一条正当的出路

一个"测试不过就打回"的钩子，分不清"我做完了"和"我有问题要问你"。没有出口的话，它就逼着 agent 去猜，这和"不清楚就问"的规矩正好冲突。所以 agent 可以写【需要你决定】：钩子看到后不跑测试，但照样检查测试有没有被改。ImpossibleBench 也发现了同一个杠杆：允许 agent 放弃之后，GPT-5 的作弊率从 54% 降到 9%。打回次数上限设为 3 次，理由和 Stripe 把 agent 的 CI 限制在两轮一样，"diminishing marginal returns"（[Stripe](https://stripe.dev/blog/minions-stripes-one-shot-end-to-end-coding-agents-part-2)）。超过上限就交给人看。

### spec 是一次可审查改动的验收约定

对"先写 spec"最常见的反对意见是：它会变回瀑布，写出一堆没人维护的长文档。Birgitta Böckeler 用一个 spec 工具修一个小 bug，结果生成了 4 个用户故事、16 条验收标准，她形容这 "like using a sledgehammer to crack a nut"（[martinfowler.com](https://martinfowler.com/articles/exploring-gen-ai/sdd-3-tools.html)）。`/spec` 的这些约束就是为了避开这个坑：

- 一份 spec 对应一次能一口气审完的改动，通常是一个 PR。只有一个 PR 装不下的才拆，而且按功能纵向切片，不按层拆。
- 最多问 5 个问题，每个都要过上面那三道筛子。其余写成默认假设让你否决：读一张清单只要几秒，答十个问题要好几分钟。
- 只写"要什么、怎样算对"，外加不能让 agent 猜的关键决定：接口、数据结构、要复用什么、什么不能动。不写实现步骤。
- 只放有代表性的例子，一般不超过 10 条。边界情况写进测试，因为测试过时了会报错，文档不会。
- 实现中有新发现记进变更记录，做完就归档。spec 不需要永远维护，测试才需要。

### 人的注意力花在出错代价最大的地方

每次改动都逐行审，规模上去就撑不住；完全不审，又算不上工程。Thoughtworks 技术雷达（2026 年 11 月）把"按风险分级的人工把关"列为 Trial：让审查深度和这次改动可能弄坏的东西相匹配（"aligns review depth with what a change could break"，[技术雷达](https://www.thoughtworks.com/radar/techniques)）。所以 spec 里带着风险档：涉及权限、并发、删改数据或数据迁移、钱、安全的算高；能回滚、只影响内部、不碰数据的算低。低风险跳过测试评审，作为代价，交付报告必须列出测试自己替 spec 做了哪些解释，比如"四舍五入"具体是怎么理解的。高风险就要你亲自读关键代码，再找一位同事审 MR。

### 写的人和审的人分开，审的人权力更小

审查员在全新的上下文里工作，拿到的是 spec、改动文件列表和测试输出；钩子限制它只能跑单条只读命令。它只报告影响正确性的问题。如果它能改代码，就会变成审它自己的修改，"写和审分开"也就不存在了。

### 每一道关卡都是对模型能力的一个假设

Anthropic 换了更强的模型以后，把长任务 harness 里整整一层去掉了，并总结说 "every component in a harness encodes an assumption about what the model can't do on its own"（[Anthropic](https://www.anthropic.com/engineering/harness-design-long-running-apps)）。这里的关卡都是一个个小文件和小脚本，可以单独拿掉；风险档已经在小改动上关掉了其中几道。模型变强以后，检验办法就是拿掉一道关卡，用真实任务重跑，效果变差才留下它。

### 犯过的错变成规矩，再犯就变成检查

Mitchell Hashimoto 把这叫 harness engineering："anytime you find an agent makes a mistake, you take the time to engineer a solution such that the agent never makes that mistake again"（[mitchellh.com](https://mitchellh.com/writing/my-ai-adoption-journey)）。OpenAI 的说法是 "When documentation falls short, we promote the rule into code"（[OpenAI](https://openai.com/index/harness-engineering/)）。`/retro` 把它变成习惯，同时控制规模：项目 `CLAUDE.md` 不超过 200 行，过时的规矩要删掉。

## 架构

| 层 | 组件 | 交给模型决定 | 用代码强制 |
|---|---|---|---|
| 编排 | `idea-kickoff` 主会话 | 怎么拆模块、分几波、合并顺序 | 每个模块一个 git worktree |
| 执行 | 跑 `/build` 的会话 | 怎么实现 | 测试锁住后不能改 |
| 验收 | `stop-verify.sh`、审查员、编排者重跑测试 | 测试够不够严，结果是否符合 spec | 测试指纹、`verify.sh` 的退出码、最多打回 3 次 |
| 人 | 你 | 审 spec、样例和方案，回答【需要你决定】 | 只有你能解锁 |

## 实测踩到的坑

下面每一条都是真实的 bug，都是在信任这些钩子之前，用脚本模拟各种场景跑出来的。

- `CLAUDE_PROJECT_DIR` 指的是会话启动的目录，不是 agent 正在工作的目录。会话从子目录启动、或者中途进了 worktree，就会锁在一个地方、查在另一个地方，锁形同虚设。现在所有脚本都按当前工作目录所在的 git 根目录来定位。
- 强制"做完才能停"的钩子，也会把提问一起挡住。【需要你决定】这个出口就是为此加的。
- 在 `SubagentStop` 事件里，`background_tasks` 属于父会话，而且里面就包含这个子 agent 自己，所以"还在等后台任务"永远成立。子 agent 跳过这条判断。
- `SubagentStop` 对所有子 agent 都会触发，包括审查员和 Claude Code 内部的 agent。现在只验收在自己 worktree 里开发的 agent；在主目录里的，交给主会话的钩子。
- 并行的子 agent 共用父会话的 session ID，所以打回计数要按 agent ID 分开记。
- 对权限的 deny 列表排序，会让 `!` 例外规则失效，因为例外只对排在它前面的规则生效。安装脚本合并时保持原顺序。
- `spec/` 目录和 `*.spec.*` 文件名都是测试文件的惯例写法，所以归档的 spec 放在 `docs/specs/`。macOS 默认的文件系统不区分大小写，`spec.md` 和 `SPEC.md` 是同一个文件，所以 `/spec` 不能覆盖 `idea-kickoff` 写的产品总纲。
- 测试文件如果在顶部导入一个还没写出来的函数，会在导入阶段就失败，同一个文件里的防回归测试也会跟着挂。所以新测试放进新文件。

## 局限

- 锁只能拦住改测试，拦不住针对测试输入写死答案。ImpossibleBench 也指出只读测试有同样的缺口。这只能靠审查员和你来发现。
- 测试和实现是同一个 agent 写的。中高风险时你会看测试；低风险时，只能依靠报告里列出的那些解释。
- 守卫会拦下任何提到锁文件的 shell 命令，包括无害的读取。
- 这套配置基于 Claude Code 的钩子机制，需要 `bash`、`git`、`jq` 和 `shasum`。
- 我没有测量过它对效率的影响，也不对此做任何声称。自测脚本验证的是钩子的行为，不是 agent 在这套机制下干得有多好。

## 安装

```bash
git clone https://github.com/WItaZhang/qianqian-responsible-build.git
cd qianqian-responsible-build
./install.sh            # 复制到 ~/.claude，被替换的文件先备份，合并 settings.json
./tests/run.sh          # 可选：在临时 HOME 里跑 40 项脚本检查
```

如果你已经有 `~/.claude/CLAUDE.md`，安装脚本不会动它，而是把规矩放在旁边，由你手动合并。然后给每个项目加一个 `.claude/verify.sh`，也就是"做完了"的那条命令：

```bash
#!/bin/bash
set -e
cd "$(dirname "$0")/.."
python -m pytest -q
```

## 文件

| 路径 | 作用 |
|---|---|
| `CLAUDE.md` | 全局规矩：先说假设，只改任务需要改的，用输出证明完成，绝不放宽测试 |
| `skills/spec/` | `/spec`：一页纸的验收约定 |
| `skills/build/` | `/build`：写测试、按风险评审、锁住、实现、审查、出报告 |
| `skills/retro/` | `/retro`：记录这次任务，把犯过的错变成规矩或检查 |
| `skills/idea-kickoff/` | 从模糊想法到第一版，用 worktree 并行开发 |
| `agents/reviewer.md` | 只读审查员，对照 spec 审改动 |
| `hooks/guard.sh` | 拦住对密钥文件的修改、锁住期间对测试的修改，以及对锁本身的操作 |
| `hooks/lock-tests.sh` | 锁住和解锁测试 |
| `hooks/stop-verify.sh` | 停下时运行：核对指纹，跑 `verify.sh` |
| `hooks/readonly-bash.sh` | 限制审查员只能跑单条只读命令 |
| `settings.example.json` | 这套配置新增的钩子和权限 |
| `tests/run.sh` | 自测脚本 |

## 参考

- Anthropic，[Best practices for Claude Code](https://code.claude.com/docs/en/best-practices)、[Harness design for long-running application development](https://www.anthropic.com/engineering/harness-design-long-running-apps)
- OpenAI，[Harness engineering](https://openai.com/index/harness-engineering/)
- Zhong、Raghunathan、Carlini，[ImpossibleBench](https://arxiv.org/html/2510.20270v1)
- METR，[Research update: reconciling slowdown with time horizons](https://metr.org/blog/2025-08-12-research-update-towards-reconciling-slowdown-with-time-horizons/)
- Mitchell Hashimoto，[My AI adoption journey](https://mitchellh.com/writing/my-ai-adoption-journey)
- Birgitta Böckeler，[Understanding spec-driven development](https://martinfowler.com/articles/exploring-gen-ai/sdd-3-tools.html)
- Stripe，[Minions, part 2](https://stripe.dev/blog/minions-stripes-one-shot-end-to-end-coding-agents-part-2)
- 美团技术团队，[AI Coding 与单元测试的协同进化](https://tech.meituan.com/2025/12/05/AI-Coding-Unit-Testing.html)
- Thoughtworks，[技术雷达 · 技术](https://www.thoughtworks.com/radar/techniques)

## 许可证

MIT
