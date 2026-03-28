# Terraform Variables for Legacy .NET Loan Processing Application

# General Configuration
variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use for authentication"
  type        = string
  default     = ""
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "loanprocessing"
}

variable "environment" {
  description = "Environment name (workshop, dev, prod)"
  type        = string
  default     = "workshop"
}

variable "cost_center" {
  description = "Cost center tag for billing"
  type        = string
  default     = "ModernizationWorkshop"
}

# Networking Configuration
variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "enable_nat_gateway" {
  description = "Enable NAT Gateway for private subnets (increases cost)"
  type        = bool
  default     = false
}

# Compute Configuration
variable "instance_type" {
  description = "EC2 instance type for application servers"
  type        = string
  default     = "t3.medium"
}

variable "ami_id" {
  description = "AMI ID for Windows Server (leave empty for latest Windows Server 2022)"
  type        = string
  default     = ""
}

variable "key_name" {
  description = "EC2 key pair name (optional, use Systems Manager Session Manager instead)"
  type        = string
  default     = ""
}

variable "asg_min_size" {
  description = "Minimum number of EC2 instances in Auto Scaling Group"
  type        = number
  default     = 1
}

variable "asg_max_size" {
  description = "Maximum number of EC2 instances in Auto Scaling Group"
  type        = number
  default     = 2
}

variable "asg_desired_capacity" {
  description = "Desired number of EC2 instances in Auto Scaling Group"
  type        = number
  default     = 1
}

# Database Configuration
variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.small"
}

variable "db_allocated_storage" {
  description = "Allocated storage for RDS in GB"
  type        = number
  default     = 20
}

variable "db_engine_version" {
  description = "SQL Server engine version"
  type        = string
  default     = "15.00.4335.1.v1" # SQL Server 2019 Express
}

variable "db_name" {
  description = "Database name"
  type        = string
  default     = "LoanProcessing"
}

variable "db_username" {
  description = "Database master username"
  type        = string
  default     = "sqladmin"
}

variable "db_multi_az" {
  description = "Enable Multi-AZ deployment for RDS"
  type        = bool
  default     = true
}

variable "db_backup_retention_period" {
  description = "Number of days to retain automated backups"
  type        = number
  default     = 7
}

# Monitoring Configuration
variable "alarm_email" {
  description = "Email address for CloudWatch alarms"
  type        = string
  default     = ""
}

# Application Configuration
variable "app_version" {
  description = "Application version to deploy"
  type        = string
  default     = "1.0.0"
}

variable "enable_detailed_monitoring" {
  description = "Enable detailed CloudWatch monitoring (increases cost)"
  type        = bool
  default     = false
}

# Security Configuration
variable "allowed_cidr_blocks" {
  description = "Additional CIDR blocks allowed to access the application (deployer IP is auto-detected)"
  type        = list(string)
  default     = []
}

variable "enable_waf" {
  description = "Enable AWS WAF for Application Load Balancer"
  type        = bool
  default     = false
}

# Tags
variable "additional_tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# CI/CD Configuration
variable "github_connection_arn" {
  description = "ARN of the CodeStar Connection to GitHub"
  type        = string
  default     = ""
}

variable "github_repository_id" {
  description = "Full GitHub repository ID in format 'owner/repo'"
  type        = string
  default     = "aws-shawn/legacy-loan-processing"
}

variable "github_branch_name" {
  description = "GitHub branch name to monitor for changes"
  type        = string
  default     = "main"
}

variable "notification_email" {
  description = "Email address for pipeline notifications (operations team)"
  type        = string
  default     = ""
}
