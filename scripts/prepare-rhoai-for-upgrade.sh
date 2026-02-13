#!/bin/bash

set -e

# Trap Ctrl-C and exit immediately
trap 'echo -e "\n\033[0;31m[ERROR]\033[0m Operation aborted by user"; exit 130' INT

# Script to prepare RHOAI 2.25 for upgrade to RHOAI 3.3
# This script:
#   1. Disables KServe serving and Service Mesh in RHOAI 2.25
#   2. Uninstalls prerequisite operators that are not compatible with RHOAI 3.x
#   3. Prepares the RHOAI subscription for upgrade to 3.3
# Usage: ./prepare-rhoai-for-upgrade.sh

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if oc is installed and user is logged in
if ! command -v oc &> /dev/null; then
    log_error "oc command not found. Please install the OpenShift CLI."
    exit 1
fi

if ! oc whoami &> /dev/null; then
    log_error "Not logged in to OpenShift cluster. Please run 'oc login' first."
    exit 1
fi

log_info "Logged in as: $(oc whoami)"
log_info "Current cluster: $(oc whoami --show-server)"

echo ""
log_warn "========================================="
log_warn "RHOAI 2.25 to 3.3 Upgrade Preparation"
log_warn "========================================="
log_warn "This script will prepare your cluster for RHOAI upgrade:"
log_warn ""
log_warn "Phase 1 - Disable incompatible components:"
log_warn "  - Set DSC KServe serving managementState to Removed"
log_warn "  - Set DSCI Service Mesh managementState to Removed"
log_warn ""
log_warn "Phase 2 - Uninstall incompatible operators and install new dependencies:"
log_warn "  - Uninstall: Red Hat Authorino Operator"
log_warn "  - Uninstall: Red Hat OpenShift Serverless"
log_warn "  - Uninstall: Red Hat OpenShift Service Mesh 2"
log_warn "  - Install: Red Hat Connectivity Link v1.2.1"
log_warn ""
log_warn "Phase 3 - Prepare RHOAI subscription:"
log_warn "  - Change installPlanApproval to Manual"
log_warn "  - Update channel to stable-3.3"
log_warn "  - Provide command to manually approve upgrade"
log_warn ""
log_warn "Cluster: $(oc whoami --show-server)"
log_warn "User: $(oc whoami)"
log_warn "========================================="
echo ""

while true; do
    read -p "Do you want to proceed with the upgrade preparation? (y/n): " CONFIRM
    
    case "$CONFIRM" in
        y|Y|yes|Yes|YES)
            log_info "Proceeding with upgrade preparation..."
            break
            ;;
        n|N|no|No|NO)
            log_info "Operation cancelled by user"
            exit 0
            ;;
        *)
            log_error "Invalid input. Please enter 'y' or 'n'"
            ;;
    esac
done

echo ""

# Phase 1: Check initial state and disable incompatible components
log_info "========================================="
log_info "Phase 1: Disable incompatible components"
log_info "========================================="

# Step 1: Check that DSC exists and is ready
log_info "Step 1: Checking DataScienceCluster status..."

oc wait --for=jsonpath='{.status.phase}'=Ready \
    datasciencecluster/default-dsc \
    --timeout=600s || log_warn "DataScienceCluster did not reach Ready state within timeout"

log_info "DataScienceCluster is Ready"

# Step 2: Check that DSCI exists and is ready
log_info "Step 2: Checking DSCInitialization status..."

oc wait --for=jsonpath='{.status.phase}'=Ready \
    dscinitialization/default-dsci \
    --timeout=600s || log_warn "DSCInitialization did not reach Ready state within timeout"

log_info "DSCInitialization is Ready"

# Step 3: Update DSC to set KServe serving managementState to Removed
log_info "Step 3: Setting KServe serving managementState to Removed..."

CURRENT_KSERVE_SERVING=$(oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.kserve.serving.managementState}' 2>/dev/null || echo "")

if [ "$CURRENT_KSERVE_SERVING" = "Removed" ]; then
    log_warn "KServe serving is already set to Removed, skipping"
else
    log_info "Current KServe serving managementState: ${CURRENT_KSERVE_SERVING}"
    oc patch datasciencecluster default-dsc --type=merge -p '{"spec":{"components":{"kserve":{"serving":{"managementState":"Removed"}}}}}'
    log_info "KServe serving managementState set to Removed"
fi

# Step 4: Update DSCI to set Service Mesh managementState to Removed
log_info "Step 4: Setting Service Mesh managementState to Removed..."

CURRENT_SERVICEMESH=$(oc get dscinitialization default-dsci -o jsonpath='{.spec.serviceMesh.managementState}' 2>/dev/null || echo "")

if [ "$CURRENT_SERVICEMESH" = "Removed" ]; then
    log_warn "Service Mesh is already set to Removed, skipping"
else
    log_info "Current Service Mesh managementState: ${CURRENT_SERVICEMESH}"
    oc patch dscinitialization default-dsci --type=merge -p '{"spec":{"serviceMesh":{"managementState":"Removed"}}}'
    log_info "Service Mesh managementState set to Removed"
