variable "ami" {}
variable "availability_zones" {}
variable "company_name" {}
variable "elb_subnets" {}
variable "environment" {}
variable "key_name" {}
variable "region" {}
variable "region_abbrev" {}
variable "service_name" {}
variable "ssl_certificate_id" {}
variable "subnets" {}
variable "vpc_id" {}
variable "zone_id" {}

variable "allocate_elb" {
  default = 1
}
variable "allocate_green_asg" {
  default = 1
}
variable "domain" {
  description = "Used to determine which hosted zone the new DNS record should be created in."
}

variable "instance_type" {
  default = "t2.nano"
}

variable "root_block_size" {
  default = "10"
}

variable "health_check_type" {}

variable "asg_min_size" {
  default = 2
}

variable "asg_max_size" {
  default = 4
}

variable "asg_desired_capacity" {
  default = 2
}

variable "asg_health_check_grace_period" {
  default = 900
}

variable "asg_load_balancers" {
  default = ""
}

variable "elb_security_group_id" {}
variable "instance_security_group_ids" {}

variable "is_in_green_mode" {
  default = 0
}

variable "health_check_interval" {
  default = 15
}

variable "num_elb_health_checks" {
  default = 2
}

variable "use_default_user_data" {
  default = 1
}

variable "user_data" {
  default = ""
}

variable "health_check_path" {
  default = "HTTP:8080/status"
}

variable "scale_down_consecutive_periods" {
  default = 2
}

variable "scale_down_period" {
  default = 300
}

variable "scaledown_adjustment" {
  default = -2
}

variable "scaleup_adjustment" {
  default = 2
}

variable "scale_up_period" {
  default = 300
}

variable "scale_up_consecutive_periods" {
  default = 1
}

variable "scale_down_cooldown" {
  default = 300
}

variable "scale_up_cooldown" {
  default = 100
}

variable "scale_down_threshold" {
  default = 0
}

variable "scale_up_threshold" {
  default = 1
}

variable "do_scale" {
  default = 0
}

variable "ebs_optimized" {
  default = true
}

variable "root_block_type" {
  default = "standard"
}

variable "no_lb_stickiness" {
  default = 0
}

variable "has_custom_role_policy" {
  default = 0
}

variable "custom_role_policy_arn" {
  default = ""
}
