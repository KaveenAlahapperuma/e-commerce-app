terraform {
  backend "s3" {
    bucket = "terraform-s3-backend-tws-hackathon"
    key    = "backend-locking"
    region = "us-west-2"
    use_lockfile = true
  }
}
