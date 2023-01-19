# Valheim server setup
- [Valheim server setup](#valheim-server-setup)
    - [Description](#description)
    - [Credits](#credits)
    - [Goal](#goal)
    - [Pre-requisites](#pre-requisites)
    - [Provider auth](#provider-auth)
    - [Network config](#network-config)
    - [Locals block](#locals-block)
    - [Data layer](#data-layer)
    - [ECS - Fargate](#ecs---fargate)
      - [cluster](#cluster)
      - [service and task](#service-and-task)
    - [Task role](#task-role)
    - [Conclusion](#conclusion)

### Description
In this repository, you will find code to set up a Valheim game server using AWS ECS with the Fargate (serverless) capacity provider. If you prefer an alternative to Fargate, check out [this other repository](https://github.com/rdalbuquerque/valheim-server-asg-ec2) that also uses AWS ECS, but with an auto-scaling group (EC2) capacity provider. The latter option may be more performant and cost-effective, as it gives you more flexibility to adjust and fine-tune cluster configurations and use EBS external volumes, while Fargate only allows for the use of EFS. However, the former option (this repo) is much easier to set up and provides greater freedom to experiment with different CPU/memory configurations.

### Credits
This repository is inpired by [this tutorial](https://updateloop.dev/dedicated-valheim-lightsail/) and uses [this image](https://github.com/mbround18/valheim-docker) to host the server with Docker.

### Goal
The goal here is to facilitate the creation and management of the server.

### Pre-requisites
* Terraform
* AWS account

### Provider auth
The AWS provider uses the following environment variables for authentication:
* AWS:
    * AWS_ACCESS_KEY_ID
    * AWS_SECRET_ACCESS_KEY
    * AWS_DEFAULT_REGION 

### Network config
Network configuration:
```hcl
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
```
With this `vpc` module I'm creating a public subnet and, since I need to communicate with Steam and other players, rules that allow on traffic from any protocol.
In a more meaningfull project you should create only the necessary inbound and outbound rules with specific protocols.

### Locals block
```hcl
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
  ecs_task_container_definition = templatefile("valheim-task-container-definition.tftpl", {
    aws_region   = data.aws_region.current.name
    mount_points = local.ecs_task_mount_points
    server_name  = "Psicolandia2"
    word_name    = "Psicolandia2"
    password     = random_string.valheim_pwd.result
    timezone     = "America/Sao_paulo"
  })
}
```
Here I create a random password that will used in the valheim server (I use `random_string` so I can output it in plain text, again, on a more meaningful project, protect your credentials acordingly).
The `locals` block are the variables that will be used to render the ECS task container definition

### Data layer

```hcl
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
```
In this block I define the EFS, it's mount target, and it's access points. the latter with a `foreach` accordingly to what was defined in `locals`.
The EFS will be used to store data from the Valheim containers.

### ECS - Fargate
#### cluster
```hcl
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
```
I use the module to configure an ECS cluster with a strategy of 100% `FARGATE_SPOT` capacity provider to decrease costs. Since my data is safe on an EFS and it's just a game, I can afford to use 100% spot capacity provider.

#### service and task
```hcl
resource "aws_ecs_service" "valheim" {
  name             = "valheim"
  cluster          = module.ecs.cluster_id
  task_definition  = aws_ecs_task_definition.valheim.arn
  desired_count    = 1
  platform_version = "2.4.0" //not specfying this version explictly will not currently work for mounting EFS to Fargate
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
  cpu                      = "2048"
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
```
I'm using a 2 CPU, 4GB Memory task here, and it held up really well with 3 players and no buildings. One advantage of using and ECS task with the Fargate approach and persisting data elsewhere is that I can easily experiment with resources to optimize costs. 
The container definition is being rendered in `locals` from [`valheim-task-container-definition.tftpl`](./valheim-task-container-definition.tftpl) file.

### Task role
```hcl
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
```
Here I define the ECS task role so it can create log group and send the logs to AWS Cloudwatch.

### Conclusion
Overall, this project on AWS using ECS and EFS was a valuable learning experience. By using ECS, I was able to easily deploy and manage the Valheim server, and by using EFS, I was able to ensure data resiliency. EFS allowed me to store Valheim server data in a central location always available to Valheim ECS task, which helped me to avoid data loss. In addition, I was able to take advantage of the Fargate launch type to simplify the infrastructure and save on costs. Overall, this project has demonstrated the power and potential of AWS for containerized applications.

OBS: This conclusion was generated by GPT Chat but greately summerized what this project was :)

