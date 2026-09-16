# ---------------------------------------------------------------------------
# Namespace da aplicacao
# ---------------------------------------------------------------------------
resource "kubernetes_namespace" "oficina" {
  metadata {
    name = var.namespace

    labels = {
      "app.kubernetes.io/part-of" = var.project
    }
  }

  depends_on = [aws_eks_node_group.this]
}

# ---------------------------------------------------------------------------
# Credenciais do banco
# Lidas do Secrets Manager (populado pelo repositorio oficina-infra-database) e
# materializadas como Secret do Kubernetes. A aplicacao consome via envFrom, de
# modo que nenhuma senha existe em manifesto versionado.
# ---------------------------------------------------------------------------
data "aws_secretsmanager_secret_version" "database" {
  secret_id = data.terraform_remote_state.database.outputs.db_secret_arn
}

resource "kubernetes_secret" "database" {
  metadata {
    name      = "oficina-db-credentials"
    namespace = kubernetes_namespace.oficina.metadata[0].name
  }

  data = jsondecode(data.aws_secretsmanager_secret_version.database.secret_string)

  type = "Opaque"
}

# ---------------------------------------------------------------------------
# Segredo de assinatura do JWT
# Publicado pelo repositorio oficina-lambda-auth. A aplicacao precisa do mesmo
# segredo para que o token emitido pela function serverless seja aceito pelos
# guards do NestJS.
# ---------------------------------------------------------------------------
data "aws_secretsmanager_secret" "jwt" {
  count = var.jwt_secret_name == "" ? 0 : 1
  name  = var.jwt_secret_name
}

data "aws_secretsmanager_secret_version" "jwt" {
  count     = var.jwt_secret_name == "" ? 0 : 1
  secret_id = data.aws_secretsmanager_secret.jwt[0].id
}

resource "kubernetes_secret" "api" {
  metadata {
    name      = "oficina-api-secrets"
    namespace = kubernetes_namespace.oficina.metadata[0].name
  }

  data = var.jwt_secret_name == "" ? {
    JWT_SECRET         = "desenvolvimento-sem-secrets-manager"
    JWT_REFRESH_SECRET = "desenvolvimento-sem-secrets-manager"
    } : merge(
    jsondecode(data.aws_secretsmanager_secret_version.jwt[0].secret_string),
    {
      # O refresh token e exclusivo da autenticacao administrativa da
      # aplicacao e nao trafega pela function serverless.
      JWT_REFRESH_SECRET = sha256(jsondecode(data.aws_secretsmanager_secret_version.jwt[0].secret_string)["JWT_SECRET"])
    }
  )

  type = "Opaque"
}

# ---------------------------------------------------------------------------
# Exposicao da aplicacao
# O Service pertence a camada de infraestrutura porque e ele quem provisiona o
# Network Load Balancer consumido pelo API Gateway. O Deployment e o HPA
# pertencem ao repositorio da aplicacao e sao alcancados por label selector,
# de modo que a ordem de deploy entre os dois repositorios e indiferente.
# ---------------------------------------------------------------------------
resource "kubernetes_service" "api" {
  metadata {
    name      = "oficina-api"
    namespace = kubernetes_namespace.oficina.metadata[0].name

    annotations = {
      "service.beta.kubernetes.io/aws-load-balancer-type"             = "nlb"
      "service.beta.kubernetes.io/aws-load-balancer-internal"         = "true"
      "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type"  = "ip"
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-path" = "/api/health"
    }
  }

  spec {
    type = "LoadBalancer"

    selector = {
      app = "oficina-api"
    }

    port {
      name        = "http"
      port        = 80
      target_port = 3000
      protocol    = "TCP"
    }
  }

  # O NLB leva alguns minutos para ficar ativo; sem isso o API Gateway seria
  # criado apontando para um hostname ainda vazio.
  wait_for_load_balancer = true

  depends_on = [
    aws_eks_addon.vpc_cni,
    aws_eks_addon.coredns,
  ]
}

# ---------------------------------------------------------------------------
# Observabilidade
# ---------------------------------------------------------------------------
resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }

  depends_on = [aws_eks_node_group.this]
}

# Stack kube-prometheus: Prometheus, Alertmanager, Grafana e os exporters de
# node e de kube-state-metrics em um unico release.
resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "65.1.1"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  timeout = 900

  values = [yamlencode({
    grafana = {
      adminPassword = var.grafana_admin_password

      service = {
        type = "LoadBalancer"
        annotations = {
          "service.beta.kubernetes.io/aws-load-balancer-type"   = "nlb"
          "service.beta.kubernetes.io/aws-load-balancer-scheme" = "internet-facing"
        }
      }

      # Dashboards versionados como codigo: provisionados a partir do
      # ConfigMap gerado por dashboards.tf.
      sidecar = {
        dashboards = {
          enabled         = true
          label           = "grafana_dashboard"
          searchNamespace = "ALL"
        }
      }

      defaultDashboardsTimezone = "America/Sao_Paulo"
    }

    # Alertas definidos em observabilidade.tf, renderizados pelo proprio chart
    # depois que as CRDs do operador ja existem no cluster.
    additionalPrometheusRulesMap = local.alertas

    prometheus = merge(local.service_monitors, {
      prometheusSpec = {
        retention = "6h"

        # Descobre automaticamente os ServiceMonitor de qualquer namespace,
        # incluindo o da aplicacao.
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
        ruleSelectorNilUsesHelmValues           = false

        resources = {
          requests = { cpu = "200m", memory = "512Mi" }
          limits   = { memory = "1Gi" }
        }

        # Sem volume persistente: o driver EBS CSI exige a policy
        # AmazonEBSCSIDriverPolicy na role dos nodes, e o AWS Academy Learner
        # Lab nao concede iam:AttachRolePolicy. Com retencao de 6 horas o
        # armazenamento efemero atende — a serie historica longa nao faz parte
        # do escopo do desafio.
        storageSpec = {
          emptyDir = { medium = "" }
        }
      }
    })

    alertmanager = {
      alertmanagerSpec = {
        resources = {
          requests = { cpu = "50m", memory = "128Mi" }
        }
      }
    }

    # O metrics-server ja vem como addon gerenciado do EKS.
    prometheusOperator = {
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
      }
    }
  })]

  depends_on = [
    aws_eks_addon.vpc_cni,
    aws_eks_addon.coredns,
    aws_eks_addon.metrics_server,
  ]
}
