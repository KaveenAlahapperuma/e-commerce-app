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
Terraform files live in terraform/ (provider.tf, terraform.tf, vpc.tf, eks.tf, ec2.tf, bastion_ec2.tf, variables.tf, outputs.tf).
State is stored in an S3 bucket (with lockfile) configured in terraform.tf.

cd terraform
terraform init
terraform plan
terraform apply

This created about 65 resources:

VPC with 2 public and 2 private subnets across 2 AZs, Internet Gateway, NAT Gateway with an Elastic IP, and route tables
EKS cluster tws-eks-cluster with a KMS key, an OIDC provider (needed for IAM roles for service accounts), add-ons (CoreDNS, kube-proxy, VPC CNI), and a managed node group of t3.large nodes
Jenkins EC2 with an Elastic IP, bootstrapped by install_tools.sh
Bastion EC2, bootstrapped by bastion_user_data.sh
Security groups and an SSH key pair

Outputs: cluster name, VPC ID, public IPs.

Step 2: Set up Jenkins (CI) on the Jenkins EC2

Open http://<jenkins-ip>:8080 and unlock with:
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
Install plugins: Docker Pipeline and Pipeline View.
Add global credentials (Manage Jenkins → Credentials):
github-credentials (GitHub username - kaveenAlahapperuma and token - jenkins-ecommerce)
docker-hub-credentials (Docker Hub username - kaveend4 and token - jenkins-ecommerce-docker)
Configure the shared library (Manage Jenkins → System → Global Pipeline Libraries): name Shared, default version main, repository = https://github.com/KaveenAlahapperuma/jenkins-shared-libraries.git
In my forks, replaced the Docker Hub username in the Jenkinsfile and in vars/update_k8s_manifest.groovy.
Created the pipeline job EasyShop:
Type: Pipeline, with the GitHub project URL - https://github.com/KaveenAlahapperuma/e-commerce-app.git
Trigger: GitHub hook trigger for GITScm polling
Definition: Pipeline script from SCM (Git, my app fork, github-credentials, branch master, script path Jenkinsfile)
Added a GitHub webhook: http://<jenkins-ip>:8080/github-webhook/.
Ran Build Now.

The Jenkinsfile loads the shared library with @Library('Shared') _ and runs these stages. The image tag is the Jenkins BUILD_NUMBER.

#	Stage	What it does
1	Cleanup Workspace	Clears the Jenkins workspace (clean_ws)
2	Clone Repository	Clones my fork of the app repo, branch master (clone)
3	Build Docker Images (parallel)	Builds the main app image (Dockerfile) and the database migration image (scripts/Dockerfile.migration) with docker_build
4	Run Unit Tests	Runs the application tests (run_tests)
5	Security Scan with Trivy	Scans the images for vulnerabilities (trivy_scan)
6	Push Docker Images (parallel)	Pushes both images to Docker Hub using docker-hub-credentials (docker_push)
7	Update Kubernetes Manifests	Writes the new image tag into the manifests under kubernetes/, then commits and pushes to Git using github-credentials (update_k8s_manifests)

Result: two new images in Docker Hub and a Git commit with the new image tag. Jenkins never touches the cluster; ArgoCD picks up the commit.

Step 3: Configure the Bastion host (CD host)
SSH into the Bastion (the instance used to manage EKS, separate from the Jenkins server):

ssh -i terra-key ubuntu@<bastion-ip>
aws configure
aws eks update-kubeconfig --region us-west-2 --name tws-eks-cluster
kubectl get nodes

Installed the tools used in the next steps: kubectl, helm, eksctl.

Step 4: Install the AWS Load Balancer Controller
It converts Kubernetes Ingress resources into AWS Application Load Balancers.
# IAM policy for the controller
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.14.1/docs/install/iam_policy.json
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json

# Confirm the cluster's OIDC provider exists
aws eks describe-cluster --name tws-eks-cluster --region us-west-2 \
  --query 'cluster.identity.oidc.issuer' --output text
aws iam list-open-id-connect-providers

# Service account with an IAM role (IRSA)
eksctl create iamserviceaccount \
  --cluster=tws-eks-cluster \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=arn:aws:iam::<ACCOUNT_ID>:policy/AWSLoadBalancerControllerIAMPolicy \
  --override-existing-serviceaccounts \
  --region us-west-2 \
  --approve

