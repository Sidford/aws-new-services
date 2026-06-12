terraform {
  backend "s3" {
    bucket         = "aws-service-monitor-tfstate-556717286844-eu-west-2"
    key            = "terraform.tfstate"
    region         = "eu-west-2"
    encrypt        = true
    dynamodb_table = "aws-service-monitor-tfstate-lock"
  }
}
