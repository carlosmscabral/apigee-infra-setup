/**
 * Copyright 2023 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */


ax_region = "us-east1"

apigee_instances = {
  southamerica-east1 = {
    region       = "southamerica-east1"
    ip_range     = "10.0.0.0/22"
    environments = ["prd"]
  }
}

apigee_environments = {
  prd = {
    display_name = "Prod Legal"
    description  = "Environment created by apigee/terraform-modules"
    node_config  = null
    iam          = null
    envgroups    = ["prod-envgroup"]
  }
}

apigee_envgroups = {
  prod-envgroup = {
    hostnames = ["change-me-later.com"]
  }
}

network = "apigee-network"

psc_ingress_network = "apigee-network"

psc_ingress_subnets = [
  {
    name               = "apigee-psc-subnet"
    ip_cidr_range      = "10.100.0.0/24"
    region             = "southamerica-east1"
    secondary_ip_range = null
  }
]

peering_range = "10.0.0.0/22"
support_range = "10.1.0.0/28"
