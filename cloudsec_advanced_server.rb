# This is an extremely lightweight web app to show the current status of a rolling auto scale update, updated every 1 second

require 'sinatra'
require 'aws-sdk'
require 'net/http'
require 'open-uri'

# Hardcode region
$region = "us-west-2"
# Create EC2 and autoscaling clients. Wide variable scope due to Sinatra

@@ec2 = Aws::EC2::Client.new(region: "#{$region}")
@@autoscaling = Aws::AutoScaling::Client.new(region: "#{$region}")

# Pull the current image and instance ID
metadata_endpoint = 'http://169.254.169.254/latest/meta-data/'
@@image_id = Net::HTTP.get( URI.parse( metadata_endpoint + 'ami-id' ) )
@@instance_id = Net::HTTP.get( URI.parse( metadata_endpoint + 'instance-id' ) )

# Identify the current auto scale group. Since this demo may change over time that's better than hard coding.
@metadata  = @@ec2.describe_instances(instance_ids: ["#{@@instance_id}"])
tags = @metadata.reservations.first.instances.first
# covert to hash to make this easier
tags = tags.to_h
tags = tags[:tags]
# quick check to avoid having to iterate through all the tags to see if the one we need is there.
temp_tags = tags.to_s
if temp_tags.include?("aws:autoscaling:groupName")
  tags.each do |curtag|
    if curtag[:key] == "aws:autoscaling:groupName"
      @@autoscalegroup = curtag[:value]
    end
  end
else
  @@autoscalegroup = "false"
end

def create_list

  if @@autoscalegroup != "false"
    # Pull all the instances
    asg = @@autoscaling.describe_auto_scaling_groups({
      auto_scaling_group_names: ["#{@@autoscalegroup}"]})
  # next line is hard coded for testing, can remove if we place this in the ASG and use lines above instead
#     asg = @@autoscaling.describe_auto_scaling_groups({
#        auto_scaling_group_names: ["test2"]})
    @@instancelist = asg.auto_scaling_groups.first.instances.map(&:instance_id)
    puts @@instancelist


  @@oldlist = {}
  @@instancelist.each do |instance|
    image = @@ec2.describe_instances(instance_ids: ["#{instance}"])
    image = image.reservations.first.instances.first.image_id
    if image == "#{@@image_id}"
      @@oldlist["#{instance}"] = "#{image}"
    end
  end

  @@newlist = {}
  @@instancelist.each do |instance|
    image = @@ec2.describe_instances(instance_ids: ["#{instance}"])
    image = image.reservations.first.instances.first.image_id
    if image != "#{@@image_id}"
      @@newlist["#{instance}"] = "#{image}"
    end
  end


  puts @@oldlist
  puts "---"
  puts @@newlist
       end
end


# Set Sinatra to production mode so it will accept outside http connections
set :environment, :production

# Start all the sinatra stuff
get '/' do 
  erb :index
end

__END__
@@ layout
<!DOCTYPE html>
<html>
<head>
  <title>Securosis Advanced Cloud Security Training Server</title>
  <meta http-equiv="refresh" content="10">
</head>
<body>
<%= yield %>
</body>
</html>
 
@@ index
<% create_list %>
<H1 style="inline-block; margin-left: auto; margin-right: auto; font-family: Arial, Helvetica, sans-serif;">Securosis Advanced Cloud Security Training Server</H1>
<br />
<p style="inline-block; margin-left: auto; margin-right: auto; font-family: Arial, Helvetica, sans-serif;">I may be ugly, but I get the job done</p>
<br />
<h2 style="inline-block; margin-left: auto; margin-right: auto; font-family: Arial, Helvetica, sans-serif;">Current Instance ID: <%= @@instance_id %></h2>
<h2 style="inline-block; margin-left: auto; margin-right: auto; font-family: Arial, Helvetica, sans-serif;">Current Image ID: <%= @@image_id %></h2>
<br />
<br />
<% begin %>
<% display_link = open('https://s3-us-west-2.amazonaws.com/advanced-cloudsec/config.txt') {|f| f.read } %>
<% if (display_link[0..3] == "http") %>
<img src="<%= display_link.to_s %>">
<% else %>
Fail 2 Sorry, no S3 service endpoint means no dynamite
<% end %>
<% rescue %>
Fail 1 Sorry, no S3 service endpoint means no dynamite
<% end %>
<br />
<br />
<% if @@autoscalegroup != "false" %>
  <p style="inline-block; margin-left: auto; margin-right: auto; font-family: Arial, Helvetica, sans-serif;"> Instances in ASG</p>
  <% @@oldlist.each do |instance, image| %>
    <p style="display: inline-block; margin-left: auto; margin-right: auto; border: 1px solid black; background-color: green; color:white; font-size:200%; font-family: Arial, Helvetica, sans-serif;" >Instance: <%= instance %> <br />Image <%= image %></p>
  <% end %>
  <% @@newlist.each do |instance, image| %>
    <p style="display: inline-block; margin-left: auto; margin-right: auto; border: 1px solid black; background-color: blue; color:white; font-size:200%; font-family: Arial, Helvetica, sans-serif;">Instance: <%= instance %> <br />Image <%= image %></p>
  <% end %>
<% else %>
  This instance is not in an auto scale group
<% end %>