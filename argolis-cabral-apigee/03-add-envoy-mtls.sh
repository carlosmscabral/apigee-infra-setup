#!/bin/sh

# New L7-XLB + mTLS done at the Envoy proxies 
# Heavily inspired by https://github.com/apigee/terraform-modules/tree/main/samples/x-l4xlb-mtls

# Assumes VPC, Apigee Instance previously created.

AUTH="Authorization: Bearer $(gcloud auth print-access-token)"
PROJECT_ID="cabral-apigee"
REGION="southamerica-east1"
NETWORK_NAME="apigee-vpc"
SUBNET_NAME="southamerica-east1-subnet"
TARGET_NETWORK_TAGS="mtls-proxies"
ENVOY_CONFIG_BUCKET_NAME="envoy-config-bucket-${PROJECT_ID}"
APIGEE_ENDPOINT="10.0.0.2"

gcloud auth login

gcloud config set project $PROJECT_ID

# Creating FW Rules
gcloud compute firewall-rules create allow-network-l4-ilb \
    --network=$NETWORK_NAME \
    --target-tags=$TARGET_NETWORK_TAGS \
    --allow=tcp:443 \
    --source-ranges=0.0.0.0/0

# Creating static IP addresses
gcloud compute addresses create network-lb-ipv4 \
    --region $REGION

LB_EXTERNAL_ADDRESS=$(gcloud compute addresses list --filter="name=(network-lb-ipv4)" --format="json" | jq '.[0].address' | tr -d '"')

### Creating Certs ###
openssl req -newkey rsa:2048 -nodes -keyform PEM -keyout server-ca.key -x509 -days 3650 -outform PEM -out server-ca.crt -subj "/CN=Test Server CA"
openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr -subj "/CN=mtls.${LB_EXTERNAL_ADDRESS}.nip.io"
openssl x509 -req -in server.csr -CA server-ca.crt -CAkey server-ca.key -set_serial 100 -days 365 -outform PEM -out server.crt

openssl req -newkey rsa:2048 -nodes -keyform PEM -keyout client-ca.key -x509 -days 3650 -outform PEM -out client-ca.crt -subj "/CN=Test Client CA"
openssl genrsa -out example-client.key 2048
openssl req -new -key example-client.key -out example-client.csr -subj "/CN=Test Client"
openssl x509 -req -in example-client.csr -CA client-ca.crt -CAkey client-ca.key -set_serial 101 -days 365 -outform PEM -out example-client.crt

### Uploading Envoy config & certs to a Bucket ### 
gsutil mb -p $PROJECT_ID -l $REGION gs://${ENVOY_CONFIG_BUCKET_NAME}

# Update envoy config file with the IP of the Apigee Instance - WORKS ON Mac
sed -i '' -e "s/ENDPOINT_IP/$APIGEE_ENDPOINT/" envoy-config-template.yaml

# Uploading config file, Client CA, Server Cert, Server Key
gsutil cp ./client-ca.crt gs://${ENVOY_CONFIG_BUCKET_NAME}/cacert.pem
gsutil cp ./server.crt gs://${ENVOY_CONFIG_BUCKET_NAME}/servercert.pem
gsutil cp ./server.key gs://${ENVOY_CONFIG_BUCKET_NAME}/serverkey.pem
gsutil cp ./envoy-config-template.yaml gs://${ENVOY_CONFIG_BUCKET_NAME}/envoy-config.yaml
gsutil cp ./startup_script_setup.sh gs://${ENVOY_CONFIG_BUCKET_NAME}

# Create Instance Group SA
gcloud iam service-accounts create mtls-proxy-service-account
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:mtls-proxy-service-account@${PROJECT_ID}.iam.gserviceaccount.com" \
--role="roles/storage.objectViewer"

# Create Instance group template
gcloud compute instance-templates create mtls-proxy-template \
--region=$REGION \
--network=$NETWORK_NAME \
--machine-type=e2-small \
--subnet=$SUBNET_NAME \
--tags=$TARGET_NETWORK_TAGS \
--image-family=debian-10 \
--image-project=debian-cloud \
--metadata=startup-script-url=gs://${ENVOY_CONFIG_BUCKET_NAME}/startup_script_setup.sh,BUCKET=${ENVOY_CONFIG_BUCKET_NAME} \
--scopes=cloud-platform \
--service-account=mtls-proxy-service-account@${PROJECT_ID}.iam.gserviceaccount.com

# Create Instance Group
gcloud compute instance-groups managed create ig-mtls-proxy --region=$REGION --size=2 --template=mtls-proxy-template

# Create HealthCheck
gcloud compute health-checks create tcp tcp-443-health-check \
    --region $REGION \
    --port 443

# Create Backend Service & Adding Backends
gcloud compute backend-services create mtls-proxies-backend-service \
    --protocol TCP \
    --health-checks tcp-443-health-check \
    --health-checks-region $REGION \
    --region $REGION

gcloud compute backend-services add-backend mtls-proxies-backend-service \
--instance-group ig-mtls-proxy \
--instance-group-region $REGION \
--region $REGION

# Create Forwarding Rule
gcloud compute forwarding-rules create network-lb-forwarding-rule-ipv4 \
  --load-balancing-scheme EXTERNAL \
  --region $REGION \
  --ports 443 \
  --address network-lb-ipv4 \
  --backend-service mtls-proxies-backend-service

# Update Apigee Instance Group to receive requests from mtls.LB_IP.nip.io
L7_LB_EXTERNAL_ADDRESS=$(gcloud compute addresses list --filter="name=(apigee-external-lb-ip)" --format="json" | jq '.[0].address' | tr -d '"')
apigeecli envgroups update -n dev-envgroup  -o $PROJECT_ID -t=$(gcloud auth print-access-token) --hosts mtls.${LB_EXTERNAL_ADDRESS}.nip.io,dev.${L7_LB_EXTERNAL_ADDRESS}.nip.io

# Sample call
# This call is presenting the client cert/key and using the server-ca to validate the certificate presented by the
# TLS server (envoy). Envoy, on the other hand, is using the customer CA to validate the cert/key presented by the client.
curl -vvv --cert example-client.crt --key example-client.key --cacert server-ca.crt "https://mtls.${LB_EXTERNAL_ADDRESS}.nip.io/hello-world"