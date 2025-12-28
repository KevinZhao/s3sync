# S3 到 S3 Express One Zone 自动同步

自动将 S3 标准桶的文件同步到 S3 Express One Zone，支持新增、更新、删除操作。

## 特点

- ✅ **真正按需**：无文件时零成本，Lambda + Fargate Spot 按使用量计费
- ✅ **自动扩展**：根据队列深度自动启动/关闭 workers (1:1 策略)
- ✅ **成本优化**：Fargate Spot 节省 70% 成本
- ✅ **高性能**：256 线程并发，S3→S3 Express 可达 69 Gbps
- ✅ **大文件支持**：自动 multipart copy (>5GB)
- ✅ **自动重试**：SQS 可见性超时 + 死信队列

## 快速开始

### 前置要求

- AWS CLI 已配置
- Docker 已安装
- 执行权限（IAM 权限创建 Lambda、ECS、SQS、ECR、IAM 角色）

### 1. 基础部署（创建新桶）

```bash
# 克隆仓库
git clone <your-repo>
cd s3sync

# 直接部署（会自动创建标准桶和 Express 桶）
./deploy.sh
```

部署完成后会输出：
- 源桶名称：`s3sync-standard-<timestamp>`
- 目标桶名称：`s3sync-express-<timestamp>--<az>--x-s3`

### 2. 使用已有桶部署

```bash
# 方式1: 指定已有的标准桶和 Express 桶
REGION=eu-west-1 \
SRC_BUCKET=my-source-bucket \
DST_BUCKET=my-express-bucket--euw1-az1--x-s3 \
./deploy.sh

# 方式2: 只指定基础名（脚本自动添加 --<az>--x-s3 后缀）
REGION=eu-west-1 \
SRC_BUCKET=my-source-bucket \
DST_BUCKET=my-express-bucket \
./deploy.sh

# 方式3: 只同步特定前缀
REGION=eu-west-1 \
SRC_BUCKET=my-bucket \
DST_BUCKET=my-express \
PREFIX_FILTER="models/deepseek/" \
./deploy.sh
```

### 3. 测试同步

```bash
# 上传测试文件
echo "Hello S3 Express" > test.txt
aws s3 cp test.txt s3://your-source-bucket/test.txt

# 等待 1-2 分钟，检查目标桶
aws s3 ls s3://your-express-bucket--<az>--x-s3/test.txt

# 删除测试
aws s3 rm s3://your-source-bucket/test.txt
```

## 配置说明

### 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `REGION` | AWS 区域 | `eu-north-1` |
| `SRC_BUCKET` | 源桶名称（S3 标准） | 自动生成 |
| `DST_BUCKET` | 目标桶名称（S3 Express） | 自动生成 |
| `PREFIX_FILTER` | 对象前缀过滤 | 空（同步所有） |

### 关键参数（deploy.sh 内修改）

```bash
MAX_WORKERS=5                       # 最大并发 worker 数
LAMBDA_POLL_RATE="1"                # Lambda 检查间隔（分钟）
TASK_CPU="2048"                     # 2 vCPU
TASK_MEMORY="4096"                  # 4 GB
VISIBILITY_TIMEOUT=7200             # SQS 可见性超时（2 小时）
```

## 监控管理

### 查看运行状态

```bash
# 检查当前运行的 workers
aws ecs list-tasks \
  --cluster s3-to-s3express-sync-cluster \
  --region eu-west-1

# 检查队列深度
aws sqs get-queue-attributes \
  --queue-url $(aws sqs get-queue-url \
    --queue-name s3-to-s3express-sync-q \
    --region eu-west-1 \
    --query 'QueueUrl' --output text) \
  --attribute-names ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible \
  --region eu-west-1
```

### 查看日志

```bash
# Lambda Starter 日志
aws logs tail /aws/lambda/s3-to-s3express-sync-starter \
  --follow --region eu-west-1

# Worker 日志
aws logs tail /ecs/s3-to-s3express-sync-task \
  --follow --region eu-west-1
```

### 手动触发同步

```bash
# 手动调用 Lambda Starter
aws lambda invoke \
  --function-name s3-to-s3express-sync-starter \
  --region eu-west-1 \
  /tmp/output.json

cat /tmp/output.json
```

## 常见操作

### 1. 批量同步已有文件

如果源桶已有大量文件，需要批量同步：

