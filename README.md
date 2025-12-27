# S3 到 S3 Express One Zone 同步方案

标准桶作为唯一数据源，自动同步到 S3 Express One Zone 桶（单向同步）。

## 重要背景

- S3 Express One Zone（Directory Bucket）**不支持** S3 Event Notifications / Replication / Versioning
- 事件必须从标准桶发出，Worker 负责操作 Express 桶
- CopyObject 单次最多 5GB，大文件使用 multipart copy（UploadPartCopy）
- 删除事件：如果源桶开启 Versioning，需监听 `DeleteMarkerCreated`

## 方案特点

**架构**：S3 → SQS → Lambda Starter（定时检查）→ ECS Fargate Spot Worker

**特点**：
- ✅ 真正按需，无消息时零成本（Lambda + Fargate Spot 都按使用量计费）
- ✅ 定时触发（1-5 分钟检查间隔，可配置）
- ✅ Fargate Spot 节省 70% 成本（自动 80/20 混合策略）
- ✅ Lambda Starter 轻量调度（检查队列深度 → 按需启动 Worker）
- ✅ Worker 自动关闭（3 次连续空轮询后退出）
- ✅ 大文件支持（>5GB 自动 256 并发 multipart copy）
- ✅ 优雅的 Spot 中断处理（SIGTERM 捕获，消息返回队列）

**成本**（每天 10 个文件，每次运行 2 分钟）：
- Lambda Starter: ~$0.0001/月（128MB，60s 超时，每分钟 1 次）
- Fargate Spot: ~$0.009/月（2 vCPU + 4GB，节省 70%）
- SQS: 免费（每月前 100 万请求免费）
- **总计**: <$0.01/月（**年成本 $0.11**，相比常驻模式节省 99.97%）

## 快速开始

### 前置条件

```bash
# 安装依赖
aws configure  # 配置 AWS 凭证
docker --version  # 确保 Docker 已安装
jq --version  # 确保 jq 已安装
```

### 1. 创建 S3 桶

```bash
# 创建标准桶
aws s3api create-bucket \
  --bucket your-standard-bucket \
  --region eu-north-1 \
  --create-bucket-configuration LocationConstraint=eu-north-1

# 创建 S3 Express One Zone 桶
aws s3api create-bucket \
  --bucket your-express-bucket--eun1-az1--x-s3 \
  --region eu-north-1 \
  --create-bucket-configuration '{
    "Location": {
      "Type": "AvailabilityZone",
      "Name": "eun1-az1"
    },
    "Bucket": {
      "DataRedundancy": "SingleAvailabilityZone",
      "Type": "Directory"
    }
  }'
```

### 2. 部署

```bash
# 编辑变量
vi deploy.sh
# 修改以下变量：
# - REGION
# - SRC_BUCKET
# - DST_BUCKET
# - PREFIX_FILTER（可选）

# 执行部署
./deploy.sh
```

## 架构详解

```
┌─────────────┐
│ S3 标准桶    │ ObjectCreated/Removed 事件
└──────┬──────┘
       ↓
┌──────────────┐
│  SQS 队列    │ 消息缓冲 + 死信队列 (DLQ)
└──────┬───────┘
       ↑
       │ (定时检查，每 1-5 分钟)
       │
┌──────────────────┐
│ Lambda Starter   │ 轻量调度器 (128MB, 60s)
│ EventBridge 定时 │ - 检查 SQS 队列深度
│                  │ - 检查当前运行的 Worker 数
│                  │ - 按需启动 Fargate Spot 任务
└──────┬───────────┘
       ↓ (启动 Worker)
┌──────────────────┐
│ Fargate Spot     │ Worker (2 vCPU + 4GB, ARM64)
│ (80% Spot +      │ - 长轮询 SQS (20s)
│  20% On-Demand)  │ - 处理 S3 事件 (copy/delete)
│                  │ - 大文件 256 并发 multipart
│                  │ - 3 次空轮询后自动退出
│                  │ - SIGTERM 优雅关闭
└──────┬───────────┘
       ↓
┌──────────────────┐
│ S3 Express       │ 目标桶
│ One Zone         │
└──────────────────┘
```

### 工作流程

1. **文件上传到标准桶** → S3 事件发送到 SQS 队列
2. **Lambda Starter 定时检查**（每 1 分钟，可配置 1-5 分钟）：
   - 获取 SQS 队列深度（visible + in-flight 消息）
   - 获取当前运行 + 等待中的 Worker 数量
   - 如果有消息且未达到 MAX_WORKERS → 启动新 Worker
   - 启动策略：每 10 条消息启动 1 个 Worker（最多 MAX_WORKERS=2）
