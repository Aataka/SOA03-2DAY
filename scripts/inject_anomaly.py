#!/usr/bin/env python3
"""異常スパイクを注入する（Round2 の検証用）。

指定した分数だけ、正常値より大幅に高い値を投稿する。
仮説X(band比較) / 仮説V(フラッピング) の発火を起こすために使う。

環境変数:
  AWS_DEFAULT_REGION : リージョン
  CW_NAMESPACE       : 名前空間（既定 TravelApplication）
  CW_METRIC          : メトリクス名（既定 UserLogins）
  SPIKE_VALUE        : 投稿する高値（既定 200）
  SPIKE_MINUTES      : 何分間スパイクを出すか（既定 8）

注: 定常投稿(login-poster)を止めずに実行すると、同一分に正常値とスパイクの
両方が入り Average が中間値になる。クリーンなスパイクが欲しい場合は
`sudo systemctl stop login-poster` してから実行する（README参照）。
"""
import datetime
import os
import time

import boto3

REGION = os.environ.get("AWS_DEFAULT_REGION", "ap-northeast-1")
NAMESPACE = os.environ.get("CW_NAMESPACE", "TravelApplication")
METRIC = os.environ.get("CW_METRIC", "UserLogins")
SPIKE_VALUE = float(os.environ.get("SPIKE_VALUE", "200"))
SPIKE_MINUTES = int(os.environ.get("SPIKE_MINUTES", "8"))

cw = boto3.client("cloudwatch", region_name=REGION)

for i in range(SPIKE_MINUTES):
    now = datetime.datetime.utcnow().replace(second=0, microsecond=0)
    cw.put_metric_data(
        Namespace=NAMESPACE,
        MetricData=[{"MetricName": METRIC, "Timestamp": now, "Value": SPIKE_VALUE, "Unit": "Count"}],
    )
    print(f"spike {METRIC}={SPIKE_VALUE} at {now.isoformat()}Z ({i + 1}/{SPIKE_MINUTES})", flush=True)
    if i < SPIKE_MINUTES - 1:
        time.sleep(60)
