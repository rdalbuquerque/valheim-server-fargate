terraform {
  backend "local" {
    path = "state/terraform.tfstate"
  }

  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

# Configure the AWS Provider
# Credentials and default region are set on envrionment variables
provider "aws" {}

data "aws_region" "current" {}

locals {
  config_default_az = "sa-east-1a"
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "valheim"
  cidr = "10.0.0.0/16"

  azs            = [local.config_default_az]
  public_subnets = ["10.0.101.0/24"]

  enable_dns_hostnames = true
  enable_dns_support   = true

  manage_default_security_group = true
  default_security_group_ingress = [
    {
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      cidr_blocks = "0.0.0.0/0"
    }
  ]
  default_security_group_egress = [
    {
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      cidr_blocks = "0.0.0.0/0"
    }
  ]

  tags = {
    Terraform = "true"
  }
}

data "aws_ami" "aws_optimized_ecs" {
  most_recent = true

  filter {
    name   = "name"
    values = ["amzn-ami*amazon-ecs-optimized"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["591542846629"] # AWS
}

resource "aws_launch_template" "valheim_ec2" {
  name_prefix   = "example"
  image_id      = data.aws_ami.aws_optimized_ecs.id
  instance_type = "c7g.medium"
  key_name      = "valheim-sa"
  network_interfaces {
    associate_public_ip_address = true
    subnet_id                   = module.vpc.public_subnets[0]
  }
  placement {
    availability_zone = local.config_default_az
  }
  monitoring {
    enabled = true
  }
  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_agent.arn
  }
  instance_market_options {
    market_type = "spot"
  }
  user_data = <<EOF
#!/bin/bash
echo ECS_CLUSTER=valheim-ec2-cluster >> /etc/ecs/ecs.config
EOF
}

resource "aws_autoscaling_group" "valheim" {
  name                = "valheim-ec2-cluster"
  vpc_zone_identifier = [module.vpc.public_subnets[0]]
  launch_template {
    id = aws_launch_template.valheim_ec2.id
  }

  desired_capacity          = 1
  min_size                  = 1
  max_size                  = 1
  health_check_grace_period = 300
  health_check_type         = "EC2"
}

resource "aws_ecs_cluster" "valheim_ec2_cluster" {
  name = "valheim-ec2-cluster"
}

#resource "random_string" "valheim_pwd" {
#  length  = 6
#  numeric = true
#  special = false
#}
#
#locals {
#  access_points = {
#    "efs-valheim-saves" = {
#      container_path = "/home/steam/.config/unity3d/IronGate/Valheim"
#      efs_path       = "/valheim/saves"
#    }
#    "efs-valheim-server" = {
#      container_path = "/home/steam/valheim"
#      efs_path       = "/valheim/server"
#    }
#    "efs-valheim-backups" = {
#      container_path = "/home/steam/backups"
#      efs_path       = "/valheim/backups"
#    }
#  }
#  ecs_task_mount_points = jsonencode([
#    for k, v in local.access_points : {
#      "sourceVolume" : "${k}"
#      "containerPath" : "${v.container_path}"
#    }
#  ])
#  ecs_task_container_definition = templatefile("valheim-task-container-definition.tfpl", {
#    aws_region   = data.aws_region.current.name
#    mount_points = local.ecs_task_mount_points
#    server_name  = "cheapear-and-faster-platworld"
#    word_name    = "cheapear-and-faster-platworld"
#    password     = random_string.valheim_pwd.result
#    timezone     = "America/Sao_paulo"
#  })
#}
#
#resource "aws_ecs_service" "valheim_ec2_cluster" {
#  name            = "valheim"
#  cluster         = aws_ecs_cluster.valheim_ec2_cluster
#  task_definition = aws_ecs_task_definition.valheim.arn
#  desired_count   = 1
#
#  network_configuration {
#    security_groups  = [module.vpc.default_security_group_id]
#    subnets          = [module.vpc.public_subnets[0]]
#    assign_public_ip = true
#  }
#}
#
#data "aws_iam_role" "valheim_task" {
#  name = "valheim_ecs_task"
#}
#
#resource "aws_ecs_task_definition" "valheim" {
#  family             = "valheim"
#  cpu                = "2048"
#  memory             = "4096"
#  network_mode       = "awsvpc"
#  execution_role_arn = data.aws_iam_role.valheim_task.arn
#
#  container_definitions = local.ecs_task_container_definition
#
#  dynamic "volume" {
#    for_each = aws_efs_access_point.valheim
#    content {
#      name = volume.key
#      efs_volume_configuration {
#        file_system_id     = aws_efs_file_system.valheim.id
#        root_directory     = "/"
#        transit_encryption = "ENABLED"
#        authorization_config {
#          access_point_id = volume.value.id
#        }
#      }
#    }
#  }
#}


#resource "aws_efs_file_system" "valheim" {
#  availability_zone_name = local.config_default_az
#
#  tags = {
#    Name = "valheim-efs"
#  }
#}
#
#resource "aws_efs_mount_target" "valheim" {
#  security_groups = [module.vpc.default_security_group_id]
#  file_system_id  = aws_efs_file_system.valheim.id
#  subnet_id       = module.vpc.public_subnets[0]
#}
#
#resource "aws_efs_access_point" "valheim" {
#  for_each = local.access_points
#
#  file_system_id = aws_efs_file_system.valheim.id
#  root_directory {
#    path = each.value.efs_path
#    creation_info {
#      owner_gid   = 0
#      owner_uid   = 0
#      permissions = 0777
#    }
#  }
#}
#
#module "ecs" {
#  source = "terraform-aws-modules/ecs/aws"
#  cluster_name = "valheim"
#
#  tags = {
#    Environment = "prd"
#    Project     = "valheim-server"
#  }
#}
#
#
##resource "aws_instance" "efs_viewer" {
##  ami           = "ami-0b22b708611ed2690" # ID of Ubuntu 20 SP ami (64-bit|x86)
##  instance_type = "t2.micro"
##  key_name      = "valheim-sa"
##  subnet_id     = module.vpc.public_subnets[0]
##  
##  tags = {
##    Name = "efs-viewer"
##  }
##}
##
##output "efs_viewer_ip" {
##  value = aws_instance.efs_viewer.public_ip
##}
#
#output "valheim_password" {
#  value = random_string.valheim_pwd.result
#}