terraform {
  backend "local" {
    path = "state/terraform.tfstate"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.0"
    }
  }
}

# Configure the AWS Provider
# Credentials and default region are set on envrionment variables
provider "aws" {}

provider "github" {}

variable "aws_access_key_id" {
  type = string
}

variable "aws_secret_access_key" {
  type      = string
  sensitive = true
}

resource "aws_security_group_rule" "valheim" {
  type              = "ingress"
  from_port         = 2456 # Port range for Valheim
  to_port           = 2458
  protocol          = "udp"
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = []
  security_group_id = "sg-35035942" # My default sg
}

resource "aws_security_group_rule" "ssh" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"] # Ideally the server admin ip or ip range
  ipv6_cidr_blocks  = []
  security_group_id = "sg-35035942" # My default sg
}

resource "aws_instance" "web" {
  depends_on = [aws_security_group_rule.ssh]

  ami           = "ami-054a31f1b3bf90920" # ID of Ubuntu 20 SP ami (64-bit|x86)
  instance_type = "t2.medium" # Minimum size for satisfatory performance and stability
  key_name      = "valheim"
  tags = {
    Name = "Valheim1"
  }

  provisioner "remote-exec" {
    connection {
      host        = self.public_ip
      user        = "ubuntu"
      private_key = file("~/.ssh/valheim.pem")
    }
    inline = ["echo 'Instance ${self.public_dns} is up!'"]
  }
}

resource "null_resource" "valheim_deploy" {
  triggers = {
    ec2_id   = aws_instance.web.id
    ec2_size = aws_instance.web.instance_type 
  }

  connection {
    host        = aws_instance.web.public_ip
    user        = "ubuntu"
    private_key = file("~/.ssh/valheim.pem")
  }

  provisioner "file" {
    source      = "deploy/"
    destination = "~"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x ~/deploy-valheim.sh && ~/deploy-valheim.sh",
    ]
  }
}

resource "github_actions_secret" "aws_access_key" {
  repository      = "valheim-server"
  secret_name     = "AWS_ACCESS_KEY_ID"
  plaintext_value = var.aws_access_key_id
}

resource "github_actions_secret" "aws_secret_key" {
  repository      = "valheim-server"
  secret_name     = "AWS_SECRET_ACCESS_KEY"
  plaintext_value = var.aws_secret_access_key
}

resource "github_actions_secret" "aws_ec2_instance_id" {
  repository      = "valheim-server"
  secret_name     = "instance_id"
  plaintext_value = aws_instance.web.id
}