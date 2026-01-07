#!/bin/bash
set -e

REGION="us-east-1"
CLUSTER_NAME="real-estate-cluster"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

cd "$SCRIPT_DIR"

echo "=== PHASE 1: Infrastructure Provisioning (Terraform) ==="
cd Master/infrastructure

# Initialize and Apply Terraform
echo "Initializing Terraform..."
terraform init -upgrade

# Import existing ECR repositories to avoid "AlreadyExists" errors
echo "Importing existing ECR repositories..."
SERVICES=("user-service" "property-service" "booking-service" "payment-service" "notification-service" "reclamation-service" "blockchain-service" "pricing-api" "api-gateway" "frontend")
for service in "${SERVICES[@]}"; do
  echo "Attempting import for $service..."
  terraform import "aws_ecr_repository.services[\"$service\"]" $service 2>/dev/null || echo "Import skipped (already managed or doesn't exist), continuing..."
done

echo "Applying Terraform (this may take 15-20 minutes)..."
terraform apply -auto-approve
cd "$SCRIPT_DIR"

echo "=== PHASE 2: Kubernetes Configuration ==="
# Update kubeconfig
echo "Updating kubeconfig for EKS..."
aws eks update-kubeconfig --region $REGION --name $CLUSTER_NAME

echo "=== PHASE 3: Build and Push Images ==="
./push-images.sh $REGION

echo "=== PHASE 4: Deploy to Kubernetes ==="
K8S_DIR="Master/k8s-aws"

# Apply Namespace & Config
echo "Creating namespace and config..."
kubectl apply -f $K8S_DIR/00-namespace.yaml
kubectl apply -f $K8S_DIR/01-secrets.yaml
kubectl apply -f $K8S_DIR/02-configmaps.yaml

# Apply Databases
echo "Deploying databases..."
kubectl apply -f $K8S_DIR/03-postgres.yaml
kubectl apply -f $K8S_DIR/04-rabbitmq.yaml

echo "Waiting for databases to be ready..."
kubectl wait --namespace derent --for=condition=ready pod -l app=postgres --timeout=180s || true
kubectl wait --namespace derent --for=condition=ready pod -l app=rabbitmq --timeout=180s || true

# Apply Backend Services
echo "Deploying backend services..."
kubectl apply -f $K8S_DIR/10-user-service.yaml
kubectl apply -f $K8S_DIR/11-property-service.yaml
kubectl apply -f $K8S_DIR/12-booking-service.yaml
kubectl apply -f $K8S_DIR/13-payment-service.yaml
kubectl apply -f $K8S_DIR/14-notification-service.yaml
kubectl apply -f $K8S_DIR/15-reclamation-service.yaml
kubectl apply -f $K8S_DIR/16-blockchain-service.yaml
kubectl apply -f $K8S_DIR/17-ai-service.yaml

# Apply Gateway
echo "Deploying API Gateway..."
kubectl apply -f $K8S_DIR/20-api-gateway.yaml

echo "Waiting for Gateway LoadBalancer..."
sleep 30
GATEWAY_URL=""
for i in {1..30}; do
  GATEWAY_URL=$(kubectl get svc api-gateway -n derent -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [ -n "$GATEWAY_URL" ]; then
    echo "Gateway URL obtained: $GATEWAY_URL"
    break
  fi
  echo "Waiting for Gateway LoadBalancer... ($i/30)"
  sleep 10
done

if [ -z "$GATEWAY_URL" ]; then
  echo "WARNING: Could not obtain Gateway URL. Using placeholder."
  GATEWAY_URL="GATEWAY_URL_NOT_AVAILABLE"
fi

echo "=== PHASE 5: Update and Deploy Frontend ==="
# Update the frontend manifest with the actual gateway URL
echo "Updating frontend manifest with Gateway URL: $GATEWAY_URL"
FRONTEND_YAML="$K8S_DIR/30-frontend.yaml"

# Replace the old ELB URL with the new one
OLD_ELB="a6c7e906ec49c4fe3ab7ddce24ec807a-2079119961.us-east-1.elb.amazonaws.com"
sed -i "s|$OLD_ELB|$GATEWAY_URL|g" "$FRONTEND_YAML"

# Also need to rebuild and push frontend with new gateway URL
echo "Rebuilding frontend with new Gateway URL..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URL="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

cd derent-main
docker build --platform linux/amd64 \
  --build-arg NEXT_PUBLIC_GATEWAY_URL="http://${GATEWAY_URL}:8090" \
  --build-arg NEXT_PUBLIC_USE_GATEWAY=true \
  -t frontend .
docker tag frontend:latest $ECR_URL/frontend:latest
docker push $ECR_URL/frontend:latest
cd "$SCRIPT_DIR"

# Deploy frontend
echo "Deploying Frontend..."
kubectl apply -f "$FRONTEND_YAML"

# Restart frontend to pull new image
kubectl rollout restart deployment/frontend -n derent

echo "=== PHASE 6: Get Service URLs ==="
sleep 30

echo ""
echo "==================================================="
echo "Deployment Complete!"
echo "==================================================="
echo ""
echo "Gateway URL: http://$GATEWAY_URL:8090"
echo ""

FRONTEND_URL=$(kubectl get svc frontend -n derent -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending...")
echo "Frontend URL: http://$FRONTEND_URL:3000"
echo ""
echo "Check all pods:"
kubectl get pods -n derent
echo ""
echo "Check all services:"
kubectl get svc -n derent