```bash
# 方式1: 手动生成 S3 事件（推荐用于少量文件 <1000）
aws s3 ls s3://your-source-bucket/ --recursive | \
  awk '{print $4}' | \
  xargs -I {} aws s3 cp s3://your-source-bucket/{} s3://your-source-bucket/{} --metadata sync=trigger

# 方式2: 使用 S3 Batch Operations（推荐用于大量文件）
# 创建 inventory 清单
aws s3api put-bucket-inventory-configuration \
  --bucket your-source-bucket \
  --id sync-inventory \
  --inventory-configuration file://inventory-config.json

# 方式3: 直接用 worker.py 脚本（性能测试显示 69 Gbps）
# 见下方 "性能测试" 章节
```

### 2. 暂停同步

```bash
# 禁用 EventBridge 定时规则
aws events disable-rule \
  --name s3-to-s3express-sync-starter-rule \
  --region eu-west-1

# 停止所有运行中的 workers
aws ecs list-tasks \
  --cluster s3-to-s3express-sync-cluster \
  --region eu-west-1 \
  --query 'taskArns[]' \
  --output text | xargs -I {} aws ecs stop-task \
    --cluster s3-to-s3express-sync-cluster \
    --task {} \
    --region eu-west-1
```

### 3. 恢复同步

```bash
# 启用 EventBridge 定时规则
aws events enable-rule \
  --name s3-to-s3express-sync-starter-rule \
  --region eu-west-1
```

### 4. 调整并发数

```bash
# 编辑 Lambda 环境变量
aws lambda update-function-configuration \
  --function-name s3-to-s3express-sync-starter \
  --environment "Variables={REGION=eu-west-1,QUEUE_URL=...,MAX_WORKERS=10,...}" \
  --region eu-west-1
```

### 5. 清理死信队列

```bash
# 查看失败消息
DLQ_URL=$(aws sqs get-queue-url \
  --queue-name s3-to-s3express-sync-dlq \
  --region eu-west-1 \
  --query 'QueueUrl' --output text)

aws sqs receive-message \
  --queue-url "$DLQ_URL" \
  --max-number-of-messages 10 \
  --region eu-west-1

# 清空 DLQ
aws sqs purge-queue --queue-url "$DLQ_URL" --region eu-west-1
```

## 性能测试

### 测试环境

- **源**: S3 Standard (eu-west-1)
- **目标**: S3 Express One Zone (eu-west-1, euw1-az1)
- **数据**: 577 文件，642 GB (DeepSeek-V3.2 模型)

### 测试结果

#### 场景1: EC2 上传 + 自动同步
- **上传速度**: 340 MB/s (c7gn.xlarge, 优化后)
- **总时间**: 2 小时 2 分钟
- **瓶颈**: EC2 上传带宽

#### 场景2: S3→S3 Express 纯同步（50 workers）
- **速度**: **8.6 GB/s = 69 Gbps**
- **总时间**: 76 秒
- **吞吐**: 单 worker ~89 MB/s，50 workers 聚合 ~8.6 GB/s

### 性能优化建议

| 场景 | MAX_WORKERS | CPU/MEM | 预期吞吐 |
|------|-------------|---------|----------|
| 小文件 (<100MB) | 10-20 | 1024/2048 | 200+ files/min |
| 中等文件 (100MB-1GB) | 5-10 | 2048/4096 | 50+ files/min |
| 大文件 (>5GB) | 5-10 | 4096/8192 | 500+ MB/s 每 worker |
| 极大文件 (>50GB) | 2-5 | 4096/8192 | 建议增加 VISIBILITY_TIMEOUT |

## 故障排查

### 问题1: 文件未同步

**排查步骤**：
```bash
# 1. 检查源桶事件通知是否配置
aws s3api get-bucket-notification-configuration \
  --bucket your-source-bucket \
  --region eu-west-1

# 2. 检查 SQS 队列是否有消息
aws sqs get-queue-attributes \
  --queue-url $(aws sqs get-queue-url \
    --queue-name s3-to-s3express-sync-q \
    --region eu-west-1 --query 'QueueUrl' --output text) \
  --attribute-names All \
  --region eu-west-1

# 3. 检查 DLQ 是否有失败消息
aws sqs receive-message \
  --queue-url $(aws sqs get-queue-url \
    --queue-name s3-to-s3express-sync-dlq \
    --region eu-west-1 --query 'QueueUrl' --output text) \
  --max-number-of-messages 10 \
  --region eu-west-1

# 4. 查看 Worker 错误日志
aws logs tail /ecs/s3-to-s3express-sync-task \
  --since 1h \
  --region eu-west-1 | grep -i error
```

### 问题2: Worker 未启动