# Install with Helm, using the cluster's actual VPC ID
VPC_ID=$(aws eks describe-cluster --name tws-eks-cluster --region us-west-2 \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)

helm repo add eks https://aws.github.io/eks-charts
helm repo update eks

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=tws-eks-cluster \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=us-west-2 \
  --set vpcId=$VPC_ID \
  --version 1.14.0

kubectl get deployment -n kube-system aws-load-balancer-controller

Step 5: Install the EBS CSI driver
# IAM role for the driver (role only; the service account comes from the Helm chart)
eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster tws-eks-cluster \
  --region us-west-2 \
  --role-name AmazonEKS_EBS_CSI_DriverRole \
  --role-only \
  --attach-policy-arn <AWS-managed EBS CSI driver policy ARN> \
  --approve

helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm repo update aws-ebs-csi-driver
helm install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver -n kube-system

# Attach the role to the driver's service account
kubectl annotate sa ebs-csi-controller-sa -n kube-system \
  eks.amazonaws.com/role-arn=arn:aws:iam::<ACCOUNT_ID>:role/AmazonEKS_EBS_CSI_DriverRole --overwrite
kubectl rollout restart deployment ebs-csi-controller -n kube-system

kubectl get pods -n kube-system | grep ebs     # controller pods should be 5/5 Running

Step 6: Install ArgoCD with Helm
Created argocd-values.yaml containing only my changes:
global:
  domain: ""

configs:
  params:
    server.insecure: true

server:
  ingress:
    enabled: true
    controller: aws
    ingressClassName: alb
    hostname: ""
    annotations:
      alb.ingress.kubernetes.io/scheme: internet-facing
      alb.ingress.kubernetes.io/group.name: easyshop-app-lb
      alb.ingress.kubernetes.io/target-type: ip
      alb.ingress.kubernetes.io/backend-protocol: HTTP
      alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80}]'
    aws:
      serviceType: ClusterIP
      backendProtocolVersion: HTTP1


helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo

helm install my-argo-cd argo/argo-cd \
  -n argocd --create-namespace \
  -f argocd-values.yaml \
  --version 8.0.10

kubectl get pods -n argocd
kubectl get ingress -n argocd          # ALB address appears in 1-3 minutes

Open http://<ALB-ADDRESS> and log in as admin:

kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath="{.data.password}" | base64 -d; echo

Changed the admin password under User Info, then deleted the initial secret:
kubectl delete secret argocd-initial-admin-secret -n argocd


Step 7: Install metrics-server
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm install my-metrics-server metrics-server/metrics-server
kubectl top pods

Step 8: Deploy the application through ArgoCD
Edited the manifests in my fork's kubernetes/ folder (see What I adapted), committed and pushed. Then in the ArgoCD UI, New App:
Field	Value
Project	default
Sync policy	Automatic
Repository URL	my fork
Revision	main
Path	kubernetes
Cluster URL	https://kubernetes.default.svc
Namespace	easyshop (auto-create)

ArgoCD applied the 12 manifests: namespace, MongoDB PV/PVC, StatefulSet and Service, ConfigMap, Secret, the app Deployment and Service, Ingress, HPA, and the database migration Job.
kubectl get pods,pvc,ingress -n easyshop

Expected: PVC Bound, MongoDB and 2 app pods Running, migration Job Completed, and an ALB address on the Ingress. After putting the ALB address into the ConfigMap URLs, restart the app:
kubectl rollout restart deployment easyshop -n easyshop

Opened the ALB address in the browser to use the shop.

Step 9: Monitoring and alerting

kubectl create namespace monitoring
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community

helm install my-kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring -f kube-prom-stack.yaml

