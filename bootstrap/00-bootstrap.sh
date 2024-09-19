#!/bin/bash
#

set -e

clear

gum style \
	--foreground 212 --border-foreground 212 --border double \
	--align center --margin "1 2" --padding "2 4" \
	'Bootstrap'

gum confirm '
Are you ready to start?
Select "Yes" only if you intend to deploy a local cluster with Headlamp and ArgoCD.
Feel free to say "No" and inspect the script if you prefer setting up resources manually.
' || exit 0

echo "
## You will need following tools installed:
|Name            |Required             |More info                                          |
|----------------|---------------------|---------------------------------------------------|
|kind            |Yes                  |'https://kind.sigs.k8s.io/docs/user/quick-start/#installation'|
|kubectl         |Yes                  |'https://kubernetes.io/docs/tasks/tools/#kubectl'  |
|crossplane cli  |Yes                  |'https://docs.crossplane.io/latest/cli'            |
|yq              |Yes                  |'https://github.com/mikefarah/yq#install'          |
|aws cli         |No                   |'https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html'|
|az cli          |No                   |'https://learn.microsoft.com/cli/azure/install-azure-cli'|

If you are running this script from **devbox**, most of the requirements are already set with the exception of **hyperscaler account**.
" | gum format

gum confirm "
Do you have those tools installed?
" || exit 0

echo "## Which Hyperscaler do you want to use?" | gum format

HYPERSCALER=$(gum choose "local" "aws" "azure")

clear

rm -f .env

echo "export HYPERSCALER=$HYPERSCALER" >> .env

##############
##  Cluster ##
##############

KIND_EXPERIMENTAL_PROVIDER=nerdctl kind create cluster --config kind.yaml || true
# dumb workaround since patching init doesn't work
kubectl label node kind-worker node-role.kubernetes.io/worker=worker

##############################
## NGINX Ingress Controller ##
##############################

helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --values bootstrap/nginx-ingress-controller/helm-values.yaml

################
## Prometheus ##
################

# helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
# helm repo update

helm upgrade --install prometheus prometheus \
    --repo https://prometheus-community.github.io/helm-charts \
    --namespace prometheus \
    --create-namespace \
    --wait

##############
## Grafana ##
##############

# helm repo add graphana https://graphana.github.io/helm-charts
# helm repo update

helm upgrade --install grafana grafana \
    --repo https://grafana.github.io/helm-charts \
    --namespace grafana \
    --create-namespace \
    --wait

################
## Crossplane ##
################

# helm repo add crossplane-stable https://charts.crossplane.io/stable
# helm repo update

helm upgrade --install crossplane crossplane \
    --repo https://charts.crossplane.io/stable \
    --namespace crossplane-system \
    --create-namespace \
    --wait

kubectl apply --filename providers/provider-kubernetes-incluster.yaml

kubectl apply --filename providers/provider-helm-incluster.yaml

kubectl apply --filename providers/dot-kubernetes.yaml

kubectl apply --filename providers/dot-sql.yaml

kubectl apply --filename providers/dot-app.yaml

gum spin --spinner dot \
    --title "Waiting for Crossplane providers..." -- sleep 60

kubectl wait --for=condition=healthy provider.pkg.crossplane.io \
    --all --timeout=1800s

kubectl apply --filename providers/$HYPERSCALER-config.yaml

if [[ "$HYPERSCALER" == "local" ]]; then

    echo "## All operations will occur within this cluster" \
        | gum format

elif [[ "$HYPERSCALER" == "aws" ]]; then

    AWS_ACCESS_KEY_ID=$(gum input --placeholder "AWS Access Key ID" --value "$AWS_ACCESS_KEY_ID")
    echo "export AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID" >> .env
    
    AWS_SECRET_ACCESS_KEY=$(gum input --placeholder "AWS Secret Access Key" --value "$AWS_SECRET_ACCESS_KEY" --password)
    echo "export AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY" >> .env

    AWS_ACCOUNT_ID=$(gum input --placeholder "AWS Account ID" --value "$AWS_ACCOUNT_ID")
    echo "export AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID" >> .env

    echo "[default]
aws_access_key_id = $AWS_ACCESS_KEY_ID
aws_secret_access_key = $AWS_SECRET_ACCESS_KEY
" >aws-creds.conf

    kubectl --namespace crossplane-system \
        create secret generic aws-creds \
        --from-file creds=./aws-creds.conf

    kubectl apply --filename providers/aws-config.yaml