**排查步骤**：
```bash
# 1. 检查 Lambda Starter 日志
aws logs tail /aws/lambda/s3-to-s3express-sync-starter \
  --since 10m \
  --region eu-west-1

# 2. 手动触发 Lambda
aws lambda invoke \
  --function-name s3-to-s3express-sync-starter \
  --region eu-west-1 \
  /tmp/output.json

# 3. 检查 IAM 权限
aws iam get-role-policy \
  --role-name s3-to-s3express-sync-starter-role \
  --policy-name s3-to-s3express-sync-starter-role-inline \
  --region eu-west-1
```

### 问题3: 性能慢

**解决方案**：
```bash
# 增加并发 workers（修改 deploy.sh 后重新部署）
MAX_WORKERS=20

# 或临时修改 Lambda 环境变量
aws lambda update-function-configuration \
  --function-name s3-to-s3express-sync-starter \
  --environment Variables="{...,MAX_WORKERS=20}" \
  --region eu-west-1
```

## 架构说明

### 系统架构图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           完整架构流程                                    │
└─────────────────────────────────────────────────────────────────────────┘

                    ┌──────────────────────┐
                    │   S3 Standard Bucket │  用户上传/删除文件
                    │  (源桶，数据源头)     │
                    └──────────┬───────────┘
                               │
                               │ S3 Event Notifications
                               │ (ObjectCreated:*, ObjectRemoved:*)
                               ↓
                    ┌──────────────────────┐
                    │     SQS Queue        │  消息缓冲
                    │   (主队列 + DLQ)      │  • Visibility: 2小时
                    └──────────┬───────────┘  • MaxReceive: 3次
                               ↑              • DLQ: 失败消息
                               │
            ┌──────────────────┴─────────────────────┐
            │                                         │
            │  EventBridge Schedule (每1分钟)         │
            ↓                                         │
┌───────────────────────────┐                        │
│   Lambda Starter          │                        │
│   (轻量调度器)             │                        │
│                           │                        │
│   检查逻辑:                │                        │
│   1. 获取队列深度          │                        │
│      queue_depth =        │                        │
│      visible + in_flight  │                        │
│   2. 获取运行中 workers    │                        │
│   3. 计算需要启动数        │                        │
│      tasks_needed =       │                        │
│      min(MAX_WORKERS -    │                        │
│          running,         │                        │
│          queue_depth)     │  1:1 策略              │
│                           │                        │
│   启动 Fargate Tasks ────────────────┐             │
└───────────────────────────┘          │             │
                                       ↓             │
                    ┌────────────────────────────┐   │
                    │  ECS Fargate Spot Workers  │   │
                    │  (按需启动，自动扩缩容)     │   │
                    │                            │   │
                    │  配置:                      │   │
                    │  • 2 vCPU + 4 GB           │   │
                    │  • ARM64 架构               │   │
                    │  • 80% Spot + 20% On-Demand│   │
                    │                            │   │
                    │  工作流程:                  │   │
                    │  1. 长轮询 SQS (20s)       │───┘ 拉取消息
                    │  2. 解析 S3 事件           │
                    │  3. 执行操作:              │
                    │     • ObjectCreated →     │
                    │       copy_to_dst()       │
                    │       - <5GB: 单次 copy   │
                    │       - ≥5GB: 256 线程    │
                    │         multipart copy    │
                    │     • ObjectRemoved →     │
                    │       delete_from_dst()   │
                    │  4. 删除 SQS 消息          │
                    │  5. 空轮询3次 → 自动退出   │
                    └────────────┬───────────────┘
                                 │
                                 │ S3 CopyObject / DeleteObject
                                 │ (256 线程并发 multipart)
                                 ↓
                    ┌──────────────────────────┐
                    │  S3 Express One Zone     │  同步完成
                    │  (目标桶，高性能存储)     │
                    └──────────────────────────┘
```

### 关键组件

| 组件 | 类型 | 配置 | 职责 |
|------|------|------|------|
| **S3 Standard** | 源桶 | 标准存储 | 数据源，发送事件 |
| **SQS Queue** | 消息队列 | 2小时超时，DLQ | 缓冲事件，重试机制 |
| **Lambda Starter** | 调度器 | 128MB, 1分钟触发 | 检查队列，启动 workers |
| **Fargate Workers** | 计算 | 2 vCPU, 4GB, Spot | 执行同步，自动退出 |
| **S3 Express** | 目标桶 | 单AZ高性能 | 最终存储 |

### 工作流程详解

#### 1️⃣ 事件触发阶段
```
用户操作 → S3 Event → SQS
• 上传文件: ObjectCreated:Put / CompleteMultipartUpload
• 删除文件: ObjectRemoved:Delete / DeleteMarkerCreated
• 延迟: <1秒
```

#### 2️⃣ 调度决策阶段
```
EventBridge (每分钟) → Lambda Starter 检查
• 队列深度 = visible_messages + in_flight_messages
• 当前运行 = running_tasks + pending_tasks
• 启动数量 = min(MAX_WORKERS - 当前运行, 队列深度)
• 策略: 1条消息 = 1个 worker (1:1)
```

#### 3️⃣ Worker 执行阶段
```
Fargate Worker 启动 (冷启动 30-60s)
  ↓
