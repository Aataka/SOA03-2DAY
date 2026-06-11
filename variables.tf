variable "region" {
  description = "デプロイ先リージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "instance_type" {
  description = "メトリクス投稿用EC2インスタンスタイプ"
  type        = string
  default     = "t3.micro"
}

variable "namespace" {
  description = "ログイン数カスタムメトリクスの名前空間"
  type        = string
  default     = "TravelApplication"
}

variable "metric_name" {
  description = "ログイン数メトリクス名"
  type        = string
  default     = "UserLogins"
}

variable "backfill_days" {
  description = "起動時に遡って投入する学習用データの日数。CloudWatchは過去2週間(14日)まで受理するが、境界での全バッチ拒否を避けるため既定は13"
  type        = number
  default     = 13
}

variable "static_threshold" {
  description = "複合アラーム用の静的しきい値（この値を超え、かつ異常バンド超過でのみ通知）"
  type        = number
  default     = 150
}

variable "notification_email" {
  description = "SNS通知先メール。空文字ならSNSトピック/サブスクリプションを作成しない（仮説W用）"
  type        = string
  default     = ""
}

variable "enable_memory_metrics" {
  description = "CloudWatchエージェント(procstat)でnginx/ssm-agentのメモリを収集する（ラボTask3の運用版）"
  type        = bool
  default     = true
}

variable "auto_stop_minutes" {
  description = "EC2をN分後に自動停止(shutdown=stop)してdestroy忘れの課金を抑えるセーフティネット。0で無効。既定1440(24h)"
  type        = number
  default     = 1440
}
