# ---------------------------------------------------------------------------
# API Gateway
# Unico ponto de entrada do sistema. O NLB da aplicacao e interno, entao nao
# existe caminho que alcance a API sem passar pelo gateway e, nas rotas
# sensiveis, pelo authorizer.
# ---------------------------------------------------------------------------

# O Network Load Balancer e criado pelo controlador do Kubernetes em resposta
# ao Service; e localizado pelas tags que o proprio controlador aplica.
data "aws_lb" "api" {
  tags = {
    "kubernetes.io/service-name" = "${var.namespace}/oficina-api"
  }

  depends_on = [kubernetes_service.api]
}

data "aws_lb_listener" "api" {
  load_balancer_arn = data.aws_lb.api.arn
  port              = 80
}

resource "aws_security_group" "vpc_link" {
  name        = "${var.project}-vpc-link-sg"
  description = "VPC Link entre o API Gateway e o NLB interno da aplicacao"
  vpc_id      = data.aws_vpc.default.id

  tags = {
    Name = "${var.project}-vpc-link-sg"
  }
}

resource "aws_vpc_security_group_egress_rule" "vpc_link" {
  security_group_id = aws_security_group.vpc_link.id
  description       = "Saida para o NLB interno"
  cidr_ipv4         = data.aws_vpc.default.cidr_block
  ip_protocol       = "-1"
}

resource "aws_apigatewayv2_vpc_link" "this" {
  name               = "${var.project}-vpc-link"
  subnet_ids         = local.eks_subnet_ids
  security_group_ids = [aws_security_group.vpc_link.id]

  tags = {
    Name = "${var.project}-vpc-link"
  }
}

resource "aws_apigatewayv2_api" "this" {
  name          = "${var.project}-api"
  protocol_type = "HTTP"
  description   = "Gateway da Oficina API - Tech Challenge SOAT Fase 3"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]
    allow_headers = ["content-type", "authorization"]
    max_age       = 300
  }
}

# ---------------------------------------------------------------------------
# Integracoes
# ---------------------------------------------------------------------------
resource "aws_apigatewayv2_integration" "api" {
  api_id             = aws_apigatewayv2_api.this.id
  integration_type   = "HTTP_PROXY"
  integration_method = "ANY"
  integration_uri    = data.aws_lb_listener.api.arn

  connection_type = "VPC_LINK"
  connection_id   = aws_apigatewayv2_vpc_link.this.id

  payload_format_version = "1.0"
  timeout_milliseconds   = 30000
}

# Emissao de token a partir do CPF, implementada no repositorio
# oficina-lambda-auth.
resource "aws_apigatewayv2_integration" "auth" {
  count = local.lambda_token_arn == "" ? 0 : 1

  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = "arn:aws:apigateway:${var.region}:lambda:path/2015-03-31/functions/${local.lambda_token_arn}/invocations"
  payload_format_version = "2.0"
  timeout_milliseconds   = 10000
}

# ---------------------------------------------------------------------------
# Authorizer
# Valida o JWT emitido pela funcao serverless. Um authorizer nativo do tipo JWT
# exigiria um emissor OIDC; como o token e assinado pela propria Lambda em
# HS256, a validacao e feita por um authorizer Lambda do tipo REQUEST.
# ---------------------------------------------------------------------------
resource "aws_apigatewayv2_authorizer" "jwt" {
  count = local.lambda_authorizer_arn == "" ? 0 : 1

  api_id          = aws_apigatewayv2_api.this.id
  authorizer_type = "REQUEST"

  # O authorizer exige o ARN de invocacao, nao o ARN da funcao; ele e montado
  # a partir do ARN recebido para que o repositorio da Lambda precise exportar
  # apenas um valor.
  authorizer_uri = "arn:aws:apigateway:${var.region}:lambda:path/2015-03-31/functions/${local.lambda_authorizer_arn}/invocations"

  identity_sources                  = ["$request.header.Authorization"]
  name                              = "${var.project}-jwt-authorizer"
  authorizer_payload_format_version = "2.0"
  enable_simple_responses           = true

  # Respostas do authorizer sao cacheadas por 5 minutos, reduzindo invocacoes
  # da Lambda e a latencia das rotas protegidas.
  authorizer_result_ttl_in_seconds = 300
}

