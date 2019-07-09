# Workflow for rolling out an updated AMI in a rolling patch scenario on AWS
# Copyright Securosis, LLC, 2016, all rights reserved
# Note that credentials for this workflow rely on the current role of where it is running!
# TODO automatically create qurantine security group if needed


require 'aws-sdk'
require 'json'
require 'optparse'


class AutoscaleActions
	def initialize
		# Initialize the needed service clients
		sts = Aws::STS::Client.new(region: "#{$region}")
		role = sts.assume_role({
  			role_arn: "arn:aws:iam::#{$account_id}:role/SecOps",
  			role_session_name: "cloudsec-jenkins",
			})

		@@ec2 = Aws::EC2::Client.new(credentials: role, region: "#{$region}")
		@@autoscaling = Aws::AutoScaling::Client.new(credentials: role, region: "#{$region}")
	end
	
	def get_autoscale_group_details(asg_name)
		# This method pulls the current launch configuration and image_id when given an auto scale group
		begin
			# Get details for the named ASG
			asg_details = @@autoscaling.describe_auto_scaling_groups({
  							auto_scaling_group_names: ["#{asg_name}"]})
  			# Check to see if it was a valid name for the current region
  			if asg_details.auto_scaling_groups == []
  				puts "#{asg_name} is not a valid auto scale group in region #{$region}"
  				exit
  			else
  				# Get the launch configuration name and then the associated image ID
  				launch_configuration_name = asg_details.auto_scaling_groups.first.launch_configuration_name
  				launch_config = @@autoscaling.describe_launch_configurations({launch_configuration_names: ["#{launch_configuration_name}"]})
		  	# get the current AMI 
		  		current_image_id = launch_config.launch_configurations.first.image_id
		  		return launch_configuration_name, current_image_id
  			end
  			puts "Current launch configuration is #{launchconfiguration_name} and image id is #{current_image_id}"
		rescue Aws::AutoScaling::Errors::ServiceError => error
			puts "error encountered in get_autoscale_group_details: "
			puts "#{error.message}"
		end
	end
	
	def change_launchconfiguration_ami(launch_configuration_name, new_ami)
		# this method changes the AMI associated with a launch configuration.
		# It pulls the current configuration, then creates a new one with the updated AMI
		#  then returns the new launch configuration to swap into an auto scale group.
		begin
			puts new_ami
			# pull the current configuration as an object
		  	launch_config = @@autoscaling.describe_launch_configurations({launch_configuration_names: ["#{launch_configuration_name}"]})
		  	# Confirm the new AMI is valid
		  	test = @@ec2.describe_images({image_ids: ["#{new_ami}"]})
		  	if test == []
		  		puts "Invalid AMI image ID, exiting."
		  		exit
		  	end
		  	# change to the new AMI
		  	launch_config.launch_configurations.first.image_id = new_ami
		  	curname = launch_config.launch_configurations.first.launch_configuration_name
		  	# See if the name has been previously modified by this workflow. If so, trim the end so it doesn't append the timestamp again
		  	if (/-[0-9]{14}TR$/x.match(curname) != nil)
		  		curname = curname[0..-19]
		  	end
		  	time = Time.now()
		  	time = time.strftime("%Y%m%d%H%M%S")
		  	newname = curname + "-" + time + "TR"
		  	# swap in the new name
		  	launch_config.launch_configurations.first.launch_configuration_name = newname
		  	# convert to hash to create the new launch config
		  	launch_config = launch_config.launch_configurations.first.to_h
		  	# Delete some things that will cause errors
		  	launch_config.delete(:launch_configuration_arn)
		  	launch_config.delete(:created_time)
		  	if launch_config[:kernel_id] == ""
		  		launch_config.delete(:kernel_id)
		  	end
		  	if launch_config[:ramdisk_id] == ""
		  		launch_config.delete(:ramdisk_id)
		  	end
		  	if launch_config[:block_device_mappings].first[:ebs].has_key?(:snapshot_id) == true
		  		launch_config[:block_device_mappings].first[:ebs].delete(:snapshot_id)
		  	end
		  	@@autoscaling.create_launch_configuration(launch_config)
		  	return newname
		rescue Aws::AutoScaling::Errors::ServiceError => error
			puts "error encountered in method"
			puts "#{error.message}"
		end
	end
	
	def change_autoscale_launch_configuration(asg_name, launchconfiguration_name)
		# this method changes the launch configuration associated with an auto scale group
		begin
			# Swap in the launch configuration
			@@autoscaling.update_auto_scaling_group({auto_scaling_group_name: "#{asg_name}", launch_configuration_name: "#{launchconfiguration_name}"})
		rescue Aws::AutoScaling::Errors::ServiceError => error
			puts "error encountered in change_autoscale_launch_configuration"
			puts "#{error.message}"
		end
	end
	
	def self.rolling_autoscale_update(asg_name, old_ami, interval, batch_size, mode)
		# This method degrades, isolates, or terminates instances in an auto scale group using
		# the requested mode, time interval, and batch size.
		# Supported modes are degrade_health (mark instances as unhealthy and let the ASG manage the update),
		# terminate (rolling terminate the instances), detach_and_quarantine (detach the instances from the 
		# ASG and put them in a quarantined security group)
		begin
			# Get a list of all the instances in the ASG
			auto_scale_description = @@autoscaling.describe_auto_scaling_groups({
				auto_scaling_group_names: ["#{asg_name}"]})
			instancelist = auto_scale_description.auto_scaling_groups.first.instances
			instancelist = instancelist.map(&:instance_id)
			

			# Ensure the min count is sufficient for the selected batch size. If not, reduce the batch size.
			instance_min = auto_scale_description.auto_scaling_groups.first.min_size
			if ((batch_size / 2) > instance_min)
				puts "Requested batch size of #{batch_size} may be too large for current auto scale group settings."
				batch_size = (batch_size / 2)
				puts "batch_size reduced to #{batch_size}"
			end
			
			# Make sure batch size is valid
			if batch_size <= 1
				batch_size = 1
			end

			# puts "Instances in the auto scale group:"
			# puts instancelist
			# Initialize the batch counter
			batch_counter = 1
			# Roll through the instances. If the AMI is the expired one, remove from the ASG using the desired method.
			instancelist.each do |curinstance|
				# Get the AMI for the instance and see if it is the one marked to remove
				instance = @@ec2.describe_instances({instance_ids: ["#{curinstance}"]})
				if instance.reservations.first.instances.first.image_id == old_ami
					unless ((instance.reservations.first.instances.first.state.name == "terminated") or (instance.reservations.first.instances.first.state.name == "shutting-down"))
						if batch_counter <= batch_size
							# add a 1 second delay to avoid API request limits
							sleep(1)
							print "Instance #{curinstance} running on old AMI. "
							if mode == "degrade_health"
								puts "Degrading health. Auto scale group will terminate the instance."
								# set the health status to unhealthy. The ASG will handle termination and replacement
								@@autoscaling.set_instance_health({instance_id: curinstance, 
									health_status: "Unhealthy"})
								batch_counter += 1
								sleep(1)
							elsif mode == "terminate"
								puts "Terminating the instance."
								# Terminate the instance
								@@autoscaling.terminate_instance_in_auto_scaling_group({instance_id: curinstance})
								batch_counter += 1
								sleep(1)
							elsif mode == "detach_and_quarantine"
								puts "Detaching the instance from the auto scale group and setting Quarantine tag to Active."
								# Detach the instance from the ASG, then quarantine it using the current config setting, then
								# tag it somehow. 
								# TODO need to pull quarantine settings. Need to determine what to tag it with.
								@@autoscaling.detach_instances({instance_ids: ["#{curinstance}", auto_scaling_group_name: asg_name]})
								# Note: to actually quarantine the instance you need to specify a quarantine security group and uncomment the line below
								# @@ec2.modify_instance_attribute(instance_id: curinstance, groups: ["#{sg-ead03c85}"])
								@@ec2.create_tags(resources: ["#{@instance_id}"], tags: [
								    {
								      key: "Quarantine",
								      value: "Active",
								    },
								  ],)
								batch_counter += 1
								sleep(1)
							end
						else
							puts "Completed batch run of #{batch_size} and pausing for #{interval} seconds."
							sleep(interval)
							batch_counter = 0
						end
					end
				end
			end
		rescue Aws::AutoScaling::Errors::ServiceError => error
			puts "error encountered in rolling_autoscale_update"
			puts "#{error.message}"
		end
		return true
	end
	
	def manage_rolling_update(asg_name, old_ami, interval, batch_size, mode)
	# Supervisor method to keep process running until the auto scale group is free of instances on the old AMI.
	# Note that since we use the rolling update code in other areas, there are some overlaps between this meithod
	# 	and rolling_autoscale_update. These don't affect function but are not totally optimized.
	
	# Set the initial array and leave a placeholder value so the loop starts running
	instancelist = [1]
	until instancelist == []
		# Build a list of all the instances in the auto scale group
		auto_scale_description = @@autoscaling.describe_auto_scaling_groups({
			auto_scaling_group_names: ["#{asg_name}"]})
		instancelist = auto_scale_description.auto_scaling_groups.first.instances
		instancelist = instancelist.map(&:instance_id)
		
		# Check those instances to find which ones are running on the old image. Loop will exit if none
		instancelist = @@ec2.describe_instances({instance_ids: instancelist, filters: [
											    {
											      name: "image-id",
											      values: ["#{old_ami}"],
											    }]})	
		instancelist = instancelist.reservations
		update = false
		update = self.class.rolling_autoscale_update(asg_name, old_ami, interval, batch_size, mode)
		sleep(1)
		until update == true	
			sleep(1)
		end 				    	
	end
	puts "All running instances now based on the new AMI."
	end

