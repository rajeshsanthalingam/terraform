resource "aws_vpc" "default" {
  cidr_block           = "${var.vpc_cidr}"
  enable_dns_hostnames = true

  tags {
    Name = "${var.project}-vpc"
  }
}

resource "aws_internet_gateway" "default" {
  vpc_id = "${aws_vpc.default.id}"

  tags {
    Name = "${var.project}-igw"
  }
}

data "external" "bitbucket_ipsv4" {
  program = ["bash", "${path.module}/external-scripts/fetch-bitbucket-ipsv4.sh"]
}

data "external" "bitbucket_ipsv6" {
  program = ["bash", "${path.module}/external-scripts/fetch-bitbucket-ipsv6.sh"]
}

locals {
  bitbucket_ipsv4 = ["${split("\n", data.external.bitbucket_ipsv4.result.bitbucket_ipsv4)}"]
  bitbucket_ipsv6 = ["${split("\n", data.external.bitbucket_ipsv6.result.bitbucket_ipsv6)}"]
}

resource "aws_default_security_group" "default" {
  vpc_id = "${aws_vpc.default.id}"

  ingress {
    protocol  = -1
    self      = true
    from_port = 0
    to_port   = 0
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Name = "${var.project}-default"
  }
}

resource "aws_security_group" "nat" {
  name        = "${var.project}-vpc-nat"
  description = "Allow traffic for webserver"

  ### Example ingress configuration to allow ports ###
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["${var.private_subnet_cidr}"]
    description = "Allow Port 80 in public"
  }

  ### Example egress configuration to allow ports ###
  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
    description      = "Allow all outbound connection"
  }

  vpc_id = "${aws_vpc.default.id}"

  tags {
    Name = "${var.project}-SecurityGroupNAT"
  }
}

resource "aws_security_group" "bitbucket_ipsv4_sg" {
  name        = "bitbucket-ipsv4-sg"
  description = "Bitbucket ipsv4 security group"
  vpc_id      = "${aws_vpc.default.id}"

  lifecycle {
    create_before_destroy = true
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["${local.bitbucket_ipsv4}"]
    description = "bitbucket.org public IPs"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Name = "${var.project}-bitbucket-ipv4-sg"
  }
}

resource "aws_security_group" "bitbucket_ipsv6_sg" {
  name        = "bitbucket-ipsv6-sg"
  description = "Bitbucket ipsv6 security group"
  vpc_id      = "${aws_vpc.default.id}"

  lifecycle {
    create_before_destroy = true
  }

  ingress {
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    ipv6_cidr_blocks = ["${local.bitbucket_ipsv6}"]
    description      = "bitbucket.org public IPs"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Name = "${var.project}-bitbucket-ipv6-sg"
  }
}

/*
    NAT Instance
  */

resource "aws_instance" "nat" {
  ami                         = "${lookup(var.natami, var.aws_region)}" # this is a special ami preconfigured to do NAT
  availability_zone           = "${var.aws_region}a"
  instance_type               = "t2.micro"
  key_name                    = "${var.aws_key_name}"
  vpc_security_group_ids      = ["${aws_security_group.nat.id}"]
  subnet_id                   = "${aws_subnet.subnet-public.id}"
  associate_public_ip_address = true
  source_dest_check           = false

  tags {
    Name = "${var.project}-vpc-nat"
  }

  volume_tags {
    Name = "${var.project}-nat-vols"
  }

  root_block_device {
    volume_size           = "20"
    delete_on_termination = true
    volume_type           = "gp2"
  }
}

resource "aws_eip" "nat-eip" {
  instance = "${aws_instance.nat.id}"
  vpc      = true

  tags {
    Name = "${var.project}-nat-eip"
  }
}

/*
  Public Subnet
*/
resource "aws_subnet" "subnet-public" {
  vpc_id = "${aws_vpc.default.id}"

  cidr_block        = "${var.public_subnet_cidr}"
  availability_zone = "${var.aws_region}a"

  tags {
    Name = "${var.project}-Public-Subnet"
  }
}

resource "aws_route_table" "route-public" {
  vpc_id = "${aws_vpc.default.id}"

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.default.id}"
  }

  tags {
    Name = "${var.project}-Public-Subnet"
  }
}

resource "aws_route_table_association" "route-ass-public" {
  subnet_id      = "${aws_subnet.subnet-public.id}"
  route_table_id = "${aws_route_table.route-public.id}"
}

/*
  Private Subnet
*/
resource "aws_subnet" "subnet-private" {
  vpc_id = "${aws_vpc.default.id}"

  cidr_block        = "${var.private_subnet_cidr}"
  availability_zone = "${var.aws_region}a"

  tags {
    Name = "${var.project}-Private-Subnet"
  }
}

resource "aws_route_table" "route-private" {
  vpc_id = "${aws_vpc.default.id}"

  route {
    cidr_block  = "0.0.0.0/0"
    instance_id = "${aws_instance.nat.id}"
  }

  tags {
    Name = "${var.project}-Private-Subnet"
  }
}

resource "aws_route_table_association" "route-ass-private" {
  subnet_id      = "${aws_subnet.subnet-private.id}"
  route_table_id = "${aws_route_table.route-private.id}"
}

resource "aws_route53_zone_association" "private_zone" {
  zone_id = "${var.zone_id_priv}"
  vpc_id  = "${aws_vpc.default.id}"
}
