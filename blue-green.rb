#!/usr/bin/env ruby

begin
  require 'aws-sdk'
  require 'OptionParser'
  require 'pry'
rescue LoadError
  puts 'Gem load error!'
  puts 'Run bundle install and then try again'
end

STDOUT.sync = true # We want to flush output immediately

class BlueGreenDeploy
  def initialize(asg_name_prefix, elb_name_prefix, new_ami = nil, region, verbose)
    # NOTE: region is not currently fully plumbed in!
    @region = region
    @asg_client = Aws::AutoScaling::Client.new(region: region)
    @elb_client = Aws::ElasticLoadBalancing::Client.new(region: region)
    @asg_name_prefix = asg_name_prefix
    @elb_name_prefix = elb_name_prefix
    @new_ami = new_ami
    @verbose = verbose
    @elb_names = [@elb_name_prefix.to_s, "#{@elb_name_prefix}-vnext"]
  end

  def update
    get_asgs
    get_active_asg
    update_inactive_asg_launch_config if @new_ami
    add_capacity_to_inactive_asg
    wait_for_asg_capacity
    wait_for_elb_capacity
  end

  def swap_asg
    get_active_asg
    get_active_elb
    if new_and_existing_amis_match
      puts 'The same AMI is being used for both ASGs.  Aborting the run.'
      exit
    end
    swap_active_asg
    move_active_asg_associated_resources
    swap_inactive_asg_to_active_elb
    remove_capacity_from_prev_active_asg
    wait_for_prev_active_asg_to_drain
  end

  def swap_elb
    get_active_asg
    get_elbs
    get_active_elb
    swap_active_elb
    swap_active_elb_tags
  end

  def get_asgs
    asg_names = ["#{@asg_name_prefix}-blue", "#{@asg_name_prefix}-green"]
    @asgs = @asg_client.describe_auto_scaling_groups(auto_scaling_group_names: asg_names).auto_scaling_groups
    puts "Found ASGs: #{@asgs.map(&:auto_scaling_group_name).join(', ')}."
    raise "ERROR: Wrong number of ASGs found. Expected 2, found #{@asgs.length}." if @asgs.length != 2
  end

  def get_elbs
    @elbs = @elb_client.describe_load_balancers(load_balancer_names: @elb_names).load_balancer_descriptions
    puts "Found ELBs: #{@elbs.map(&:load_balancer_name).join(', ')}."

    raise "ERROR: Wrong number of ELBs found. Expected 2, found #{@elbs.length}." if @elbs.length != 2
  end

  def get_active_asg
    get_asgs

    # sanity checking time! If there are two active tags, that's bad. If there
    # are NO active tags, that's bad as well, lets catch those two conditions
    active_asgs = @asgs.select { |asg| asg.tags.any? { |tag| tag.key == 'active' } }
    raise 'ERROR: No active ASGs found' if active_asgs.none?
    raise 'ERROR: More than one active ASG found' if active_asgs.size > 1

    # now that we are reasonably confident that we're safe to proceed, lets
    # figure out which is the active ASG and which is the inactive
    @starting_active_asg = @asgs.select { |group| group.tags.any? { |n| n.key == 'active' } }.first
    @starting_inactive_asg = @asgs.detect { |n| n != @starting_active_asg }

    # check if ACTIVE ASG has at least ONE instance
    puts "Checking Active ASG min size > zero: #{@starting_active_asg.auto_scaling_group_name} min=#{@starting_active_asg.min_size}"
    raise 'ERROR: Active ASG has ZERO for minimum size' if @starting_active_asg.min_size.equal? 0

    puts "Active ASG: name=#{@starting_active_asg.auto_scaling_group_name} min=#{@starting_active_asg.min_size} desired=#{@starting_active_asg.desired_capacity} max=#{@starting_active_asg.max_size}"
    puts "Inactive ASG: name=#{@starting_inactive_asg.auto_scaling_group_name} min=#{@starting_inactive_asg.min_size} desired=#{@starting_inactive_asg.desired_capacity} max=#{@starting_inactive_asg.max_size}"
  end

  def get_active_elb
    # sanity checking time! If there are two active tags, that's bad. If there
    # are NO active tags, that's bad as well, lets catch those two conditions
    @elb_tags = @elb_client.describe_tags(load_balancer_names: @elb_names).tag_descriptions
    active_elbs = @elb_tags.select { |elb| elb.tags.any? { |tag| tag.key == 'active' } }
    raise 'ERROR: No active ELBs found' if active_elbs.none?
    raise 'ERROR: More than one active ELB found' if active_elbs.size > 1

    # select/reject the active/non active
    @starting_active_elb = @elb_client.describe_tags(load_balancer_names: @elb_names).tag_descriptions.select { |group| group.tags.any? { |tags| tags.key == 'active' } }.first
    @starting_inactive_elb = @elb_client.describe_tags(load_balancer_names: @elb_names).tag_descriptions.reject { |group| group.tags.any? { |tags| tags.key == 'active' } }.first

    # prepare for some validations
    @asg_elbs = @asg_client.describe_load_balancers(auto_scaling_group_name: @starting_active_asg.auto_scaling_group_name).load_balancers
    active_asg_elbs = @asg_elbs.select(&:load_balancer_name)

    raise 'ERROR: Unable to find any active ASG ELBs' if active_asg_elbs.nil? || active_asg_elbs.first.nil?

    # detect "removing" and "removed" condition, and bail out, as we can't
    # reliably predict what is intended
    raise 'ERROR: detected ASG being removed, exiting' if active_asg_elbs.first.state == 'Removing'
    raise 'ERROR: detected ASG as removed, exiting' if active_asg_elbs.first.state == 'Removed'

    #  lets validate that there is only one ELB attached to the active ASG
    raise 'ERROR: The active ASG has NO ELBs attached' if active_asg_elbs.none?
    raise 'ERROR: The active ASG has more than one ELB attached' if active_asg_elbs.size > 1

    puts "Active ELB: #{@starting_active_elb.load_balancer_name}"
    puts "Inactive ELB: #{@starting_inactive_elb.load_balancer_name}"
  end

  def update_inactive_asg_launch_config
    # We have a naming convention that we'd like to stick to
    # (i.e. dev-kuiper-lc-20171016231445) - so we'll split up the prefix a bit
    split_asg_name_prefix = @asg_name_prefix.split('-')
    new_launch_config_name = "#{split_asg_name_prefix[0]}-#{split_asg_name_prefix[1]}-lc-#{DateTime.now.strftime('%Y%m%d%H%M%S')}"
    existing_launch_config = get_existing_launch_config
    new_launch_config_options = update_launch_config_for_reuse(existing_launch_config, new_launch_config_name)
    @asg_client.create_launch_configuration(new_launch_config_options)

    @asg_client.update_auto_scaling_group(
      auto_scaling_group_name: @starting_inactive_asg.auto_scaling_group_name,
      launch_configuration_name: new_launch_config_name
    )
  end

  def new_and_existing_amis_match
    inactive_launch_config_ami_id = @asg_client.describe_launch_configurations(
      launch_configuration_names: [@starting_inactive_asg.launch_configuration_name]
    ).data.to_h[:launch_configurations][0][:image_id]
    active_launch_config_ami_id = @asg_client.describe_launch_configurations(
      launch_configuration_names: [@starting_active_asg.launch_configuration_name]
    ).data.to_h[:launch_configurations][0][:image_id]
    inactive_launch_config_ami_id == active_launch_config_ami_id
  end

  def get_existing_launch_config
    @asg_client.describe_launch_configurations(
      launch_configuration_names: [@starting_inactive_asg.launch_configuration_name]
    ).data.to_h[:launch_configurations][0]
  end

  def update_launch_config_for_reuse(launch_config, new_launch_config_name)
    # clean up the read-only and empty config options
    %i[launch_configuration_arn created_time].each { |k| launch_config.delete(k) }
    filtered_launch_config_options = launch_config.reject { |_k, v| v.is_a?(String) && v.empty? }

    filtered_launch_config_options[:launch_configuration_name] = new_launch_config_name
    filtered_launch_config_options[:image_id] = @new_ami
    filtered_launch_config_options
  end

  def add_capacity_to_inactive_asg
    @asg_client.update_auto_scaling_group(
      auto_scaling_group_name: @starting_inactive_asg.auto_scaling_group_name,
      min_size: @starting_active_asg.min_size,
      desired_capacity: @starting_active_asg.desired_capacity,
      max_size: @starting_active_asg.max_size
    )
    puts "Updating asg: name=#{@starting_inactive_asg.auto_scaling_group_name} min=#{@starting_active_asg.min_size} desired=#{@starting_active_asg.desired_capacity} max=#{@starting_active_asg.max_size}"
  end

  def wait_for_asg_capacity
    asg_instances = []
    loop do
      result = @asg_client.describe_auto_scaling_groups(auto_scaling_group_names: [@starting_inactive_asg.auto_scaling_group_name])
      asg_instances = result.auto_scaling_groups[0].instances.select { |n| n.lifecycle_state == 'InService' }
      break if asg_instances.length == @starting_active_asg.desired_capacity

      puts "Waiting for #{asg_instances.length}/#{@starting_active_asg.desired_capacity} asg instance's state to become InService. name=#{@starting_inactive_asg.auto_scaling_group_name} in_service=#{asg_instances.map(&:instance_id).join(',')}"

      sleep 15
    end
    puts "#{asg_instances.length}/#{@starting_active_asg.desired_capacity} asg instances have become InService. name=#{@starting_inactive_asg.auto_scaling_group_name} in_service=#{asg_instances.map(&:instance_id).join(',')}"
  end

  def wait_for_elb_capacity
    elb_names = @starting_inactive_asg.load_balancer_names
    elb_capacity_checks = elb_names.map { |_x| false }
    asg_instances = []
    elb_instances = []
    loop do
      elb_names.each_with_index do |elb_name, index|
        result = @asg_client.describe_auto_scaling_groups(auto_scaling_group_names: [@starting_inactive_asg.auto_scaling_group_name])
        asg_instances = result.auto_scaling_groups[0].instances.select { |n| n.lifecycle_state == 'InService' }
        elb_instances = @elb_client.describe_instance_health(
          load_balancer_name: elb_name,
          instances: asg_instances.map { |n| { instance_id: n.instance_id } }
        ).instance_states.select { |n| n.state == 'InService' }
        elb_capacity_checks[index] = true if elb_instances.length == @starting_active_asg.desired_capacity
        puts "Waiting for #{elb_instances.length}/#{@starting_active_asg.desired_capacity} elb instance's state to become InService. name=#{@starting_inactive_asg.auto_scaling_group_name} elb_name=#{elb_name} in_service=#{elb_instances.map(&:instance_id).join(',')}"
      end
      break if elb_capacity_checks.all?
      sleep 15
    end
    puts "#{elb_instances.length}/#{@starting_active_asg.desired_capacity} elb instances have become InService. name=#{@starting_inactive_asg.auto_scaling_group_name} elb_name=#{elb_names} in_service=#{elb_instances.map(&:instance_id).join(',')}"
  end

  def swap_active_asg
    if (@starting_inactive_asg.desired_capacity < 1) || (@starting_inactive_asg.max_size < 1)
      puts 'Unable to perform ASG swap.  The ASG to become active does not have any instances running.  Try performing an ASG update first.'
      exit
    end
    @asg_client.delete_tags(
      tags: [{
        resource_id: @starting_active_asg.auto_scaling_group_name,
        resource_type: 'auto-scaling-group',
        key: 'active'
      }]
    )
    puts "Removed active tag from asg #{@starting_active_asg.auto_scaling_group_name}"

    @asg_client.create_or_update_tags(
      tags: [{
        resource_id: @starting_inactive_asg.auto_scaling_group_name,
        resource_type: 'auto-scaling-group',
        key: 'active',
        value: 'true',
        propagate_at_launch: false
      }]
    )
    puts "Adding active tag to asg #{@starting_inactive_asg.auto_scaling_group_name}"
  end

  def swap_inactive_asg_to_active_elb
    result = @asg_client.describe_auto_scaling_groups(auto_scaling_group_names: [@starting_inactive_asg.auto_scaling_group_name])
    asg_instances = result.auto_scaling_groups[0].instances.select { |instance| instance.lifecycle_state == 'InService' }

    raise "ERROR: the starting inactive ASG has ZERO InService instances, this could cause an outage, so we're erroring out" if asg_instances.length.equal? 0

    puts "Attaching starting inactive ASG (#{@starting_inactive_asg.auto_scaling_group_name}) to #{@starting_active_elb.load_balancer_name}"
    @asg_client.attach_load_balancers(auto_scaling_group_name: @starting_inactive_asg.auto_scaling_group_name,
                                      load_balancer_names: [@starting_active_elb.load_balancer_name])
    wait_for_load_balancer_action_to_finish(5, @starting_inactive_asg.auto_scaling_group_name)
    puts "Attached starting inactive ASG (#{@starting_active_asg.auto_scaling_group_name}) to #{@starting_active_elb.load_balancer_name}"

    puts "Detaching active ASG (#{@starting_active_asg.auto_scaling_group_name}) from #{@starting_active_elb.load_balancer_name}"
    # We appear to sometimes NOT have the old ELB associated with the ASG in question.  In that case, we only need to remove it if it's there.
    attached_load_balancers = @asg_client.describe_load_balancers(auto_scaling_group_name: @starting_active_asg.auto_scaling_group_name).load_balancers
    if attached_load_balancers.any? { |s| s.load_balancer_name.include?(@starting_active_elb.load_balancer_name) }
      @asg_client.detach_load_balancers(auto_scaling_group_name: @starting_active_asg.auto_scaling_group_name,
                                        load_balancer_names: [@starting_active_elb.load_balancer_name])
    end
    wait_for_load_balancer_action_to_finish(5, @starting_active_asg.auto_scaling_group_name)
    puts "Detached active ASG (#{@starting_active_asg.auto_scaling_group_name}) from #{@starting_active_elb.load_balancer_name}"
  end

  def wait_for_load_balancer_action_to_finish(max_wait_time_in_minutes, load_balancer_name)
    total_time_waited = 0
    loop do
      load_balancers = @asg_client.describe_load_balancers(auto_scaling_group_name: load_balancer_name).load_balancers
      break if max_wait_time_in_minutes * 60 < total_time_waited || load_balancers.none? { |e| e.state != 'InService' }

      puts 'Waiting for prior ELB action to finish. '
      puts load_balancers.to_s if @verbose

      sleep 10
      total_time_waited += 10
    end

    if total_time_waited > max_wait_time_in_minutes * 60
      puts 'Exceeded allowable wait time for ELB action.  Terminating.'
      exit
    end
  end

  def swap_active_elb
    # NOTE: Assuming we've now passed the "only one ASG live" check, we should
    #       probably check to see if at least one healthy instance is live in
    #       the active ASG. If we put an ASG into service that has ZERO
    #       instances, we will be doing Continuous Downtime, not Continuous
    #       Deployment. This is just another safety check

    result = @asg_client.describe_auto_scaling_groups(auto_scaling_group_names: [@starting_active_asg.auto_scaling_group_name])
    asg_instances = result.auto_scaling_groups[0].instances.select { |instance| instance.lifecycle_state == 'InService' }

    raise "ERROR: the currently active ASG has ZERO InService instances, this could cause an outage, so we're erroring out" if asg_instances.length.equal? 0

    puts "Attaching active ASG (#{@starting_active_asg.auto_scaling_group_name}) to #{@starting_inactive_elb.load_balancer_name}"
    @asg_client.attach_load_balancers(auto_scaling_group_name: @starting_active_asg.auto_scaling_group_name,
                                      load_balancer_names: [@starting_inactive_elb.load_balancer_name])
    wait_for_load_balancer_action_to_finish(5, @starting_active_asg.auto_scaling_group_name)
    puts "Attached active ASG (#{@starting_active_asg.auto_scaling_group_name}) to #{@starting_inactive_elb.load_balancer_name}"

    puts "Detaching active ASG (#{@starting_active_asg.auto_scaling_group_name}) from #{@starting_active_elb.load_balancer_name}"
    # We appear to sometimes NOT have the old ELB associated with the ASG in question.  In that case, we only need to remove it if it's there.
    attached_load_balancers = @asg_client.describe_load_balancers(auto_scaling_group_name: @starting_active_asg.auto_scaling_group_name).load_balancers
    if attached_load_balancers.any? { |s| s.load_balancer_name.include?(@starting_active_elb.load_balancer_name) }
      @asg_client.detach_load_balancers(auto_scaling_group_name: @starting_active_asg.auto_scaling_group_name,
                                        load_balancer_names: [@starting_active_elb.load_balancer_name])
    end
    wait_for_load_balancer_action_to_finish(5, @starting_active_asg.auto_scaling_group_name)
    puts "Detached active ASG (#{@starting_active_asg.auto_scaling_group_name}) from #{@starting_active_elb.load_balancer_name}"
  end

  def swap_active_elb_tags
    @elb_client.remove_tags(load_balancer_names: [@starting_active_elb.load_balancer_name],
                            tags: [
                              {
                                key: 'active'
                              }
                            ])

    puts "Removed active tag from #{@starting_active_elb.load_balancer_name}"

    @elb_client.add_tags(load_balancer_names: [@starting_inactive_elb.load_balancer_name],
                         tags: [
                           {
                             key: 'active',
                             value: 'true'
                           }
                         ])

    puts "Added active tag to #{@starting_inactive_elb.load_balancer_name}"
  end

  def move_active_asg_associated_resources
    scheduled_actions = @asg_client.describe_scheduled_actions(
      auto_scaling_group_name: @starting_active_asg.auto_scaling_group_name
    ).data.to_h
    scheduled_actions[:scheduled_update_group_actions].each do |scheduled_action|
      copy_scheduled_action_to_starting_inactive_asg(scheduled_action)
      delete_scheduled_action_from_starting_active_asg(scheduled_action)
    end
  end

  def copy_scheduled_action_to_starting_inactive_asg(scheduled_action)
    scheduled_action.delete(:scheduled_action_arn)
    scheduled_action[:auto_scaling_group_name] = @starting_inactive_asg.auto_scaling_group_name
    @asg_client.put_scheduled_update_group_action(scheduled_action)
  end

  def delete_scheduled_action_from_starting_active_asg(scheduled_action)
    @asg_client.delete_scheduled_action(
      auto_scaling_group_name: @starting_active_asg.auto_scaling_group_name,
      scheduled_action_name: scheduled_action[:scheduled_action_name]
    )
  end

  def remove_capacity_from_prev_active_asg
    @asg_client.update_auto_scaling_group(
      auto_scaling_group_name: @starting_active_asg.auto_scaling_group_name,
      min_size: 0,
      desired_capacity: 0,
      max_size: 0
    )
    puts "Updating asg: name=#{@starting_active_asg.auto_scaling_group_name} min=0 desired=0 max=0"
  end

  def wait_for_prev_active_asg_to_drain
    asg_instances = []
    loop do
      result = @asg_client.describe_auto_scaling_groups(auto_scaling_group_names: [@starting_active_asg.auto_scaling_group_name])
      asg_instances = result.auto_scaling_groups[0].instances
      break if asg_instances.empty?

      puts "Waiting for #{asg_instances.length}/0 asg instance's state to terminate. name=#{@starting_active_asg.auto_scaling_group_name} in_service=#{asg_instances.map(&:instance_id).join(',')}"
      sleep 15
    end
    puts "#{asg_instances.length}/0 asg instances have terminated. name=#{@starting_active_asg.auto_scaling_group_name}"
  end
