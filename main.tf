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

resource "aws_efs_access_point" "valheim_saves" {
  file_system_id = aws_efs_file_system.valheim.id
  root_directory {
    path = "/valheim/saves"
    creation_info {
      owner_gid = 0
      owner_uid = 0
      permissions = 0777
    }
  }
}

resource "aws_efs_access_point" "valheim_server" {
  file_system_id = aws_efs_file_system.valheim.id
  root_directory {
    path = "/valheim/server"
    creation_info {
      owner_gid = 0
      owner_uid = 0
      permissions = 0777
    }
  }
}

resource "aws_efs_access_point" "valheim_backup" {
  file_system_id = aws_efs_file_system.valheim.id
  root_directory {
    path = "/valheim/backups"
    creation_info {
      owner_gid = 0
      owner_uid = 0
      permissions = 0777
    }
  }
}

module "ecs" {
  source = "terraform-aws-modules/ecs/aws"

  cluster_name = "valheim"

  fargate_capacity_providers = {
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
  desired_count    = 1
  launch_type      = "FARGATE"
  platform_version = "1.4.0" //not specfying this version explictly will not currently work for mounting EFS to Fargate

  network_configuration {
    security_groups  = [module.vpc.default_security_group_id]
    subnets          = [module.vpc.public_subnets[0]]
    assign_public_ip = true
  }
}

resource "aws_ecs_task_definition" "valheim" {
  family                   = "valheim"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "2048"
  memory                   = "4096"
  network_mode             = "awsvpc"
  execution_role_arn       = aws_iam_role.valheim_task.arn

  container_definitions = <<DEFINITION
[
  {
      "logConfiguration": {
          "logDriver": "awslogs",
          "options": {
              "awslogs-group": "valheim-container",
              "awslogs-region": "us-east-1",
              "awslogs-create-group": "true",
              "awslogs-stream-prefix": "valheim"
          }
      },
      "portMappings": [
          {
              "hostPort": 2456,
              "containerPort": 2456,
              "protocol": "udp"
          },
          {
              "hostPort": 2457,
              "containerPort": 2457,
              "protocol": "udp"
          },
          {
              "hostPort": 2458,
              "containerPort": 2458,
              "protocol": "udp"
          }
      ],
      "essential": true,
      "mountPoints": [
          {
              "containerPath": "/home/steam/.config/unity3d/IronGate/Valheim",
              "sourceVolume": "efs-valheim-saves"
          },
          {
              "containerPath": "/home/steam/valheim",
              "sourceVolume": "efs-valheim-server"
          },
          {
              "containerPath": "/home/steam/backups",
              "sourceVolume": "efs-valheim-backups"
          }
      ],
      "name": "valheim-latest",
      "image": "mbround18/valheim:latest",
      "environment": [
        {"name": "PORT", "value": "2456"},
        {"name": "NAME", "value": "VALHEIMZINN"},
        {"name": "WORLD", "value": "WorldDosCria"},
        {"name": "PASSWORD", "value": "Banda123"},
        {"name": "TZ", "value": "America/Sao_paulo"},
        {"name": "AUTO_UPDATE", "value": "1"},
        {"name": "AUTO_UPDATE_SCHEDULE", "value": "0 1 * * *"},
        {"name": "AUTO_BACKUP", "value": "1"},
        {"name": "AUTO_BACKUP_SCHEDULE", "value": "*/15 * * * *"},
        {"name": "AUTO_BACKUP_REMOVE_OLD", "value": "1"},
        {"name": "AUTO_BACKUP_DAYS_TO_LIVE", "value": "3"}
      ]
  }
]
DEFINITION

  volume {
    name = "efs-valheim-saves"
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.valheim.id
      root_directory     = "/"
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.valheim_saves.id
      }
    }
  }
  volume {
    name = "efs-valheim-server"
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.valheim.id
      root_directory     = ""
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.valheim_server.id
      }
    }
  }
  volume {
    name = "efs-valheim-backups"
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.valheim.id
      root_directory     = ""
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.valheim_backup.id
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

resource "aws_instance" "efs_viewer" {
  ami           = "ami-0574da719dca65348" # ID of Ubuntu 20 SP ami (64-bit|x86)
  instance_type = "t2.micro"
  key_name      = "valheim-us"
  subnet_id     = module.vpc.public_subnets[0]
  tags = {
    Name = "efs-viewer"
  }
}

output "efs_viewer_ip" {
  value = aws_instance.efs_viewer.public_ip
}