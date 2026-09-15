terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.32"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.15"
    }
  }

  backend "s3" {
    bucket         = "oficina-tfstate-679445922616"
    key            = "k8s/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "oficina-tflock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "oficina"
      Phase     = "fase-3"
      ManagedBy = "terraform"
      Repo      = "oficina-infra-k8s"
    }
  }
}

# Autenticacao no cluster via token efemero do proprio AWS CLI, evitando
# guardar kubeconfig no state.
provider "kubernetes" {
  host                   = aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.this.name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.this.name, "--region", var.region]
    }
  }
}
