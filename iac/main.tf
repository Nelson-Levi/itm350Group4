terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_security_group" "ghost_sg" {
  name        = "ghost-security-group"
  description = "Allow HTTP and SSH traffic"
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "Ghost"
    from_port   = 2368
    to_port     = 2368
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "ghost-sg"
  }
}

resource "aws_instance" "ghost" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  key_name               = "vockey"
  vpc_security_group_ids = [aws_security_group.ghost_sg.id]
  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y docker
              systemctl start docker
              systemctl enable docker
              docker pull nellevi/ghost-devops:latest
              docker run -d \
                --name ghost \
                --restart always \
                -p 2368:2368 \
                -e url=http://$(curl -s ifconfig.me):2368 \
                nellevi/ghost-devops:latest
              EOF
  tags = {
    Name = "ghost-devops"
  }
}

resource "aws_s3_bucket" "ghost_bucket" {
  bucket = "ghost-project-bucket" 

  tags = {
    Name = "ghost-devops"
  }
}

resource "aws_s3_bucket_public_access_block" "ghost_bucket_block" {
  bucket = aws_s3_bucket.ghost_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}


resource "aws_ecs_cluster" "ghost" {
  name = "ghost-cluster"
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2008-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_task_definition" "ghost" {
  family                   = "ghost-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name  = "ghost"
      image = "nellevi/ghost-devops:latest"

      portMappings = [
        {
          containerPort = 2368
          hostPort      = 2368
        }
      ]

      environment = [
        {
          name  = "url"
          value = "http://localhost:2368"
        }
      ]
    }
  ])
}

resource "aws_ecs_service" "ghost" {
  name            = "ghost-service"
  cluster         = aws_ecs_cluster.ghost.id
  task_definition = aws_ecs_task_definition.ghost.arn
  launch_type     = "FARGATE"
  desired_count   = 1

  network_configuration {
    subnets = data.aws_subnets.default.ids
    security_groups = [aws_security_group.ghost_sg.id]
    assign_public_ip = true
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}