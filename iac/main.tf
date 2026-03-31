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

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_security_group" "alb_sg" {
  name        = "ghost-alb-sg"
  description = "Allow HTTP to ALB"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
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
    Name = "ghost-alb-sg"
  }
}

resource "aws_security_group" "ecs_service_sg" {
  name        = "ghost-ecs-service-sg"
  description = "Allow ALB traffic to ECS tasks"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "Ghost app traffic from ALB"
    from_port       = 2368
    to_port         = 2368
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ghost-ecs-service-sg"
  }
}

resource "aws_lb" "ghost" {
  name               = "ghost-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = data.aws_subnets.default.ids

  tags = {
    Name = "ghost-alb"
  }
}

resource "aws_lb_target_group" "ghost" {
  name        = "ghost-tg"
  port        = 2368
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = data.aws_vpc.default.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "ghost_http" {
  load_balancer_arn = aws_lb.ghost.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ghost.arn
  }
}

resource "aws_cloudwatch_log_group" "ghost" {
  name              = "/ecs/ghost"
  retention_in_days = 7
}

resource "aws_ecs_cluster" "ghost" {
  name = "ghost-cluster"
}

resource "aws_iam_role" "ecs_task_execution" {
  name = "ghost-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_task_definition" "ghost" {
  family                   = "ghost-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([
    {
      name      = "ghost"
      image     = "nellevi/ghost-devops:latest"
      essential = true
      portMappings = [
        {
          containerPort = 2368
          hostPort      = 2368
          protocol      = "tcp"
        }
      ]
      environment = [
        {
          name  = "url"
          value = "http://${aws_lb.ghost.dns_name}"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ghost.name
          awslogs-region        = "us-east-1"
          awslogs-stream-prefix = "ghost"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "ghost" {
  name            = "ghost-service"
  cluster         = aws_ecs_cluster.ghost.id
  task_definition = aws_ecs_task_definition.ghost.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.ecs_service_sg.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.ghost.arn
    container_name   = "ghost"
    container_port   = 2368
  }

  depends_on = [
    aws_lb_listener.ghost_http,
    aws_iam_role_policy_attachment.ecs_task_execution
  ]
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

output "ec2_public_ip" {
  description = "Public endpoint for Ghost through ALB"
  value       = aws_lb.ghost.dns_name
}

output "ghost_url" {
  description = "URL to access Ghost through ALB"
  value       = "http://${aws_lb.ghost.dns_name}"
}

output "ghost_bucket" {
  description = "Name of the S3 bucket"
  value       = aws_s3_bucket.ghost_bucket.bucket
}