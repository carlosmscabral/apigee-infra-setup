#!/bin/bash
# https://cloud.google.com/architecture/build-ha-vpn-connections-google-cloud-aws 
# https://blog.searce.com/multi-cloud-private-dns-forwarding-a77718e2a3f9
HA_VPN_GATEWAY_NAME=gcp-sa-east1-ha-vpn-gw
NETWORK=apigee-vpc
REGION="southamerica-east1"
ROUTER_NAME=gcp-sa-east1-router 
GOOGLE_ASN="65001"
PEER_ASN="65002"
INTERFACE_0_IP_ADDRESS="34.124.22.120"
INTERFACE_1_IP_ADDRESS="34.104.84.71"
PEER_GATEWAY_NAME="aws-tgw"
AWS_GW_IP_1=52.67.137.107
AWS_GW_IP_2=54.207.134.107
AWS_GW_IP_3=18.228.84.51
AWS_GW_IP_4=54.232.140.45
SHARED_SECRET="apigeedocabral"
### These below are not clear in AWS Console. They select the /30 for each tunnel
### and the AWS gets the first IP for the Range, GCP will get the second.
GOOGLE_BGP_IP_TUNNEL_1=169.254.35.126
AWS_T1_IP=169.254.35.125
GOOGLE_BGP_IP_TUNNEL_2=169.254.81.238
AWS_T2_IP=169.254.81.237
GOOGLE_BGP_IP_TUNNEL_3=169.254.217.162
AWS_T3_IP=169.254.217.161
GOOGLE_BGP_IP_TUNNEL_4=169.254.88.246
AWS_T4_IP=169.254.88.245
AWS_DNS_SUFFIX=aws.cabral.internal.






gcloud auth login
gcloud config set project cabral-apigee

gcloud compute vpn-gateways create $HA_VPN_GATEWAY_NAME \
    --network $NETWORK \
    --region $REGION

gcloud compute routers create $ROUTER_NAME \
    --region $REGION \
    --network $NETWORK \
    --asn $GOOGLE_ASN \
    --advertisement-mode custom \
    --set-advertisement-groups all_subnets

#########################################################################################
####### CREATE AWS CONFIG IN THE CONSOLE! I DIDN'T MANAGE TO GET aws CLI TO WORK! #######
#########################################################################################

gcloud compute external-vpn-gateways create $PEER_GATEWAY_NAME  --interfaces \
  0=$AWS_GW_IP_1,1=$AWS_GW_IP_2,2=$AWS_GW_IP_3,3=$AWS_GW_IP_4

# Tunnels
gcloud compute vpn-tunnels create tunnel-1 \
    --peer-external-gateway $PEER_GATEWAY_NAME \
    --peer-external-gateway-interface 0 \
    --region $REGION \
    --ike-version 2 \
    --shared-secret $SHARED_SECRET \
    --router $ROUTER_NAME \
    --vpn-gateway $HA_VPN_GATEWAY_NAME \
    --interface 0

gcloud compute vpn-tunnels create tunnel-2 \
    --peer-external-gateway $PEER_GATEWAY_NAME \
    --peer-external-gateway-interface 1 \
    --region $REGION \
    --ike-version 2 \
    --shared-secret $SHARED_SECRET \
    --router $ROUTER_NAME \
    --vpn-gateway $HA_VPN_GATEWAY_NAME \
    --interface 0

gcloud compute vpn-tunnels create tunnel-3 \
    --peer-external-gateway $PEER_GATEWAY_NAME \
    --peer-external-gateway-interface 2 \
    --region $REGION \
    --ike-version 2 \
    --shared-secret $SHARED_SECRET \
    --router $ROUTER_NAME \
    --vpn-gateway $HA_VPN_GATEWAY_NAME \
    --interface 1

gcloud compute vpn-tunnels create tunnel-4 \
    --peer-external-gateway $PEER_GATEWAY_NAME \
    --peer-external-gateway-interface 3 \
    --region $REGION \
    --ike-version 2 \
    --shared-secret $SHARED_SECRET \
    --router $ROUTER_NAME \
    --vpn-gateway $HA_VPN_GATEWAY_NAME \
    --interface 1

# Cloud Routers IFaces
gcloud compute routers add-interface $ROUTER_NAME \
    --interface-name int-1 \
    --vpn-tunnel tunnel-1 \
    --ip-address $GOOGLE_BGP_IP_TUNNEL_1 \
    --mask-length 30 \
    --region $REGION

gcloud compute routers add-interface $ROUTER_NAME \
    --interface-name int-2 \
    --vpn-tunnel tunnel-2 \
    --ip-address $GOOGLE_BGP_IP_TUNNEL_2 \
    --mask-length 30 \
    --region $REGION

gcloud compute routers add-interface $ROUTER_NAME \
    --interface-name int-3 \
    --vpn-tunnel tunnel-3 \
    --ip-address $GOOGLE_BGP_IP_TUNNEL_3 \
    --mask-length 30 \
    --region $REGION

gcloud compute routers add-interface $ROUTER_NAME \
    --interface-name int-4 \
    --vpn-tunnel tunnel-4 \
    --ip-address $GOOGLE_BGP_IP_TUNNEL_4 \
    --mask-length 30 \
    --region $REGION


# BGP Peers
gcloud compute routers add-bgp-peer $ROUTER_NAME \
    --peer-name aws-conn1-tunn1 \
    --peer-asn $PEER_ASN \
    --interface int-1 \
    --peer-ip-address $AWS_T1_IP \
    --region $REGION

gcloud compute routers add-bgp-peer $ROUTER_NAME \
    --peer-name aws-conn1-tunn2 \
    --peer-asn $PEER_ASN \
    --interface int-2 \
    --peer-ip-address $AWS_T2_IP \
    --region $REGION

gcloud compute routers add-bgp-peer $ROUTER_NAME \
    --peer-name aws-conn2-tunn1 \
    --peer-asn $PEER_ASN \
    --interface int-3 \
    --peer-ip-address $AWS_T3_IP \
    --region $REGION

gcloud compute routers add-bgp-peer $ROUTER_NAME \
    --peer-name aws-conn2-tunn2 \
    --peer-asn $PEER_ASN \
    --interface int-4 \
    --peer-ip-address $AWS_T4_IP \
    --region $REGION



### SSH to EC2
ssh -i ~/creds/cabral-ec2-key.pem admin@ec2-54-207-210-68.sa-east-1.compute.amazonaws.com

### Key learnings:
### -------------
### AWS requires manual return routes to Apigee in the subnet Routing Table (need to understand how propagation should work, if at all)
### Need to add Apigee CIDR in the Cloud Router for announcement (Cloud Router does that automatically only for local subnets)
### Need to poke firewall holes in both sides for reachability; for the Apigee managed VPC, that's handled by Apigee
### Export/Import custom routes in the peering connection is necessary for the Apigee VPC to learn AWS's subnets

### DNS Forwarding - https://blog.searce.com/multi-cloud-private-dns-forwarding-a77718e2a3f9

### DNS Peering - so Apigee can "access" the consumer VPC DNS Resolution, which will forward to AWS

gcloud services peered-dns-domains create apigee-to-consumer-peering --dns-suffix=$AWS_DNS_SUFFIX. --network=$NETWORK
gcloud services peered-dns-domains list --network=$NETWORK 
