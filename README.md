# S3 Sync Automation Scripts

自动化配置脚本，用于从京东云通过 DX + TGW 私网上传到 AWS S3，并自动同步到 S3 Express One Zone。

## 架构概述

### Phase 1: 京东云 → 标准 S3 桶
- 京东云 IDC → Direct Connect → Frankfurt DXGW → Transit VIF → eu-north-1 TGW → 业务 VPC
- S3 Interface Endpoint（私网访问）
- Route 53 Resolver Inbound Endpoint（DNS 解析）

### Phase 2: 标准 S3 桶 → S3 Express One Zone
- Lambda 函数监听 S3 事件
- 自动将新上传文件同步到 S3 Express 目录桶

## 前置要求

1. **AWS 环境**
   - 已配置好的 VPC（在 eu-north-1）
   - 至少 2 个私网子网（跨 AZ）
   - Transit Gateway 已连接
   - **S3 Express One Zone 目录桶已创建**（必须）
   - S3 标准桶（可选，可通过脚本自动创建或使用已存在的）

2. **京东云环境**
   - Direct Connect 已建立
   - 能够访问 AWS VPC 的网络连通性

3. **依赖工具**
   - AWS CLI v2
   - jq
   - yq (mikefarah/yq)
   - bash 4.0+

## 安装步骤

### 1. 安装依赖

```bash
# Amazon Linux 2023
sudo yum install -y aws-cli jq

# 安装 yq
sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq
sudo chmod +x /usr/bin/yq
```

### 2. 准备 S3 桶

**S3 Express One Zone 桶**（必须手动创建）：
```bash
# Express 桶必须指定可用区，命名格式：bucket-name--azid--x-s3
aws s3api create-bucket \
  --bucket my-express-bucket--eun1-az1--x-s3 \
  --region eu-north-1 \
  --create-bucket-configuration \
    'Location={Type=AvailabilityZone,Name=eun1-az1},Bucket={Type=Directory,DataRedundancy=SingleAvailabilityZone}'
```

**S3 标准桶**（两种方式）：
- **方式1**：使用已存在的桶，配置 `auto_create: false`
- **方式2**：让脚本自动创建，配置 `auto_create: true`

### 3. 配置

复制配置文件并填入您的环境信息：

```bash
cp config.yaml.example config.yaml
vim config.yaml
```

需要配置的关键参数：
- `vpc_id`: VPC ID
- `subnet_ids`: 私网子网 ID（至少 2 个）
- `jd_cloud_cidr`: 京东云 CIDR 地址段
- `standard_bucket.name`: 标准 S3 桶名称
- `standard_bucket.auto_create`: `false`（使用已存在的桶）或 `true`（脚本自动创建）
- `express_bucket.name`: Express 目录桶名称（完整格式，如 `my-bucket--eun1-az1--x-s3`）

### 4. 运行设置

```bash
# 设置脚本执行权限
chmod +x setup.sh scripts/*.sh

# 完整安装（Phase 1 + Phase 2）
./setup.sh all

# 或分阶段安装
./setup.sh phase1  # 仅 Phase 1
./setup.sh phase2  # 仅 Phase 2
```

## 使用方法

### 完整设置
```bash
./setup.sh all
```

### 分阶段设置

**Phase 1**: 网络和 S3 Interface Endpoint
```bash
./setup.sh phase1
```

完成后需要手动配置：
1. 在京东云 DNS 服务器配置 forwarder，将 `s3.eu-north-1.amazonaws.com` 查询转发到 Resolver IP
2. 验证 DNS 解析：`nslookup s3.eu-north-1.amazonaws.com`
3. 测试上传：`aws s3 cp testfile s3://your-bucket/incoming/`

**Phase 2**: Lambda 同步到 S3 Express
```bash
./setup.sh phase2
```

### 验证配置
```bash
./setup.sh verify
```

验证内容：
- S3 Interface Endpoint 状态
- Route53 Resolver Endpoint 状态
- Lambda 函数配置
- S3 事件通知
- IAM 角色和权限

### 清理资源
```bash
./setup.sh cleanup
```

清理内容：
- Lambda 函数及相关资源
- S3 事件通知配置
- IAM 角色和策略
- S3 Interface Endpoint
- Route53 Resolver Endpoint
- 安全组

注意：默认不删除 S3 桶，需要手动确认。

## 目录结构

```
s3sync/
├── config.yaml                 # 配置文件
├── setup.sh                    # 主设置脚本
├── design.md                   # 设计文档
├── README.md                   # 本文档
├── scripts/
│   ├── common.sh              # 公共函数
│   ├── setup-phase1.sh        # Phase 1 设置脚本
│   ├── setup-phase2.sh        # Phase 2 设置脚本
│   ├── lambda_function.py     # Lambda 函数代码
│   ├── verify.sh              # 验证脚本
│   └── cleanup.sh             # 清理脚本
├── phase1-output.json         # Phase 1 输出（自动生成）
└── phase2-output.json         # Phase 2 输出（自动生成）
```

