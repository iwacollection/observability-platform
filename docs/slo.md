# SLO 示例

示例服务是 demo-app，目标也可以套到任何发出 `http.server.request.duration` 的服务。规则在 `config/prometheus/rules/recording.yml` 和 `alerts.yml`。`/healthz` 不计入。

## 目标

| 名称 | 目标 | 错误预算（30 天） | 好请求 |
| --- | --- | --- | --- |
| 可用性 | 99.9% | 0.1% | HTTP 状态不是 5xx |
| 延迟 | 99% | 1% | 延迟 ≤ 300ms |

300ms 对应直方图上的 `le="0.3"`。Demo 的 bucket 边界包含 0.3，所以这个阈值落在桶上，而不是被插值摊薄。

## 记录规则

- `slo:http_requests:rate5m`：非探针 QPS。
- `slo:http_errors:ratio_rate5m` 到 `ratio_rate3d`：5xx 占比。
- `slo:http_latency_good:ratio_rate5m`、`1h`、`6h`：落在 300ms 以内的占比。

窗口和 Prometheus 的 `rate()` 对齐。多窗口烧录用一长一短，避免单点毛刺直接升级。

## 烧录告警

可用性预算系数是 `0.001`，延迟预算系数是 `0.01`。

| 告警 | 烧录倍数 | 短窗口 | 长窗口 | 严重级别 | 含义 |
| --- | --- | --- | --- | --- | --- |
| SLOAvailabilityFastBurn | 14.4 | 5m | 1h | critical | 约 1 小时烧掉 30 天预算的 2%，该叫人 |
| SLOAvailabilitySlowBurn | 6 | 30m | 6h | warning | 约 6 小时烧掉 5%，该开单 |
| SLOLatencyFastBurn | 14.4 | 5m | 1h | critical | 延迟目标同样按快烧处理 |

倍数来自 SRE workbook 的多窗口多烧录：`14.4 = 2% / (1h / 30d)`，`6 = 5% / (6h / 30d)`。

除此之外还有不挂 SLO 名字的症状告警：`HighErrorRate`（5 分钟 5xx 超过 5%，且 QPS > 0.1）和 `HighLatency`（p95 > 500ms）。它们比烧录更早、更吵，用来在预算计算还没积累够窗口时看见问题。

业务支付失败不是这组 HTTP SLO。`/api/checkout?fail=1` 返回 HTTP 200，失败记在 `business_payments_total{result="failure"}`。双窗口告警是 `BusinessPaymentFailureBurn`，短窗口 5 分钟失败比超过 20%，长窗口 1 小时超过 10%。记录规则是 `business:payments:failure_ratio5m` 和 `business:payments:failure_ratio1h`。

## 和 Alertmanager 的关系

`severity=critical` 进 `critical` 接收器，`warning` 进 `warning` 接收器。这两个接收器默认是空的，Alertmanager 会留下告警但不外发。要接到真实系统，把路由改到 `webhook-example`，或给带 `notify=webhook` 标签的告警走示例 webhook，再把 URL 换成你自己的地址。不要把 token 写进 git。

同一 `alertname` + `service_name` + `namespace` + `job` 上，critical 会抑制 warning。

## 改一个新的 SLO

1. 在 `recording.yml` 增加好事件比率，标签至少保留 `service_name`。
2. 按上面的倍数写一对快烧 / 慢烧，`for` 不要短于短窗口的一个评估周期。
3. 用 `promtool test rules config/prometheus/tests/alerts_test.yml` 补一条输入序列。
4. 在 Grafana 的 Overview 或服务仪表盘加一条同样的表达式，避免告警和看图各写一套。