kube-prom-stack.yaml (key parts) puts Grafana, Prometheus and Alertmanager behind one ALB using path-based routing:
grafana:
  grafana.ini:
    server:
      root_url: "%(protocol)s://%(domain)s/grafana/"
      serve_from_sub_path: true
  ingress:
    enabled: true
    ingressClassName: alb
    annotations:
      alb.ingress.kubernetes.io/group.name: easyshop-monitoring
      alb.ingress.kubernetes.io/scheme: internet-facing
      alb.ingress.kubernetes.io/target-type: ip
      alb.ingress.kubernetes.io/backend-protocol: HTTP
      alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80}]'
      alb.ingress.kubernetes.io/healthcheck-path: /grafana/api/health
    hosts: []
    path: /grafana
    pathType: Prefix

prometheus:
  ingress:
    enabled: true
    ingressClassName: alb
    annotations:
      alb.ingress.kubernetes.io/group.name: easyshop-monitoring
      alb.ingress.kubernetes.io/scheme: internet-facing
      alb.ingress.kubernetes.io/target-type: ip
      alb.ingress.kubernetes.io/backend-protocol: HTTP
      alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80}]'
      alb.ingress.kubernetes.io/healthcheck-path: /prometheus/-/healthy
    hosts: []
    paths:
      - /prometheus
    pathType: Prefix
  prometheusSpec:
    routePrefix: /prometheus
    externalUrl: http://<MONITORING-ALB-ADDRESS>/prometheus

alertmanager:
  ingress:
    enabled: true
    ingressClassName: alb
    annotations:
      alb.ingress.kubernetes.io/group.name: easyshop-monitoring
      alb.ingress.kubernetes.io/scheme: internet-facing
      alb.ingress.kubernetes.io/target-type: ip
      alb.ingress.kubernetes.io/backend-protocol: HTTP
      alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80}]'
      alb.ingress.kubernetes.io/healthcheck-path: /alertmanager/-/healthy
    hosts: []
    paths:
      - /alertmanager
    pathType: Prefix
  alertmanagerSpec:
    routePrefix: /alertmanager

# EKS does not expose these control-plane components
kubeEtcd:
  enabled: false
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
kubeProxy:
  enabled: false

Install once, read the ALB address (kubectl get ingress -n monitoring), put it into externalUrl, then upgrade (pin the chart version shown by helm list -n monitoring):
helm upgrade my-kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring -f kube-prom-stack.yaml --version <chart-version>
  
Access:

Grafana: http://<ALB>/grafana (user admin)
Prometheus: http://<ALB>/prometheus
Alertmanager: http://<ALB>/alertmanager

kubectl get secret my-kube-prometheus-stack-grafana -n monitoring \
  -o jsonpath="{.data.admin-password}" | base64 -d; echo

Slack alerts
Created a Slack workspace and an #alerts channel.
At api.slack.com/apps, created an app, enabled Incoming Webhooks, and added a webhook for #alerts. (The webhook URL is a secret and is never committed.)
Added the Alertmanager config to kube-prom-stack.yaml:
alertmanager:
  config:
    global:
      resolve_timeout: 5m
    route:
      group_by: ['alertname', 'namespace']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 12h
      receiver: 'slack-notification'
      routes:
        - receiver: 'null'
          matchers:
            - alertname =~ "Watchdog|InfoInhibitor"
        - receiver: 'slack-notification'
          matchers:
            - severity =~ "critical|warning"
    receivers:
      - name: 'null'
      - name: 'slack-notification'
        slack_configs:
          - api_url: '<SLACK_WEBHOOK_URL>'
            channel: '#alerts'
            send_resolved: true
            title: '[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }}'
            text: >-
              {{ range .Alerts }}
              *Severity:* {{ .Labels.severity }}
              *Namespace:* {{ .Labels.namespace }}
              *Summary:* {{ .Annotations.summary }}
              {{ end }}

Applied with helm upgrade, then tested with a manual alert:

kubectl port-forward svc/my-kube-prometheus-stack-alertmanager -n monitoring 9093:9093 &

curl -XPOST http://localhost:9093/alertmanager/api/v2/alerts \
  -H "Content-Type: application/json" \
  -d '[{"labels":{"alertname":"TestAlert","severity":"critical","namespace":"easyshop"},"annotations":{"summary":"Test alert from Alertmanager"}}]'

The alert arrived in the #alerts Slack channel. Grafana dashboards used: Node Exporter / Nodes, Kubernetes / Compute Resources (Workload, Namespace), and Prometheus / Overview.  