3. **Fargate Spot Worker 处理**：
   - 从 SQS 长轮询接收消息（20 秒等待）
   - 解析 S3 事件（支持批量 Records）
   - 执行操作：
     - ObjectCreated → copy_to_dst（<5GB 单次，≥5GB 并发 multipart）
     - ObjectRemoved → delete_from_dst
   - 成功后删除 SQS 消息（Worker 负责消息删除）
   - 失败 → 消息可见性超时后自动重试（最多 3 次，然后进 DLQ）
4. **自动关闭机制**：
   - Worker 连续 3 次空轮询（每次 20 秒长轮询）→ 约 1 分钟后自动退出
   - Spot 中断（SIGTERM）→ 当前消息返回队列，优雅退出
   - 新消息到达 → Lambda Starter 下次检查时启动新 Worker

## 配置参数

### 关键参数

```bash
# deploy.sh
LAMBDA_POLL_RATE="1"                # Lambda 检查间隔（分钟，1-5 推荐）
MAX_WORKERS=2                       # 最大并发 Worker 数
EMPTY_POLLS_BEFORE_EXIT=3           # Worker 空轮询退出阈值
VISIBILITY_TIMEOUT=7200             # SQS 可见性超时（2 小时，适合大文件）
VISIBILITY_EXTEND_INTERVAL=300      # 处理期间每 5 分钟延长一次
TASK_CPU="2048"                     # 每 Worker CPU（2 vCPU）
TASK_MEMORY="4096"                  # 每 Worker 内存（4GB）
```

### 成本优化

**成本对比**（每天 10 个文件，假设每次运行 2 分钟）：

| 方案 | 计算成本 | 触发成本 | 总月成本 | 年成本 | 节省比例 |
|------|---------|---------|---------|--------|---------|
| 常驻模式（2 workers）| $30.00 | $0 | $30.00 | $360 | - |
| **Lambda + Fargate Spot** | **$0.009** | **$0.0001** | **$0.0091** | **$0.11** | **99.97%** |

**详细定价**（eu-west-1，ARM64）：

1. **Lambda Starter**（每分钟 1 次检查）：
   - 请求：43,200 次/月（60 min × 24 hr × 30 天）
   - 计算时间：~100ms/次 → 4,320 秒/月 = 0.55 GB-秒
   - 成本：免费（每月 100 万请求 + 400,000 GB-秒免费额度）

2. **Fargate Spot Worker**（2 vCPU + 4GB）：
   - On-Demand: $0.04656/小时 → Spot: ~$0.014/小时（70% 节省）
   - 每天 2 分钟 × 30 天 = 1 小时/月
   - 成本：~$0.014/月

3. **SQS**：
   - 免费（每月前 100 万请求免费）

**总计**：<$0.02/月（**年成本 $0.24**）

### 调优建议

| 场景 | LAMBDA_POLL_RATE | TASK_CPU/MEMORY | 月成本估算 |
|------|------------------|-----------------|----------|
| 低频率更新（每天 10 个文件）| 1 分钟 | 2048/4096 | $0.02 |
| 中等频率（每天 50 个文件）| 1 分钟 | 2048/4096 | $0.10 |
| 高频率（每天 200 个文件）| 1 分钟 | 4096/8192 | $0.50 |
| 大文件（>10GB）| 1 分钟 | 4096/8192 | 按使用量 |

### 进一步优化建议

1. **调整 Lambda 检查频率**（降低响应延迟 vs 降低成本）：
```bash
# deploy.sh 中修改
LAMBDA_POLL_RATE="5"  # 5 分钟检查一次（更省钱，适合非紧急场景）
# 或
LAMBDA_POLL_RATE="1"  # 1 分钟检查一次（默认，平衡响应速度和成本）
```

2. **降低 CPU/内存配置**（小文件场景）：
```bash
# deploy.sh 中修改
TASK_CPU="512"     # 0.5 vCPU
TASK_MEMORY="1024" # 1GB
# 再节省约 75%
```

3. **增加并发 Worker**（高吞吐场景）：
```bash
# deploy.sh 中修改
MAX_WORKERS=5  # 最多同时运行 5 个 Worker
# Lambda Starter 会根据队列深度自动启动（每 10 条消息 1 个 Worker）
```

