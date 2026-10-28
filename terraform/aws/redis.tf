# 
# ElastiCache (Redis)
# Stores SSO Portal feature flags.
#

resource "aws_elasticache_subnet_group" "redis" {
  name       = "redis-subnet-group"
  subnet_ids = module.idp_vpc.private_subnet_ids
  tags       = local.common_tags
}

resource "aws_elasticache_replication_group" "redis" {
  automatic_failover_enabled = true
  replication_group_id       = "login-redis-rep-group"
  description                = "Shared key-value store for the IdP login ECS service"
  node_type                  = "cache.t3.micro"
  num_cache_clusters         = 2
  engine                     = "valkey"
  engine_version             = "7.2"
  parameter_group_name       = "default.valkey7"
  port                       = 6379
  multi_az_enabled           = true
  auto_minor_version_upgrade = true
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  transit_encryption_mode    = "preferred"
  subnet_group_name          = aws_elasticache_subnet_group.redis.name
  security_group_ids         = [aws_security_group.idp_login_redis.id]

  tags = local.common_tags

}

resource "aws_ssm_parameter" "idp_login_redis_url" {
  name  = "idp_login_redis_url"
  type  = "SecureString"
  value = "redis://${aws_elasticache_replication_group.redis.primary_endpoint_address}:${aws_elasticache_replication_group.redis.port}"
  tags  = local.core_tags
}