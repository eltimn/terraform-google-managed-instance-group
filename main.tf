/*
 * Copyright 2017 Google Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

resource "google_compute_instance_template" "default" {
  count        = var.module_enabled ? 1 : 0
  project      = var.project
  name_prefix  = "default-"
  machine_type = var.machine_type

  region = var.region

  tags = concat(["allow-ssh"], var.target_tags)

  labels = var.instance_labels

  network_interface {
    network    = var.subnetwork == "" ? var.network : ""
    subnetwork = var.subnetwork

    access_config {
      nat_ip       = lookup(var.access_config, "nat_ip", null)
      network_tier = lookup(var.access_config, "network_tier", null)
    }

    network_ip         = var.network_ip
    subnetwork_project = var.subnetwork_project == "" ? var.project : var.subnetwork_project
  }

  can_ip_forward = var.can_ip_forward

  disk {
    auto_delete  = var.disk_auto_delete
    boot         = true
    source_image = var.compute_image
    type         = "PERSISTENT"
    disk_type    = var.disk_type
    disk_size_gb = var.disk_size_gb
    mode         = var.mode
  }

  service_account {
    email  = var.service_account_email
    scopes = var.service_account_scopes
  }

  metadata = merge(
    {
      "startup-script" = var.startup_script
      "tf_depends_id"  = var.depends_id
    },
    var.metadata,
  )

  scheduling {
    preemptible       = var.preemptible
    automatic_restart = var.automatic_restart
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_instance_group_manager" "default" {
  provider           = google-beta
  count              = var.module_enabled && var.zonal ? 1 : 0
  project            = var.project
  name               = var.name
  description        = "compute VM Instance Group"
  wait_for_instances = var.wait_for_instances
  base_instance_name = var.name

  version {
    name              = "${var.name}-default"
    instance_template = google_compute_instance_template.default[0].self_link
  }

  zone = var.zone
  dynamic "update_policy" {
    for_each = var.update_policy
    content {
      max_surge_fixed         = lookup(update_policy.value, "max_surge_fixed", null)
      max_surge_percent       = lookup(update_policy.value, "max_surge_percent", null)
      max_unavailable_fixed   = lookup(update_policy.value, "max_unavailable_fixed", null)
      max_unavailable_percent = lookup(update_policy.value, "max_unavailable_percent", null)
      min_ready_sec           = lookup(update_policy.value, "min_ready_sec", null)
      minimal_action          = update_policy.value.minimal_action
      type                    = update_policy.value.type
    }
  }

  target_pools = var.target_pools
  target_size  = var.size

  named_port {
    name = var.service_port_name
    port = var.service_port
  }

  auto_healing_policies {
    health_check = var.http_health_check ? element(
      concat(
        google_compute_health_check.mig-http-hc.*.self_link,
        google_compute_health_check.mig-https-hc.*.self_link,
      ),
      0,
    ) : ""
    initial_delay_sec = var.hc_initial_delay
  }

  # provisioner "local-exec" {
  #   when    = destroy
  #   command = var.local_cmd_destroy
  # }

  provisioner "local-exec" {
    when    = create
    command = var.local_cmd_create
  }
}

data "google_compute_zones" "available" {
  project = var.project
  region  = var.region
}

locals {
  distribution_zones = {
    default = data.google_compute_zones.available.names
    user    = var.distribution_policy_zones
  }

  dependency_id = element(
    concat(null_resource.region_dummy_dependency.*.id, ["disabled"]),
    0,
  )
}

resource "google_compute_region_instance_group_manager" "default" {
  provider           = google-beta
  count              = var.module_enabled && false == var.zonal ? 1 : 0
  project            = var.project
  name               = var.name
  description        = "compute VM Instance Group"
  wait_for_instances = var.wait_for_instances

  base_instance_name = var.name

  version {
    name              = "${var.name}-default"
    instance_template = google_compute_instance_template.default[0].self_link
  }

  region = var.region

  dynamic "update_policy" {
    for_each = var.update_policy
    content {
      max_surge_fixed         = lookup(update_policy.value, "max_surge_fixed", null)
      max_surge_percent       = lookup(update_policy.value, "max_surge_percent", null)
      max_unavailable_fixed   = lookup(update_policy.value, "max_unavailable_fixed", null)
      max_unavailable_percent = lookup(update_policy.value, "max_unavailable_percent", null)
      min_ready_sec           = lookup(update_policy.value, "min_ready_sec", null)
      minimal_action          = update_policy.value.minimal_action
      type                    = update_policy.value.type
    }
  }

  distribution_policy_zones = [local.distribution_zones[length(var.distribution_policy_zones) == 0 ? "default" : "user"]]

  target_pools = var.target_pools
  target_size  = var.size

  auto_healing_policies {
    health_check = var.http_health_check ? element(
      concat(
        google_compute_health_check.mig-http-hc.*.self_link,
        google_compute_health_check.mig-https-hc.*.self_link,
      ),
      0,
    ) : ""
    initial_delay_sec = var.hc_initial_delay
  }

  named_port {
    name = var.service_port_name
    port = var.service_port
  }

  # provisioner "local-exec" {
  #   when    = destroy
  #   command = var.local_cmd_destroy
  # }

  provisioner "local-exec" {
    when    = create
    command = var.local_cmd_create
  }

  // Initial instance verification can take 10-15m when a health check is present.
  timeouts {
    create = var.http_health_check ? "15m" : "5m"
  }
}

resource "null_resource" "dummy_dependency" {
  count      = var.module_enabled && var.zonal ? 1 : 0
  depends_on = [google_compute_instance_group_manager.default]

  triggers = {
    instance_template = google_compute_instance_template.default[0].self_link
  }
}

resource "null_resource" "region_dummy_dependency" {
  count      = var.module_enabled && false == var.zonal ? 1 : 0
  depends_on = [google_compute_region_instance_group_manager.default]

  triggers = {
    instance_template = google_compute_instance_template.default[0].self_link
  }
}

resource "google_compute_firewall" "default-ssh" {
  count   = var.module_enabled && var.ssh_fw_rule ? 1 : 0
  project = var.subnetwork_project == "" ? var.project : var.subnetwork_project
  name    = "${var.name}-vm-ssh"
  network = var.network

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = var.ssh_source_ranges
  target_tags   = ["allow-ssh"]
}

resource "google_compute_health_check" "mig-http-hc" {
  count   = var.module_enabled && var.http_health_check ? 1 : 0
  name    = var.name
  project = var.project

  check_interval_sec  = var.hc_interval
  timeout_sec         = var.hc_timeout
  healthy_threshold   = var.hc_healthy_threshold
  unhealthy_threshold = var.hc_unhealthy_threshold

  http_health_check {
    port         = var.hc_port == "" ? var.service_port : var.hc_port
    request_path = var.hc_path
  }
}

resource "google_compute_health_check" "mig-https-hc" {
  count   = var.https_health_check ? 1 : 0
  name    = var.name
  project = var.project

  check_interval_sec  = var.hc_interval
  timeout_sec         = var.hc_timeout
  healthy_threshold   = var.hc_healthy_threshold
  unhealthy_threshold = var.hc_unhealthy_threshold

  https_health_check {
    port         = var.hc_port == "" ? var.service_port : var.hc_port
    request_path = var.hc_path
  }
}

resource "google_compute_firewall" "mig-health-check" {
  count   = var.module_enabled && var.http_health_check ? 1 : 0
  project = var.subnetwork_project == "" ? var.project : var.subnetwork_project
  name    = "${var.name}-vm-hc"
  network = var.network

  allow {
    protocol = "tcp"
    ports    = [var.hc_port == "" ? var.service_port : var.hc_port]
  }

  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = var.target_tags
}

data "google_compute_instance_group" "zonal" {
  count   = var.zonal ? 1 : 0
  zone    = var.zone
  project = var.project

  // Use the dependency id which is recreated whenever the instance template changes to signal when to re-read the data source.
  name = element(
    split(
      "|",
      "${local.dependency_id}|${element(
        concat(
          google_compute_instance_group_manager.default.*.name,
          ["unused"],
        ),
        0,
      )}",
    ),
    1,
  )
}