4. **Fargate Spot 中断处理**：
   - Spot 可能被中断（极少发生，通常 <5%）
   - SIGTERM 信号捕获 → 优雅关闭，当前消息返回队列
   - SQS 可见性超时会自动重试
   - 80/20 混合策略自动降级到 On-Demand
   - 无需额外配置

## 文件结构

```
s3sync/
├── deploy.sh                 # 完整部署脚本（Lambda + Fargate Spot）
├── cleanup.sh                # 完整清理脚本
├── Dockerfile                # Worker 容器镜像
├── worker.py                 # Worker 主程序（SQS 轮询 + 自动关闭 + SIGTERM 处理）
├── starter.py                # Lambda Starter 代码（队列检查 + 按需启动）
├── requirements.txt          # Python 依赖（boto3[crt]）
└── README.md                 # 本文档
```

## 监控和管理

### 查看日志

```bash
# Lambda Starter 日志
aws logs tail /aws/lambda/s3-to-s3express-sync-starter \
  --follow --region eu-west-1

# Fargate Worker 日志
aws logs tail /ecs/s3-to-s3express-sync-task \
  --follow --region eu-west-1
```

### 查看运行状态

```bash
# 查看 Lambda Starter 函数配置
aws lambda get-function \
  --function-name s3-to-s3express-sync-starter \
  --region eu-west-1

# 查看 EventBridge 定时规则
aws events describe-rule \
  --name s3-to-s3express-sync-starter-rule \
  --region eu-west-1

# 查看当前运行的 ECS Worker 任务
aws ecs list-tasks \
  --cluster s3-to-s3express-sync-cluster \
  --desired-status RUNNING \
  --region eu-west-1

# 查看 SQS 队列深度
QUEUE_URL=$(aws sqs get-queue-url \
  --queue-name s3-to-s3express-sync-q \
  --region eu-west-1 \
  --query 'QueueUrl' --output text)

aws sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible \
  --region eu-west-1

# 查看死信队列（失败消息）
aws sqs receive-message \
  --queue-url $(aws sqs get-queue-url \
    --queue-name s3-to-s3express-sync-dlq \
    --region eu-west-1 \
    --query 'QueueUrl' --output text) \
  --max-number-of-messages 10 \
  --region eu-west-1
```

## 功能特性

### ✅ 已实现

- [x] 自动同步新增文件（ObjectCreated:*）
- [x] 自动同步更新文件（覆盖写）
- [x] 自动同步删除操作（ObjectRemoved:*）
- [x] 大文件支持（≥5GB 自动 256 并发 multipart copy）
- [x] 前缀过滤（可选）
- [x] 幂等性保证（HeadObject 验证源文件存在）
- [x] 自动重试（SQS 可见性超时 + DLQ）
- [x] 按需启动/关闭（Lambda Starter + Worker 自动退出）
- [x] 定时触发（EventBridge Schedule，1-5 分钟可配置）
- [x] 成本优化（Fargate Spot 80/20 混合 + Lambda 免费额度）
- [x] Spot 中断处理（SIGTERM 捕获，优雅关闭）
- [x] 长时间运行保护（每 5 分钟自动延长可见性超时）

### 核心组件功能

**Lambda Starter** ([starter.py](starter.py)):
```python
1. 队列检查：
   - 获取 SQS 队列深度（visible + in-flight）
   - 获取当前运行的 Worker 数量

2. 智能启动：
   - 启动策略：每 10 条消息启动 1 个 Worker
   - 最大并发控制：MAX_WORKERS=2（可配置）
   - 容量保护：不超过最大 Worker 数

3. Spot 优先：
   - 80% Fargate Spot（base=0, weight=4）
   - 20% Fargate On-Demand（base=0, weight=1）
```

**Fargate Worker** ([worker.py](worker.py)):
```python
1. 智能复制：
   - <5GB: 单次 CopyObject
   - ≥5GB: 256 并发 multipart copy（64MB parts）
   - 幂等性：HeadObject 验证源文件存在

2. 自动关闭：
   - 连续 3 次空轮询（每次 20 秒）→ 约 1 分钟后退出
   - SIGTERM 捕获（Spot 中断）→ 消息返回队列

3. 长时间运行保护：
   - 每 5 分钟自动延长可见性超时（适合大文件）
   - 默认可见性超时：2 小时

4. 错误处理：
   - 处理成功 → 删除 SQS 消息
   - 处理失败 → 可见性超时后自动重试
   - 重试 3 次失败 → 进入死信队列（DLQ）
```

## 测试验证

### 上传测试