end

# Set empty hash to hold command line options
options = {}
optparse = OptionParser.new do |opts|
	# opts.banner = "Usage: rolling_update.rb [options] [auto scale group name] [new AMI image ID]"
	
	options[:suppress] = false
	opts.on( '-y', '--yes', 'Suppress confirmation to proceed' ) do
			options[:suppress] = true
	end
	
	options[:region] = "us-west-2"
	opts.on( '-r', '--region REGION', 'Set region. Default is us-west-2' ) do |region|
		options[:region] = region
	end
	
	options[:account_id] = ""
	opts.on( '-a', '--account_id ACCOUNTID', 'Set the account ID for the AWS account. Default is none' ) do |account_id|
		options[:account_id] = account_id
	end
	
	options[:mode] = "degrade_health"
	opts.on( '-m', '--mode MODE', 'Set the mode for removing instances from the auto scale group. Default is degrade_health. Other options are terminate and detach_and_quarantine' ) do |method|
		options[:mode] = mode
	end
	
	options[:batch_size] = 1
	opts.on( '-b', '--batch SIZE', 'The number of instances to remove from the group during each round. Default is 5' ) do |size|
		options[:batch_size] = size
	end
	
	options[:interval] = 60
	opts.on( '-i', '--interval SECONDS', 'The amount of time to wait between each batch. Default is 60 seconds' ) do |interval|
		options[:interval] = interval
	end
	
	opts.on( '-h', '--help', 'Display this screen' ) do
		puts opts
		exit
	end