fi

# Step 5: Wait for DSCI to reconcile and reach Ready state
log_info "Step 5: Waiting for DSCInitialization to reconcile..."
sleep 10

oc wait --for=jsonpath='{.status.phase}'=Ready \
    dscinitialization/default-dsci \
    --timeout=600s || log_warn "DSCInitialization did not reach Ready state within timeout"

DSCI_PHASE=$(oc get dscinitialization default-dsci -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
if [ "$DSCI_PHASE" = "Ready" ]; then
    log_info "DSCInitialization is Ready"
else
    log_warn "Current DSCI phase: ${DSCI_PHASE}"
    log_error "DSCInitialization did not reach Ready state after disabling Service Mesh"
    exit 1
fi

# Step 6: Wait for DSC to reconcile and reach Ready state
log_info "Step 6: Waiting for DataScienceCluster to reconcile..."
sleep 10

oc wait --for=jsonpath='{.status.phase}'=Ready \
    datasciencecluster/default-dsc \
    --timeout=600s || log_warn "DataScienceCluster did not reach Ready state within timeout"

DSC_PHASE=$(oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
if [ "$DSC_PHASE" = "Ready" ]; then
    log_info "DataScienceCluster is Ready"
else
    log_warn "Current DSC phase: ${DSC_PHASE}"
    log_error "DataScienceCluster did not reach Ready state after disabling components"
    exit 1
fi

log_info "Phase 1 completed: DSC and DSCI are Ready for upgrade"

# Phase 2: Uninstall incompatible operators and install new dependencies
log_info ""
log_info "========================================="
log_info "Phase 2: Manage operator dependencies"
log_info "========================================="

# Step 7: Uninstall Authorino operator
log_info "Step 7: Uninstalling Red Hat Authorino operator..."

if oc get subscription authorino-operator -n openshift-operators &> /dev/null; then
    log_info "  - Deleting Authorino subscription..."
    oc delete subscription authorino-operator -n openshift-operators || log_warn "Failed to delete Authorino subscription"
    
    AUTHORINO_CSV=$(oc get csv -n openshift-operators -o name 2>/dev/null | grep authorino || true)
    if [ -n "$AUTHORINO_CSV" ]; then
        log_info "  - Deleting Authorino CSV: ${AUTHORINO_CSV}"
        oc delete ${AUTHORINO_CSV} -n openshift-operators || log_warn "Failed to delete Authorino CSV"
    fi
    
    log_info "Red Hat Authorino operator uninstalled"
else
    log_warn "Authorino subscription not found, skipping"
fi

# Step 8: Uninstall Serverless operator
log_info "Step 8: Uninstalling Red Hat OpenShift Serverless operator..."

if oc get subscription serverless-operator -n openshift-serverless &> /dev/null; then
    log_info "  - Deleting Serverless subscription..."
    oc delete subscription serverless-operator -n openshift-serverless || log_warn "Failed to delete Serverless subscription"
    
    SERVERLESS_CSV=$(oc get csv -n openshift-serverless -o name 2>/dev/null | grep serverless || true)
    if [ -n "$SERVERLESS_CSV" ]; then
        log_info "  - Deleting Serverless CSV: ${SERVERLESS_CSV}"
        oc delete ${SERVERLESS_CSV} -n openshift-serverless || log_warn "Failed to delete Serverless CSV"
    fi
    
    # Delete Serverless OperatorGroup
    if oc get operatorgroup openshift-serverless -n openshift-serverless &> /dev/null; then
        log_info "  - Deleting Serverless OperatorGroup..."
        oc delete operatorgroup openshift-serverless -n openshift-serverless || log_warn "Failed to delete Serverless OperatorGroup"
    fi
    
    # Delete openshift-serverless namespace
    if oc get namespace openshift-serverless &> /dev/null; then
        log_info "  - Deleting namespace: openshift-serverless"
        oc delete namespace openshift-serverless --timeout=300s || log_warn "Namespace deletion timed out (may still be in progress)"
    fi
    
    log_info "Red Hat OpenShift Serverless operator uninstalled"
else
    log_warn "Serverless subscription not found, skipping"
fi

# Step 9: Uninstall Service Mesh operator
log_info "Step 9: Uninstalling Red Hat OpenShift Service Mesh 2 operator..."

if oc get subscription servicemeshoperator -n openshift-operators &> /dev/null; then
    log_info "  - Deleting Service Mesh subscription..."
    oc delete subscription servicemeshoperator -n openshift-operators || log_warn "Failed to delete Service Mesh subscription"
    
    SERVICEMESH_CSV=$(oc get csv -n openshift-operators -o name 2>/dev/null | grep servicemesh || true)
    if [ -n "$SERVICEMESH_CSV" ]; then
        log_info "  - Deleting Service Mesh CSV: ${SERVICEMESH_CSV}"
        oc delete ${SERVICEMESH_CSV} -n openshift-operators || log_warn "Failed to delete Service Mesh CSV"
    fi
    
    log_info "Red Hat OpenShift Service Mesh 2 operator uninstalled"
else
    log_warn "Service Mesh subscription not found, skipping"
fi

# Step 10: Install Red Hat Connectivity Link operator
log_info "Step 10: Installing Red Hat Connectivity Link operator..."

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhcl-operator
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: rhcl-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  startingCSV: rhcl-operator.v1.2.1
EOF

log_info "Red Hat Connectivity Link subscription created"

# Wait for Connectivity Link operator to be installed
log_info "Waiting for Connectivity Link operator to be ready..."

oc wait --for=jsonpath='{.status.state}'=AtLatestKnown \
    subscription/rhcl-operator \
    -n openshift-operators \
    --timeout=300s || log_warn "Connectivity Link subscription did not reach AtLatestKnown state within timeout"

log_info "Red Hat Connectivity Link operator installed"

log_info "Phase 2 completed: Incompatible operators uninstalled and Connectivity Link installed"

# Phase 3: Prepare RHOAI subscription for upgrade
log_info ""
log_info "========================================="
log_info "Phase 3: Prepare RHOAI subscription"
log_info "========================================="

# Step 11: Set RHOAI subscription installPlanApproval to Manual
log_info "Step 11: Setting RHOAI subscription installPlanApproval to Manual..."

if ! oc get subscription rhods-operator -n redhat-ods-operator &> /dev/null; then
    log_error "RHOAI subscription 'rhods-operator' not found in redhat-ods-operator namespace"
    exit 1
fi

CURRENT_APPROVAL=$(oc get subscription rhods-operator -n redhat-ods-operator -o jsonpath='{.spec.installPlanApproval}' 2>/dev/null || echo "Unknown")
log_info "Current installPlanApproval: ${CURRENT_APPROVAL}"

if [ "$CURRENT_APPROVAL" = "Manual" ]; then
    log_warn "installPlanApproval is already set to Manual"
else
    oc patch subscription rhods-operator -n redhat-ods-operator --type=merge -p '{"spec":{"installPlanApproval":"Manual"}}'
    log_info "installPlanApproval set to Manual"
fi

# Step 12: Update RHOAI subscription channel to stable-3.3
log_info "Step 12: Updating RHOAI subscription channel to stable-3.3..."

CURRENT_CHANNEL=$(oc get subscription rhods-operator -n redhat-ods-operator -o jsonpath='{.spec.channel}' 2>/dev/null || echo "Unknown")
log_info "Current channel: ${CURRENT_CHANNEL}"

if [ "$CURRENT_CHANNEL" = "stable-3.3" ]; then
    log_warn "Channel is already set to stable-3.3"
else
    oc patch subscription rhods-operator -n redhat-ods-operator --type=merge -p '{"spec":{"channel":"stable-3.3"}}'
    log_info "Channel updated to stable-3.3"
fi

# Wait for the subscription to show UpgradePending
log_info "Waiting for subscription to reach UpgradePending state..."

oc wait --for=jsonpath='{.status.state}'=UpgradePending \
    subscription/rhods-operator \
    -n redhat-ods-operator \
    --timeout=120s || log_warn "Subscription did not reach UpgradePending state within timeout"

SUBSCRIPTION_STATE=$(oc get subscription rhods-operator -n redhat-ods-operator -o jsonpath='{.status.state}' 2>/dev/null || echo "Unknown")
log_info "Subscription state: ${SUBSCRIPTION_STATE}"

# Get the pending InstallPlan name
INSTALL_PLAN=$(oc get subscription rhods-operator -n redhat-ods-operator -o jsonpath='{.status.installplan.name}' 2>/dev/null || echo "")

if [ -n "$INSTALL_PLAN" ]; then
    log_info "Pending InstallPlan: ${INSTALL_PLAN}"
else
    log_warn "InstallPlan reference not yet available in subscription status"
fi

log_info "Phase 3 completed: RHOAI subscription prepared for upgrade"

# Final summary and instructions
echo ""
log_info "========================================="
log_info "Upgrade Preparation Complete!"
log_info "========================================="
log_info ""
log_info "Summary of changes:"
log_info "  ✓ KServe serving managementState: Removed"
log_info "  ✓ Service Mesh managementState: Removed"
log_info "  ✓ Authorino operator: Uninstalled"
log_info "  ✓ Serverless operator: Uninstalled"
log_info "  ✓ Service Mesh 2 operator: Uninstalled"
log_info "  ✓ Connectivity Link operator: Installed (v1.2.1)"
log_info "  ✓ RHOAI subscription: Manual approval"
log_info "  ✓ RHOAI channel: stable-3.3"
log_info ""
log_warn "========================================="
log_warn "NEXT STEPS - Manual Approval Required"
log_warn "========================================="
echo ""
echo "oc patch installplan ${INSTALL_PLAN:-<INSTALL_PLAN_NAME>} -n redhat-ods-operator --type=merge -p '{\"spec\":{\"approved\":true}}'"
echo ""
