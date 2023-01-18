provider "aws" {
  profile = "ekama"
}

data "aws_availability_zones" "available_zones" {
  state = "available"
}

data "aws_s3_bucket" "infra" {
  bucket = "infralogs12345"
}


output "Az_data" {
  value = data.aws_availability_zones.available_zones.names
}

output "internet_gtw" {
  value = aws_internet_gateway.BWT_internet_gateway
}

variable "vpc_cidr" {
  default = "10.0.0.0/16"
  type    = string
}

variable "prifix" {
  default = "BWF"
  type    = string
}
variable "nick_name" {
  default = "build_with_friends"
}

resource "aws_vpc" "vpc" {
  cidr_block = var.vpc_cidr
  tags = {
    Name = "${var.prifix}_vpc"
  }
}

variable "private_subnet_cidr" {
  default = 2
  type    = number
}


variable "public_subnet_cidr" {
  default = 2
  type    = number
}




resource "aws_subnet" "BWT_private_subnet" {
  count  = var.private_subnet_cidr
  vpc_id = aws_vpc.vpc.id

  cidr_block        = cidrsubnet(var.vpc_cidr, 8, range(0, 255, 2)[count.index])
  availability_zone = data.aws_availability_zones.available_zones.names[count.index]
  tags = {
    Name      = "${var.prifix}_private_subent_${count.index}"
    nick_name = var.nick_name
  }
}

resource "aws_subnet" "BWT_public_subnet" {
  count             = var.public_subnet_cidr
  vpc_id            = aws_vpc.vpc.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, range(1, 255, 2)[count.index])
  availability_zone = element(data.aws_availability_zones.available_zones.names, count.index)
  tags = {
    Name      = "${var.prifix}_public_subent_${count.index}"
    nick_name = var.nick_name
  }

}

resource "aws_internet_gateway" "BWT_internet_gateway" {
  vpc_id = aws_vpc.vpc.id
}
resource "aws_eip" "BWT_eip" {
  count      = var.private_subnet_cidr
  vpc        = true
  depends_on = [aws_internet_gateway.BWT_internet_gateway]
}

resource "aws_nat_gateway" "BWT_nat_gateway" {
  count         = var.private_subnet_cidr
  subnet_id     = aws_subnet.BWT_private_subnet.*.id[count.index]
  allocation_id = element(aws_eip.BWT_eip.*.id, count.index)
}

resource "aws_route" "internet_access" {
  route_table_id         = aws_vpc.vpc.main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.BWT_internet_gateway.id
}

resource "aws_route_table" "BWT_private_rt" {
  vpc_id = aws_vpc.vpc.id
  count  = var.private_subnet_cidr

  route {
    cidr_block     = "0.0.0.0/0" //wildcat
    nat_gateway_id = element(aws_nat_gateway.BWT_nat_gateway.*.id, count.index)
  }

  tags = {
    Name = "BWT_private_rt"
  }
}

resource "aws_route_table_association" "BWT_private_rt_associate" {
  count          = var.private_subnet_cidr
  subnet_id      = element(aws_subnet.BWT_private_subnet.*.id, count.index)
  route_table_id = element(aws_route_table.BWT_private_rt.*.id, count.index)

}


resource "aws_lb" "BWF_elb" {
  name               = "BWF-elb"
  # internal           = false
  # load_balancer_type = "application"
  security_groups    = [aws_security_group.BWT_sg["load_balancer_sg"].id] // unknown 
  subnets            = [for subnet in aws_subnet.BWT_public_subnet : subnet.id]
  depends_on = [aws_internet_gateway.BWT_internet_gateway]

  # enable_deletion_protection = true

  access_logs {
    bucket  = data.aws_s3_bucket.infra.bucket
    prefix  = "infralogs"
    enabled = true
  }

  tags = {
    Environment = "BWF-lb"
  }
}

output "load_balancer_ip" {
  value = aws_lb.BWF_elb.dns_name
}

resource "aws_lb_target_group" "BWF_tg" {
  name        = "BWF-tg"
  target_type = "instance"
  port        = 80
  protocol    = "HTTP"

  vpc_id = aws_vpc.vpc.id

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    path = "/"
  }
  
  lifecycle {
    ignore_changes = [name]
    create_before_destroy = true
  } 
}

resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.BWF_elb.arn
  port        = 80
  protocol    = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.BWF_tg.arn
  }
}





locals {
  security_groups = {
    public = {
      name        = "public_sg"
      description = "allow access from anywhere"
      ingress = {
        ssh = {

          from        = 22
          to          = 22
          protocol    = "tcp"
          cidr_blocks = ["0.0.0.0/0"]
        }
        http = {

          from        = 80
          to          = 80
          protocol    = "tcp"
          cidr_blocks = ["0.0.0.0/0"]
        }
      }
    }
    instance = {
      name        = "instance"
      description = "allow access to database"
      ingress = {
        db_igrs = {
          from        = 80
          to          = 80
          protocol    = "tcp"
          cidr_blocks = ["0.0.0.0/0"]
        }

      }
    }
    load_balancer_sg = {
      name        = "load_balancer_sg"
      description = "allow access to load_balancer"
      ingress = {
        db_igrs = {
          from        = 80
          to          = 80
          protocol    = "tcp"
          cidr_blocks = ["0.0.0.0/0"]
        }

      }
    }
  }
}


resource "aws_security_group" "BWT_sg" {
  for_each    = local.security_groups
  name        = each.value.name
  description = each.value.description
  vpc_id      = aws_vpc.vpc.id

  dynamic "ingress" {
    for_each = each.value.ingress
    content {
      from_port   = ingress.value.from
      to_port     = ingress.value.to
      protocol    = ingress.value.protocol
      cidr_blocks = ingress.value.cidr_blocks
    }
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    # ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "allow_tls"
  }
}



resource "aws_launch_template" "BWF_launch_teplate" {
  name_prefix   = "BWF_teplate"
  image_id      = "ami-06878d265978313ca" //ubuntu`
  instance_type = "t2.micro"
  vpc_security_group_ids = [aws_security_group.BWT_sg["public"].id]
    user_data = "${base64encode(file("configures.sh"))}"
  key_name = "bwt"
    lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "bwt_scale_group" {
  vpc_zone_identifier= aws_subnet.BWT_private_subnet.*.id
  desired_capacity   = 2
  max_size           = 3
  min_size           = 1
  depends_on = [
    aws_launch_template.BWF_launch_teplate
  ]

  launch_template {
    id      = aws_launch_template.BWF_launch_teplate.id
    # varsion ="$latest"
   
  }
}

resource "aws_autoscaling_attachment" "asg_attachment_bar" {
  autoscaling_group_name = aws_autoscaling_group.bwt_scale_group.id
  lb_target_group_arn    = aws_lb_target_group.BWF_tg.arn
}





















# wrote configuration file 
# understand syntax
# understand count attribute 
# understand functions
#  "         variable
# string concat
# 





# use  commands
#   init          Prepare your working directory for other commands
#   validate      Check whether the configuration is valid
#   plan          Show changes required by the current configuration
#   apply         Create or update infrastructure
#   destroy       Destroy previously-created infrastructure
#   import        Associate existing infrastructure with a Terraform resource
#   show          Show the current state or a saved plan
#   state         Advanced state management  
#   fmt           Reformat your configuration in the standard style  

