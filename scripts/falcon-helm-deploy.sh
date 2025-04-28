#!/bin/bash

# CrowdStrike Falcon Helm Deployment Script
# This script handles the deployment of CrowdStrike Falcon components using Helm

set -e

# Color codes and formatting
BLUE='\033[0;34m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Helper functions for pretty printing
print_header() {
    echo -e "\n${BLUE}${BOLD}[*] $1${NC}"
}

print_success() {
    echo -e "${GREEN}[+] $1${NC}"
}

print_info() {
    echo -e "${CYAN}[>] $1${NC}"
}

print_error() {
    echo -e "${RED}[-] $1${NC}"
}

# Function to wait for pods to be ready
wait_for_pods() {
    namespace=$1
    timeout=120  # 2 minutes timeout
    counter=0
    print_info "Waiting for pods in namespace '$namespace' to be ready..."
    
    while true; do
        if [ $counter -gt $timeout ]; then
            print_error "Timeout waiting for pods in namespace '$namespace'"
            return 1
        fi
        
        # Check if all pods are ready
        if kubectl get pods -n "$namespace" 2>/dev/null | grep -v NAME | awk '{print $2}' | grep -v '^1/1\|^2/2\|^3/3' > /dev/null; then
            sleep 1
            counter=$((counter + 1))
        else
            # All pods are ready
            pods=$(kubectl get pods -n "$namespace" -o wide --no-headers)
            if [ -n "$pods" ]; then
                print_success "All pods in namespace '$namespace' are ready!"
                echo "$pods" | awk '{printf "   %-40s %-20s\n", $1, $3}'
                return 0
            fi
        fi
    done
}

usage() {
    echo "Usage: $0
Required Flags:
    --client-id <FALCON_CLIENT_ID>         Falcon API Client ID
    --client-secret <FALCON_CLIENT_SECRET> Falcon API Client Secret
    --cluster-name <CLUSTER_NAME>          Kubernetes cluster name (Required for KAC and IAR)

Optional Flags:
    --autopilot                            Enable GKE Autopilot mode
    --tags <TAGS>                          Comma-separated tags for components
    --skip-sensor                          Skip Falcon Sensor deployment
    --skip-kac                             Skip KAC deployment
    --skip-iar                             Skip IAR deployment
    --uninstall                            Uninstall all Falcon components
    
Advanced Options:
    --custom-registry <REGISTRY_URL>       Custom registry URL
    --sensor-tag <TAG>                     Custom Falcon Sensor image tag
    --kac-tag <TAG>                        Custom KAC image tag
    --iar-tag <TAG>                        Custom IAR image tag
    --help                                 Display this help message"
    exit 2
}


# Initialize variables
AUTOPILOT=false
SKIP_SENSOR=false
SKIP_KAC=false
SKIP_IAR=false
UNINSTALL=false
CUSTOM_REGISTRY=""
SENSOR_TAG=""
KAC_TAG=""
IAR_TAG=""
SKIP_CONTAINER=false
CONTAINER_TAG=""