end

options = { ami: nil, asg: nil, both: nil, environment: nil, elbprefix: nil, region: nil, swap: nil, update: nil, verbose: nil }

parser = OptionParser.new do |opts|
  opts.banner = 'Example ASG swap: ruby blue-green.rb -s asg -e dev -r us-west-2 -a myawesomeasg'
  opts.banner += "\nExample ELB swap: ruby blue-green.rb -s elb -e dev -r us-west-2 -a myawesomeelb"
  opts.banner += "\nUsage: blue-green.rb [options]"

  opts.on('-a ASG', '--asg ASG', 'App/ASG to update') do |asg|
    options[:asg] = asg
  end
  opts.on('-b', '--both', 'Update and Swap ASG') do |both|
    options[:both] = both
  end
  opts.on('-e ENVIRONMENT', '--env ENVIRONMENT', 'Environment to target (default: dev)') do |environment|
    options[:environment] = environment
  end
  opts.on('-p', '--elbprefix elbprefix', 'Prefix of ELB to swap') do |elbprefix|
    options[:elbprefix] = elbprefix
  end
  opts.on('-i ami', '--image ami', 'Update AMI') do |ami|
    options[:ami] = ami
  end
  opts.on('-r REGION', '--region REGION', 'Region') do |region|
    options[:region] = region
  end
  opts.on('-s SWAP', '--swap SWAP', 'Swap ASG or ELB') do |swap|
    options[:swap] = swap
  end
  opts.on('-u', '--update', 'Update ASG') do |update|
    options[:update] = update
  end
  opts.on('-v', '--verbose', 'Enable verbose/debug output') do |verbose|
    options[:verbose] = verbose
  end
  opts.on('-h', '--help', 'Displays Help') do
    puts opts
    exit(0)
  end
