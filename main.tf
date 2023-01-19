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
  config_default_az = "us-east-1a"
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

resource "random_string" "valheim_pwd" {
  length  = 6
  numeric = true
  special = false
}

locals {
  access_points = {
    "efs-valheim-saves" = {
      container_path = "/home/steam/.config/unity3d/IronGate/Valheim"
      efs_path       = "/valheim/saves"
    }
    "efs-valheim-server" = {
      container_path = "/home/steam/valheim"
      efs_path       = "/valheim/server"
    }
    "efs-valheim-backups" = {
      container_path = "/home/steam/backups"
      efs_path       = "/valheim/backups"
    }
  }
  ecs_task_mount_points = jsonencode([
    for k, v in local.access_points : {
      "sourceVolume" : "${k}"
      "containerPath" : "${v.container_path}"
    }
  ])
  ecs_task_container_definition = templatefile("valheim-task-container-definition.tfpl", {
    aws_region   = data.aws_region.current.name
    mount_points = local.ecs_task_mount_points
    server_name  = var.server_name
    word_name    = var.world_name
    password     = random_string.valheim_pwd.result
    timezone     = var.timezone
  })
}

resource "aws_efs_file_system" "valheim" {
  availability_zone_name = local.config_default_az

  tags = {
    Name = "valheim-efs"
  }
}

resource "aws_efs_mount_target" "valheim" {
  security_groups = [module.vpc.default_security_group_id]
  file_system_id  = aws_efs_file_system.valheim.id
  subnet_id       = module.vpc.public_subnets[0]
}

resource "aws_efs_access_point" "valheim" {
  for_each = local.access_points

  file_system_id = aws_efs_file_system.valheim.id
  root_directory {
    path = each.value.efs_path
    creation_info {
      owner_gid   = 0
      owner_uid   = 0
      permissions = 0777
    }
  }
}

module "ecs" {
  source = "terraform-aws-modules/ecs/aws"

  cluster_name = "valheim"

  fargate_capacity_providers = {
    FARGATE = {
      default_capacity_provider_strategy = {
        weight = 1
      }
    }
    FARGATE_SPOT = {
      default_capacity_provider_strategy = {
        weight = 100
      }
    }
  }

  tags = {
    Environment = "prd"
    Project     = "valheim-server"
  }
}

resource "aws_ecs_service" "valheim" {
  name             = "valheim"
  cluster          = module.ecs.cluster_id
  task_definition  = aws_ecs_task_definition.valheim.arn
  desired_count    = 0
  platform_version = "1.4.0" //not specfying this version explictly will not currently work for mounting EFS to Fargate
  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 100
    base              = 1
  }

  network_configuration {
    security_groups  = [module.vpc.default_security_group_id]
    subnets          = [module.vpc.public_subnets[0]]
    assign_public_ip = true
  }
}

resource "aws_ecs_task_definition" "valheim" {
  family                   = "valheim"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "4096"
  network_mode             = "awsvpc"
  execution_role_arn       = aws_iam_role.valheim_task.arn

  container_definitions = local.ecs_task_container_definition

  dynamic "volume" {
    for_each = aws_efs_access_point.valheim
    content {
      name = volume.key
      efs_volume_configuration {
        file_system_id     = aws_efs_file_system.valheim.id
        root_directory     = "/"
        transit_encryption = "ENABLED"
        authorization_config {
          access_point_id = volume.value.id
        }
      }
    }
  }
}

resource "aws_iam_role" "valheim_task" {
  name = "valheim_ecs_task"

  assume_role_policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Sid" : "",
        "Effect" : "Allow",
        "Principal" : {
          "Service" : [
            "ecs-tasks.amazonaws.com"
          ]
        },
        "Action" : "sts:AssumeRole"
      }
    ]
  })
}

data "aws_iam_policy" "ecs_task" {
  name = "AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy_attachment" "ecs_task" {
  role       = aws_iam_role.valheim_task.name
  policy_arn = data.aws_iam_policy.ecs_task.arn
}

data "aws_iam_policy" "cloudwatch" {
  name = "CloudWatchLogsFullAccess"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_ecs" {
  role       = aws_iam_role.valheim_task.name
  policy_arn = data.aws_iam_policy.cloudwatch.arn
}

#resource "aws_instance" "efs_viewer" {
#  ami           = "ami-0574da719dca65348" # ID of Ubuntu 20 SP ami (64-bit|x86)
#  instance_type = "t2.micro"
#  key_name      = "valheim-us"
#  subnet_id     = module.vpc.public_subnets[0]
#  
#  tags = {
#    Name = "efs-viewer"
#  }
#}
#
#output "efs_viewer_ip" {
#  value = aws_instance.efs_viewer.public_ip
#}

output "valheim_password" {
  value = random_string.valheim_pwd.result
}