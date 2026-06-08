output "instance_id" {
  description = "EC2 instance ID for SSM Session Manager."
  value       = aws_instance.this.id
}

output "huggingface_secret_name" {
  description = "Set this Secrets Manager secret value to your Hugging Face token before restarting the app."
  value       = aws_secretsmanager_secret.huggingface_token.name
}

output "set_huggingface_token_command" {
  description = "Command template to set the Hugging Face token after terraform apply."
  value       = "aws secretsmanager put-secret-value --region ${data.aws_region.current.name} --secret-id ${aws_secretsmanager_secret.huggingface_token.name} --secret-string '<your-hf-token>'"
  sensitive   = true
}

output "coder_port_forward_command" {
  description = "Run this locally, then open http://localhost:7080."
  value       = "aws ssm start-session --region ${data.aws_region.current.name} --target ${aws_instance.this.id} --document-name AWS-StartPortForwardingSession --parameters file://aws/ssm-parameters/coder-port-forward.json"
}

output "vllm_port_forward_command" {
  description = "Optional: forward vLLM's OpenAI-compatible API to http://localhost:8000/v1."
  value       = "aws ssm start-session --region ${data.aws_region.current.name} --target ${aws_instance.this.id} --document-name AWS-StartPortForwardingSession --parameters file://aws/ssm-parameters/vllm-port-forward.json"
}

output "app_status_command" {
  description = "Check Docker Compose status through SSM."
  value       = "aws ssm start-session --region ${data.aws_region.current.name} --target ${aws_instance.this.id}"
}
