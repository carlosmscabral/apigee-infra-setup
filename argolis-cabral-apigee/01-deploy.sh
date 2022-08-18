#!/bin/bash

# Assumes the project exists, and has a VPC created, with a single subnet.
# Also assumes that the tool apigeecli (https://github.com/apigee/apigeecli) installed
# and available in your path.
# Finally, remember to lift all necessary Org Policies restrictions if in Argolis before proceeding.
# Feel free to update the variables at the beggining of the script with your own project/region and...
# fire it up!

AUTH="Authorization: Bearer $(gcloud auth print-access-token)"
PROJECT_ID="cabral-apigee"
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")
RUNTIME_LOCATION="southamerica-east1"
REGION="southamerica-east1"
ANALYTICS_REGION="us-east1"
NETWORK_NAME="apigee-vpc"
SUBNET_NAME="southamerica-east1-subnet"
RANGE_NAME=apigee-range
APIGEE_RANGE="10.0.0.0" #/22
RANGE_NAME_BASTION=apigee-support
BASTION_RANGE="10.1.0.0" #/28
NEG_NAME="apigee-psc-neg"
ADDRESS_NAME="apigee-external-lb-ip"
BACKEND_SERVICE_NAME="apigee-backend-service-psc-neg"
URL_MAP_NAME="apigee-l7xlb-psc"
TARGET_PROXY_NAME="apigee-target-proxy-lb"
CERTIFICATE="apigee-lb-cert"
FWD_RULE="apigee-forwarding-rule"
SAMPLE_PROXY_PATH="../../apigee-vscode-workspace/src/main/apigee/apiproxies/hello-world/apiproxy"


gcloud auth login

#### Enable APIs
gcloud services enable apigee.googleapis.com \
  servicenetworking.googleapis.com compute.googleapis.com \
  cloudkms.googleapis.com --project=$PROJECT_ID

#### Create Apigee Service Identity P4SA
gcloud beta services identity create --service=apigee.googleapis.com \
  --project=$PROJECT_ID

### Setup Ranges / Peering
gcloud compute addresses create $RANGE_NAME \
  --global \
  --prefix-length=22 \
  --description="Peering range for Apigee services" \
  --network=$NETWORK_NAME \
  --purpose=VPC_PEERING \
  --project=$PROJECT_ID \
  --addresses=$APIGEE_RANGE

gcloud compute addresses create $RANGE_NAME_BASTION \
  --global \
  --prefix-length=28 \
  --description="Peering range for supporting Apigee services" \
  --network=$NETWORK_NAME \
  --purpose=VPC_PEERING \
  --project=$PROJECT_ID \
  --addresses=$BASTION_RANGE

gcloud services vpc-peerings connect \
  --service=servicenetworking.googleapis.com \
  --network=$NETWORK_NAME \
  --ranges=$RANGE_NAME,$RANGE_NAME_BASTION \
  --project=$PROJECT_ID

#### I STILL HAVEN'T FOUND A CLI FOR EXCHANGING CUSTOM ROUTES

#### Setup gcloud alpha
gcloud components install alpha --quiet

#### Setup org trial - today, gcloud alpha supports only trial/eval
gcloud alpha apigee organizations provision \
  --runtime-location="$RUNTIME_LOCATION" \
  --analytics-region="$ANALYTICS_REGION" \
  --authorized-network="$NETWORK_NAME" \
  --project="$PROJECT_ID"