## 工作流程

### 上传流程
1. 京东云主机上传文件到标准 S3 桶：
   ```bash
   aws s3 cp /path/to/file s3://your-bucket/incoming/ --region eu-north-1
   ```

2. S3 触发 Lambda 函数（ObjectCreated 事件）

3. Lambda 自动将文件同步到 S3 Express 目录桶

4. 查看同步结果：
   ```bash
   aws s3 ls s3://your-express-bucket/ingest/
   ```

### 监控和日志

查看 Lambda 执行日志：
```bash
aws logs tail /aws/lambda/s3-to-express-sync --follow --region eu-north-1
```

查看最近的 Lambda 调用：
```bash
aws lambda list-versions-by-function \
  --function-name s3-to-express-sync \
  --region eu-north-1
```

## 故障排查

### S3 桶相关问题

**标准桶不存在错误**：
```
Bucket does not exist: my-standard-bucket
Either create it manually or set 'auto_create: true' in config.yaml
```
解决方法：
- 手动创建桶，或
- 修改 [config.yaml](config.yaml) 设置 `auto_create: true`

**Express 桶不存在错误**：
```
S3 Express bucket does not exist: my-express-bucket--eun1-az1--x-s3
```
解决方法：
- Express 桶必须手动创建（见上方准备步骤）
- 确认桶名格式正确：`bucket-name--azid--x-s3`

**Express 桶命名格式警告**：
```
Warning: Bucket name doesn't match Express One Zone naming pattern
```
- 检查桶名是否符合格式：`name--azid--x-s3`
- Express 桶必须包含可用区 ID，如 `eun1-az1`

### DNS 解析失败
- 检查 Route53 Resolver Endpoint 状态
- 确认京东云 DNS forwarder 配置正确
- 验证安全组允许 UDP/TCP 53 端口

### 上传失败
- 检查 S3 Interface Endpoint 状态
- 验证路由表配置
- 确认 IAM 凭证有效

### Lambda 同步失败
- 查看 CloudWatch Logs
- 检查 Lambda IAM 角色权限
- 确认 Lambda VPC 配置正确
- 验证 S3 Express 桶存在且可访问

### 网络连接问题
- 确认 TGW 路由配置
- 检查安全组规则（443/TCP）
- 验证 VPC 子网路由表

## 最佳实践

1. **安全**
   - 使用最小权限原则配置 IAM
   - 定期轮换 AWS 凭证
   - 启用 S3 桶版本控制

2. **性能**
   - Lambda 和 Express 桶使用相同 AZ
   - 合理设置 Lambda 内存和超时
   - 考虑批量处理大量文件

3. **成本优化**
   - 定期清理测试文件
   - 使用生命周期策略管理旧版本
   - 监控数据传输成本

4. **监控**
   - 设置 CloudWatch 告警
   - 监控 Lambda 错误率
   - 跟踪 S3 请求指标

## 高级配置

### S3 桶配置选项

**使用已存在的标准桶**：
```yaml
phase1:
  standard_bucket:
    name: your-existing-bucket
    auto_create: false
```

**自动创建标准桶**：
```yaml
phase1:
  standard_bucket:
    name: new-bucket-name
    auto_create: true
```

**Express 桶配置**：
```yaml
phase2:
  express_bucket:
    name: my-bucket--eun1-az1--x-s3  # 必须已存在
    ingest_prefix: ingest/
```

### 修改 Lambda 运行时
在 [config.yaml](config.yaml) 中修改：
```yaml
phase2:
  lambda:
    runtime: python3.12  # 或 python3.11, python3.10
```

### 自定义同步逻辑
编辑 [scripts/lambda_function.py](scripts/lambda_function.py) 以实现：
- 文件过滤
- 路径转换
- 元数据处理
- 错误重试

### 多区域部署
为每个区域创建单独的配置文件：
```bash
cp config.yaml config-eu-north-1.yaml
cp config.yaml config-us-east-1.yaml
```

## 参考文档

- [AWS S3 Interface Endpoints](https://docs.aws.amazon.com/AmazonS3/latest/userguide/privatelink-interface-endpoints.html)
- [S3 Express One Zone](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-express-one-zone.html)
- [Route 53 Resolver](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/resolver.html)
- [Lambda VPC Configuration](https://docs.aws.amazon.com/lambda/latest/dg/configuration-vpc.html)

## 许可证

MIT License

## 支持

如有问题或建议，请提交 Issue。
