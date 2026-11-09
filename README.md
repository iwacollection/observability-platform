# Observability Platform

可观测性平台相关的架构实践、故障案例与可靠性改进记录。

## Incident Reviews

- [2024-12-11 OpenAI Kubernetes 控制面过载事故复盘](docs/incidents/2024-12-11-openai-kubernetes-control-plane-overload.md)
  - 聚焦遥测服务 API 负载放大、Kubernetes API Server 过载、DNS 缓存导致的延迟故障暴露、止血恢复和后续优化。
  - 严格区分官方确认事实与本文提出的工程整改建议，不将未经证实的 CFS、etcd、CNI 等因素列为事故根因。
