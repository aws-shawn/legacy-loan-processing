# Main Terraform configuration for Legacy .NET Loan Processing Application
# AWS Lift-and-Shift Deployment for Modernization Workshop

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = {
      Project     = "LoanProcessing"
      Environment = var.environment
      ManagedBy   = "Terraform"
      Purpose     = "ModernizationWorkshop"
      CostCenter  = var.cost_center
    }
  }
}

# Data sources
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

# Fetch the public IP of the machine running Terraform
data "http" "my_ip" {
  url = "https://checkip.amazonaws.com"
}

# Random suffix for unique resource names
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

# Local variables
locals {
  name_prefix = "${var.project_name}-${var.environment}"
  common_tags = {
    Name        = local.name_prefix
    Project     = var.project_name
    Environment = var.environment
  }

  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

# Modules
module "networking" {
  source = "./modules/networking"

  project_name         = var.project_name
  environment          = var.environment
  vpc_cidr             = var.vpc_cidr
  availability_zones   = local.azs
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  enable_nat_gateway   = var.enable_nat_gateway
  resource_suffix      = random_string.suffix.result
  region               = var.aws_region

  tags = local.common_tags
}

module "security" {
  source = "./modules/security"

  project_name        = var.project_name
  environment         = var.environment
  vpc_id              = module.networking.vpc_id
  allowed_cidr_blocks = distinct(concat(
    var.allowed_cidr_blocks,
    ["${chomp(data.http.my_ip.response_body)}/32"]
  ))

  tags = local.common_tags
}

module "database" {
  source = "./modules/database"

  project_name            = var.project_name
  environment             = var.environment
  vpc_id                  = module.networking.vpc_id
  private_subnet_ids      = module.networking.private_subnet_ids
  db_security_group_id    = module.security.db_security_group_id
  db_instance_class       = var.db_instance_class
  db_allocated_storage    = var.db_allocated_storage
  db_engine_version       = var.db_engine_version
  db_name                 = var.db_name
  db_username             = var.db_username
  multi_az                = var.db_multi_az
  backup_retention_period = var.db_backup_retention_period

  tags = local.common_tags
}

module "compute" {
  source = "./modules/compute"

  project_name              = var.project_name
  environment               = var.environment
  aws_region                = var.aws_region
  vpc_id                    = module.networking.vpc_id
  public_subnet_ids         = module.networking.public_subnet_ids
  private_subnet_ids        = module.networking.private_subnet_ids
  app_security_group_id     = module.security.app_security_group_id
  alb_security_group_id     = module.security.alb_security_group_id
  instance_type             = var.instance_type
  key_name                  = var.key_name
  ami_id                    = var.ami_id
  min_size                  = var.asg_min_size
  max_size                  = var.asg_max_size
  desired_capacity          = var.asg_desired_capacity
  db_endpoint               = module.database.db_endpoint
  db_name                   = var.db_name
  db_secret_arn             = module.database.db_secret_arn
  iam_instance_profile_name = module.security.instance_profile_name

  tags = local.common_tags

  depends_on = [module.database]
}

module "monitoring" {
  source = "./modules/monitoring"

  project_name            = var.project_name
  environment             = var.environment
  alb_arn_suffix          = module.compute.alb_arn_suffix
  target_group_arn_suffix = module.compute.target_group_arn_suffix
  asg_name                = module.compute.asg_name
  db_instance_id          = module.database.db_instance_id
  alarm_email             = var.alarm_email

  tags = local.common_tags
}

module "cicd" {
  source = "./modules/cicd"

  environment           = var.environment
  aws_region            = var.aws_region
  github_connection_arn = var.github_connection_arn
  github_repository_id  = var.github_repository_id
  github_branch_name    = var.github_branch_name
  notification_email    = var.notification_email
  asg_name              = module.compute.asg_name
  target_group_name     = module.compute.target_group_name
  ec2_instance_role_arn = module.security.instance_role_arn
  db_secret_arn         = module.database.db_secret_arn
  resource_suffix       = random_string.suffix.result
  common_tags           = local.common_tags

  depends_on = [module.compute, module.database]
}
