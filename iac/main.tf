terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

variable "ecs_task_execution_role_name" {
  description = "Existing IAM role name for ECS task execution"
  type        = string
  default     = "LabRole"
}

resource "random_id" "suffix" {
  byte_length = 3
}

data "aws_iam_role" "ecs_task_execution" {
  name = var.ecs_task_execution_role_name
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
  name_prefix = "ghost-alb-"
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
  name_prefix = "ghost-ecs-service-"
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
  name               = "ghost-alb-${random_id.suffix.hex}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = data.aws_subnets.default.ids

  tags = {
    Name = "ghost-alb"
  }
}

resource "aws_lb_target_group" "ghost" {
  name        = "ghost-tg-${random_id.suffix.hex}"
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
  name              = "/ecs/ghost-${random_id.suffix.hex}"
  retention_in_days = 7
}

resource "aws_ecs_cluster" "ghost" {
  name = "ghost-cluster-${random_id.suffix.hex}"
}

resource "aws_ecs_task_definition" "ghost" {
  family                   = "ghost-task-${random_id.suffix.hex}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = data.aws_iam_role.ecs_task_execution.arn

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
  name            = "ghost-service-${random_id.suffix.hex}"
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
    aws_lb_listener.ghost_http
  ]
}

output "alb_dns_name" {
  description = "ALB DNS name for Ghost"
  value       = aws_lb.ghost.dns_name
}

output "ghost_url" {
  description = "URL to access Ghost through ALB"
  value       = "http://${aws_lb.ghost.dns_name}"
}


