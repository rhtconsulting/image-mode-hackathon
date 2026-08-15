############################################################
# Networking
############################################################

resource "aws_vpc" "lab" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "${var.environment_name}-vpc"
    Environment = var.environment_name
  }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id

  tags = {
    Name        = "${var.environment_name}-igw"
    Environment = var.environment_name
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name        = "${var.environment_name}-public-subnet-a"
    Environment = var.environment_name
  }
}

resource "aws_subnet" "resolver" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = var.resolver_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = false

  tags = {
    Name        = "${var.environment_name}-resolver-subnet-b"
    Environment = var.environment_name
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }

  tags = {
    Name        = "${var.environment_name}-public-rt"
    Environment = var.environment_name
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "resolver" {
  subnet_id      = aws_subnet.resolver.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "lab" {
  name        = "${var.environment_name}-sg"
  description = "Security group for RHEL image mode lab nodes"
  vpc_id      = aws_vpc.lab.id

  ingress {
    description = "SSH from home network and internal VPC"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"

    cidr_blocks = [
      var.ssh_allowed_cidr,
      var.vpc_cidr
    ]
  }

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Internal lab traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Outbound internet access"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.environment_name}-sg"
    Environment = var.environment_name
  }
}

############################################################
# Image Builder Security Group
############################################################

resource "aws_security_group" "image_builder" {
  name        = "${var.environment_name}-image-builder-sg"
  description = "Additional access for Image Builder hosts"
  vpc_id      = aws_vpc.lab.id

  ingress {
    description = "Cockpit Web Console"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description      = "Cockpit Web Console IPv6"
    from_port        = 9090
    to_port          = 9090
    protocol         = "tcp"
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name        = "${var.environment_name}-image-builder-sg"
    Environment = var.environment_name
  }
}

############################################################
# GitLab Security Group
############################################################

resource "aws_security_group" "gitlab" {
  name        = "${var.environment_name}-gitlab-sg"
  description = "Additional access for GitLab hosts"
  vpc_id      = aws_vpc.lab.id

  ingress {
    description = "GitLab container registry"
    from_port   = 5050
    to_port     = 5050
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description      = "GitLab container registry IPv6"
    from_port        = 5050
    to_port          = 5050
    protocol         = "tcp"
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    description = "Outbound access"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.environment_name}-gitlab-sg"
    Environment = var.environment_name
  }
}



