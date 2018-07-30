import requests
import click
import re
import boto3
from datetime import datetime
import time
import subprocess
import os
import sh
import sys

# To work, your environment needs to be set up properlu:
# To install gauntlt you may need:
#       sudo yum groupinstall "Development Tools"
#       sudo yum install ruby-devel
#       You need gauntlt installed where Jenkins can see it, adding "sh 'gem install gauntlt'
#           just once as a pipeline step will put it in the right location
# This also assumes you have an AWS IAM role with the needed permissions for the EC2 operations.
#

@click.command()
# TODO change remaining OS environment variables to saving to files
# TODO update to check security group only for the current VPC

def assess():
    region = 'us-west-2'
    job_console = requests.get('http://127.0.0.1:8080/job/Website/lastBuild/consoleText', auth=('admin', 'ec3892ddfc2276191a32702bf3e0ced0'))
    click.echo(job_console.text)
    pattern = re.compile('(?<= )ami-.{8}')
    image_id = ''
    for image_id in re.findall(pattern, job_console.text):
        pass
    file = open("./ami.txt", "w+")
    file.write(image_id)
    file.close()
    click.echo(image_id)
    cur_mac = requests.get('http://169.254.169.254/latest/meta-data/mac')
    click.echo(cur_mac.text)
    subnet_url = 'http://169.254.169.254/latest/meta-data/network/interfaces/macs/' + cur_mac.text + '/subnet-id'
    curr_subnet = requests.get(subnet_url)
    click.echo(curr_subnet.text)
    curr_sg = requests.get('http://169.254.169.254/latest/meta-data/security-groups')
    curr_sg = curr_sg.text.split('\n', 1)[0]
    click.echo(curr_sg)
    curr_vpc = 'http://169.254.169.254/latest/meta-data/network/interfaces/macs/' + cur_mac.text + '/vpc-id'
    curr_vpc = requests.get(curr_vpc)
    curr_vpc = curr_vpc.text
    click.echo(curr_vpc)
    ec2 = boto3.client('ec2', region_name=region)
    jenkins_sg = ec2.describe_security_groups(
        Filters=[
            {
                'Name': 'group-name',
                'Values': [
                    curr_sg,
                ]
            },
        ])
    jenkins_sg = jenkins_sg['SecurityGroups'][0]['GroupId']
    click.echo(jenkins_sg)
    stamp = datetime.now()
    tmpkey = 'tempkey-' + stamp.strftime('%H%M%S%m%d%Y')
    key = ec2.create_key_pair(KeyName=tmpkey)
    click.echo(str(key))
    tmpsg = 'tempsg-' + stamp.strftime('%H%M%S%m%d%Y')
    sg = ec2.create_security_group(Description='Temporary security group for gauntlt assessment', GroupName=tmpsg, VpcId=curr_vpc)
    time.sleep(3)
    sg = sg['GroupId']
    click.echo(sg)
    # add rule to security group
    ec2.authorize_security_group_ingress(GroupId=sg, IpPermissions=[{'IpProtocol': '-1', 'FromPort': -1,'ToPort': -1,'UserIdGroupPairs': [{'GroupId': jenkins_sg}]}])
    instance = ec2.run_instances(ImageId=image_id, InstanceType='t2.micro', SecurityGroupIds=[sg], IamInstanceProfile={'Name': 'Dev'}, SubnetId=curr_subnet.text, MaxCount=1, MinCount=1)
    click.echo('Launching Instance ' + instance['Instances'][0]['InstanceId'] + '... will resume when it is running')
    waiter = ec2.get_waiter('instance_running')
    waiter.wait(InstanceIds=[instance['Instances'][0]['InstanceId']])
    time.sleep(60)
    instance_ip = instance['Instances'][0]['PrivateIpAddress']
    # This is a bit hacky, should convert to saving to a file instead
    os.environ["TEST_HOSTNAME"] = instance_ip

    # Testing area to try and correctly parse results and fail the build
    e = ''
    result_code = 1
    result = ''
    try:
        gauntlt = sh.Command("/var/lib/jenkins/bin/gauntlt")
        result = gauntlt("./myattack.attack", _err_to_out=True)
        result_code = result.exit_code
    except sh.ErrorReturnCode as e:
        click.echo(e)
        result_code = e
    if result_code == 0:
        click.echo('All Gauntlt tests passed')
        click.echo(result)
    else:
        click.echo('Gauntlt test failed')
        click.echo(e.stdout)

    # *** begin old code
    # assess = subprocess.Popen(["/var/lib/jenkins/bin/gauntlt", "./myattack.attack"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    # result = assess.communicate()
    # ***end old code


    ec2.terminate_instances(InstanceIds=[instance['Instances'][0]['InstanceId']])
    waiter = ec2.get_waiter('instance_terminated')
    waiter.wait(InstanceIds=[instance['Instances'][0]['InstanceId']])
    ec2.delete_security_group(GroupId=sg)
    ec2.delete_key_pair(KeyName=tmpkey)

     if result_code != 0:
         sys.exit(1)

if __name__ == "__main__":
    assess()