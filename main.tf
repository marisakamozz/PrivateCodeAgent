locals {
  tags = merge(
    {
      Project   = var.name_prefix
      ManagedBy = "terraform"
    },
    var.tags
  )
}

data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ssm_parameter" "dlami" {
  name = "/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-22.04/latest/ami-id"
}

data "archive_file" "bootstrap" {
  type        = "zip"
  output_path = "/private/tmp/${var.name_prefix}-bootstrap.zip"

  source {
    content  = file("${path.module}/app/docker-compose.yml")
    filename = "app/docker-compose.yml"
  }

  source {
    content  = file("${path.module}/app/render-runtime-config.py")
    filename = "app/render-runtime-config.py"
  }

  source {
    content  = file("${path.module}/app/coder-template/main.tf")
    filename = "app/coder-template/main.tf"
  }

  source {
    content  = file("${path.module}/app/coder-template/build/Dockerfile")
    filename = "app/coder-template/build/Dockerfile"
  }

  source {
    content  = file("${path.module}/aws/ssm-parameters/coder-port-forward.json")
    filename = "aws/ssm-parameters/coder-port-forward.json"
  }

  source {
    content  = file("${path.module}/aws/ssm-parameters/vllm-port-forward.json")
    filename = "aws/ssm-parameters/vllm-port-forward.json"
  }
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-vpc"
  })
}

resource "aws_internet_gateway" "this" {
  count  = var.enable_nat_gateway ? 1 : 0
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-igw"
  })
}

resource "aws_subnet" "public" {
  count                   = var.enable_nat_gateway ? 1 : 0
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-public"
  })
}

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.private_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-private"
  })
}

resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? 1 : 0
  domain = "vpc"

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-nat"
  })
}

resource "aws_nat_gateway" "this" {
  count         = var.enable_nat_gateway ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-nat"
  })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  count  = var.enable_nat_gateway ? 1 : 0
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this[0].id
  }

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-public"
  })
}

resource "aws_route_table_association" "public" {
  count          = var.enable_nat_gateway ? 1 : 0
  subnet_id      = aws_subnet.public[0].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  dynamic "route" {
    for_each = var.enable_nat_gateway ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.this[0].id
    }
  }

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-private"
  })
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "instance" {
  name        = "${var.name_prefix}-instance"
  description = "No inbound access; SSM Session Manager only."
  vpc_id      = aws_vpc.this.id

  egress {
    description = "Allow outbound HTTPS and package/model downloads."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-instance"
  })
}

resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.name_prefix}-endpoints"
  description = "Allow the EC2 instance to reach private VPC endpoints."
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "HTTPS from the EC2 instance."
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.instance.id]
  }

  egress {
    description = "Endpoint responses."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-endpoints"
  })
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset([
    "ssm",
    "ssmmessages",
    "ec2messages",
    "secretsmanager",
    "logs"
  ])

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.key}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.vpc_endpoints.id]

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-${each.key}-endpoint"
  })
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-s3-endpoint"
  })
}

resource "aws_s3_bucket" "bootstrap" {
  bucket_prefix = "${var.name_prefix}-bootstrap-"
  force_destroy = true

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-bootstrap"
  })
}

resource "aws_s3_bucket_public_access_block" "bootstrap" {
  bucket                  = aws_s3_bucket.bootstrap.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "bootstrap" {
  bucket = aws_s3_bucket.bootstrap.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_object" "bootstrap" {
  bucket       = aws_s3_bucket.bootstrap.id
  key          = "bootstrap/private-code-agent.zip"
  source       = data.archive_file.bootstrap.output_path
  source_hash  = data.archive_file.bootstrap.output_base64sha256
  content_type = "application/zip"
}

resource "aws_secretsmanager_secret" "huggingface_token" {
  name                    = var.hf_secret_name
  description             = "Hugging Face API token for downloading ${var.model_id}. Set SecretString manually after apply."
  recovery_window_in_days = 0

  tags = local.tags
}

resource "aws_iam_role" "instance" {
  name = "${var.name_prefix}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "app" {
  name = "${var.name_prefix}-app"
  role = aws_iam_role.instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = aws_secretsmanager_secret.huggingface_token.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = aws_s3_object.bootstrap.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name_prefix}-instance-profile"
  role = aws_iam_role.instance.name
}

resource "aws_instance" "this" {
  ami                         = data.aws_ssm_parameter.dlami.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.private.id
  vpc_security_group_ids      = [aws_security_group.instance.id]
  iam_instance_profile        = aws_iam_instance_profile.this.name
  associate_public_ip_address = false

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size           = var.root_volume_size_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    app_dir                = "/opt/private-code-agent"
    bootstrap_s3_uri       = "s3://${aws_s3_bucket.bootstrap.id}/${aws_s3_object.bootstrap.key}"
    aws_region             = data.aws_region.current.name
    hf_secret_id           = aws_secretsmanager_secret.huggingface_token.id
    model_id               = var.model_id
    mtp_assistant_model    = var.mtp_assistant_model_id
    num_speculative_tokens = var.num_speculative_tokens
    max_model_len          = var.max_model_len
    vllm_image             = var.vllm_image
    coder_image            = var.coder_image
  })

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-ec2"
  })

  depends_on = [
    aws_iam_role_policy_attachment.ssm,
    aws_vpc_endpoint.interface,
    aws_vpc_endpoint.s3
  ]
}
