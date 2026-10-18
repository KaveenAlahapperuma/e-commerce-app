EasyShop on AWS EKS: End-to-End DevOps Deployment

A 3-tier e-commerce application (Next.js, Node API routes, MongoDB) provisioned and deployed on AWS EKS using Terraform, Jenkins (CI), ArgoCD (GitOps CD), Helm, Prometheus, Grafana and Alertmanager with Slack alerts.

Credit: forked from LondheShubham153/tws-e-commerce-app. The application, base Terraform, Jenkinsfile and Kubernetes manifests are by the original author. This repository documents how I provisioned, adapted, deployed, monitored and operated it on my own AWS account.

Project flow
Terraform builds the VPC, EKS cluster, node group, Jenkins EC2 and Bastion EC2.
A push to GitHub triggers Jenkins through a webhook.
Jenkins builds the Docker image, pushes it to Docker Hub, and commits the new image tag to the Kubernetes manifests in Git.
ArgoCD detects the change in Git and syncs it to the EKS cluster.
The AWS Load Balancer Controller creates an ALB from the Ingress resource and sends traffic to the pods.
Prometheus collects metrics, Grafana visualizes them, and Alertmanager sends alerts to Slack.

No manual kubectl apply is used for the application. Git is the single source of truth.

Step-by-step build
Step 0: Prerequisites
AWS account and an IAM user with programmatic access
Tools on my laptop: Terraform, AWS CLI, Git
Docker Hub account and a GitHub account
Forked the application repo and the Jenkins shared-library repo
Configured the AWS CLI
Generated an SSH key pair for the EC2 instances (never committed to Git)

Step 1: Provision the infrastructure with Terraform
