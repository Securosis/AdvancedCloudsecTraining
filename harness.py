import requests
import click
import re
import boto3
from datetime import datetime
import time
import subprocess
import os

# To work, your environment needs to be set up properlu:
# To install gauntlt you may need:
#       sudo yum groupinstall "Development Tools"
#       sudo yum install ruby-devel
#       You need gauntlt installed where Jenkins can see it, adding "sh 'gem install gauntlt'
#           just once as a pipeline step will put it in the right location
#

@click.command()
# TODO deal with IAM role
# TODO parse out gauntlt codes and return value- jsut r for "failed"?
# TODO set environment variable for AMI or save to a local file like before
# TODO set ASG name with default but as a parameter so the user can change it in the jenkins job
# TODO terminate instance on failed test
# TODO change remaining OS environment variables to saving to files

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
    stamp = datetime.now()
    tmpkey = 'tempkey-' + stamp.strftime('%H%M%S%m%d%Y')
    key = ec2.create_key_pair(KeyName=tmpkey)
    click.echo(str(key))
    tmpsg = 'tempsg-' + stamp.strftime('%H%M%S%m%d%Y')
    sg = ec2.create_security_group(Description='Temporary security group for gauntlt assessment', GroupName=tmpsg, VpcId=curr_vpc)
    time.sleep(3)
    sg = sg['GroupId']
    # add rule to security group
    ec2.authorize_security_group_ingress(GroupId=sg, IpPermissions=[{'IpProtocol': '-1', 'FromPort': -1,'ToPort': -1,'UserIdGroupPairs': [{'GroupId': jenkins_sg}]}])
    instance = ec2.run_instances(ImageId=image_id.group(), InstanceType='t2.micro', SecurityGroupIds=[sg], IamInstanceProfile={'Name': 'Dev'}, SubnetId=curr_subnet.text, MaxCount=1, MinCount=1)
    click.echo('Launching Instance ' + instance['Instances'][0]['InstanceId'] + '... will resume when it is running')
    waiter = ec2.get_waiter('instance_running')
    waiter.wait(InstanceIds=[instance['Instances'][0]['InstanceId']])
    time.sleep(60)
    instance_ip = instance['Instances'][0]['PrivateIpAddress']
    # This is a bit hacky, should convert to saving to a file instead
    os.environ["TEST_HOSTNAME"] = instance_ip
    assess = subprocess.Popen(["/var/lib/jenkins/bin/gauntlt", "./myattack.attack"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    # assess = gauntlt("myattack.attack")
    result = assess.communicate()
    click.echo(result)
    ec2.terminate_instances(InstanceIds=[instance['Instances'][0]['InstanceId']])
    waiter = ec2.get_waiter('instance_terminated')
    waiter.wait(InstanceIds=[instance['Instances'][0]['InstanceId']])
    ec2.delete_security_group(GroupId=sg)
    ec2.delete_key_pair(KeyName=tmpkey)

if __name__ == "__main__":
    assess()