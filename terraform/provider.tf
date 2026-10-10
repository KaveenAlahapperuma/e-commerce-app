locals {

  region          = "us-west-2"
  name            = "tws-eks-cluster"
  vpc_cidr        = "10.0.0.0/16"
  azs             = ["us-west-2a", "us-west-2b"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.3.0/24", "10.0.4.0/24"]

  tags = {
    example = local.name
  }

}

provider "aws" {

  region = local.region

}