### Deletion of default eval environments created in trial and creation of prod and dev
apigeecli apis undeploy -o $PROJECT_ID -e eval -n hello-world --rev 1 -t=$(gcloud auth print-access-token)
apigeecli instances attachments detach  -o $PROJECT_ID -e eval -n eval-instance -t=$(gcloud auth print-access-token)
sleep 20
apigeecli environments -t=$(gcloud auth print-access-token) -o cabral-apigee delete -e eval -t=$(gcloud auth print-access-token)
sleep 20
apigeecli environments -t=$(gcloud auth print-access-token) -o cabral-apigee create -e dev -t=$(gcloud auth print-access-token)
apigeecli environments -t=$(gcloud auth print-access-token) -o cabral-apigee create -e prod -t=$(gcloud auth print-access-token)
apigeecli instances attachments attach  -o $PROJECT_ID -e dev -n eval-instance -t=$(gcloud auth print-access-token)
sleep 120
apigeecli instances attachments attach  -o $PROJECT_ID -e prod -n eval-instance -t=$(gcloud auth print-access-token)
sleep 120

### Setup L7-XLB + PSC NEG
curl -i -X GET -H "$AUTH" \
  "https://apigee.googleapis.com/v1/organizations/$PROJECT_ID/instances"

echo "Copy the service attachement complete name"
read -r SA

gcloud compute network-endpoint-groups create $NEG_NAME \
  --network-endpoint-type=private-service-connect \
  --psc-target-service=$SA \
  --region=$REGION \
  --network=$NETWORK_NAME \
  --subnet=$SUBNET_NAME \
  --project=$PROJECT_ID

gcloud compute addresses create $ADDRESS_NAME \
  --ip-version=IPV4 --global --project=$PROJECT_ID

gcloud compute backend-services create $BACKEND_SERVICE_NAME \
  --load-balancing-scheme=EXTERNAL_MANAGED \
  --protocol=HTTPS \
  --global --project=$PROJECT_ID

gcloud compute backend-services add-backend $BACKEND_SERVICE_NAME \
  --network-endpoint-group=$NEG_NAME \
  --network-endpoint-group-region=$REGION \
  --global --project=$PROJECT_ID

gcloud compute url-maps create $URL_MAP_NAME \
  --default-service=$BACKEND_SERVICE_NAME \
  --global --project=$PROJECT_ID

# Creates nip.io cert
gcloud compute addresses list
echo "Copy IP Address the External LB will use"
read -r EXT_IP

gcloud compute ssl-certificates create $CERTIFICATE \
  --domains=dev.${EXT_IP}.nip.io,prod.${EXT_IP}.nip.io,${EXT_IP}.nip.io --project=$PROJECT_ID

gcloud compute target-https-proxies create $TARGET_PROXY_NAME \
  --url-map=$URL_MAP_NAME \
  --ssl-certificates=$CERTIFICATE --project=$PROJECT_ID

gcloud compute forwarding-rules create $FWD_RULE \
  --load-balancing-scheme=EXTERNAL_MANAGED \
  --network-tier=PREMIUM \
  --address=$ADDRESS_NAME \
  --target-https-proxy=$TARGET_PROXY_NAME \
  --ports=443 \
  --global --project=$PROJECT_ID

# Create new envgroups
apigeecli envgroups create  -o $PROJECT_ID -n prod-envgroup -t=$(gcloud auth print-access-token) --hosts prod.${EXT_IP}.nip.io
apigeecli envgroups create  -o $PROJECT_ID -n dev-envgroup -t=$(gcloud auth print-access-token) --hosts dev.${EXT_IP}.nip.io

apigeecli envgroups attach -e prod -n prod-envgroup  -o $PROJECT_ID -t=$(gcloud auth print-access-token)
apigeecli envgroups attach -e dev -n dev-envgroup  -o $PROJECT_ID -t=$(gcloud auth print-access-token)

# Deploy sample API proxy
apigeecli apis create bundle -n hello-world -p $SAMPLE_PROXY_PATH  -o $PROJECT_ID -t=$(gcloud auth print-access-token)
apigeecli apis deploy -e prod -n hello-world -v 1 -o $PROJECT_ID -t=$(gcloud auth print-access-token)
apigeecli apis deploy -e dev -n hello-world -v 1 -o $PROJECT_ID -t=$(gcloud auth print-access-token)