长轮询 SQS (20秒等待)
  ↓
接收到消息 → 解析 S3 事件
  ↓
判断操作类型:
  • ObjectCreated → 执行复制
    - 文件 <5GB: s3.copy_object()
    - 文件 ≥5GB: 256 线程 multipart copy
      └─ 64MB per part, 进度跟踪
  • ObjectRemoved → 执行删除
    - s3.delete_object()
  ↓
成功 → 删除 SQS 消息
失败 → 消息返回队列 (可见性超时)
  ↓
连续3次空轮询 → 自动退出 (~1分钟)
```

#### 4️⃣ 容错机制
```
• Worker 崩溃: SQS 可见性超时 (2小时) → 自动重试
• 重试3次失败: 消息进入 DLQ (死信队列)
• Spot 中断: SIGTERM 捕获 → 消息返回队列 → 优雅退出
• 网络故障: boto3 自动重试 + 指数退避
```

### 扩缩容策略

**自动扩展**：
```python
# Lambda Starter 每分钟执行
queue_depth = visible + in_flight  # 队列总深度
running = RUNNING + PENDING         # 运行中 + 启动中
needed = min(MAX_WORKERS - running, queue_depth)  # 1:1 策略

if needed > 0:
    启动 needed 个 Fargate Workers
```

**自动缩容**：
```python
# Worker 内部逻辑
empty_polls = 0
while True:
    messages = sqs.receive_message(WaitTimeSeconds=20)  # 长轮询
    if not messages:
        empty_polls += 1
        if empty_polls >= 3:  # 连续3次空轮询 (~1分钟)
            退出 Worker
    else:
        empty_polls = 0
        处理消息()
```

### 性能特性

**并发能力**：
- 单 worker: 256 线程 multipart copy
- 多 workers: 最多 MAX_WORKERS 个并发
- 测试结果: 50 workers = 8.6 GB/s (69 Gbps)

**延迟**：
- S3 → SQS: <1秒
- SQS → Lambda 检查: 最多1分钟
- Worker 冷启动: 30-60秒
- 总端到端: 1-2分钟

**成本优化**：
- Lambda: 免费额度内 (<100万请求/月)
- Fargate Spot: 70% 折扣
- 无消息时: $0/月

## 成本估算

**低频场景**（每天 10 个文件，每次 2 分钟）：
- Lambda: 免费（在免费额度内）
- Fargate Spot: ~$0.014/月
- SQS: 免费
- **总计**: <$0.02/月 = **$0.24/年**

**高频场景**（每天 1000 个文件，每次 30 分钟）：
- Lambda: ~$0.001/月
- Fargate Spot: ~$0.21/月
- SQS: 免费
- **总计**: ~$0.22/月 = **$2.64/年**

## 清理资源

```bash
# 删除所有资源（保留 S3 桶）
./cleanup.sh

# 手动删除 S3 桶（可选）
aws s3 rb s3://your-source-bucket --force --region eu-west-1
aws s3 rb s3://your-express-bucket--<az>--x-s3 --force --region eu-west-1
```

## 文件说明

```
s3sync/
├── deploy.sh          # 部署脚本（一键部署所有资源）
├── cleanup.sh         # 清理脚本
├── worker.py          # Worker 主程序（处理 S3 事件）
├── Dockerfile         # Worker 容器镜像
├── requirements.txt   # Python 依赖
└── README.md          # 本文档
```

## 技术原理（简述）

### S3 Express One Zone 限制
- 不支持 S3 Event Notifications
- 不支持 Replication
- 必须从标准桶发送事件，Worker 操作 Express 桶

### 大文件处理
- <5GB: 单次 `CopyObject`
- ≥5GB: 256 线程并发 multipart copy
  - 每个 part 64MB
  - 最大 10,000 parts = 640GB

### 自动扩缩容
- Lambda Starter 检查：`queue_depth / running_workers`
- 启动策略：1:1 (每条消息 1 个 worker)
- 上限：`MAX_WORKERS` (默认 5)
- 自动退出：3 次空轮询（~1 分钟）

### Spot 中断处理
- Fargate 80% Spot + 20% On-Demand
- SIGTERM 捕获 → 消息返回队列
- SQS 可见性超时自动重试

## 许可证

MIT License

## 贡献

欢迎提交 Issue 和 Pull Request。
