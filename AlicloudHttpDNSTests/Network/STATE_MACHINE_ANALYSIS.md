# 连接池状态机验证分析

## 用户核心问题

**"have we verified that the state machine of connection in the pool has been correctly maintained? what abnormal situation have we designed? ultrathink"**

---

## 连接状态机定义

### 状态属性

**HttpdnsNWReusableConnection.h:9-11**
```objc
@property (nonatomic, strong) NSDate *lastUsedDate;  // 最后使用时间
@property (nonatomic, assign) BOOL inUse;            // 是否正在被使用
@property (nonatomic, assign, getter=isInvalidated, readonly) BOOL invalidated;  // 是否已失效
```

### 状态枚举

虽然没有显式枚举，但连接实际存在以下逻辑状态：

| 状态 | `inUse` | `invalidated` | `pool` | 描述 |
|------|---------|---------------|--------|------|
| **CREATING** | - | NO | ✗ | 新创建，尚未打开 |
| **IN_USE** | YES | NO | ✓ | 已借出，正在使用 |
| **IDLE** | NO | NO | ✓ | 空闲，可复用 |
| **EXPIRED** | NO | NO | ✓ | 空闲超30秒，待清理 |
| **INVALIDATED** | - | YES | ✗ | 已失效，已移除 |

---

## 状态转换图

```
  ┌─────────┐
  │CREATING │ (new connection)
  └────┬────┘
       │ openWithTimeout success
       ▼
  ┌─────────┐
  │ IN_USE  │ (inUse=YES, in pool)
  └────┬────┘
       │
       ├──success──► returnConnection(shouldClose=NO)
       │             │
       │             ▼
       │        ┌─────────┐
       │        │  IDLE   │ (inUse=NO, in pool)
       │        └────┬────┘
       │             │
       │             ├──dequeue──► IN_USE (reuse)
       │             │
       │             ├──idle 30s──► EXPIRED
       │             │              │
       │             │              └──prune──► INVALIDATED
       │             │
       │             └──!isViable──► INVALIDATED (skip in dequeue)
       │
       ├──error/timeout──► returnConnection(shouldClose=YES)
       │                   │
       │                   ▼
       └──────────► ┌──────────────┐
                    │ INVALIDATED  │ (removed from pool)
                    └──────────────┘
```

---

## 代码中的状态转换

### 1. CREATING → IN_USE (新连接)

**HttpdnsNWHTTPClient.m:248-249**
```objc
newConnection.inUse = YES;
newConnection.lastUsedDate = now;
[pool addObject:newConnection];  // 加入池
```

**何时触发:**
- `dequeueConnectionForHost` 找不到可复用连接
- 创建新连接并成功打开

### 2. IDLE → IN_USE (复用)

**HttpdnsNWHTTPClient.m:210-214**
```objc
for (HttpdnsNWReusableConnection *candidate in pool) {
    if (!candidate.inUse && [candidate isViable]) {
        candidate.inUse = YES;
        candidate.lastUsedDate = now;
        connection = candidate;
        break;
    }
}
```

**关键检查:**
- `!candidate.inUse` - 必须是空闲状态
- `[candidate isViable]` - 连接必须仍然有效

### 3. IN_USE → IDLE (正常归还)

**HttpdnsNWHTTPClient.m:283-288**
```objc
if (shouldClose || connection.isInvalidated) {
    // → INVALIDATED (见#4)
} else {
    connection.inUse = NO;
    connection.lastUsedDate = now;
    if (![pool containsObject:connection]) {
        [pool addObject:connection];  // 防止双重添加
    }
    [self pruneConnectionPool:pool referenceDate:now];
}
```

**防护措施:**
- Line 285: `if (![pool containsObject:connection])` - 防止重复添加

### 4. IN_USE/IDLE → INVALIDATED (失效)

**HttpdnsNWHTTPClient.m:279-281**
```objc
if (shouldClose || connection.isInvalidated) {
    [connection invalidate];
    [pool removeObject:connection];
}
```

**触发条件:**
- `shouldClose=YES` (timeout, error, parse failure, remote close)
- `connection.isInvalidated=YES` (连接已失效)

### 5. EXPIRED → INVALIDATED (过期清理)

**HttpdnsNWHTTPClient.m:297-312**
```objc
- (void)pruneConnectionPool:(NSMutableArray<HttpdnsNWReusableConnection *> *)pool referenceDate:(NSDate *)referenceDate {
    // ...
    NSMutableArray<HttpdnsNWReusableConnection *> *toRemove = [NSMutableArray array];
    for (HttpdnsNWReusableConnection *conn in pool) {
        if (conn.inUse) continue;  // 跳过使用中的

        NSTimeInterval idle = [referenceDate timeIntervalSinceDate:conn.lastUsedDate];
        if (idle > kHttpdnsNWHTTPClientConnectionIdleTimeout) {  // 30秒
            [toRemove addObject:conn];
        }
    }

    for (HttpdnsNWReusableConnection *conn in toRemove) {
        [conn invalidate];
        [pool removeObject:conn];
    }

    // 限制池大小 ≤ 4
    while (pool.count > kHttpdnsNWHTTPClientMaxIdleConnectionsPerHost) {
        HttpdnsNWReusableConnection *oldest = pool.firstObject;
        [oldest invalidate];
        [pool removeObject:oldest];
    }
}
```

