# qianqian-responsible-build

A Claude Code setup for building software with agents. The agent writes the code; checks it cannot talk its way past decide when the work is done.

[中文说明](README.zh-CN.md)

```
/spec add rise alerts          one or two questions, a one-screen spec, you reply "ok"
/build                         tests → lock → implement → independent review → delivery report
unlock, commit, /retro         the mistakes from this task become rules for the next one
```

## Why this exists

Coding agents fail in three recurring ways. They misread what you meant. They change more than you asked for. They report success that is not there. Better prompting helps with the first two and does almost nothing for the third, because the model that did the work is also the one telling you it worked.

Each failure gets its own gate, and the gate sits wherever it is hardest to bypass:

| Failure | Gate | Who enforces it |
|---|---|---|
| Misreads intent | `/spec`: acceptance examples and visible default assumptions, approved before any code | You |
| Changes too much | Scope and "not doing this time" in the spec; a reviewer that checks for out-of-scope edits | A second model, then you |
| Claims it is done | Tests locked before implementation; a stop hook that reruns them every time the agent tries to finish | Code |

## How a feature gets built

**1. `/spec`.** The agent reads the relevant code, restates how it works today, and asks at most five questions, multiple choice with a recommendation. A question is only asked if the answer changes the approach, cannot be found in the code, and is expensive to guess wrong. Everything else becomes a listed default assumption you can strike out. The result fits on one screen: goal, risk level, scope, key decisions, acceptance examples, default assumptions, change log.

**2. `/build` in a fresh session.** The agent checks that the test command runs at all, writes the examples as tests, and confirms that the new ones fail for the right reason. Then:

- Low risk: it locks the tests and keeps going.
- Medium or high risk: it stops and shows you a table mapping each spec line to its test. You say "ok", then it locks.

It implements until the project's `.claude/verify.sh` passes, has a read-only reviewer compare the diff against the spec, and hands you a fixed-format report: test output, reviewer verdict, files changed, what the tests had to interpret on their own, and what you should look at given the risk level.

**3. You unlock, commit, and run `/retro`.** The first time a mistake happens it becomes a line in the project's `CLAUDE.md`. If it happens again, prose has failed, and it becomes a test, a lint rule or a line in `verify.sh`.

Bugs skip the spec: write a failing reproduction test, lock, fix. Trivial edits skip everything.

**New projects** go through `idea-kickoff`. One round of batched questions, then 10–20 worked examples you review, then a plan that splits the work into modules and waves. The main session acts as orchestrator. It defines interfaces, gives each module its own git worktree and builder, and re-runs every builder's tests before merging. Builders follow `/build` but do not stop to show tests, because those tests come from examples you already approved.

## Design notes

These are the decisions I would defend in a design review.

### "Done" is something the harness checks, not something the model says

