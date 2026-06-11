# SOA03-2DAY — CloudWatch 異常検知を「想定→実測検証」する

AWS Skill Builder ラボ *DevOps and AI on AWS: CloudWatch Anomaly Detection* を題材に、
**ラボUIをなぞるのではなく Terraform で独立再構築し、自分のアカウントで実測検証する**ためのIaC一式。

CloudWatch 異常検知（`ANOMALY_DETECTION_BAND`）を本番運用に載せるとき、ラボが省いている
「学習」「誤検知」「監視喪失」「フラッピング」「通知設計」をすべて実測で確認する。

## 検証する想定（仮説）

| ID | 想定 | 検証で出す実測値 |
|----|------|------------------|
| **U** | 異常検知は過去データがないと学習できず `data insufficient` のまま。`put-metric-data` で過去最大14日をbackfillすれば当日中に学習が成立する | `StateValue` が `PENDING_TRAINING`→`TRAINED` になるまでの時間 |
| **X** | バンド幅（標準偏差の数）が誤検知量を左右する。`BAND(m1,2)` と `(m1,3)` で同じスパイクの発火有無が変わる | band=2 と band=3 の上限値の差、同一スパイクでのALARM発火有無 |
| **Y** | メトリクス欠落（=アプリ停止）はデフォルトでは見逃す。`treat_missing_data="breaching"` で監視喪失を検知できる | 投稿停止→ALARM遷移までの分数 |
| **V** | 評価データポイント数（M-of-N）でフラッピングを抑制できる。`1/1` は即ALARM、`3/3` はノイズ吸収 | 同一スパイクでの `1/1` と `3/3` の遷移差 |
| **W** | 異常アラーム単独通知は誤検知でうるさい→静的しきい値との複合アラームで抑制。SNS通知も実装 | 複合アラームの発火抑制、SNS到達 |
| **Z**(任意) | 上振れだけでなく**ログイン急減(=障害)も異常**。下限バンド割れ(`LessThanLowerThreshold`)で早期検知できる | 低値注入→`low-drop`アラームのALARM遷移 |

## 構成

```
default VPC / public subnet
└─ EC2 (t3.micro, AL2023, SSMのみ・SSH鍵なし)
   ├─ login-poster.service … 起動時に13日backfill → 60秒ごとに UserLogins を投稿
   └─ CloudWatch Agent(procstat) … nginx / ssm-agent のメモリを HostResources へ(任意)
        ↓ put-metric-data
   CloudWatch メトリクス (TravelApplication/UserLogins)
        ↓ ANOMALY_DETECTION_BAND（検出器は自動作成・1つを共有）
   アラーム群:
     logins-anomaly-band2            (band2, 1/1)   … X基準 / V(1of1) / W片側
     logins-anomaly-band3            (band3, 1/1)   … X比較
     logins-anomaly-3of3             (band2, 3/3)   … V比較
     logins-anomaly-missing-breaching(band2, 3/3, breaching) … Y
     logins-anomaly-low-drop         (band2下限, 3/3) … Z(任意)
     logins-static-high              (static>150)   … W片側
     logins-composite-...            (band2 AND static) → SNS … W
```

> **コスト安全装置**: EC2は `auto_stop_minutes`(既定1440=24h)後に自動**停止**(terminateではない)。
> destroyを忘れてもEC2課金が頭打ちになる。`-var="auto_stop_minutes=0"` で無効化可。

## 前提ツール

```bash
terraform -version   # >= 1.5
aws --version        # v2
aws sts get-caller-identity   # 認証済みであること
```

## デプロイ

```bash
terraform init
terraform fmt -check
terraform validate
terraform plan

# SNS通知(仮説W)も試すなら notification_email を渡す。省略するとSNSは作られない。
# terraform.tfvars に notification_email = "you@example.com" と書いてもよい（.gitignore済み）。
terraform apply -var="notification_email=you@example.com"
```

`apply` 直後に EC2 が backfill を実行する（数分）。`StateValue` が `TRAINED` になるまでは
アラームは `INSUFFICIENT_DATA`。**A案（2回に分ける）運用**: ここで一旦放置し、学習完了後に
Round2 を実施する（EC2を止めずに置いても課金は数円）。

---

## 検証Runbook

### Round 1 — 仕込み（apply 当日）

```bash
# 1) backfill が完了したか（EC2のログ）
aws ssm start-session --target <INSTANCE_ID> --region <REGION>
sudo journalctl -u login-poster -n 20 --no-pager   # "backfilled NNNN datapoints" を確認

# 2) 学習状態をポーリング（仮説U）
aws cloudwatch describe-anomaly-detectors \
  --namespace TravelApplication --metric-name UserLogins --region <REGION> \
  --query "AnomalyDetectors[0].StateValue"
# PENDING_TRAINING → TRAINED になった時刻を記録
```

### Round 2 — 実測（学習完了後）

**STEP A 仮説X: まず band2 と band3 の実バンド値を測る**
```bash
# terraform output band_compare_cmd の中身を実行。b2(High) と b3(High) の実値を記録。
# 例: b2_High≈83, b3_High≈90。この2値の「あいだ」がXの肝。
```

**STEP B 仮説X: 中程度スパイクで「band2だけ発火・band3は発火しない」を作る**
```bash
aws ssm start-session --target <INSTANCE_ID> --region <REGION>
sudo systemctl stop login-poster        # クリーンな単一値スパイクのため定常投稿を止める
# ★重要: SPIKE_VALUE は b2_High より上・b3_High より下に設定する（例 87）。
#   200のような大スパイクだと band3 も超えてしまい X の差が出ない。
sudo SPIKE_VALUE=87 SPIKE_MINUTES=8 AWS_DEFAULT_REGION=<REGION> \
     python3 /opt/poster/inject_anomaly.py
# 別ターミナルで観測:
aws cloudwatch describe-alarms \
  --alarm-names logins-anomaly-band2 logins-anomaly-band3 \
  --region <REGION> --query "MetricAlarms[].[AlarmName,StateValue]" --output table
# 期待: band2=ALARM / band3=OK（=低感度band3が誤検知を吸収）。実測を記録。
```

