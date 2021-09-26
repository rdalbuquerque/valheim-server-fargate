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

resource "aws_security_group_rule" "valheim" {
  type              = "ingress"
  from_port         = 2456 # Range de portas usadas pelo Valheim
  to_port           = 2458
  protocol          = "udp"
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = []
  security_group_id = "sg-35035942" # Default sg
}

resource "aws_security_group_rule" "ssh" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"] # Preferencialmente IP do host principal que executará o terraform
  ipv6_cidr_blocks  = []
  security_group_id = "sg-35035942" # Default sg
}

resource "aws_instance" "web" {
  depends_on = [aws_security_group_rule.ssh]

  ami           = "ami-054a31f1b3bf90920" # ID of Ubuntu 20 SP ami (64-bit|x86)
  instance_type = "t2.medium"
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
    ec2_id = aws_instance.web.id
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