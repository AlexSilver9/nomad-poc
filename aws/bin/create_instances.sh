#!/usr/bin/bash

# Create 3 EC2 instances for the Nomad cluster (nomad1, nomad2, nomad3).
# Requires: aws-cli configured with appropriate credentials.
# Output: stdout of aws command appended to /tmp/aws_create_instances.log, stderr to terminal.
# Output: prints ssh connection command for each instance to terminal.
# Usage: ./aws_create_instances.sh

instance_prefix="nomad"
instance_ids=()

for i in {1..3}; do
    name="$instance_prefix$i"
    echo "Creating instance $name..."

    result=$(aws ec2 run-instances \
        --image-id 'ami-0191d47ba10441f0b' \
        --instance-type 't3.micro' \
        --key-name 'nomad-keypair' \
        --network-interfaces '{"SubnetId":"subnet-3ee53954","AssociatePublicIpAddress":true,"DeviceIndex":0,"Groups":["sg-07fee22cbcdad4c58","sg-09aa7199da65ed0e3","sg-0beaa6c98d73ebd3b","sg-77476f14"]}' \
        --credit-specification '{"CpuCredits":"unlimited"}' \
        --tag-specifications '{"ResourceType":"instance","Tags":[{"Key":"Name","Value":"'"$name"'"}]}' \
        --metadata-options '{"HttpEndpoint":"enabled","HttpPutResponseHopLimit":2,"HttpTokens":"required"}' \
        --private-dns-name-options '{"HostnameType":"ip-name","EnableResourceNameDnsARecord":false,"EnableResourceNameDnsAAAARecord":false}' \
        --count '1')

    echo "$result" >> /tmp/aws_create_instances.log
    instance_id=$(echo "$result" | jq -r '.Instances[0].InstanceId')
    instance_ids+=("$instance_id")
    echo "Created $name: $instance_id"
done

echo "Waiting for instances to be running..."
aws ec2 wait instance-running --instance-ids "${instance_ids[@]}"

echo "Fetching connection details..."
for instance_id in "${instance_ids[@]}"; do
    pubdns=$(aws ec2 describe-instances --instance-ids "$instance_id" \
        | jq -r '.Reservations[0].Instances[0].PublicDnsName')
    echo "Connect to node: ssh -i ~/workspace/nomad/nomad-keypair.pem ec2-user@$pubdns"
done

echo "Done"
