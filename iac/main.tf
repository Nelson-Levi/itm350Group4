terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket = "ghost-project-bucket"  
    key    = "terraform/state.tfstate"
    region = "us-east-1"
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
  name_prefix        = "ghost-sg"
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
              docker pull nellevi/ghost:latest
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



data "aws_s3_bucket" "ghost_bucket" {
  bucket = "ghost-project-bucket"
}

resource "aws_ecs_cluster" "ghost" {
  name = "ghost-cluster"
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