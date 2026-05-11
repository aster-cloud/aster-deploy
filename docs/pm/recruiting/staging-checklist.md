# Staging 可用性测试环境 — 准备清单

> 在 Pilot 之前（W2 周二前）必须全部勾选。
> 任何一项未达标都会污染 5 个稀缺样本的数据。

---

## 1. Tenant 与账号

- [ ] 在 aster-cloud staging 创建独立租户：`tenant_id = ut2026w3`，名称 "Usability Test 2026 W3"
- [ ] 该租户启用 zh-CN 作为默认 lexicon
- [ ] 创建 6 个测试账号（5 个正式 + 1 个 pilot 备份）：
  - `ut-p1@aster-internal.test` / `ut-p2@...` / ... / `ut-p5@...` / `ut-pilot@...`
  - 密码统一：`AsterUT2026!`（测试结束后立即吊销）
  - 角色：`business_expert`（确保 NSM 事件 author_role 命中）
- [ ] 每个账号关掉双因子，避免短信/邮件中断
- [ ] 检查每个账号能登录、能进入"新建策略"页

---

## 2. 模板预置

进入 staging 控制台，给 ut2026w3 租户创建 3 个 zh-CN 模板：

- [ ] **空白模板**：仅有 `模块 aster.finance.loan。` 头部，给 P1/P5 用
- [ ] **半成品模板**：包含信用分判断，缺收入与拒绝分支，给 P3 用
- [ ] **完整示例模板**：用作"修改而非从零写"的对照组（任务 3 用）

模板内容存档：`recruiting/templates/`（运行时由产品同事手工填充，不进 git）

---

## 3. AI 助手配置

- [ ] 确认 staging LLM endpoint 指向 gpt-5.2 而非降级模型
- [ ] AI 用量上限调高：每账号 100 次/天（默认 20，避免测试中限流）
- [ ] 提前 24h 跑 smoke test：
  - [ ] 用每个账号生成一次草稿
  - [ ] 确认 SSE 流稳定，没有超时
  - [ ] 确认 validated 事件能触发自动填充
  - [ ] 确认 AI Repair 触发时不会卡住
- [ ] 准备 fallback：如果 LLM 不可用，主持人有备选 prompt 列表，能跳到下一任务

---

## 4. 埋点 verify（保护 NSM 数据）

- [ ] **Mixpanel staging project** 已创建，token 配置在 staging 环境变量
- [ ] 在 Mixpanel Live View 验证 4 个事件能收到：
  - [ ] `ai_draft_generated` ← 触发 AI 助手
  - [ ] `draft_edited` ← 改 AI 草稿后保存
  - [ ] `draft_published` ← 普通保存
  - [ ] `rule_rolled_back` ← 走一次回滚 endpoint（用 curl 模拟）
- [ ] 创建 Mixpanel "Usability Test 2026 W3" 看板，按 distinct_id = ut-p* 过滤
- [ ] **`policy_versions.source_kind`** 列在 staging DB 已迁移（V6.7.0）

---

## 5. 录屏与会议

- [ ] 飞书会议房间预约 6 个独立会议号（pilot + P1–P5）
- [ ] 每个会议房间名带"录屏"二字，方便复盘
- [ ] 主备录屏：
  - 主：飞书会议自带云录屏
  - 备：主持人本地 OBS（防云录屏故障）
- [ ] 测试 screen share + audio 在 macOS / Windows / 移动端都能正常显示

---

## 6. 主持人 Checklist（每场前 24h）

- [ ] 已读 `04-usability-test-plan.md` 任务剧本
- [ ] 已读 `W1-recruiting-kit.md` 主持人脚本
- [ ] 已读参与者的筛选问卷答案（避免现场尴尬重复问）
- [ ] 测试电脑：键鼠静音、关闭通知、隐藏个人 tab、开启免打扰
- [ ] 度量表（`04-usability-test-plan.md` 第 5 节）打印或新建副本
- [ ] 备好 ¥500 转账渠道（微信红包 / 支付宝转账截图模板）

---

## 7. 紧急联系

| 角色 | 姓名 | 微信/电话 | 备份联系人 |
|---|---|---|---|
| 主持人 | TBD | TBD | TBD |
| 记录员 | TBD | TBD | TBD |
| 工程支持（处理 staging 故障） | TBD | TBD | TBD |
| 产品负责人 | TBD | TBD | TBD |

---

## 8. 一键回滚

如果测试中发现严重 bug 影响数据，能否在 30 分钟内还原 staging？

- [ ] DB 备份点已在 W2 周一创建（`pg_dump ut2026w3_*.sql`）
- [ ] aster-cloud staging 镜像 tag 已锁定，知道如何回滚 ArgoCD App
- [ ] 不要在测试期间合并 main → staging（W3 周一到周五冻结）

---

## 9. 测试后清理（W4 周一前）

- [ ] 6 个测试账号吊销
- [ ] ut2026w3 租户保留 30 天后归档
- [ ] AI 用量上限调回默认
- [ ] 录屏从飞书云迁移到内部 OneDrive 加密目录
- [ ] Mixpanel "Usability Test" 看板加锁，仅产品团队可见

---

**版本**：v1.0 · 2026-05-10
**关联**：`W1-recruiting-kit.md` / `../04-usability-test-plan.md` / `../03-telemetry-spec.md`