```bash
echo "Test file" > test.txt
aws s3 cp test.txt s3://your-standard-bucket/test.txt --region eu-west-1

# 等待处理（最多 1-2 分钟）
# 1. Lambda Starter 下次检查时（最多 1 分钟）
# 2. Worker 启动并处理（约 30-60 秒）

# 实时监控
aws logs tail /aws/lambda/s3-to-s3express-sync-starter --follow --region eu-west-1 &
aws logs tail /ecs/s3-to-s3express-sync-task --follow --region eu-west-1 &

# 验证目标桶
aws s3 ls s3://your-express-bucket--euw1-az1--x-s3/ --region eu-west-1
```

### 删除测试

```bash
aws s3 rm s3://your-standard-bucket/test.txt --region eu-west-1

# 等待处理（最多 1-2 分钟）
# 验证已删除（命令应该失败）
aws s3 ls s3://your-express-bucket--euw1-az1--x-s3/test.txt --region eu-west-1
```

### 大文件测试（multipart copy）

```bash
# 创建 6GB 测试文件
dd if=/dev/zero of=bigfile.bin bs=1M count=6144

# 上传到标准桶
aws s3 cp bigfile.bin s3://your-standard-bucket/bigfile.bin --region eu-west-1

# 监控 Worker 日志（观察 multipart copy 进度）
aws logs tail /ecs/s3-to-s3express-sync-task --follow --region eu-west-1
# 应该看到：
# "Using multipart copy for large file"
# "Uploading 96 parts in parallel (max 256 concurrent)..."
# "Progress: 20/96 parts (20%)"
```

## 故障排除

### Lambda Starter 未启动 Worker

**问题现象**：SQS 有消息，但没有 Worker 启动

```bash
# 1. 检查 Lambda Starter 是否正常运行
aws lambda get-function \
  --function-name s3-to-s3express-sync-starter \
  --region eu-west-1

# 2. 检查 Lambda 最近的调用日志
aws logs tail /aws/lambda/s3-to-s3express-sync-starter \
  --since 10m \
  --region eu-west-1

# 3. 检查 EventBridge 规则是否启用
aws events describe-rule \
  --name s3-to-s3express-sync-starter-rule \
  --region eu-west-1 \
  --query 'State'
# 应该返回 "ENABLED"

# 4. 手动触发 Lambda 测试
aws lambda invoke \
  --function-name s3-to-s3express-sync-starter \
  --region eu-west-1 \
  /tmp/lambda-output.json
cat /tmp/lambda-output.json
```

**常见原因**：
- Lambda IAM 角色权限不足（无法 RunTask）
- ECS 任务定义不存在或无效
- 子网配置错误（无公网访问）

### Worker 启动失败

```bash
# 检查最近失败的 ECS 任务
aws ecs list-tasks \
  --cluster s3-to-s3express-sync-cluster \
  --desired-status STOPPED \
  --region eu-west-1

# 查看任务失败原因
TASK_ARN=$(aws ecs list-tasks \
  --cluster s3-to-s3express-sync-cluster \
  --desired-status STOPPED \
  --region eu-west-1 \
  --query 'taskArns[0]' --output text)

aws ecs describe-tasks \
  --cluster s3-to-s3express-sync-cluster \
  --tasks "$TASK_ARN" \
  --region eu-west-1 \
  --query 'tasks[0].stoppedReason'
```

**常见原因**：
- ECR 镜像不存在或拉取失败
- Task Role 权限不足（无法访问 S3/SQS）
- 子网无公网访问（无法拉取 ECR 镜像）
- CPU/内存配置不兼容

### 文件未同步

```bash
# 1. 检查 SQS 队列深度
QUEUE_URL=$(aws sqs get-queue-url \
  --queue-name s3-to-s3express-sync-q \
  --region eu-west-1 \
  --query 'QueueUrl' --output text)

aws sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names All \
  --region eu-west-1

# 2. 检查死信队列（DLQ）中的失败消息
DLQ_URL=$(aws sqs get-queue-url \
  --queue-name s3-to-s3express-sync-dlq \
  --region eu-west-1 \
  --query 'QueueUrl' --output text)

aws sqs receive-message \
  --queue-url "$DLQ_URL" \
  --max-number-of-messages 10 \
  --region eu-west-1

# 3. 查看 Worker 日志中的错误
aws logs tail /ecs/s3-to-s3express-sync-task \
  --since 1h \
  --region eu-west-1 | grep -i error
```