copy_images() {
    local registry="$1"
    local sensor_tag="$2"
    local kac_tag="$3"
    local iar_tag="$4"
    local container_tag="$5"

    print_info "Starting image copy process..."
    
    # Get region from sensor image path first
    print_info "Detecting Falcon cloud region..."
    local temp_image_info=$(curl -s https://raw.githubusercontent.com/CrowdStrike/falcon-scripts/main/bash/containers/falcon-container-sensor-pull/falcon-container-sensor-pull.sh | \
        bash -s -- -t falcon-sensor --client-id "$FALCON_CLIENT_ID" --client-secret "$FALCON_CLIENT_SECRET" --get-image-path 2>/dev/null)
    
    FALCON_REGION=$(get_region_from_image "$temp_image_info")
    if [ -z "$FALCON_REGION" ]; then
        print_error "Could not determine Falcon cloud region from image URL"
        return 1
    fi
    print_info "Detected Falcon cloud region: $FALCON_REGION"
    
    # Only copy images for components being deployed
    if [ "$SKIP_SENSOR" = false ]; then
        print_info "Copying sensor image to $registry:$sensor_tag"
        if ! curl -s https://raw.githubusercontent.com/CrowdStrike/falcon-scripts/main/bash/containers/falcon-container-sensor-pull/falcon-container-sensor-pull.sh | \
            bash -s -- \
            -u "$FALCON_CLIENT_ID" \
            -s "$FALCON_CLIENT_SECRET" \
            -t "falcon-sensor" \
            -c "$registry" \
            --copy-omit-image-name \
            --copy-custom-tag "$sensor_tag"; then
            
            print_error "Failed to copy sensor image"
            return 1
        fi
        print_success "sensor image copied successfully"
    fi

    if [ "$SKIP_CONTAINER" = false ]; then
        print_info "Copying container sensor image to $registry:$container_tag"
        if ! curl -s https://raw.githubusercontent.com/CrowdStrike/falcon-scripts/main/bash/containers/falcon-container-sensor-pull/falcon-container-sensor-pull.sh | \
            bash -s -- \
            -u "$FALCON_CLIENT_ID" \
            -s "$FALCON_CLIENT_SECRET" \
            -t "falcon-container" \
            -c "$registry" \
            --copy-omit-image-name \
            --copy-custom-tag "$container_tag"; then
            
            print_error "Failed to copy container sensor image"
            return 1
        fi
        print_success "container sensor image copied successfully"
    fi

    if [ "$SKIP_KAC" = false ]; then
        print_info "Copying KAC image to $registry:$kac_tag"
        if ! curl -s https://raw.githubusercontent.com/CrowdStrike/falcon-scripts/main/bash/containers/falcon-container-sensor-pull/falcon-container-sensor-pull.sh | \
            bash -s -- \
            -u "$FALCON_CLIENT_ID" \
            -s "$FALCON_CLIENT_SECRET" \
            -t "falcon-kac" \
            -c "$registry" \
            --copy-omit-image-name \
            --copy-custom-tag "$kac_tag"; then
            
            print_error "Failed to copy KAC image"
            return 1
        fi
        print_success "KAC image copied successfully"
    fi

    if [ "$SKIP_IAR" = false ]; then
        print_info "Copying IAR image to $registry:$iar_tag"
        if ! curl -s https://raw.githubusercontent.com/CrowdStrike/falcon-scripts/main/bash/containers/falcon-container-sensor-pull/falcon-container-sensor-pull.sh | \
            bash -s -- \
            -u "$FALCON_CLIENT_ID" \
            -s "$FALCON_CLIENT_SECRET" \
            -t "falcon-imageanalyzer" \
            -c "$registry" \
            --copy-omit-image-name \
            --copy-custom-tag "$iar_tag"; then
            
            print_error "Failed to copy IAR image"
            return 1
        fi
        print_success "IAR image copied successfully"
    fi

    print_success "All images copied successfully to custom registry"
    return 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --client-id)
            FALCON_CLIENT_ID="$2"
            shift 2
            ;;
        --client-secret)
            FALCON_CLIENT_SECRET="$2"
            shift 2
            ;;
        --cluster-name)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        --autopilot)
            AUTOPILOT=true
            shift
            ;;
        --tags)
            SENSOR_TAGS=$(echo "$2" | sed 's/,/\\,/g')
            shift 2
            ;;
        --skip-sensor)
            SKIP_SENSOR=true
            shift
            ;;
        --skip-kac)
            SKIP_KAC=true
            shift
            ;;
        --skip-iar)
            SKIP_IAR=true
            shift
            ;;
        --custom-registry)
            CUSTOM_REGISTRY="$2"
            shift 2
            ;;
        --sensor-tag)
            SENSOR_TAG="$2"
            shift 2
            ;;
        --kac-tag)
            KAC_TAG="$2"
            shift 2
            ;;
        --iar-tag)
            IAR_TAG="$2"
            shift 2
            ;;
        --skip-container)
            SKIP_CONTAINER=true
            shift
            ;;
        --container-tag)
            CONTAINER_TAG="$2"
            shift 2
            ;;
        --uninstall)
            UNINSTALL=true
            shift
            ;;
        --help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Function to determine region from image URL
