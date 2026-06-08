variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-west-2"
}

variable "name_prefix" {
  description = "Prefix used for resource names."
  type        = string
  default     = "private-code-agent"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.44.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the NAT public subnet."
  type        = string
  default     = "10.44.0.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR block for the EC2 private subnet."
  type        = string
  default     = "10.44.10.0/24"
}

variable "instance_type" {
  description = "GPU instance type for vLLM. Gemma 4 31B QAT with MTP uses an NVIDIA L40S 44 GiB GPU by default."
  type        = string
  default     = "g6e.xlarge"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size. Model cache, Docker layers, Coder state, and workspace volumes live here."
  type        = number
  default     = 300
}

variable "model_id" {
  description = "Hugging Face model ID served by vLLM."
  type        = string
  default     = "google/gemma-4-31B-it-qat-w4a16-ct"
}

variable "mtp_assistant_model_id" {
  description = "Hugging Face assistant checkpoint used by Gemma 4 MTP speculative decoding."
  type        = string
  default     = "google/gemma-4-31B-it-qat-q4_0-unquantized-assistant"
}

variable "num_speculative_tokens" {
  description = "Number of speculative tokens for Gemma 4 MTP."
  type        = number
  default     = 4
}

variable "max_model_len" {
  description = "Maximum context length served by vLLM."
  type        = number
  default     = 131072
}

variable "vllm_image" {
  description = "vLLM OpenAI-compatible Docker image."
  type        = string
  default     = "vllm/vllm-openai:v0.22.1"
}

variable "coder_image" {
  description = "Coder Docker image."
  type        = string
  default     = "ghcr.io/coder/coder:latest"
}

variable "hf_secret_name" {
  description = "AWS Secrets Manager secret name that will contain the Hugging Face token."
  type        = string
  default     = "private-code-agent/huggingface-token"
}

variable "enable_nat_gateway" {
  description = "Create a NAT Gateway for outbound Docker/Hugging Face/package downloads from the private EC2 instance."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags to apply to resources."
  type        = map(string)
  default     = {}
}
