#!/usr/bin/env bash
# 门禁：已废弃的 task 不得被任何流水线调用。
#
# ══ 为什么需要这个门禁 ════════════════════════════════════════════
#
# deploy:api 随 k3s digest-pin 废弃后**主动 exit 1**，但它仍留在 release
# 的 cmds 里 —— 于是 `task release` 必然中断在那一步。这个缺陷在仓里
# **没有任何检查能发现**：审计实测把 `- task: deploy:api` 加回 release，
# 没有一项检查变红（本仓 workflow 只有 cleanup-old-runs 与
# license-signing-api，都不碰 Taskfile）。
#
# 修掉一次不等于修掉这一类。故本门禁按**废弃标记**而非任务名工作：
# 任何 desc 以「【已废弃】」开头的 task，只要被别的 task 用
# `- task: X` 调用，就报错。将来废弃任何任务都自动受保护，无需改本脚本。
#
# ── 用法 ──
#   scripts/verify-task-graph.sh            # 检查 Taskfile.yml
#   scripts/verify-task-graph.sh --self-test  # 反向自检：故意注入违规必须被抓到
set -euo pipefail

TASKFILE="${TASKFILE:-Taskfile.yml}"

scan() {
  python3 - "$1" <<'PY'
import re, sys
src = open(sys.argv[1], encoding='utf-8').read()

# 切出每个顶层 task（两空格缩进的 `  name:`）的文本块
blocks, names = {}, []
heads = list(re.finditer(r'^  ([A-Za-z0-9:_-]+):[ \t]*$', src, re.M))
for i, h in enumerate(heads):
    end = heads[i + 1].start() if i + 1 < len(heads) else len(src)
    blocks[h.group(1)] = src[h.end():end]
    names.append(h.group(1))

if not names:
    print('!! 未解析出任何 task —— 解析器与 Taskfile 结构不符，拒绝放行', file=sys.stderr)
    sys.exit(2)

# ★必须钉住关键流水线确实被解析到。否则解析器一旦与 Taskfile 结构脱节
#   （比如 `release:` 写成 `release :`，本脚本就少解析出一个 task），
#   受保护的流水线会**静默消失**，门禁随之恒绿 —— 这正是
#   「结构上无法变红」的经典形态。实测：不加这一条，改名后仍打印 ✓。
REQUIRED = {'release', 'deploy:api'}
missing = REQUIRED - set(names)
if missing:
    print(f'!! 关键 task 未被解析到: {sorted(missing)} —— '
          f'解析器与 Taskfile 结构脱节，拒绝放行', file=sys.stderr)
    sys.exit(2)

# 废弃集合：desc 里含「【已废弃】」
deprecated = {n for n, b in blocks.items()
              if re.search(r'desc:.*【已废弃】', b)}

violations = []
for caller, body in blocks.items():
    # 只看**未被注释**的调用行：注释里提及废弃任务是合法的（解释为何移除）
    for line in body.splitlines():
        if re.match(r'\s*#', line):
            continue
        m = re.match(r'\s*-\s*task:\s*([A-Za-z0-9:_-]+)', line)
        if m and m.group(1) in deprecated:
            violations.append((caller, m.group(1)))

print(f'解析到 {len(names)} 个 task，其中已废弃 {len(deprecated)} 个: '
      f'{sorted(deprecated) if deprecated else "（无）"}')

if violations:
    for caller, callee in violations:
        print(f'✗ {caller} 调用了已废弃的 {callee}', file=sys.stderr)
    sys.exit(1)
print('✓ 没有流水线调用已废弃 task')
PY
}

if [[ "${1:-}" == "--self-test" ]]; then
  # ★反向自检：门禁必须能真的变红。只断言「干净树通过」的门禁，
  #   在解析器坏掉（比如 Taskfile 结构变了导致一个 task 都没解析出来）时
  #   会恒绿 —— 那正是「结构上无法变红」的经典形态。
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  fixture="$tmp/Taskfile.yml"

  echo "── 自检 1/2：干净的 Taskfile 必须通过 ──"
  cp "$TASKFILE" "$fixture"
  if ! scan "$fixture"; then
    echo "✗ 自检失败：当前 Taskfile 本就不该报错" >&2; exit 1
  fi

  echo "── 自检 2/2：注入违规必须被抓到 ──"
  # 把 deploy:api 加回 release 的 cmds（复刻审计变异 D1）
  python3 - "$fixture" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
anchor = '      - task: deploy:lsp'
assert s.count(anchor) == 1, f'!! 自检锚点未命中 count={s.count(anchor)}，变异未落地'
open(p, 'w', encoding='utf-8').write(
    s.replace(anchor, '      - task: deploy:api\n' + anchor, 1))
PY
  # ★把注入后的扫描输出完整转存再判定：直接 `if scan ...` 会先打印
  #   扫描器的进度行（"✓ 没有流水线调用…" 之外的那几行），肉眼读起来
  #   像是「注入了却通过了」，与真实退出码矛盾，制造误判。
  rc=0
  out=$(scan "$fixture" 2>&1) || rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "✗ 自检失败：注入了 release→deploy:api 却没报错，门禁形同虚设" >&2
    echo "$out" >&2
    exit 1
  fi
  echo "$out" | sed 's/^/    /'
  # ★变量名必须加花括号：后面紧跟的是全角右括号「）」，bash 会把它当成
  #   变量名的一部分，`$rc）` 在 set -u 下直接报 unbound variable。
  echo "✓ 自检通过：门禁在违规时确实变红（exit=${rc}）"
  exit 0
fi

scan "$TASKFILE"
