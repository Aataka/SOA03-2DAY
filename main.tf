# =========================================================
# データソース: デフォルトVPC / サブネット / 最新AL2023 AMI
# =========================================================
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# =========================================================
# IAM: EC2 が SSM 接続 + メトリクス Put/Get + CWエージェント
# =========================================================
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name_prefix        = "soa03-anomaly-ec2-"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

# Session Manager 接続用
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# CloudWatch エージェント (procstat メモリ)
resource "aws_iam_role_policy_attachment" "cwagent" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# backfill/投稿スクリプトが get-metric-data も使うため明示付与
resource "aws_iam_role_policy" "metrics" {
  name_prefix = "cw-metrics-"
  role        = aws_iam_role.ec2.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["cloudwatch:PutMetricData", "cloudwatch:GetMetricData", "cloudwatch:ListMetrics"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name_prefix = "soa03-anomaly-"
  role        = aws_iam_role.ec2.name
}

# =========================================================
# セキュリティグループ: インバウンドなし（SSMのみ）/ アウトバウンド全許可
# =========================================================
resource "aws_security_group" "ec2" {
  name_prefix = "soa03-anomaly-sg-"
  description = "No inbound (SSM only), egress all"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "all outbound (SSM endpoints / CloudWatch)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "soa03-anomaly-sg" }
}

# =========================================================
# EC2: UserLogins を backfill + 60秒ごとに投稿し続けるインスタンス
# =========================================================
resource "aws_instance" "poster" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.instance_type
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.ec2.id]
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    region                = var.region
    namespace             = var.namespace
    metric_name           = var.metric_name
    backfill_days         = var.backfill_days
    enable_memory_metrics = var.enable_memory_metrics
    auto_stop_minutes     = var.auto_stop_minutes
    seed_script_b64       = base64encode(file("${path.module}/scripts/seed_and_post.py"))
    inject_script_b64     = base64encode(file("${path.module}/scripts/inject_anomaly.py"))
    agent_config_b64      = base64encode(file("${path.module}/scripts/cw-agent-config.json"))
  })

  # ルートEBS: destroy/terminate時に確実に削除（クリーンアップ保証）
  root_block_device {
    volume_size           = 8
    volume_type           = "gp3"
    delete_on_termination = true
  }

  # IMDSv2 必須化
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = { Name = "soa03-anomaly-poster" }
}
