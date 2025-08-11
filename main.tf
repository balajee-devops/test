provider "aws" {
  region = var.aws_region
}



resource "aws_vpc" "main" { #this name belongs to only terraform reference

    cidr_block       = "10.0.0.0/16"
    instance_tenancy = "default"
    tags = {
        Name = "automated-vpc" #this name belongs to AWS
    }
}

resource "aws_subnet" "private" {
  vpc_id     = aws_vpc.main.id # it will fetch VPC ID created from above code
  cidr_block = "10.0.2.0/24"

  tags = {
    Name = "private-subnet-automated-vpc"
  }
}

resource "aws_subnet" "main" {
  vpc_id     = aws_vpc.main.id # it will fetch VPC ID created from above code
  cidr_block = "10.0.1.0/24"

  tags = {
    Name = "public-subnet-automated-vpc"
  }
}

resource "aws_internet_gateway" "automated-igw" {
  vpc_id = aws_vpc.main.id # internet gateway depends on VPC

  tags = {
    Name = "automated-somechange"
  }
}

resource "aws_route_table" "public-rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.automated-igw.id
  }

  tags = {
    Name = "public-rt"
  }
}

resource "aws_eip" "auto-eip" {

}

resource "aws_nat_gateway" "example" {
  allocation_id = aws_eip.auto-eip.id
  subnet_id     = aws_subnet.main.id

  tags = {
    Name = "automated-NAT"
  }

  # To ensure proper ordering, it is recommended to add an explicit dependency
  # on the Internet Gateway for the VPC.
  depends_on = [aws_internet_gateway.automated-igw]
}

resource "aws_route_table" "private-rt" { #for private route we don't attach IGW, we attach NAT
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_nat_gateway.example.id
  }

  tags = {
    Name = "private-rt"
  }
}


resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.main.id
  route_table_id = aws_route_table.public-rt.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private-rt.id
}

#data "aws_availability_zones" "available" {}

# --------- Security Group for RDS ---------
resource "aws_security_group" "rds_sg" {
  name        = "${var.db_cluster_identifier}-sg"
  description = "Security group for Aurora PostgreSQL cluster"
  vpc_id      = var.vpc_id

  # Allow inbound Postgres from allowed CIDR (or another security group)
  ingress {
    description      = "Postgres"
    from_port        = 5432
    to_port          = 5432
    protocol         = "tcp"
    cidr_blocks      = [var.allowed_cidr]
    ipv6_cidr_blocks = []
  }

  # Optional: allow all outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.db_cluster_identifier}-sg"
  }
}

# --------- DB Subnet Group (Aurora) ---------
resource "aws_db_subnet_group" "aurora_subnet_group" {
  name       = "${var.db_cluster_identifier}-subnets"
  subnet_ids = var.private_subnet_ids
  description = "Subnet group for ${var.db_cluster_identifier}"

  tags = {
    Name = "${var.db_cluster_identifier}-subnet-group"
  }
}

# --------- Cluster Parameter Group: enforce SSL ---------
resource "aws_rds_cluster_parameter_group" "aurora_pg_param" {
  name        = "${var.db_cluster_identifier}-paramgrp"
  family      = var.db_parameter_group_family
  description = "Cluster parameter group for ${var.db_cluster_identifier} - enforce SSL"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  tags = {
    Name = "${var.db_cluster_identifier}-parameter-group"
  }
}

# --------- IAM Role for RDS (example: S3 access) ---------
# This role can be associated with the cluster to allow cluster actions (e.g., import/export to S3).
resource "aws_iam_role" "rds_role" {
  count = var.associate_iam_role_for_s3 ? 1 : 0

  name = "${var.db_cluster_identifier}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "rds.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# Attach an example policy (S3 read-only). Replace/extend with the policy your use-case needs.
resource "aws_iam_role_policy_attachment" "rds_role_s3_attach" {
  count      = var.associate_iam_role_for_s3 ? 1 : 0
  role       = aws_iam_role.rds_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

# If you need a custom policy for more restricted S3/KMS usage, create aws_iam_policy & attach it.

# --------- Aurora RDS Cluster ---------
resource "aws_rds_cluster" "aurora_cluster" {
  cluster_identifier                = var.db_cluster_identifier
  engine                            = var.engine
  engine_version                    = var.engine_version
  database_name                     = var.db_name
  master_username                   = var.master_username
  master_password                   = var.master_password
  skip_final_snapshot               = true
  backup_retention_period           = var.backup_retention_period
  preferred_backup_window           = var.preferred_backup_window
  db_subnet_group_name              = aws_db_subnet_group.aurora_subnet_group.name
  vpc_security_group_ids            = [aws_security_group.rds_sg.id]
  storage_encrypted                 = true
  apply_immediately                 = false
  db_cluster_parameter_group_name   = aws_rds_cluster_parameter_group.aurora_pg_param.name

  # Enables IAM database authentication
  iam_database_authentication_enabled = true

  # Optionally associate IAM role(s) (e.g., for S3 import/export). Use if created.
  iam_roles = var.associate_iam_role_for_s3 ? [aws_iam_role.rds_role[0].arn] : []

  # Availability zones optional - Aurora will place instances in subnets, but you can list AZs
  availability_zones = data.aws_availability_zones.available.names[0:3]

  tags = {
    Name = var.db_cluster_identifier
  }
}

# --------- Cluster Instances (3, one per AZ/subnet) ---------
# Create one writer + two readers as distinct instances. We'll create three instances and
# let RDS elect the writer. Use lifecycle ignore_changes on engine_version if you update engine manually.
resource "aws_rds_cluster_instance" "aurora_instances" {
  count              = length(var.private_subnet_ids)
  identifier         = "${var.db_cluster_identifier}-inst-${count.index + 1}"
  cluster_identifier = aws_rds_cluster.aurora_cluster.id
  instance_class     = var.db_instance_class
  engine             = var.engine
  engine_version     = var.engine_version
  db_subnet_group_name = aws_db_subnet_group.aurora_subnet_group.name
  publicly_accessible  = false
  # placement: put each instance in a specific subnet/AZ via subnet group & AZ ordering
  availability_zone = element(data.aws_availability_zones.available.names, count.index)

  tags = {
    Name = "${var.db_cluster_identifier}-inst-${count.index + 1}"
  }

  lifecycle {
    ignore_changes = [engine_version]
  }
}

# --------- VPC Interface Endpoints for RDS APIs (PrivateLink) ---------
# Create security group for endpoints to control ENIs
resource "aws_security_group" "vpce_sg" {
  name        = "${var.db_cluster_identifier}-vpce-sg"
  description = "SG for VPC endpoints for RDS"
  vpc_id      = var.vpc_id

  ingress {
    description = "Allow inbound from inside VPC (RDS API clients)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# RDS API endpoint
resource "aws_vpc_endpoint" "rds_api" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.rds"
  vpc_endpoint_type = "Interface"
  subnet_ids        = var.private_subnet_ids
  security_group_ids = [aws_security_group.vpce_sg.id]
  private_dns_enabled = true
  tags = {
    Name = "${var.db_cluster_identifier}-vpce-rds"
  }
}

# RDS Data API endpoint (useful if you use Data API / Serverless v2)
resource "aws_vpc_endpoint" "rds_data_api" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.rds-data"
  vpc_endpoint_type = "Interface"
  subnet_ids        = var.private_subnet_ids
  security_group_ids = [aws_security_group.vpce_sg.id]
  private_dns_enabled = true
  tags = {
    Name = "${var.db_cluster_identifier}-vpce-rds-data"
  }
}
