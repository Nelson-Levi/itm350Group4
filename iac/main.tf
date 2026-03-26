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
  bucket = "ghost-devops-bucket-12345"  # Change this to any unique name

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
  description = "Public IP of the Ghost EC2 instance"
  value       = aws_instance.ghost.public_ip
}

output "ghost_url" {
  description = "URL to access Ghost"
  value       = "http://${aws_instance.ghost.public_ip}:2368"
}

output "ghost_bucket" {
  description = "Name of the S3 bucket"
  value       = aws_s3_bucket.ghost_bucket.bucket
}