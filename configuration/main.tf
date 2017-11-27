resource "aws_elb" "web-blue" {
  count                       = "${var.allocate_elb}"
  name                        = "${var.service_name}-${var.environment}"
  subnets                     = ["${split(",", var.elb_subnets)}"]
  cross_zone_load_balancing   = true
  security_groups             = ["${var.elb_security_group_id}"]
  idle_timeout                = 500
  connection_draining         = true
  connection_draining_timeout = 310

  listener {
    instance_port     = 80
    instance_protocol = "http"
    lb_port           = 80
    lb_protocol       = "http"
  }

  listener {
    instance_port      = 443
    instance_protocol  = "http"
    lb_port            = 443
    lb_protocol        = "https"
    ssl_certificate_id = "${var.ssl_certificate_id}"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = "${var.num_elb_health_checks}"
    timeout             = 14
    target              = "${var.health_check_path}"
    interval            = "${var.health_check_interval}"
  }

  cross_zone_load_balancing   = true

  tags                        = {
    service        = "${var.company_name}-${var.service_name}"
    environment = "${var.environment}"
  }
}

  resource "aws_elb" "web-green" {
  count                       = "${var.allocate_elb}"
  name                        = "${var.service_name}-${var.environment}"
  subnets                     = ["${split(",", var.elb_subnets)}"]
  cross_zone_load_balancing   = true
  security_groups             = ["${var.elb_security_group_id}"]
  idle_timeout                = 500
  connection_draining         = true
  connection_draining_timeout = 310

  listener {
    instance_port     = 80
    instance_protocol = "http"
    lb_port           = 80
    lb_protocol       = "http"
  }

  listener {
    instance_port      = 443
    instance_protocol  = "http"
    lb_port            = 443
    lb_protocol        = "https"
    ssl_certificate_id = "${var.ssl_certificate_id}"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = "${var.num_elb_health_checks}"
    timeout             = 14
    target              = "${var.health_check_path}"
    interval            = "${var.health_check_interval}"
  }

  cross_zone_load_balancing   = true

  tags                        = {
    service        = "${var.company_name}-${var.service_name}"
    environment = "${var.environment}"
  }
}

# Autoscaling policy for scale down
resource "aws_autoscaling_policy" "web_scaledown" {
  count                  = "${element(split(",","0,2"), var.do_scale)}"
  name                   = "${var.service_name}-${var.environment}${element(split(",",",_green"), count.index)}-scaledown"
  scaling_adjustment     = "${var.scaledown_adjustment}"
  adjustment_type        = "ChangeInCapacity"
  autoscaling_group_name = "${element(split(",","${aws_autoscaling_group.blue.name},${aws_autoscaling_group.green.name}"),count.index)}"
  cooldown               = "${var.scale_down_cooldown}"
}

# Autoscaling policy for scale up
resource "aws_autoscaling_policy" "web_scaleup" {
  count                  = "${element(split(",","0,2"), var.do_scale)}"
  name                   = "${var.service_name}-${var.environment}${element(split(",",",_green"), count.index)}-scaleup"
  scaling_adjustment     = "${var.scaleup_adjustment}"
  adjustment_type        = "ChangeInCapacity"
  autoscaling_group_name = "${element(split(",","${aws_autoscaling_group.blue.name},${aws_autoscaling_group.green.name}"),count.index)}"
  cooldown               = "${var.scale_up_cooldown}"
}

# Alarm to scale down if there are more healthy instances than we expect
resource "aws_cloudwatch_metric_alarm" "web_scaledown" {
  count               = "${element(split(",","0,2"), var.do_scale)}"
  alarm_name          = "${var.service_name}-${var.environment}${element(split(",",",_green"), count.index)}-scaledown"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = "${var.scale_down_consecutive_periods}"
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/EC2"
  period              = "${var.scale_down_period}"
  statistic           = "Average"
  threshold           = "${var.scale_down_threshold}"
  dimensions {
    LoadBalancerName = "${aws_elb.web.name}"
  }
  alarm_description   = "This metric monitors unhealthy hosts in ${aws_elb.web.name}"
  alarm_actions       = ["${element(aws_autoscaling_policy.web_scaledown.*.arn, count.index)}"]
}

# Alarm to scale up if there are fewer healthy instances than we expect
resource "aws_cloudwatch_metric_alarm" "web_scaleup" {
  count               = "${element(split(",","0,2"), var.do_scale)}"
  alarm_name          = "${var.service_name}-${var.environment}${element(split(",",",_green"), count.index)}-scaleup"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = "${var.scale_up_consecutive_periods}"
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/EC2"
  period              = "${var.scale_up_period}"
  statistic           = "Average"
  threshold           = "${var.scale_up_threshold}"
  dimensions {
    LoadBalancerName = "${aws_elb.web.name}"
  }
  alarm_description   = "This metric monitors healthy hosts in ${aws_elb.web.name}"
  alarm_actions       = ["${element(aws_autoscaling_policy.web_scaleup.*.arn, count.index)}"]
}

