pipeline {
    agent any
    parameters {
        string(name: 'ASG_NAME', defaultValue: 'website', description: 'Name of the auto scale group to update. Defaults to the training class expected name if not set.')
        string(name: 'AWS_ACCOUNT', description: 'The AWS Account ID where the auto scaling group to update is located')
        }
    stages {
        stage('Security Credential Scan') {
            steps {
                echo 'Examining source files for AWS credentials...'
                sh 'python cred_scanner.py'
                }
            }
        stage('Build') {
            steps {
                  echo 'building'
                sh '/usr/local/packer build  -machine-readable -debug ./packer.json'
            }
        }
        stage('Test') {
            steps {
                echo 'Testing..'
                sh 'python harness.py'
            }
        }
        stage('Deploy') {
            steps {
               script {
                       input message: 'Deploy to the auto scale group?', ok: 'Deploy',
                               parameters: [
                                       string(name: '', description: ''),
                               ]
                   }
                echo 'Deploying....'
                script {
                          // trim removes leading and trailing whitespace from the string
                          image_id = readFile('ami.txt').trim()
                        }
                echo "Image ID for new AMI: ${image_id}"
                aws ec2 modify-image-attribute \
                    --image-id ${image_id} \
                    --launch-permission "Add=[{UserId=${AWS_ACCOUNT}}]"
                sh "ruby rolling_update.rb -y ${ASG_NAME} -a ${AWS_ACCOUNT} ${image_id}"
            }
        }
    }
}