else

    AZURE_TENANT_ID=$(gum input --placeholder "Azure Tenant ID" --value "$AZURE_TENANT_ID")

    az login --tenant $AZURE_TENANT_ID

    export SUBSCRIPTION_ID=$(az account show --query id -o tsv)

    az ad sp create-for-rbac --sdk-auth --role Owner --scopes /subscriptions/$SUBSCRIPTION_ID | tee azure-creds.json

    kubectl --namespace crossplane-system create secret generic azure-creds --from-file creds=./azure-creds.json

    kubectl apply --filename providers/azure-config.yaml

    DB_NAME=silly-demo-db-$(date +%Y%m%d%H%M%S)

    echo "---
apiVersion: devopstoolkitseries.com/v1alpha1
kind: ClusterClaim
metadata:
  name: cluster-01
spec:
  id: cluster01
  compositionSelector:
    matchLabels:
      provider: azure
      cluster: aks
  parameters:
    nodeSize: small
    minNodeCount: 3
---
apiVersion: v1
kind: Secret
metadata:
  name: $DB_NAME-password
data:
  password: SVdpbGxOZXZlclRlbGxAMQ==
---
apiVersion: devopstoolkitseries.com/v1alpha1
kind: SQLClaim
metadata:
  name: silly-demo-db
spec:
  id: $DB_NAME
  compositionSelector:
    matchLabels:
      provider: azure
      db: postgresql
  parameters:
    version: \"11\"
    size: small
---
apiVersion: devopstoolkitseries.com/v1alpha1
kind: AppClaim
metadata:
  name: silly-demo
spec:
  id: silly-demo
  compositionSelector:
    matchLabels:
      type: backend-db
      location: remote
  parameters:
    namespace: cto-development
    image: c8n.io/vfarcic/silly-demo:1.4.52
    port: 8080
    host: silly-demo.acme.com
    dbSecret:
      name: silly-demo-db
      namespace: cto-development
    kubernetesProviderConfigName: cluster01
---
apiVersion: devopstoolkitseries.com/v1alpha1
kind: AppClaim
metadata:
  name: silly-demo
spec:
  id: silly-demo
  compositionSelector:
    matchLabels:
      type: backend-db
      location: remote
  parameters:
    namespace: cto-integration
    image: c8n.io/vfarcic/silly-demo:1.4.52
    port: 8080
    host: silly-demo.acme.com
    dbSecret:
      name: silly-demo-db
      namespace: cto-integration
    kubernetesProviderConfigName: cluster01
---
apiVersion: devopstoolkitseries.com/v1alpha1
kind: AppClaim
metadata:
  name: silly-demo
spec:
  id: silly-demo
  compositionSelector:
    matchLabels:
      type: backend-db
      location: remote
  parameters:
    namespace: cto-prduction
    image: c8n.io/vfarcic/silly-demo:1.4.52
    port: 8080
    host: silly-demo.acme.com
    dbSecret:
      name: silly-demo-db
      namespace: cto-production
    kubernetesProviderConfigName: cluster01" \
    | tee examples/azure-intro.yaml

fi

kubectl create namespace cto-development || true
kubectl create namespace cto-integration || true
kubectl create namespace cto-production || true

##############
## Headlamp ##
##############

kubectl -n kube-system create serviceaccount headlamp-admin

helm upgrade --install headlamp headlamp \
   --repo https://headlamp-k8s.github.io/headlamp \
   --namespace kube-system \
   --values bootstrap/headlamp/helm-values.yaml \
   --wait

kubectl apply --filename bootstrap/headlamp/metrics-server-components.yaml
kubectl create token headlamp --namespace kube-system

###########
# ArgoCD #
###########

REPO_URL=$(git config --get remote.origin.url)
# workaround to avoid setting up SSH key in ArgoCD
REPO_URL=$(echo $REPO_URL | sed 's/git@github.com:/https:\/\/github.com\//') # replace git@github.com: to https://github.com/

yq --inplace ".spec.source.repoURL = \"$REPO_URL\"" bootstrap/argocd/projects.yaml

helm upgrade --install argocd argo-cd \
    --repo https://argoproj.github.io/argo-helm \
    --namespace argocd --create-namespace \
    --values bootstrap/argocd/helm-values.yaml \
    --wait

kubectl apply --filename bootstrap/argocd/projects.yaml

