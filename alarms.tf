# =========================================================
# 異常検知アラーム群
# ANOMALY_DETECTION_BAND を参照するアラームを PutMetricAlarm すると、
# 同一 Namespace+MetricName+Stat の異常ディテクターが自動作成される。
# band の数値(2/3)はアラーム側パラメータなので、検出器は1つを共有する。
# =========================================================

# --- 仮説X(基準) / 仮説V(1of1) / 仮説W(複合の片側): band=2, 1/1 評価 ---
resource "aws_cloudwatch_metric_alarm" "logins_band2" {
  alarm_name          = "logins-anomaly-band2"
  alarm_description   = "UserLoginsが band=2 の上限バンドを超過（高感度）"
  comparison_operator = "GreaterThanUpperThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold_metric_id = "ad1"
  treat_missing_data  = "missing"

  metric_query {
    id          = "m1"
    return_data = true
    metric {
      namespace   = var.namespace
      metric_name = var.metric_name
      period      = 60
      stat        = "Average"
    }
  }

  metric_query {
    id          = "ad1"
    expression  = "ANOMALY_DETECTION_BAND(m1, 2)"
    label       = "UserLogins (expected band=2)"
    return_data = true
  }
}

# --- 仮説X(比較): band=3, 1/1 評価（低感度＝誤検知を減らす） ---
resource "aws_cloudwatch_metric_alarm" "logins_band3" {
  alarm_name          = "logins-anomaly-band3"
  alarm_description   = "UserLoginsが band=3 の上限バンドを超過（低感度）"
  comparison_operator = "GreaterThanUpperThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold_metric_id = "ad1"
  treat_missing_data  = "missing"

  metric_query {
    id          = "m1"
    return_data = true
    metric {
      namespace   = var.namespace
      metric_name = var.metric_name
      period      = 60
      stat        = "Average"
    }
  }

  metric_query {
    id          = "ad1"
    expression  = "ANOMALY_DETECTION_BAND(m1, 3)"
    label       = "UserLogins (expected band=3)"
    return_data = true
  }
}

# --- 仮説V(比較): band=2, 3/3 評価（フラッピング抑制） ---
resource "aws_cloudwatch_metric_alarm" "logins_3of3" {
  alarm_name          = "logins-anomaly-3of3"
  alarm_description   = "band=2 を 3データポイント連続で超過したらALARM（ノイズ吸収）"
  comparison_operator = "GreaterThanUpperThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold_metric_id = "ad1"
  treat_missing_data  = "missing"

  metric_query {
    id          = "m1"
    return_data = true
    metric {
      namespace   = var.namespace
      metric_name = var.metric_name
      period      = 60
      stat        = "Average"
    }
  }

  metric_query {
    id          = "ad1"
    expression  = "ANOMALY_DETECTION_BAND(m1, 2)"
    label       = "UserLogins (expected band=2)"
    return_data = true
  }
}

# --- 仮説Y: メトリクス欠落(=アプリ停止)を検知する ---
# treat_missing_data="breaching" にすると、データ欠落でALARMに遷移する。
resource "aws_cloudwatch_metric_alarm" "logins_missing_breaching" {
  alarm_name          = "logins-anomaly-missing-breaching"
  alarm_description   = "band=2 超過 OR データ欠落(=投稿停止)でALARM。監視喪失の検知"
  comparison_operator = "GreaterThanUpperThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold_metric_id = "ad1"
  treat_missing_data  = "breaching"

  metric_query {
    id          = "m1"
    return_data = true
    metric {
      namespace   = var.namespace
      metric_name = var.metric_name
      period      = 60
      stat        = "Average"
    }
  }

  metric_query {
    id          = "ad1"
    expression  = "ANOMALY_DETECTION_BAND(m1, 2)"
    label       = "UserLogins (expected band=2)"
    return_data = true
  }
}

# --- 仮説Z(任意): ログイン急減(=障害)を下限バンド割れで検知 ---
# スパイク(上振れ)だけでなく、急減(下振れ)も異常。障害・離脱の早期シグナル。
resource "aws_cloudwatch_metric_alarm" "logins_low_drop" {
  alarm_name          = "logins-anomaly-low-drop"
  alarm_description   = "UserLoginsが下限バンドを下回る（ログイン急減=障害シグナル）"
  comparison_operator = "LessThanLowerThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold_metric_id = "ad1"
  treat_missing_data  = "missing"

  metric_query {
    id          = "m1"
    return_data = true
    metric {
      namespace   = var.namespace
      metric_name = var.metric_name
      period      = 60
      stat        = "Average"
    }
  }

  metric_query {
    id          = "ad1"
    expression  = "ANOMALY_DETECTION_BAND(m1, 2)"
    label       = "UserLogins (expected band=2)"
    return_data = true
  }
}

# =========================================================
# 仮説W: 静的しきい値アラーム + 複合アラーム + SNS
# 異常バンド超過(=誤検知しやすい)だけでは通知せず、
# 静的しきい値も同時に超えたときだけ通知する（誤検知抑制）。
# =========================================================
resource "aws_cloudwatch_metric_alarm" "logins_static_high" {
  alarm_name          = "logins-static-high"
  alarm_description   = "UserLoginsが静的しきい値(${var.static_threshold})を超過"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  metric_name         = var.metric_name
  namespace           = var.namespace
  period              = 60
  statistic           = "Average"
  threshold           = var.static_threshold
  treat_missing_data  = "missing"
}

resource "aws_sns_topic" "alerts" {
  count = var.notification_email != "" ? 1 : 0
  name  = "soa03-anomaly-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.notification_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = var.notification_email
}

resource "aws_cloudwatch_composite_alarm" "logins_composite" {
  alarm_name        = "logins-composite-anomaly-and-static"
  alarm_description = "異常バンド超過 AND 静的しきい値超過の両方が真のときだけALARM（誤検知抑制）"

  alarm_rule = join(" AND ", [
    "ALARM(\"${aws_cloudwatch_metric_alarm.logins_band2.alarm_name}\")",
    "ALARM(\"${aws_cloudwatch_metric_alarm.logins_static_high.alarm_name}\")",
  ])

  alarm_actions = var.notification_email != "" ? [aws_sns_topic.alerts[0].arn] : []
  ok_actions    = var.notification_email != "" ? [aws_sns_topic.alerts[0].arn] : []
}