end

# parse the passed in options
parser.parse!

verbose = false
# App/ASG
verbose = true unless options[:verbose].nil?

# AMI
if options[:ami].nil?
  puts 'No AMI updates'
else
  new_ami = options[:ami]
  puts "AMI is: #{new_ami}"
end

# App/ASG
if options[:asg].nil?
  puts 'ERROR: You are required to provide an App/ASG to update!'
  exit(1)
else
  asgname = options[:asg]
  puts "APP/ASG passed: #{asgname}"
end

# ENV
if options[:environment].nil?
  puts 'ERROR: You are required to provide an environment!'
  exit(1)
else
  environment = options[:environment]
  puts "Environment: #{environment}"
end

# REGION
if options[:region].nil?
  puts 'No REGION was specified'
  exit(1)
else
  region = options[:region]
  puts "REGION passed: #{region}"
end

# ELB name
if options[:elbprefix].nil?
  elbprefix = ''
  puts 'No ELB was specified'
else
  elbprefix = options[:elbprefix]
  puts "ELB prefix passed: #{elbprefix}"
end

asg_name_prefix = environment + '-' + asgname
elb_name_prefix = environment + '-' + elbprefix
bgd = BlueGreenDeploy.new(asg_name_prefix, elb_name_prefix, new_ami, region, verbose)

@swap_command = options[:swap].to_s.downcase
if options[:both].nil?
  puts 'Update and Swap was not specified'
else
  if @swap_command != ''
    puts 'You cannot specify the SWAP and BOTH arguments in the same program execution.'
    exit(1)
  end
  puts "BOTH: Environment with ASG name: #{asg_name_prefix}"
  bgd.update
  bgd.swap_asg
end

# SWAP
if (@swap_command != 'elb') && (@swap_command != 'asg')
  puts 'Swap argument was not specified or was an invalid value'
else
  if options[:elbprefix].nil?
    puts 'ELB prefix is mandatory when performing a swap.'
    exit(1)
  end
  if @swap_command == 'elb'
    puts 'ELB Swap was specified.'
    bgd.swap_elb
  end
  if @swap_command == 'asg'
    puts "ASG Swap: Environment with ASG name: #{asg_name_prefix}"
    bgd.swap_asg
  end
end

# UPDATE
if options[:update].nil?
  puts 'Update argument was not specified'
else
  puts "UPDATE: Environment with ASG name: #{asg_name_prefix}"
  bgd.update
end