**常见原因**：
- Task Role 权限不足（无法访问源桶或目标桶）
- S3 Express 桶不存在或命名错误
- 前缀过滤配置错误
- 源文件已删除（幂等性处理）

### 性能问题（处理缓慢）

```bash
# 检查当前运行的 Worker 数量
aws ecs list-tasks \
  --cluster s3-to-s3express-sync-cluster \
  --desired-status RUNNING \
  --region eu-west-1 | jq '.taskArns | length'

# 检查队列积压
aws sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names ApproximateNumberOfMessages \
  --region eu-west-1
```

**解决方案**：
- 增加 MAX_WORKERS（更多并发 Worker）
- 降低 LAMBDA_POLL_RATE（更频繁检查）
- 增加 TASK_CPU/MEMORY（更快处理）
- 检查网络带宽限制

## 清理资源

```bash
# 完整清理所有资源（Lambda + ECS + ECR + SQS + IAM，保留 S3 桶）
./cleanup.sh

# 手动删除 S3 桶（可选）
aws s3 rb s3://your-standard-bucket --force --region eu-west-1
aws s3 rb s3://your-express-bucket--euw1-az1--x-s3 --force --region eu-west-1
```

cleanup.sh 会删除：
- Lambda Starter 函数
- EventBridge 定时规则
- ECS 集群、任务定义
- ECR 仓库和镜像
- SQS 队列（主队列 + DLQ）
- IAM 角色和策略（Lambda Role + Task Role + Exec Role）
- S3 VPC Endpoint（可选）

## 最佳实践

### 1. 前缀过滤

```bash
# 只同步特定前缀（推荐用于大型桶）
PREFIX_FILTER="models/"  # 只同步 models/ 下的文件
```

### 2. 生命周期管理

如果源桶启用了 Lifecycle 过期删除，需额外监听：

```json
{
  "Events": [
    "s3:ObjectCreated:*",
    "s3:ObjectRemoved:*",
    "s3:LifecycleExpiration:*"
  ]
}
```

### 3. 版本控制

如果源桶启用了 Versioning：
- 当前配置已监听 `ObjectRemoved:*`（包含 DeleteMarkerCreated）
- 建议使用 `ObjectRemoved:DeleteMarkerCreated` 精确匹配

### 4. 安全建议

- 使用 IAM 角色最小权限原则
- 启用 S3 桶加密
- 启用 CloudTrail 审计
- 定期检查 DLQ 消息

## 性能指标

### 响应时间

- **S3 → SQS 延迟**: <1 秒
- **Lambda Starter 检查间隔**: 1 分钟（可配置 1-5 分钟）
- **Worker 启动时间**: ~30-60 秒（冷启动，包含镜像拉取）
- **文件同步延迟**: <5 秒（Worker 启动后，小文件）
- **总端到端延迟**: ~1-2 分钟（从上传到同步完成）

### 吞吐量

**单个 Worker**（2 vCPU + 4GB）：

| 文件大小 | 处理时间 | 吞吐量 | 备注 |
|---------|---------|--------|------|
| <1MB | <5s | >200 files/min | 单次 CopyObject |
| 1-100MB | <30s | ~30 files/min | 单次 CopyObject |
| 100MB-1GB | 1-5min | ~10 files/min | 单次 CopyObject |
| 1-5GB | 2-10min | ~6 files/min | 单次 CopyObject |
| >5GB | 256 并发 | ~500-1000 MB/s | Multipart copy，依网络带宽 |

**多 Worker 并发**（MAX_WORKERS=2）：
- 吞吐量线性扩展（2x）
- 适合批量文件同步场景
- Lambda Starter 自动根据队列深度启动 Worker

## 许可证

MIT License

## 贡献

欢迎提交 Issue 和 Pull Request。

## 参考资料

- [S3 Express One Zone 文档](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-express-one-zone.html)
- [S3 Event Notifications](https://docs.aws.amazon.com/AmazonS3/latest/userguide/NotificationHowTo.html)
- [Amazon SQS 文档](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/welcome.html)
- [AWS Lambda 文档](https://docs.aws.amazon.com/lambda/latest/dg/welcome.html)
- [EventBridge Scheduler](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-create-rule-schedule.html)
- [ECS Fargate 定价](https://aws.amazon.com/fargate/pricing/)
- [Fargate Spot](https://aws.amazon.com/blogs/compute/deep-dive-into-fargate-spot-to-run-your-ecs-tasks-for-up-to-70-less/)
- [S3 Multipart Upload](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpuoverview.html)