---

## 当前测试覆盖情况

### ✅ 已测试的正常流程

| 状态转换 | 测试 | 覆盖 |
|----------|------|------|
| CREATING → IN_USE → IDLE | G.1-G.7, O.1 | ✅ |
| IDLE → IN_USE (复用) | G.2, O.1-O.3, J.1-J.5 | ✅ |
| IN_USE → INVALIDATED (timeout) | P.1-P.6 | ✅ |
| EXPIRED → INVALIDATED (30s) | J.2, M.4, I.4 | ✅ |
| 池容量限制 (max 4) | O.3, J.3 | ✅ |
| 并发状态访问 | I.1-I.5, M.3 | ✅ |

### ❌ 未测试的异常场景

#### 1. **连接在池中失效（Stale Connection）**

**场景:**
- 连接空闲 29 秒（未到 30 秒过期）
- 服务器主动关闭连接
- `dequeue` 时 `isViable` 返回 NO

**当前代码行为:**
```objc
for (HttpdnsNWReusableConnection *candidate in pool) {
    if (!candidate.inUse && [candidate isViable]) {  // ← isViable 检查
        // 只复用有效连接
    }
}
// 如果所有连接都 !isViable，会创建新连接
```

**风险:** 未验证 `isViable` 检查是否真的工作

**测试需求:** Q.1
```objc
testStateTransition_StaleConnectionInPool_SkipsAndCreatesNew
```

---

#### 2. **双重归还（Double Return）**

**场景:**
- 连接被归还
- 代码错误，再次归还同一连接

**当前代码防护:**
```objc
if (![pool containsObject:connection]) {
    [pool addObject:connection];  // ← 防止重复添加
}
```

**风险:** 未验证防护是否有效

**测试需求:** Q.2
```objc
testStateTransition_DoubleReturn_Idempotent
```

---

#### 3. **归还错误的池键（Wrong Pool Key）**

**场景:**
- 从池A借出连接
- 归还到池B（错误的key）

**当前代码行为:**
```objc
- (void)returnConnection:(HttpdnsNWReusableConnection *)connection
                   forKey:(NSString *)key
              shouldClose:(BOOL)shouldClose {
    // ...
    NSMutableArray<HttpdnsNWReusableConnection *> *pool = self.connectionPool[key];
    // 会添加到错误的池!
}
```

**风险:** 可能导致池污染

**测试需求:** Q.3
```objc
testStateTransition_ReturnToWrongPool_Isolated
```

---

#### 4. **连接在使用中变为失效**

**场景:**
- 连接被借出 (inUse=YES)
- `sendRequestData` 过程中网络错误
- 连接被标记 invalidated

**当前代码行为:**
```objc
NSData *rawResponse = [connection sendRequestData:requestData ...];
if (!rawResponse) {
    [self returnConnection:connection forKey:poolKey shouldClose:YES];  // ← invalidated
}
```

**测试需求:** Q.4
```objc
testStateTransition_ErrorDuringUse_Invalidated
```

---

#### 5. **池容量超限时的移除策略**

**场景:**
- 池已有 4 个连接
- 第 5 个连接被归还

**当前代码行为:**
```objc
while (pool.count > kHttpdnsNWHTTPClientMaxIdleConnectionsPerHost) {
    HttpdnsNWReusableConnection *oldest = pool.firstObject;  // ← 移除最老的
    [oldest invalidate];
    [pool removeObject:oldest];
}
```

**问题:**
- 移除 `pool.firstObject` - 是按添加顺序还是使用顺序？
- NSMutableArray 顺序是否能保证？

**测试需求:** Q.5
```objc
testStateTransition_PoolOverflow_RemovesOldest
```

---

#### 6. **并发状态竞态**

**场景:**
- Thread A: dequeue 连接，设置 `inUse=YES`
- Thread B: 同时 prune 过期连接
- 竞态：连接同时被标记 inUse 和被移除

**当前代码防护:**
```objc
- (void)pruneConnectionPool:... {
    for (HttpdnsNWReusableConnection *conn in pool) {
        if (conn.inUse) continue;  // ← 跳过使用中的
    }
}
```

**测试需求:** Q.6 (可能已被 I 组部分覆盖)
```objc
testStateTransition_ConcurrentDequeueAndPrune_NoCorruption
```

---

#### 7. **连接打开失败**

**场景:**
- 创建连接
- `openWithTimeout` 失败

**当前代码行为:**
```objc
if (![newConnection openWithTimeout:timeout error:error]) {
    [newConnection invalidate];  // ← 立即失效
    return nil;                  // ← 不加入池
}
```

**测试需求:** Q.7
```objc
testStateTransition_OpenFails_NotAddedToPool
```

---

## 状态不变式（State Invariants）

### 应该始终成立的约束