end


# Parse the command line options
optparse.parse!
# Set the region
$region = options[:region]
$account_id = options[:account_id]
# Initialize the class for the auto scale group actions
autoscale = AutoscaleActions.new()

# Set the required variables based on the arguments. Validity is checked later in the application.
asg_name = ARGV.shift
new_ami = ARGV.shift

# Require the user to manually approve execution unless the suppress option is set
if options[:suppress] == false
	puts "WARNING! This application will significantly alter an auto scale group, changing the launch configuration, swapping out the AMI, and degrading or terminating running instances. Press Y to continue or any other key to exit."
	confirm = gets.chomp
	if confirm != "Y"
		exit
	end
else
	puts "WARNING! This application is about to significantly alter an auto scale group, changing the launch configuration, swapping out the AMI, and degrading or terminating running instances."
	puts "These actions are not automatically reversable, and if you see this message it means you supressed manual confirmation."
	puts "So now it's too late, unless you kill this app *really quickly*."
end

# Start the rolling update process by pulling the existing AMI image id and launch configuration name
vars = autoscale.get_autoscale_group_details(asg_name)
launch_configuration_name = vars[0]
old_ami = vars[1]

# Create a new launch configuration that swaps in the new AMI image id, then update the auto scale group.
puts "Updating the launch configuration and auto scale group to use the new AMI image ID."
new_launchconfiguration_name = autoscale.change_launchconfiguration_ami("#{launch_configuration_name}", "#{new_ami}")
autoscale.change_autoscale_launch_configuration(asg_name, new_launchconfiguration_name)
puts "Auto scale group updated. Degraded and terminated instances will be replaced with the updated image."
sleep(5)


# Begin the rolling update process.
puts "Beginning rolling update. Existing this program before completion may result in instances based on the old AMI remaining in service."
autoscale.manage_rolling_update(asg_name, old_ami, options[:interval], options[:batch_size], options[:mode])