**STEP C 仮説V: 大スパイクで 1/1 と 3/3 のフラッピング差を見る**
```bash
sudo systemctl stop login-poster
sudo SPIKE_VALUE=200 SPIKE_MINUTES=8 AWS_DEFAULT_REGION=<REGION> \
     python3 /opt/poster/inject_anomaly.py
aws cloudwatch describe-alarms \
  --alarm-names logins-anomaly-band2 logins-anomaly-3of3 \
  --region <REGION> --query "MetricAlarms[].[AlarmName,StateValue]" --output table
# 期待: band2(1/1)=1〜数分でALARM / 3of3=3データポイント連続後に遷移。遷移時刻の差を記録。
```

**仮説Y: メトリクス欠落の検知**
```bash
sudo systemctl stop login-poster   # 投稿停止（=アプリ停止相当）
# 以降、欠落が3データポイント続くと breaching アラームがALARMへ
aws cloudwatch describe-alarms --alarm-names logins-anomaly-missing-breaching logins-anomaly-band2 \
  --region <REGION> --query "MetricAlarms[].[AlarmName,StateValue,StateReason]" --output table
# breaching=ALARM へ遷移 / 通常(missing)=INSUFFICIENT_DATA 止まり、までの分数を記録
```

**仮説W: 複合アラーム + SNS**
```bash
# 定常投稿を戻し、再度スパイク注入（static>150 かつ band超過 の両立を作る）
sudo systemctl start login-poster
aws cloudwatch describe-alarms --alarm-types CompositeAlarm \
  --alarm-names logins-composite-anomaly-and-static --region <REGION> \
  --query "CompositeAlarms[].[AlarmName,StateValue]" --output table
# 片側だけ(band超過だが static未満)では通知されないことを確認 → SNSメール受信を記録
```

**仮説Z(任意): ログイン急減(=障害)の検知**
```bash
sudo systemctl stop login-poster          # 定常投稿を止める
# 下限バンド(≈50)を下回る低値を注入（例 10）
sudo SPIKE_VALUE=10 SPIKE_MINUTES=8 AWS_DEFAULT_REGION=<REGION> \
     python3 /opt/poster/inject_anomaly.py
aws cloudwatch describe-alarms --alarm-names logins-anomaly-low-drop \
  --region <REGION> --query "MetricAlarms[].[AlarmName,StateValue]" --output table
# 期待: low-drop=ALARM（急減=障害シグナルを上振れと別に捕捉）。遷移分数を記録。
```

### クリーンアップ（必須）

```bash
terraform destroy -var="notification_email=you@example.com"

# 異常検出器がアラーム削除後も残る場合は明示削除
aws cloudwatch delete-anomaly-detector \
  --namespace TravelApplication --metric-name UserLogins --stat Average --region <REGION>
# 残存確認（空配列なら完了）
aws cloudwatch describe-anomaly-detectors --region <REGION> \
  --namespace TravelApplication --metric-name UserLogins
```

---

## ハマりどころ（実測で更新する）

- **異常検知は新規メトリクスでは即動かない**。backfill しないと `data insufficient` のまま。
  CloudWatch は過去14日(2週間)まで `put-metric-data` のタイムスタンプを受理する（それ以前は拒否）。
  境界ちょうどだと最古バッチが丸ごと弾かれることがあるため、本構成は安全側で `backfill_days=13`。
- **検出器はアラーム削除では消えないことがある** → `delete-anomaly-detector` で明示削除。
- **CWエージェントの procstat 設定**は `measurement` を**文字列配列**で書く（`["memory_rss"]`）。
  `{name,rename,unit}` のオブジェクト形式はスキーマエラー（`Invalid type. Expected: string, given: object`）で
  agent起動に失敗する。メトリクスは `HostResources/procstat_memory_rss`、ディメンションはラボの
  `ProcessName` と異なり `pattern`/`InstanceId` になる（運用版に置換しているため）。
- SNSメール購読が確認直後に解除される場合は
  `aws sns confirm-subscription --authenticate-on-unsubscribe true`（リンク直クリックを避ける）。

## コスト（改善込み・東京リージョン）

支配項はEC2起動時間。メトリクス(約3)＋アラーム(異常5＋静的1＋複合1)＋API＋SNSは合計でも月額$2.7前後を時間按分した数円。

| シナリオ | EC2＋EBS | メトリクス＋アラーム他 | 合計 |
|---|---|---|---|
| 約5hで検証完了→destroy | $0.07 | $0.02 | **約$0.09 ≈ 14円** |
| 一晩(24h)→翌朝destroy | $0.35 | $0.10 | **約$0.45 ≈ 68円** |
| destroy忘れ1週間（**24h自動停止あり**） | $0.33(停止で頭打ち)＋EBS$0.15 | $0.50 | **約$1.0 ≈ 150円** |
| （参考）自動停止なしで1ヶ月放置 | 約$9.7 | 約$2.7 | 約$12 ≈ 1,800円 |

→ **24時間自動停止**がEC2課金を頭打ちにするため、最悪ケースでも数百円で収まる（自動停止なしの月放置だと500円を超える）。
検証後は必ず `destroy` し、`describe-anomaly-detectors` が空になるまで確認する。