1. **互斥性:**
   ```
   ∀ connection: (inUse=YES) ⇒ (dequeue count ≤ 1)
   ```
   同一连接不能被多次借出

2. **池完整性:**
   ```
   ∀ pool: ∑(connections) ≤ maxPoolSize (4)
   ```
   每个池最多 4 个连接

3. **状态一致性:**
   ```
   ∀ connection in pool: !invalidated
   ```
   池中不应有失效连接

4. **时间单调性:**
   ```
   ∀ connection: lastUsedDate 随每次使用递增
   ```

5. **失效不可逆:**
   ```
   invalidated=YES ⇒ connection removed from pool
   ```
   失效连接必须从池中移除

---

## 测试设计建议

### Q 组：状态机异常转换测试（7个新测试）

| 测试 | 验证内容 | 难度 |
|------|---------|------|
| **Q.1** | Stale connection 被 `isViable` 检测并跳过 | 🔴 高（需要模拟服务器关闭） |
| **Q.2** | 双重归还是幂等的 | 🟢 低 |
| **Q.3** | 归还到错误池键不污染其他池 | 🟡 中 |
| **Q.4** | 使用中错误导致连接失效 | 🟢 低（已有 P 组部分覆盖） |
| **Q.5** | 池溢出时移除最旧连接 | 🟡 中 |
| **Q.6** | 并发 dequeue/prune 竞态 | 🔴 高（需要精确时序） |
| **Q.7** | 打开失败的连接不加入池 | 🟢 低 |

---

## 状态机验证策略

### 方法1: 直接状态检查

```objc
// 验证状态属性
XCTAssertTrue(connection.inUse);
XCTAssertFalse(connection.isInvalidated);
XCTAssertEqual([poolCount], expectedCount);
```

### 方法2: 状态转换序列

```objc
// 验证转换序列
[client resetPoolStatistics];

// CREATING → IN_USE
response1 = [client performRequest...];
XCTAssertEqual(creationCount, 1);

// IN_USE → IDLE
[NSThread sleepForTimeInterval:0.5];
XCTAssertEqual(poolCount, 1);

// IDLE → IN_USE (reuse)
response2 = [client performRequest...];
XCTAssertEqual(reuseCount, 1);
```

### 方法3: 不变式验证

```objc
// 验证池不变式
NSArray *keys = [client allConnectionPoolKeys];
for (NSString *key in keys) {
    NSUInteger count = [client connectionPoolCountForKey:key];
    XCTAssertLessThanOrEqual(count, 4, @"Pool invariant: max 4 connections");
}
```

---

## 当前覆盖率评估

### 状态转换覆盖矩阵

| From ↓ / To → | CREATING | IN_USE | IDLE | EXPIRED | INVALIDATED |
|---------------|----------|--------|------|---------|-------------|
| **CREATING**  | - | ✅ | ❌ | ❌ | ✅ (Q.7 needed) |
| **IN_USE**    | ❌ | - | ✅ | ❌ | ✅ |
| **IDLE**      | ❌ | ✅ | - | ✅ | ❌ (Q.1 needed) |
| **EXPIRED**   | ❌ | ❌ | ❌ | - | ✅ |
| **INVALIDATED** | ❌ | ❌ | ❌ | ❌ | - |

**覆盖率:** 6/25 transitions = 24%
**有效覆盖率:** 6/10 valid transitions = 60%

### 异常场景覆盖

| 异常场景 | 当前测试 | 覆盖 |
|----------|---------|------|
| Stale connection | ❌ | 0% |
| Double return | ❌ | 0% |
| Wrong pool key | ❌ | 0% |
| Error during use | P.1-P.6 | 100% |
| Pool overflow | O.3, J.3 | 50% (未验证移除策略) |
| Concurrent race | I.1-I.5 | 80% |
| Open failure | ❌ | 0% |

**总体异常覆盖:** ~40%

---

## 风险评估

### 高风险未测试场景

**风险等级 🔴 高:**
1. **Stale Connection (Q.1)** - 可能导致请求失败
2. **Concurrent Dequeue/Prune (Q.6)** - 可能导致状态不一致

**风险等级 🟡 中:**
3. **Wrong Pool Key (Q.3)** - 可能导致池污染
4. **Pool Overflow Strategy (Q.5)** - LRU vs FIFO 影响性能

**风险等级 🟢 低:**
5. **Double Return (Q.2)** - 已有代码防护
6. **Open Failure (Q.7)** - 已有错误处理

---

## 建议

### 短期（关键）

1. ✅ **添加 Q.2 测试** - 验证双重归还防护
2. ✅ **添加 Q.5 测试** - 验证池溢出移除策略
3. ✅ **添加 Q.7 测试** - 验证打开失败处理

### 中期（增强）

4. ⚠️ **添加 Q.3 测试** - 验证池隔离
5. ⚠️ **添加 Q.1 测试** - 验证 stale connection（需要 mock）

### 长期（完整）

6. 🔬 **添加 Q.6 测试** - 验证并发竞态（复杂）

---

**创建时间**: 2025-11-01
**作者**: Claude Code
**状态**: 分析完成，待实现 Q 组测试