# ---------------------------------------------------------------------------
# Rotas
# ---------------------------------------------------------------------------

# Emissao de token: publica por definicao, e a porta de entrada da autenticacao.
resource "aws_apigatewayv2_route" "auth" {
  count = local.lambda_token_arn == "" ? 0 : 1

  api_id    = aws_apigatewayv2_api.this.id
  route_key = "POST /auth"
  target    = "integrations/${aws_apigatewayv2_integration.auth[0].id}"
}

# Rotas publicas da aplicacao: consulta de status da OS pelo numero e webhook
# de aprovacao de orcamento, ambos acessados por terceiros sem token.
resource "aws_apigatewayv2_route" "publico" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "ANY /api/publico/{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.api.id}"
}

# Autenticacao administrativa servida pela propria aplicacao. Precisa ser
# publica no gateway: exigir token para obter um token deixaria o operador sem
# nenhum caminho de entrada.
resource "aws_apigatewayv2_route" "auth_aplicacao" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "POST /api/auth/{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.api.id}"
}

# Healthcheck e documentacao, usados pelo smoke test do pipeline.
resource "aws_apigatewayv2_route" "health" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "GET /api/health"
  target    = "integrations/${aws_apigatewayv2_integration.api.id}"
}

resource "aws_apigatewayv2_route" "docs" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "ANY /docs/{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.api.id}"
}

# /docs/{proxy+} exige algo depois da barra, entao a URL que a pessoa digita
# — sem barra no fim — nao casava com nenhuma rota.
resource "aws_apigatewayv2_route" "docs_raiz" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "ANY /docs"
  target    = "integrations/${aws_apigatewayv2_integration.api.id}"
}

# Especificacao OpenAPI, usada para importar as APIs em outras ferramentas.
resource "aws_apigatewayv2_route" "docs_json" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "ANY /docs-json"
  target    = "integrations/${aws_apigatewayv2_integration.api.id}"
}

# Demais rotas da aplicacao: protegidas pelo authorizer.
resource "aws_apigatewayv2_route" "protegida" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "ANY /api/{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.api.id}"

  authorization_type = local.lambda_authorizer_arn == "" ? "NONE" : "CUSTOM"
  authorizer_id      = local.lambda_authorizer_arn == "" ? null : aws_apigatewayv2_authorizer.jwt[0].id
}

# Permite ao API Gateway invocar as funcoes Lambda.
resource "aws_lambda_permission" "authorizer" {
  count = local.lambda_authorizer_arn == "" ? 0 : 1

  statement_id  = "AllowAPIGatewayInvokeAuthorizer"
  action        = "lambda:InvokeFunction"
  function_name = local.lambda_authorizer_arn
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/authorizers/${aws_apigatewayv2_authorizer.jwt[0].id}"
}

resource "aws_lambda_permission" "token" {
  count = local.lambda_token_arn == "" ? 0 : 1

  statement_id  = "AllowAPIGatewayInvokeToken"
  action        = "lambda:InvokeFunction"
  function_name = local.lambda_token_arn
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}

# ---------------------------------------------------------------------------
# Stage e logs
# Logs de acesso em JSON estruturado, com o requestId propagado para permitir
# correlacionar uma requisicao do gateway ate o log da aplicacao.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "apigw" {
  name              = "/aws/apigateway/${var.project}"
  retention_in_days = 7
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.apigw.arn

    format = jsonencode({
      requestId        = "$context.requestId"
      requestTime      = "$context.requestTime"
      httpMethod       = "$context.httpMethod"
      path             = "$context.path"
      routeKey         = "$context.routeKey"
      status           = "$context.status"
      responseLatency  = "$context.responseLatency"
      integrationError = "$context.integrationErrorMessage"
      authorizerError  = "$context.authorizer.error"
      sourceIp         = "$context.identity.sourceIp"
      userAgent        = "$context.identity.userAgent"
    })
  }

  default_route_settings {
    detailed_metrics_enabled = true
    throttling_burst_limit   = 200
    throttling_rate_limit    = 100
  }
}
