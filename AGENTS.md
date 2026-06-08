# AGENTS.md

Use static validation first. Do not run `terraform apply` or live EC2 runtime checks unless explicitly requested; provide the commands for the user to run instead.
For AWS SSM Run Command via the AWS CLI, write the `--parameters` payload to a temporary JSON file under `/private/tmp` and pass it with `--parameters file://...` to avoid shell quoting issues. Regular cleanup is not required because these temporary files are removed on macOS restart.
Run AWS SSM CLI operations with escalated permissions from the start instead of the local sandbox.
