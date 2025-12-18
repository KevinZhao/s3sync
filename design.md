Phase 1：京东云 → 标准 S3 桶 上传链路

目标： 京东云虚拟机可以通过 DX + TGW，私网写入 eu-north-1 标准 S3 桶。
	1.	网络连通确认
	•	已有：京东云 IDC → DX → Frankfurt DXGW → Transit VIF → eu-north-1 TGW → 业务 VPC。
	•	检查路由：
	•	京东云 CIDR → VPC CIDR 走 DX；
	•	VPC 子网 Route Table 中，目的京东云 CIDR 指向 TGW Attachment。
	2.	在 eu-north-1 VPC 创建 S3 Interface Endpoint
	•	Service：com.amazonaws.eu-north-1.s3，类型选 Interface。
	•	绑定 VPC 与至少两个私网子网（多 AZ）。
	•	Security Group：允许来自京东云 CIDR / TGW CIDR 的 443/TCP 入站。
	3.	配置 DNS：京东云解析到 Interface Endpoint
	•	在 eu-north-1 VPC 创建 Route 53 Resolver Inbound Endpoint，记录其两个私网 IP。
	•	在京东云侧 DNS 服务器配置 forwarder，将 s3.eu-north-1.amazonaws.com 的查询转发到该 Inbound Endpoint。
	•	验证：在京东云主机上 nslookup s3.eu-north-1.amazonaws.com，返回 VPC 内网 IP（Interface ENI）。
	4.	京东云主机上传验证
	•	配好 AWS 凭证（AK/SK 或 AssumeRole）。
	•	使用 CLI 测试：

aws s3 cp /path/to/file s3://<标准桶名>/incoming/ \
  --region eu-north-1


Phase 2：标准 S3 桶 → S3 Express One Zone 自动同步

目标： 一旦标准桶有新文件，自动同步到指定的 S3 Express One Zone 目录桶。
	1.	前置：Express 目录桶与 Endpoint 已就绪
	•	已在 eu-north-1 创建好目标 目录桶（directory bucket）。
	•	已配置对应的 S3 Express Endpoint（挂在运行计算的子网 Route Table 上）。
	2.	创建同步执行环境（推荐 Lambda）
	•	创建 IAM Role：
	•	对标准桶：s3:GetObject, s3:ListBucket。
	•	对 Express 目录桶：授予必要的 s3express:* 权限（如 CreateSession, PutObject 等）。
	•	创建 Lambda 函数（Region：eu-north-1）：
	•	绑定上述 IAM Role。
	•	配置 VPC 与私网子网（与 Express Endpoint 同 VPC / 同 AZ 优先）。
	3.	实现同步逻辑
	•	Lambda 入口从 S3 Event 读取：
	•	src_bucket = 标准桶
	•	src_key = 对象 Key
	•	目标：
	•	dst_bucket = Express 目录桶
	•	dst_key = 统一前缀（如 ingest/<src_key>）
	•	函数中使用 SDK：
	•	建立 S3 Express 会话；
	•	调用 Copy / Put，将对象从标准桶写入 Express 目录桶。
	4.	配置标准桶的 S3 Event 触发
	•	在标准桶上创建事件通知：
	•	事件类型：ObjectCreated（或指定前缀如 incoming/）。
	•	目标：Phase 2 中的 Lambda 函数。
	•	保存后，任何新对象写入匹配前缀，都会自动触发同步。
	5.	端到端验证
	•	从京东云主机上传一个测试文件到标准桶指定前缀。
	•	检查：
	•	CloudWatch Logs 中 Lambda 执行是否成功；
	•	Express 目录桶中是否出现对应对象路径。