# ---------------------------------------------------------------------------
# Rede e identidades
# O Learner Lab nao permite criar IAM roles; as roles de control plane e de
# worker node ja vem provisionadas no ambiente e sao referenciadas por nome.
# ---------------------------------------------------------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# us-east-1e nao suporta EKS; as demais AZs sao filtradas dinamicamente.
data "aws_subnet" "selected" {
  for_each = toset(data.aws_subnets.default.ids)
  id       = each.value
}

locals {
  eks_subnet_ids = [
    for s in data.aws_subnet.selected : s.id
    if s.availability_zone != "us-east-1e"
  ]
}

data "aws_iam_role" "cluster" {
  name = var.eks_cluster_role_name
}

data "aws_iam_role" "node" {
  name = var.eks_node_role_name
}

# Estado do repositorio do banco: endpoint, security group e ARN do secret.
data "terraform_remote_state" "database" {
  backend = "s3"

  config = {
    bucket = "oficina-tfstate-679445922616"
    key    = "database/terraform.tfstate"
    region = "us-east-1"
  }
}

# ---------------------------------------------------------------------------
# Cluster EKS
# ---------------------------------------------------------------------------
resource "aws_eks_cluster" "this" {
  name     = "${var.project}-eks"
  version  = var.cluster_version
  role_arn = data.aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = local.eks_subnet_ids
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  # Logs do control plane vao para o CloudWatch e alimentam a trilha de
  # auditoria exigida pelo requisito de observabilidade.
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags = {
    Name = "${var.project}-eks"
  }
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.project}-nodes"
  node_role_arn   = data.aws_iam_role.node.arn
  subnet_ids      = local.eks_subnet_ids

  instance_types = [var.node_instance_type]
  capacity_type  = "ON_DEMAND"
  disk_size      = 20

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  tags = {
    Name = "${var.project}-nodes"
  }

  lifecycle {
    # O Cluster Autoscaler ajusta desired_size em resposta ao HPA; o Terraform
    # nao deve reverter esse valor no proximo apply.
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# ---------------------------------------------------------------------------
# Addons gerenciados
# ---------------------------------------------------------------------------
resource "aws_eks_addon" "vpc_cni" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "vpc-cni"
  addon_version = data.aws_eks_addon_version.vpc_cni.version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.this]
}

resource "aws_eks_addon" "coredns" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "coredns"
  addon_version = data.aws_eks_addon_version.coredns.version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.this]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "kube-proxy"
  addon_version = data.aws_eks_addon_version.kube_proxy.version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.this]
}

# O HPA da aplicacao depende do metrics-server para ler CPU e memoria dos pods.
resource "aws_eks_addon" "metrics_server" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "metrics-server"
  addon_version = data.aws_eks_addon_version.metrics_server.version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.this]
}

data "aws_eks_addon_version" "vpc_cni" {
  addon_name         = "vpc-cni"
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = true
}

data "aws_eks_addon_version" "coredns" {
  addon_name         = "coredns"
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = true
}

data "aws_eks_addon_version" "kube_proxy" {
  addon_name         = "kube-proxy"
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = true
}

data "aws_eks_addon_version" "metrics_server" {
  addon_name         = "metrics-server"
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = true
}

# ---------------------------------------------------------------------------
# Conectividade com o banco gerenciado
# Libera a porta 5432 do RDS especificamente para o security group do cluster.
# ---------------------------------------------------------------------------
resource "aws_vpc_security_group_ingress_rule" "db_from_cluster" {
  security_group_id            = data.terraform_remote_state.database.outputs.db_security_group_id
  description                  = "PostgreSQL a partir dos nodes do EKS"
  referenced_security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

# ---------------------------------------------------------------------------
# Acesso do Network Load Balancer aos nodes
#
# O Service do tipo LoadBalancer sem o AWS Load Balancer Controller usa o modo
# "instance": o NLB entrega o trafego no NodePort de cada node. O security
# group gerenciado do EKS so libera comunicacao entre nodes, entao tanto o
# health check quanto o trafego chegam bloqueados e os alvos ficam unhealthy.
#
# A faixa de NodePort e liberada para dentro da VPC — o NLB e interno e nao
# tem rota a partir da internet.
# ---------------------------------------------------------------------------
resource "aws_vpc_security_group_ingress_rule" "nodeport_from_vpc" {
  security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  description       = "NodePort a partir do NLB interno"
  cidr_ipv4         = data.aws_vpc.default.cidr_block
  from_port         = 30000
  to_port           = 32767
  ip_protocol       = "tcp"
}
