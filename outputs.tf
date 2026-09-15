output "cluster_name" {
  description = "Nome do cluster EKS."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "Endpoint do control plane."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_version" {
  description = "Versao do Kubernetes."
  value       = aws_eks_cluster.this.version
}

output "kubeconfig_command" {
  description = "Comando para configurar o kubectl."
  value       = "aws eks update-kubeconfig --name ${aws_eks_cluster.this.name} --region ${var.region}"
}

output "namespace" {
  description = "Namespace da aplicacao."
  value       = kubernetes_namespace.oficina.metadata[0].name
}

output "api_gateway_url" {
  description = "URL publica do sistema. Unico ponto de entrada."
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "api_gateway_id" {
  description = "Identificador da API no API Gateway."
  value       = aws_apigatewayv2_api.this.id
}

output "nlb_hostname" {
  description = "DNS interno do Network Load Balancer da aplicacao."
  value       = data.aws_lb.api.dns_name
}

output "vpc_id" {
  description = "VPC onde o cluster foi criado."
  value       = data.aws_vpc.default.id
}

output "cluster_security_group_id" {
  description = "Security group gerenciado do cluster."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "subnet_ids" {
  description = "Subnets usadas pelo cluster, consumidas pelo repositorio da Lambda."
  value       = local.eks_subnet_ids
}

output "grafana_url_command" {
  description = "Comando para descobrir a URL publica do Grafana."
  value       = "kubectl -n monitoring get svc kube-prometheus-stack-grafana -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
}