get_region_from_image() {
    local image_url="$1"
    
    case "$image_url" in
        *"registry.crowdstrike.com"*)
            if [[ $image_url == *"/us-1/"* ]]; then
                echo "us-1"
            elif [[ $image_url == *"/us-2/"* ]]; then
                echo "us-2"
            elif [[ $image_url == *"/eu-1/"* ]]; then
                echo "eu-1"
            fi
            ;;
        *"registry.laggar.gcw.crowdstrike.com"*)
            echo "gov-1"
            ;;
        *"registry.us-gov-2.crowdstrike.mil"*)
            echo "gov-2"
            ;;
        *)
            return 1
            ;;
    esac
}
deploy_container_sensor() {
    print_header "Deploying Falcon Container Sensor..."
    
    local repo
    local tag
    
    if [ -n "$CUSTOM_REGISTRY" ]; then
        repo="$CUSTOM_REGISTRY"
        tag="falcon-container"
    else
        IMAGE_INFO=$(curl -s https://raw.githubusercontent.com/CrowdStrike/falcon-scripts/main/bash/containers/falcon-container-sensor-pull/falcon-container-sensor-pull.sh | bash -s -- -t falcon-container --client-id "$FALCON_CLIENT_ID" --client-secret "$FALCON_CLIENT_SECRET" --get-image-path 2>/dev/null)
        repo=$(echo "$IMAGE_INFO" | cut -d':' -f1)
        tag=$(echo "$IMAGE_INFO" | cut -d':' -f2)
    fi
    
    print_info "Using repository: $repo"
    print_info "Using tag: $tag"

    local helm_args=(
        --set node.enabled=false
        --set container.enabled=true
        --set falcon.cid="$FALCON_CID"
        --set container.image.repository="$repo"
        --set container.image.tag="$tag"
        --set container.image.pullSecrets.enable=true
        --set container.image.pullSecrets.allNamespaces=true
        --set container.image.pullSecrets.namespaces=""
    )

    if [ -z "$CUSTOM_REGISTRY" ]; then
        helm_args+=(--set "container.image.pullSecrets.registryConfigJSON=$PULL_TOKEN")
    fi

    if [ -n "$SENSOR_TAGS" ]; then
        helm_args+=(--set "falcon.tags=$SENSOR_TAGS")
    fi

    if ! helm upgrade --install falcon-sensor crowdstrike/falcon-sensor \
        -n falcon-system --create-namespace \
        "${helm_args[@]}" >/dev/null 2>&1; then
        print_error "Failed to deploy Falcon Container Sensor"
        return 1
    fi

    print_success "Container Sensor deployment initiated"
    
    # Add wait and display logic for container sensor pods
    print_info "Waiting for Container Sensor pods..."
    if ! wait_for_pods "falcon-system"; then
        print_error "Timeout waiting for Container Sensor pods"
        return 1
    fi
}

# Function to get common values (only needed for standard deployment)
get_common_values() {
    print_info "Getting common credentials..."
    
    # Get image info first to determine region
    IMAGE_INFO=$(curl -s https://raw.githubusercontent.com/CrowdStrike/falcon-scripts/main/bash/containers/falcon-container-sensor-pull/falcon-container-sensor-pull.sh | bash -s -- -t falcon-sensor --client-id "$FALCON_CLIENT_ID" --client-secret "$FALCON_CLIENT_SECRET" --get-image-path 2>/dev/null)
    
    if [ -z "$IMAGE_INFO" ]; then
        print_error "Failed to get image information"
        return 1
    fi

    # Determine region from image URL (only for standard deployment)
    if [ -z "$CUSTOM_REGISTRY" ]; then
        FALCON_REGION=$(get_region_from_image "$IMAGE_INFO")
        if [ -z "$FALCON_REGION" ]; then
            print_error "Could not determine Falcon cloud region from image URL"
            return 1
        fi
        print_info "Detected Falcon cloud region: $FALCON_REGION"
    fi

    # Get CID (needed for both standard and custom deployments)
    FALCON_CID=$(curl -s https://raw.githubusercontent.com/CrowdStrike/falcon-scripts/main/bash/containers/falcon-container-sensor-pull/falcon-container-sensor-pull.sh | bash -s -- -t falcon-sensor --client-id "$FALCON_CLIENT_ID" --client-secret "$FALCON_CLIENT_SECRET" --get-cid 2>/dev/null)
    
    if [ -z "$FALCON_CID" ]; then
        print_error "Failed to get CID"
        return 1
    fi

    # Get pull token (only needed for standard deployment)
    if [ -z "$CUSTOM_REGISTRY" ]; then
        PULL_TOKEN=$(curl -s https://raw.githubusercontent.com/CrowdStrike/falcon-scripts/main/bash/containers/falcon-container-sensor-pull/falcon-container-sensor-pull.sh | bash -s -- -t falcon-sensor --client-id "$FALCON_CLIENT_ID" --client-secret "$FALCON_CLIENT_SECRET" --get-pull-token 2>/dev/null)
        if [ -z "$PULL_TOKEN" ]; then
            print_error "Failed to get pull token"
            return 1
        fi
    fi
}

deploy_sensor() {
    print_header "Deploying Falcon Sensor..."
    
    local repo
    local tag
    
    if [ -n "$CUSTOM_REGISTRY" ]; then
        repo="$CUSTOM_REGISTRY"
        tag="$SENSOR_TAG"
    else
        IMAGE_INFO=$(curl -s https://raw.githubusercontent.com/CrowdStrike/falcon-scripts/main/bash/containers/falcon-container-sensor-pull/falcon-container-sensor-pull.sh | bash -s -- -t falcon-sensor --client-id "$FALCON_CLIENT_ID" --client-secret "$FALCON_CLIENT_SECRET" --get-image-path 2>/dev/null)
        repo=$(echo "$IMAGE_INFO" | cut -d':' -f1)
        tag=$(echo "$IMAGE_INFO" | cut -d':' -f2)
    fi
    
    print_info "Using repository: $repo"
    print_info "Using tag: $tag"
    
    local helm_args=(
        --set falcon.cid="$FALCON_CID"
        --set node.image.repository="$repo"
        --set node.image.tag="$tag"
        --set node.gke.autopilot="$AUTOPILOT"
    )

    # Only add registry config for standard deployment
    if [ -z "$CUSTOM_REGISTRY" ]; then
        helm_args+=(--set "node.image.registryConfigJSON=$PULL_TOKEN")
    fi

    # Add tags if specified
    if [ -n "$SENSOR_TAGS" ]; then
        helm_args+=(--set "falcon.tags=$SENSOR_TAGS")
    fi

    if ! helm upgrade --install falcon-sensor crowdstrike/falcon-sensor \
        -n falcon-system --create-namespace \
        "${helm_args[@]}" >/dev/null 2>&1; then
        print_error "Failed to deploy Falcon Sensor"
        return 1
    fi
    
    print_success "Falcon Sensor deployment initiated"
    wait_for_pods "falcon-system"
}

deploy_kac() {
    print_header "Deploying Kubernetes Admission Controller..."
    
    local repo
    local tag
    
    if [ -n "$CUSTOM_REGISTRY" ]; then
        repo="$CUSTOM_REGISTRY"
        tag="falcon-kac"
    else
        IMAGE_INFO=$(curl -s https://raw.githubusercontent.com/CrowdStrike/falcon-scripts/main/bash/containers/falcon-container-sensor-pull/falcon-container-sensor-pull.sh | bash -s -- -t falcon-kac --client-id "$FALCON_CLIENT_ID" --client-secret "$FALCON_CLIENT_SECRET" --get-image-path 2>/dev/null)
        repo=$(echo "$IMAGE_INFO" | cut -d':' -f1)
        tag=$(echo "$IMAGE_INFO" | cut -d':' -f2)
    fi
    
    print_info "Using repository: $repo"
    print_info "Using tag: $tag"

    local helm_args=(
        --set falcon.cid="$FALCON_CID"
        --set image.repository="$repo"
        --set image.tag="$tag"
        --set clusterName="$CLUSTER_NAME"
    )

    # Add registry config JSON only for standard deployment
    if [ -z "$CUSTOM_REGISTRY" ]; then
        helm_args+=(--set "image.registryConfigJSON=$PULL_TOKEN")
    fi

    # Add tags if specified
    if [ -n "$SENSOR_TAGS" ]; then
        helm_args+=(--set "falcon.tags=$SENSOR_TAGS")
    fi

    if ! helm upgrade --install falcon-kac crowdstrike/falcon-kac \
        -n falcon-kac --create-namespace \
        "${helm_args[@]}" >/dev/null 2>&1; then
        print_error "Failed to deploy KAC"
        return 1
    fi
    
    print_success "KAC deployment initiated"
    wait_for_pods "falcon-kac"
}

deploy_iar() {
    print_header "Deploying Image Assessment at Runtime..."
    
    local repo
    local tag
    
    if [ -n "$CUSTOM_REGISTRY" ]; then
        repo="$CUSTOM_REGISTRY"
        tag="$IAR_TAG"
    else
        IMAGE_INFO=$(curl -s https://raw.githubusercontent.com/CrowdStrike/falcon-scripts/main/bash/containers/falcon-container-sensor-pull/falcon-container-sensor-pull.sh | bash -s -- -t falcon-imageanalyzer --client-id "$FALCON_CLIENT_ID" --client-secret "$FALCON_CLIENT_SECRET" --get-image-path 2>/dev/null)
        repo=$(echo "$IMAGE_INFO" | cut -d':' -f1)
        tag=$(echo "$IMAGE_INFO" | cut -d':' -f2)
    fi
    
    print_info "Using repository: $repo"
    print_info "Using tag: $tag"

    local helm_args=(
        --set deployment.enabled=true
        --set crowdstrikeConfig.cid="$FALCON_CID"
        --set crowdstrikeConfig.clientID="$FALCON_CLIENT_ID"
        --set crowdstrikeConfig.clientSecret="$FALCON_CLIENT_SECRET"
        --set crowdstrikeConfig.clusterName="$CLUSTER_NAME"
        --set crowdstrikeConfig.agentRegion="$FALCON_REGION"
        --set image.repository="$repo"
        --set image.tag="$tag"
    )

    # Only add registry config for standard deployment
    if [ -z "$CUSTOM_REGISTRY" ]; then
        helm_args+=(--set "image.registryConfigJSON=$PULL_TOKEN")
    fi

    if ! helm upgrade --install imageanalyzer crowdstrike/falcon-image-analyzer \
        -n falcon-image-analyzer --create-namespace \
        "${helm_args[@]}" >/dev/null 2>&1; then
        print_error "Failed to deploy IAR"
        return 1
    fi
    
    print_success "IAR deployment initiated"
    wait_for_pods "falcon-image-analyzer"
}

# Function to uninstall components
uninstall_components() {
    print_header "We're sad to see you go! Uninstalling CrowdStrike Falcon components..."
    print_info "If you're having any issues, please don't hesitate to reach out to CrowdStrike Support"
    echo ""
    
    # Uninstall Helm releases if they exist
    if helm list -n falcon-system | grep -q "falcon-sensor"; then
        print_info "Uninstalling Falcon Sensor..."
        helm uninstall falcon-sensor -n falcon-system
    fi
    
    if helm list -n falcon-kac | grep -q "falcon-kac"; then
        print_info "Uninstalling Kubernetes Admission Controller..."
        helm uninstall falcon-kac -n falcon-kac
    fi
    
    if helm list -n falcon-image-analyzer | grep -q "imageanalyzer"; then
        print_info "Uninstalling Image Assessment at Runtime..."
        helm uninstall imageanalyzer -n falcon-image-analyzer
    fi
    
    # Clean up namespaces
    print_info "Cleaning up namespaces..."
    kubectl delete namespace falcon-system --ignore-not-found
    kubectl delete namespace falcon-kac --ignore-not-found
    kubectl delete namespace falcon-image-analyzer --ignore-not-found
    
    print_success "Uninstallation complete!"
    echo ""
    print_info "We hope to see you again soon! If you change your mind, just run the install command again."
}

# Main execution logic
if [ "$UNINSTALL" = true ]; then
    uninstall_components
    exit 0
fi

# Validate required parameters (unless uninstalling)
if [ "$UNINSTALL" = false ]; then
    # Always require client ID and secret
    if [ -z "$FALCON_CLIENT_ID" ] || [ -z "$FALCON_CLIENT_SECRET" ]; then
        print_error "Missing required parameters: client ID and/or client secret"
        usage
    fi

    # Only require cluster name if deploying KAC or IAR
    if { [ "$SKIP_KAC" = false ] || [ "$SKIP_IAR" = false ]; } && [ -z "$CLUSTER_NAME" ]; then
        print_error "Cluster name is required when deploying KAC or IAR"
        usage
    fi
fi

# Handle custom registry setup if specified
if [ -n "$CUSTOM_REGISTRY" ]; then
    print_header "Using custom registry configuration"
    copy_images "$CUSTOM_REGISTRY" \
                "falcon-sensor" \
                "falcon-kac" \
                "falcon-imageanalyzer" \
                "falcon-container" || exit 1
fi

# Get common values
get_common_values || exit 1

print_header "Starting CrowdStrike Falcon deployment"
print_info "Cluster: $CLUSTER_NAME"
if [ -z "$CUSTOM_REGISTRY" ]; then
    print_info "Region: $FALCON_REGION"
else
    print_info "Using custom registry: $CUSTOM_REGISTRY"
fi

# Add Helm repository
print_info "Adding Helm repository..."
if ! helm repo add crowdstrike https://crowdstrike.github.io/falcon-helm >/dev/null 2>&1; then
    print_error "Failed to add Helm repository"
    exit 1
fi

print_info "Updating Helm repositories..."
if ! helm repo update >/dev/null 2>&1; then
    print_error "Failed to update Helm repositories"
    exit 1
fi

# Create required namespaces
print_info "Creating required namespaces..."
kubectl create namespace falcon-system --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
kubectl create namespace falcon-kac --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1

# Deploy components based on flags
[ "$SKIP_SENSOR" = false ] && deploy_sensor
[ "$SKIP_KAC" = false ] && deploy_kac
[ "$SKIP_IAR" = false ] && deploy_iar
[ "$SKIP_CONTAINER" = false ] && deploy_container_sensor  # Only deploy if not skipped

print_header "Deployment Complete!"
print_info "Monitor your deployment with:"
echo "  kubectl get pods -n falcon-system"
echo "  kubectl get pods -n falcon-kac"
echo "  kubectl get pods -n falcon-image-analyzer"
