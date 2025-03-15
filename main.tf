# Variables for configuration
variable "region" {
  default = "us-east-1"
}

variable "cidr_block" {
  default = "10.0.0.0/16"
}

variable "project_name" {
  default = "my-project"
}

# AWS Provider
provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = "production"
    }
  }
}

# Fetch availability zones dynamically
data "aws_availability_zones" "available" {
  state = "available"
}

# Create a VPC
resource "aws_vpc" "main" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "${var.project_name} VPC"
  }
}

# Create public subnets in each availability zone
resource "aws_subnet" "public_subnets" {
  count             = length(data.aws_availability_zones.available.names)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags = {
    Name = "Public Subnet ${count.index}"
  }
}

# Create private subnets in each availability zone
resource "aws_subnet" "private_subnets" {
  count             = length(data.aws_availability_zones.available.names)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, length(data.aws_availability_zones.available.names) + count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = {
    Name = "Private Subnet ${count.index}"
  }
}

# Create Internet Gateway for public subnets
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "Internet Gateway"
  }
}

# Create a public route table and associate it with public subnets
resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "Public Route Table"
  }
}

resource "aws_route" "public_route" {
  route_table_id         = aws_route_table.public_route_table.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public_subnet_associations" {
  count          = length(aws_subnet.public_subnets)
  subnet_id      = aws_subnet.public_subnets[count.index].id
  route_table_id = aws_route_table.public_route_table.id
}

# Create ECS Cluster
resource "aws_ecs_cluster" "app_cluster" {
  name = "${var.project_name}-cluster"
}

# Fetch existing ECR repository for the app image
data "aws_ecr_repository" "app_ecr_repo" {
  name = "my-python-app"
}

# CloudWatch Log Group for ECS
resource "aws_cloudwatch_log_group" "ecs_log_group" {
  name              = "/ecs/my-python-app"
  retention_in_days = 7
}

# ECS Task Definition
resource "aws_ecs_task_definition" "app_task_definition" {
  family                   = "my-python-app-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 1024
  memory                   = 2048
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn

  container_definitions = jsonencode([{
    name      = "my-python-app"
    image     = "${data.aws_ecr_repository.app_ecr_repo.repository_url}:latest"
    portMappings = [{
      containerPort = 8000
      hostPort      = 8000
      protocol      = "tcp"
    }]
    essential       = true
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = "/ecs/my-python-app"
        awslogs-region        = var.region
        awslogs-stream-prefix = "my-python-app"
      }
    }
  }])
}

# ECS Service using private subnets for deployment
resource "aws_ecs_service" "app_service" {
  name            = "my-python-app-service"
  cluster         = aws_ecs_cluster.app_cluster.id
  task_definition = aws_ecs_task_definition.app_task_definition.arn
  launch_type     = "FARGATE"
  desired_count   = 1

  network_configuration {
    subnets          = aws_subnet.private_subnets[*].id
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = false
  }
}

# Security Group for ECS tasks
resource "aws_security_group" "ecs_sg" {
  name        = "ecs-sg"
  description = "Allow inbound access to ECS tasks"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# IAM Role for ECS Execution
resource "aws_iam_role" "ecs_execution_role" {
  name = "${var.project_name}-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Attach Policies to ECS Execution Role
resource "aws_iam_role_policy_attachment" "ecs_execution_policy" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Outputs
output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = aws_subnet.public_subnets[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private_subnets[*].id
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.app_cluster.name
}
