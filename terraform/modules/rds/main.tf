resource "random_password" "master" {
  for_each = var.databases

  length           = 20
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.project_name}-rds-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = var.tags
}

resource "aws_security_group" "rds" {
  for_each = var.databases

  name        = "${var.project_name}-${each.key}-rds-sg"
  description = "Allow Postgres access from the EKS worker nodes to ${each.key} database"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Postgres from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = var.allowed_security_group_ids
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.project_name}-${each.key}-rds-sg" })
}

resource "aws_db_instance" "this" {
  for_each = var.databases

  identifier             = "${var.project_name}-${each.key}-db"
  engine                 = "postgres"
  engine_version         = var.engine_version
  instance_class         = var.instance_class
  allocated_storage      = var.allocated_storage
  db_name                = each.value.db_name
  username               = var.master_username
  password               = random_password.master[each.key].result
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds[each.key].id]

  multi_az                = false
  publicly_accessible     = false
  storage_encrypted       = true
  skip_final_snapshot     = true
  deletion_protection     = false
  backup_retention_period = 1
  apply_immediately       = true

  tags = merge(var.tags, { Name = "${var.project_name}-${each.key}-db" })
}

resource "aws_secretsmanager_secret" "db_credentials" {
  for_each = var.databases

  name = "${var.project_name}/${each.key}/database-url"
  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  for_each = var.databases

  secret_id = aws_secretsmanager_secret.db_credentials[each.key].id
  secret_string = jsonencode({
    database_url = "postgres://${var.master_username}:${urlencode(random_password.master[each.key].result)}@${aws_db_instance.this[each.key].address}:5432/${each.value.db_name}?sslmode=require"
    host         = aws_db_instance.this[each.key].address
    port         = 5432
    db_name      = each.value.db_name
    username     = var.master_username
    password     = random_password.master[each.key].result
  })
}
