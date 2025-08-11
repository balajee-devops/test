variable "aws_region" {
  type    = string
  default = "eu-central-1"
}

variable "vpc_id" {
  type = string
}

# Provide exactly 3 private subnet IDs (one in each AZ)
variable "private_subnet_ids" {
  type = list(string)
  validation {
    condition     = length(var.private_subnet_ids) == 3
    error_message = "Provide exactly 3 subnet IDs (one per AZ)."
  }
}

variable "db_cluster_identifier" {
  type    = string
  default = "aurora-pg-cluster"
}

variable "db_name" {
  type    = string
  default = "appdb"
}

variable "master_username" {
  type    = string
  default = "pgadmin"
}

variable "master_password" {
  description = "Master password - consider storing in secrets manager and referencing via data source"
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  type    = string
  default = "db.r6g.large"
}

# Aurora engine & family - change as needed
variable "engine" {
  type    = string
  default = "aurora-postgresql"
}

variable "engine_version" {
  type    = string
  default = "14.7" # change to valid Aurora PostgreSQL version for your region
}

# Cluster parameter group family - match your engine version family, e.g. "aurora-postgresql14"
variable "db_parameter_group_family" {
  type    = string
  default = "aurora-postgresql14"
}

variable "backup_retention_period" {
  type    = number
  default = 7
}

variable "preferred_backup_window" {
  type    = string
  default = "03:00-04:00"
}

variable "allowed_cidr" {
  type    = string
  default = "10.0.0.0/16" # change to app SG or narrower CIDR as desired
}

variable "associate_iam_role_for_s3" {
  type    = bool
  default = true
}
