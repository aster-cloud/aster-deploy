-- 测试用户种子数据
-- 用户: test@aster.dev / test1234
-- bcrypt cost=12（与 aster-cloud/src/auth.ts:21 一致）
-- 幂等：重复执行不会报错

INSERT INTO "User" (id, name, email, "passwordHash", plan, "createdAt", "updatedAt")
VALUES (
  'test-user-00000000-0000-0000-0000-000000000001',
  'Test User',
  'test@aster.dev',
  '$2b$12$JByIQ.BYRo2PPRLYjlUqcuk5SX34LRRVuIpIp5qL6e5fP5yxRTpsq',
  'trial',
  NOW(),
  NOW()
)
ON CONFLICT (email) DO NOTHING;