# BLUE autoscaling group
resource "aws_autoscaling_group" "blue" {
  availability_zones        = ["${split(",", var.availability_zones)}"]
  vpc_zone_identifier       = ["${split(",", var.subnets)}"]
  name                      = "${var.service_name}-${var.environment}"
  min_size                  = "${element(split(",","${var.asg_min_size},0"), var.is_in_green_mode)}"
  max_size                  = "${element(split(",","${var.asg_max_size},0"), var.is_in_green_mode)}"
  desired_capacity          = "${element(split(",","${var.asg_desired_capacity},0"), var.is_in_green_mode)}"
  health_check_grace_period = "${var.asg_health_check_grace_period}"
  health_check_type         = "${element(split(",","EC2,${var.health_check_type}"),var.allocate_elb)}"
  force_delete              = false
  launch_configuration      = "${aws_launch_configuration.web.name}"
  load_balancers            = ["${compact(split(",", "${join("",aws_elb.web.*.name)},${var.asg_load_balancers}"))}"]

  tag                       = {
    key                 = "${element(split(",","active,not_active"), var.is_in_green_mode)}"
    value               = "true"
    propagate_at_launch = false
  }

  tag                       = {
    key                 = "role"
    value               = "${var.company_name}-${var.service_name}"
    propagate_at_launch = true
  }

  tag                       = {
    key                 = "environment"
    value               = "${var.environment}"
    propagate_at_launch = true
  }

  tag                       = {
    key                 = "Name"
    value               = "autoscale-${var.service_name}-${var.environment}"
    propagate_at_launch = true
  }

  metrics_granularity       = "1Minute"

  enabled_metrics           = [
    "GroupMinSize",
    "GroupMaxSize",
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupPendingInstances",
    "GroupStandbyInstances",
    "GroupTerminatingInstances",
    "GroupTotalInstances"
  ]

  lifecycle {
    create_before_destroy = true
  }
}


# GREEN autoscaling group
resource "aws_autoscaling_group" "green" {
  availability_zones        = ["${split(",", var.availability_zones)}"]
  vpc_zone_identifier       = ["${split(",", var.subnets)}"]
  name                      = "${var.service_name}-${var.environment}-green"
  min_size                  = "${element(split(",","0,${var.asg_min_size}"), var.is_in_green_mode)}"
  max_size                  = "${element(split(",","0,${var.asg_max_size}"), var.is_in_green_mode)}"
  desired_capacity          = "${element(split(",","0,${var.asg_desired_capacity}"), var.is_in_green_mode)}"
  health_check_grace_period = "${var.asg_health_check_grace_period}"
  health_check_type         = "${element(split(",","EC2,${var.health_check_type}"),var.allocate_elb)}"
  force_delete              = false
  launch_configuration      = "${aws_launch_configuration.web.name}"
  load_balancers            = ["${compact(split(",", "${join("",aws_elb.web.*.name)},${var.asg_load_balancers}"))}"]

  tag                       = {
    key                 = "${element(split(",","not_active,active"), var.is_in_green_mode)}"
    value               = "true"
    propagate_at_launch = false
  }

  tag                       = {
    key                 = "role"
    value               = "${var.company_name}-${var.service_name}"
    propagate_at_launch = true
  }

  tag                       = {
    key                 = "environment"
    value               = "${var.environment}"
    propagate_at_launch = true
  }

  tag                       = {
    key                 = "Name"
    value               = "autoscale-${var.service_name}-${var.environment}-green"
    propagate_at_launch = true
  }

  metrics_granularity       = "1Minute"

  enabled_metrics           = [
    "GroupMinSize",
    "GroupMaxSize",
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupPendingInstances",
    "GroupStandbyInstances",
    "GroupTerminatingInstances",
    "GroupTotalInstances"
  ]

  lifecycle {
    create_before_destroy = true
  }

  count                     = "${var.allocate_green_asg}"
}

resource "aws_launch_configuration" "web" {
  image_id             = "${var.ami}"
  security_groups      = ["${compact(split(",", "${var.instance_security_group_ids}"))}"]
  instance_type        = "${var.instance_type}"
  user_data            = "${element(list(var.user_data, data.template_file.user_data.rendered), var.use_default_user_data)}"
  key_name             = "${var.key_name}"
  ebs_optimized        = "${var.ebs_optimized}"
  iam_instance_profile = "${aws_iam_instance_profile.instance_profile.name}"

  root_block_device {
    volume_type           = "${var.root_block_type}"
    volume_size           = "${var.root_block_size}"
    delete_on_termination = true
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes = ["image_id", "key_name"]
  }
}

output "elb_dns_name" {
  value = "${aws_elb.web.dns_name}"
}

output "elb_zone_id" {
  value = "${aws_elb.web.zone_id}"
}

output "asg_names" {
  value = "${aws_autoscaling_group.blue.name},${aws_autoscaling_group.green.name}"
}
