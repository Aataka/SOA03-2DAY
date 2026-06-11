#!/usr/bin/env python3
"""TravelApplication/UserLogins を CloudWatch に投稿する。

起動時に過去データを backfill（異常検知モデルの学習用）し、
以降は60秒ごとに現在値を投稿し続ける。

環境変数:
  AWS_DEFAULT_REGION : リージョン
  CW_NAMESPACE       : 名前空間（既定 TravelApplication）
  CW_METRIC          : メトリクス名（既定 UserLogins）
  BACKFILL_DAYS      : 起動時に遡って投入する日数（既定 14, CloudWatchの上限）

backfill は1度だけ実行する（マーカーファイルで再投入を防ぐ）。
"""
import datetime
import math
import os
import random
import time

import boto3

REGION = os.environ.get("AWS_DEFAULT_REGION", "ap-northeast-1")
NAMESPACE = os.environ.get("CW_NAMESPACE", "TravelApplication")
METRIC = os.environ.get("CW_METRIC", "UserLogins")
DAYS = int(os.environ.get("BACKFILL_DAYS", "14"))
MARKER = "/var/lib/login-poster.seeded"

BASE = 65.0   # 1日の平均ログイン数
AMP = 15.0    # 昼夜の振れ幅
NOISE = 6.0   # ばらつき幅(±)。σ≒3.5となり band2/band3 の上限差が約3.5に開く（仮説Xを明確化）

cw = boto3.client("cloudwatch", region_name=REGION)


def value_at(dt: datetime.datetime) -> float:
    """1日周期の正弦波。深夜(6時)が谷、昼(18時)が山。週末はやや低め。"""
    minute_of_day = dt.hour * 60 + dt.minute
    v = BASE + AMP * math.sin(2 * math.pi * (minute_of_day - 360) / 1440.0)
    if dt.weekday() >= 5:  # 土日
        v -= 5
    return max(0.0, v)


def _flush(batch: list) -> int:
    """1バッチを投入。古すぎるタイムスタンプ等で弾かれても例外を握りつぶし、
    backfill全体（とサービス）を止めない。"""
    if not batch:
        return 0
    try:
        cw.put_metric_data(Namespace=NAMESPACE, MetricData=batch)
        return len(batch)
    except Exception as e:
        print(f"WARN: put_metric_data failed for {len(batch)} points: {e}", flush=True)
        return 0


def backfill() -> None:
    """過去 DAYS 日ぶんを1分刻みでまとめて投入する（学習データの種まき）。"""
    now = datetime.datetime.utcnow().replace(second=0, microsecond=0)
    start = now - datetime.timedelta(days=DAYS)
    batch, sent = [], 0
    t = start
    while t < now:
        v = round(value_at(t) + random.uniform(-NOISE, NOISE), 2)
        batch.append(
            {"MetricName": METRIC, "Timestamp": t, "Value": v, "Unit": "Count"}
        )
        # PutMetricData は1コールあたり最大1000データポイント
        if len(batch) == 1000:
            sent += _flush(batch)
            batch = []
        t += datetime.timedelta(minutes=1)
    sent += _flush(batch)
    print(f"backfilled {sent} datapoints over {DAYS} days", flush=True)


def steady_loop() -> None:
    """60秒ごとに現在時刻の正常値を投稿し続ける。"""
    while True:
        now = datetime.datetime.utcnow().replace(second=0, microsecond=0)
        v = round(value_at(now) + random.uniform(-NOISE, NOISE), 2)
        cw.put_metric_data(
            Namespace=NAMESPACE,
            MetricData=[{"MetricName": METRIC, "Timestamp": now, "Value": v, "Unit": "Count"}],
        )
        print(f"posted {METRIC}={v} at {now.isoformat()}Z", flush=True)
        time.sleep(60)


if __name__ == "__main__":
    if not os.path.exists(MARKER):
        try:
            backfill()
        except Exception as e:
            # 何が起きても定常投稿には進む。再起動時の再backfillも防ぐ。
            print(f"WARN: backfill aborted: {e}", flush=True)
        open(MARKER, "w").close()
    else:
        print("backfill already done; skipping", flush=True)
    steady_loop()