Passing tests and being correct are different things. METR had people review pull requests that Claude 3.7 Sonnet produced on real issues: "none of them are mergeable as-is", including the ones that passed the tests ([METR](https://metr.org/blog/2025-08-12-research-update-towards-reconciling-slowdown-with-time-horizons/)). Anthropic reports that agents asked to grade their own work tend to respond "by confidently praising the work—even when, to a human observer, the quality is obviously mediocre" ([Anthropic](https://www.anthropic.com/engineering/harness-design-long-running-apps)). So completion is decided in two places that are not the builder: a `Stop` hook that reruns `verify.sh`, and a reviewer that never saw the implementation.

### A rule with no exceptions belongs in a hook, not in a prompt

Anthropic's guidance says a `CLAUDE.md` line the agent keeps ignoring is often "a rule that can't have exceptions, in which case it belongs in a hook" ([docs](https://code.claude.com/docs/en/best-practices)). I saw the reason while testing this setup. The reviewer's prompt says it is read-only. When a parent agent told it to run `touch`, it tried, and the hook stopped it. Asking the reviewer to stay read-only did not keep it read-only; the hook did. That is also the line I draw for every gate here: the model decides how to implement, and code enforces what it may not touch.

### Lock the tests between writing the exam and sitting it

ImpossibleBench gives agents tasks where the tests contradict the spec. GPT-5 took a shortcut on 54% of them, Claude Opus 4.1 on 50%, and for Claude models more than 79% of those shortcuts were edits to the tests ([arXiv 2510.20270](https://arxiv.org/html/2510.20270v1)). Meituan's engineering team handles this with a written rule: in the red phase only touch `src/test/`, in the green phase never touch the tests ([Meituan](https://tech.meituan.com/2025/12/05/AI-Coding-Unit-Testing.html)). Here the rule is mechanical. Locking fingerprints every test file. A `PreToolUse` guard blocks edits to tests while the lock exists. At every stop the fingerprints are recomputed, which catches edits made through the shell that no guard could enumerate in advance. Only a human can unlock.

### Give the agent a legitimate way out

A hook that sends the agent back whenever tests fail cannot tell "I'm done" apart from "I need to ask you something". Without an exit, it pushes the agent to guess, which contradicts the rule to ask when unclear. So the agent can write 【需要你决定】 ("your call"). The hook then skips the test run but still checks that the tests are untouched. ImpossibleBench found the same lever: letting the agent abstain cut GPT-5's cheating rate from 54% to 9%. The retry count is capped at three for the same reason Stripe caps its agents at two CI rounds, "diminishing marginal returns" ([Stripe](https://stripe.dev/blog/minions-stripes-one-shot-end-to-end-coding-agents-part-2)). After that a human looks.

### A spec is the acceptance contract for one reviewable change

The common objection to spec-first development is that it turns into waterfall: long documents nobody maintains. Birgitta Böckeler watched a spec tool turn a small bug into 4 user stories and 16 acceptance criteria, "like using a sledgehammer to crack a nut" ([martinfowler.com](https://martinfowler.com/articles/exploring-gen-ai/sdd-3-tools.html)). The constraints in `/spec` exist to avoid that:

- One spec per change that can be reviewed in one sitting, usually one PR. Only work that cannot fit in a PR gets split, into vertical slices rather than layers.
- At most five questions, each passing the three filters above. Everything else is written down as a default assumption to veto, which takes seconds to read instead of minutes to answer.
- What and how-to-judge, plus the decisions that must not be guessed: interfaces, data structures, what to reuse, what to leave alone. No implementation steps.
- Representative examples only, normally ten or fewer. Edge cases live in tests, which fail when they go stale. Prose does not.
- A change log for discoveries during implementation, and archiving when the work ships. The spec is not maintained forever; the tests are.

### Spend human attention where a mistake would cost the most

Reviewing every line of every change does not scale, and reviewing nothing is not engineering. Thoughtworks' Technology Radar (Nov 2026) puts risk-tiered human oversight in Trial: "aligns review depth with what a change could break" ([Radar](https://www.thoughtworks.com/radar/techniques)). The spec carries a risk level. Permissions, concurrency, data deletion or migration, money and security are high. Reversible, internal, data-free changes are low. Low risk skips the test review. In exchange, the report has to list every place where the tests interpreted the spec on their own, such as how "round half up" was read. High risk means you read the critical lines yourself and a colleague reviews the merge request.

### Separate the writer from the judge, and give the judge less power

The reviewer runs in a fresh context, gets the spec, the changed files and the test output, and is limited by a hook to single read-only commands. It reports only problems that affect correctness. If it could edit, it would end up reviewing its own fixes, and the separation would be gone.

### Every gate is an assumption about the model

Anthropic dropped a whole layer of their long-running harness once a newer model no longer needed it, and concluded that "every component in a harness encodes an assumption about what the model can't do on its own" ([Anthropic](https://www.anthropic.com/engineering/harness-design-long-running-apps)). The gates here are small files and scripts you can remove one at a time, and the risk tier already turns some of them off for cheap changes. When models improve, the test is to remove a gate, rerun some real tasks, and keep it only if things get worse.

### Mistakes become rules; repeated mistakes become checks

Mitchell Hashimoto calls this harness engineering: "anytime you find an agent makes a mistake, you take the time to engineer a solution such that the agent never makes that mistake again" ([mitchellh.com](https://mitchellh.com/writing/my-ai-adoption-journey)). OpenAI's version: "When documentation falls short, we promote the rule into code" ([OpenAI](https://openai.com/index/harness-engineering/)). `/retro` makes that a habit with a size limit: project `CLAUDE.md` stays under 200 lines, and stale rules get deleted.

## Architecture

| Layer | Component | Decided by the model | Enforced by code |
|---|---|---|---|
| Orchestration | `idea-kickoff` main session | How to split modules, which wave, merge order | One git worktree per module |
| Execution | A session running `/build` | How to implement | Tests cannot change once locked |
| Verification | `stop-verify.sh`, the reviewer, the orchestrator's re-run | Whether tests are strong enough; whether the result matches the spec | Test fingerprints, `verify.sh` exit code, a cap of three send-backs |
| Human | You | Approve spec, examples and plan; answer 【需要你决定】 | Only you can unlock |

## What testing it taught me

Every one of these was a real bug, found by running the hooks against scripted scenarios before trusting them.

- `CLAUDE_PROJECT_DIR` is where the session started, not where the agent is working. A session started in a subdirectory, or one that moved into a worktree, locked one place and checked another, so the lock silently did nothing. Every script now resolves the git root of the working directory.
- A stop hook that enforces "done" also blocks questions. That is why the 【需要你决定】 exit exists.
- In a `SubagentStop` event, `background_tasks` belongs to the parent session and includes the subagent itself, so "still waiting on background work" was always true. Subagents skip that check.
- `SubagentStop` fires for every subagent, including reviewers and Claude Code's internal agents. Only builders working in their own worktree are verified. Ones in the main checkout are left to the main session's hook.
- Parallel subagents share the parent's session ID, so their retry counters must be keyed by agent ID.
- Sorting a permissions deny list breaks `!` carve-outs, because a carve-out only applies to rules listed before it. The installer merges without reordering.
- `spec/` and `*.spec.*` are test-file conventions, so archived specs live in `docs/specs/`. On macOS's default filesystem `spec.md` and `SPEC.md` are the same file, so `/spec` must not overwrite `idea-kickoff`'s product spec.
- A test file that imports a function that does not exist yet fails at import and takes the regression tests in that file down with it. New tests go in new files.

## Limitations

- The lock stops edits to tests, not code that special-cases test inputs. ImpossibleBench notes the same gap for read-only tests. The reviewer and you are the only defence.
- The same agent writes the tests and the implementation. Medium and high risk put your eyes on the tests; low risk relies on the interpretation list in the report.
- The guard blocks any shell command that mentions the lock file, including harmless reads.
- This is built for Claude Code's hook system and needs `bash`, `git`, `jq` and `shasum`.
- I have not measured productivity effects and make no claims about them. The self-test covers how the hooks behave, not how well agents work under them.

## Install

```bash
git clone https://github.com/WItaZhang/qianqian-responsible-build.git
cd qianqian-responsible-build
./install.sh            # copies into ~/.claude, backs up anything it replaces, merges settings.json
./tests/run.sh          # optional: 40 scripted checks in a throwaway HOME
```

If you already have a `~/.claude/CLAUDE.md`, the installer leaves it alone and puts the rules next to it for you to merge. Then give each project a `.claude/verify.sh`, the one command that means "done":

```bash
#!/bin/bash
set -e
cd "$(dirname "$0")/.."
python -m pytest -q
```

## Files

| Path | Purpose |
|---|---|
| `CLAUDE.md` | Global rules: state assumptions, change only what the task needs, prove completion with output, never weaken tests |
| `skills/spec/` | `/spec`: a one-screen acceptance contract |
| `skills/build/` | `/build`: tests, risk-based review, lock, implement, review, report |
| `skills/retro/` | `/retro`: log the task, turn mistakes into rules or checks |
| `skills/idea-kickoff/` | From a vague idea to a first version with parallel worktree builders |
| `agents/reviewer.md` | Read-only reviewer that compares a diff against the spec |
| `hooks/guard.sh` | Blocks edits to secrets, to tests while locked, and to the lock itself |
| `hooks/lock-tests.sh` | Locks and unlocks tests |
| `hooks/stop-verify.sh` | Runs on stop: checks fingerprints and runs `verify.sh` |
| `hooks/readonly-bash.sh` | Keeps the reviewer to single read-only commands |
| `settings.example.json` | The hooks and permissions this setup adds |
| `tests/run.sh` | Self-test |

The skills and agent prompts are written in Chinese, which is the language I work in. Claude reads them fine either way.

## Sources

- Anthropic, [Best practices for Claude Code](https://code.claude.com/docs/en/best-practices) and [Harness design for long-running application development](https://www.anthropic.com/engineering/harness-design-long-running-apps)
- OpenAI, [Harness engineering](https://openai.com/index/harness-engineering/)
- Zhong, Raghunathan, Carlini, [ImpossibleBench](https://arxiv.org/html/2510.20270v1)
- METR, [Research update: reconciling slowdown with time horizons](https://metr.org/blog/2025-08-12-research-update-towards-reconciling-slowdown-with-time-horizons/)
- Mitchell Hashimoto, [My AI adoption journey](https://mitchellh.com/writing/my-ai-adoption-journey)
- Birgitta Böckeler, [Understanding spec-driven development](https://martinfowler.com/articles/exploring-gen-ai/sdd-3-tools.html)
- Stripe, [Minions, part 2](https://stripe.dev/blog/minions-stripes-one-shot-end-to-end-coding-agents-part-2)
- Meituan, [AI Coding 与单元测试的协同进化](https://tech.meituan.com/2025/12/05/AI-Coding-Unit-Testing.html)
- Thoughtworks, [Technology Radar, techniques](https://www.thoughtworks.com/radar/techniques)

## License

MIT
