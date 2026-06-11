output "region" {
  value = var.region
}

output "instance_id" {
  description = "投稿用EC2インスタンスID"
  value       = aws_instance.poster.id
}

output "ssm_start_session" {
  description = "Session Managerで接続するコマンド"
  value       = "aws ssm start-session --target ${aws_instance.poster.id} --region ${var.region}"
}

output "detector_state_cmd" {
  description = "異常検知モデルの学習状態を確認するコマンド（仮説U）"
  value       = "aws cloudwatch describe-anomaly-detectors --namespace ${var.namespace} --metric-name ${var.metric_name} --region ${var.region} --query \"AnomalyDetectors[0].StateValue\""
}

output "band_compare_cmd" {
  description = "band=2 と band=3 の上限/下限バンド値を取得するコマンド（仮説X）"
  value       = <<-EOT
    aws cloudwatch get-metric-data --region ${var.region} \
      --start-time $(date -u -d '-15 minutes' +%Y-%m-%dT%H:%M:%SZ) \
      --end-time   $(date -u +%Y-%m-%dT%H:%M:%SZ) \
      --metric-data-queries '[
        {"Id":"m1","MetricStat":{"Metric":{"Namespace":"${var.namespace}","MetricName":"${var.metric_name}"},"Period":60,"Stat":"Average"},"ReturnData":false},
        {"Id":"b2","Expression":"ANOMALY_DETECTION_BAND(m1,2)"},
        {"Id":"b3","Expression":"ANOMALY_DETECTION_BAND(m1,3)"}
      ]'
  EOT
}

output "alarm_names" {
  description = "作成したアラーム一覧"
  value = {
    band2          = aws_cloudwatch_metric_alarm.logins_band2.alarm_name
    band3          = aws_cloudwatch_metric_alarm.logins_band3.alarm_name
    three_of_three = aws_cloudwatch_metric_alarm.logins_3of3.alarm_name
    missing_breach = aws_cloudwatch_metric_alarm.logins_missing_breaching.alarm_name
    low_drop       = aws_cloudwatch_metric_alarm.logins_low_drop.alarm_name
    static_high    = aws_cloudwatch_metric_alarm.logins_static_high.alarm_name
    composite      = aws_cloudwatch_composite_alarm.logins_composite.alarm_name
  }
}

output "sns_topic_arn" {
  description = "SNSトピックARN（notification_email指定時のみ）"
  value       = length(aws_sns_topic.alerts) > 0 ? aws_sns_topic.alerts[0].arn : "（notification_email未指定のため未作成）"
}
