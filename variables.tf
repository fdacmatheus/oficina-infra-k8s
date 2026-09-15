variable "region" {
  description = "Regiao AWS. O AWS Academy Learner Lab so libera us-east-1."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Prefixo aplicado ao nome dos recursos."
  type        = string
  default     = "oficina"
}

variable "cluster_version" {
  description = "Versao do Kubernetes no EKS."
  type        = string
  default     = "1.31"
}

variable "node_instance_type" {
  description = "Tipo das instancias do node group."
  type        = string
  default     = "t3.medium"
}

variable "node_desired_size" {
  description = "Quantidade desejada de nodes."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimo de nodes."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximo de nodes. Teto do Cluster Autoscaler quando o HPA solicita mais pods."
  type        = number
  default     = 4
}

variable "namespace" {
  description = "Namespace da aplicacao."
  type        = string
  default     = "oficina"
}

variable "eks_cluster_role_name" {
  description = "Role de control plane pre-criada pelo Learner Lab."
  type        = string
  default     = "c221562a5587885l16541669t1w679445-LabEksClusterRole-adNS6kIo8yJd"
}

variable "eks_node_role_name" {
  description = "Role dos worker nodes pre-criada pelo Learner Lab."
  type        = string
  default     = "c221562a5587885l16541669t1w679445922-LabEksNodeRole-fWeL75fa3KI6"
}

variable "lambda_authorizer_arn" {
  description = "ARN da Lambda authorizer publicada pelo repositorio oficina-lambda-auth. Vazio desabilita a protecao das rotas no API Gateway."
  type        = string
  default     = ""
}

variable "lambda_token_arn" {
  description = "ARN da Lambda de emissao de token por CPF."
  type        = string
  default     = ""
}

variable "grafana_admin_password" {
  description = "Senha do usuario admin do Grafana."
  type        = string
  default     = "oficina-admin"
  sensitive   = true
}
