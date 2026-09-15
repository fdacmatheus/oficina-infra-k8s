# ---------------------------------------------------------------------------
# Dashboards como codigo
# O sidecar do Grafana carrega todo ConfigMap rotulado com grafana_dashboard,
# entao os paineis ficam versionados neste repositorio e sao recriados a cada
# apply, sem configuracao manual na interface.
# ---------------------------------------------------------------------------
resource "kubernetes_config_map" "dashboards" {
  for_each = fileset("${path.module}/dashboards", "*.json")

  metadata {
    name      = "grafana-dashboard-${trimsuffix(each.value, ".json")}"
    namespace = kubernetes_namespace.monitoring.metadata[0].name

    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    (each.value) = file("${path.module}/dashboards/${each.value}")
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

# ---------------------------------------------------------------------------
# ServiceMonitor e PrometheusRule
# Sao Custom Resources do prometheus-operator. Declara-los com
# kubernetes_manifest exigiria que a CRD ja existisse no momento do plan, o que
# impede um apply a partir do zero. Por isso sao entregues como valores do
# proprio chart, que os renderiza depois de instalar as CRDs.
# ---------------------------------------------------------------------------
locals {
  # Coleta das metricas expostas pela aplicacao em /api/metrics.
  service_monitors = {
    additionalServiceMonitors = [{
      name              = "oficina-api"
      namespaceSelector = { matchNames = [var.namespace] }
      selector          = { matchLabels = { app = "oficina-api" } }

      endpoints = [{
        port     = "http"
        path     = "/api/metrics"
        interval = "15s"
      }]
    }]
  }

  # Alertas cobrindo os quatro eixos exigidos: disponibilidade, desempenho,
  # recursos do cluster e falhas no processamento de ordens de servico.
  alertas = {
    "oficina-disponibilidade" = {
      groups = [{
        name = "oficina.disponibilidade"
        rules = [
          {
            alert  = "ApiIndisponivel"
            expr   = "up{job=\"oficina-api\"} == 0"
            for    = "2m"
            labels = { severity = "critical" }
            annotations = {
              summary     = "A Oficina API esta fora do ar"
              description = "O alvo {{ $labels.instance }} nao responde ao scrape ha 2 minutos."
            }
          },
          {
            alert  = "PodsReiniciandoEmLoop"
            expr   = "increase(kube_pod_container_status_restarts_total{namespace=\"oficina\"}[15m]) > 3"
            for    = "5m"
            labels = { severity = "warning" }
            annotations = {
              summary     = "Pod {{ $labels.pod }} reiniciando repetidamente"
              description = "Mais de 3 reinicios em 15 minutos, provavel falha de liveness probe."
            }
          },
        ]
      }]
    }

    "oficina-desempenho" = {
      groups = [{
        name = "oficina.desempenho"
        rules = [
          {
            alert  = "LatenciaAlta"
            expr   = "histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{job=\"oficina-api\"}[5m]))) > 1"
            for    = "5m"
            labels = { severity = "warning" }
            annotations = {
              summary     = "Latencia p95 acima de 1 segundo"
              description = "O percentil 95 das requisicoes esta em {{ $value }}s."
            }
          },
          {
            alert  = "TaxaErro5xxAlta"
            expr   = "sum(rate(http_requests_total{job=\"oficina-api\",status=~\"5..\"}[5m])) / clamp_min(sum(rate(http_requests_total{job=\"oficina-api\"}[5m])), 0.001) > 0.05"
            for    = "5m"
            labels = { severity = "critical" }
            annotations = {
              summary     = "Mais de 5% das respostas sao erro de servidor"
              description = "Taxa atual: {{ $value | humanizePercentage }}."
            }
          },
          {
            alert  = "HpaNoTeto"
            expr   = "kube_horizontalpodautoscaler_status_current_replicas{namespace=\"oficina\"} >= kube_horizontalpodautoscaler_spec_max_replicas{namespace=\"oficina\"}"
            for    = "10m"
            labels = { severity = "warning" }
            annotations = {
              summary     = "HPA no numero maximo de replicas"
              description = "A aplicacao esta no teto de escala ha 10 minutos; avaliar aumento do maxReplicas."
            }
          },
        ]
      }]
    }

    "oficina-negocio" = {
      groups = [{
        name = "oficina.negocio"
        rules = [
          {
            alert  = "FalhaProcessamentoOrdemServico"
            expr   = "increase(oficina_ordem_servico_erros_total[10m]) > 0"
            for    = "1m"
            labels = { severity = "critical" }
            annotations = {
              summary     = "Falha no processamento de ordens de servico"
              description = "{{ $value }} erro(s) ao processar OS nos ultimos 10 minutos, operacao {{ $labels.operacao }}."
            }
          },
          {
            alert  = "FalhaIntegracaoNotificacao"
            expr   = "increase(oficina_integracao_falhas_total{integracao=\"email\"}[15m]) > 5"
            for    = "5m"
            labels = { severity = "warning" }
            annotations = {
              summary     = "Notificacoes por e-mail falhando"
              description = "Clientes podem nao estar sendo avisados das mudancas de status da OS."
            }
          },
          {
            alert  = "OrdensParadasAguardandoAprovacao"
            expr   = "oficina_ordens_servico_por_status{status=\"AGUARDANDO_APROVACAO\"} > 20"
            for    = "30m"
            labels = { severity = "info" }
            annotations = {
              summary     = "Acumulo de ordens aguardando aprovacao do cliente"
              description = "{{ $value }} ordens aguardando resposta do orcamento."
            }
          },
        ]
      }]
    }
  }
}
