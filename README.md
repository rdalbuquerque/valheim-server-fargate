# Valheim server setup
### Credits
This repository is based on [this](https://updateloop.dev/dedicated-valheim-lightsail/) tutorial and uses [this](https://github.com/mbround18/valheim-docker) image to host the server with Docker.

### Goal
The goal here is to facilitate the creation and management of the server.

### Pre-requisites
* Terraform
* Github account to manage Actions
* AWS account
* Pre-generated EC2 Key Pair named ``valheim``

### Providers autentication
The AWS and Github providers uses the following environment variables for authentication:
* AWS:
    * AWS_ACCESS_KEY_ID
    * AWS_SECRET_ACCESS_KEY
    * AWS_DEFAULT_REGION 
* Github:
    * GITHUB_TOKEN

## ``main.tf``
Network configuration:
```hcl
resource "aws_security_group_rule" "valheim" {
  type              = "ingress"
  from_port         = 2456 # Port range for Valheim
  to_port           = 2458
  protocol          = "udp"
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = []
  security_group_id = "sg-35035942" # My default sg
}
```
Configures the ingress udp ports for Valheim server communication
```hcl
resource "aws_security_group_rule" "ssh" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"] # Ideally the server admin ip or ip range
  ipv6_cidr_blocks  = []
  security_group_id = "sg-35035942" # My default sg
}
```
Configures ssh port for last mile server configuration

### EC2 instance 
```hcl
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
```
Configures EC2 instance that will host Valheim server. Somethings to notice:
* ami attribute: This Id is for the ubuntu 20.04 image on sa-east-1 region. Each region has it's on AMI Id's
* instance_type attribute: I Tried to host with t2.micro, no chance. t2.small was able to start a fresh server but once I uploaded my own it couldn't load everything up. t2.medium ran my server with 3 players for a couple of hours without any hickups and stable cpu usage at around 20%.

```hcl
resource "null_resource" "valheim_deploy" {
  triggers = {
    ec2_id   = aws_instance.web.id
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
```
This block is the last mile setup for the server.  
The [``deploy-valheim.sh``](deploy/deploy-valheim.sh) script is responsible for installing Docker and Docker Compose and initiating the server with ``sudo docker-compose up -d`` command. It also configures the crontab to run the Docker Compose command on reboot.  
The [``docker-compose.yml``](deploy/docker-compose.yml) is a copy paste from [this](https://updateloop.dev/dedicated-valheim-lightsail/) tutorial and there is a lot more info in the [image repo on Github](https://github.com/mbround18/valheim-docker).

### Github Action secrets
```hcl
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
```
This secrets are used in the workflow to stop and start the server.

### The workflows
Since the server I was creating was not intended to be a public 24/7 server, the solution I came up with was to use Github Actions to start/stop the instance, keeping AWS costs as low as possible. This is all they do. The [``start-server.yml``](.github/workflows/start-server.yml) is intended to be manually triggered by the first person who needs the server. The [``stop-server.yml``](.github/workflows/stop-server.yml) can also be manually triggered but is also scheduled to run everyday at 3 AM (UTC - 3) in case someone forgets to shut the server down.

### Disclaimer
This was done in a day out of curiosity, so there are probably much better ways to run, both more robust and cheaper, Valheim servers.



