# Azure Infrastructure Resources

resource "tls_private_key" "global_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "local_file" "ssh_private_key_pem" {
  filename          = "${path.module}/id_rsa"
  sensitive_content = tls_private_key.global_key.private_key_pem
  file_permission   = "0600"
}

resource "local_file" "ssh_public_key_openssh" {
  filename = "${path.module}/id_rsa.pub"
  content  = tls_private_key.global_key.public_key_openssh
}


# Resource group containing all resources
resource "azurerm_resource_group" "rancher" {
  name     = "${var.prefix}-${var.resource_group_name}"
  location = var.azure_location

  tags = {
    Resource_owner = var.tag_resource_owner,
    Group          = var.tag_group,
    Department     = var.tag_department,
    Stakeholder    = var.tag_stakeholder,
    Environment    = var.tag_environment,
    Project        = var.tag_project
  }
}

# Azure virtual network space for the resource group
resource "azurerm_virtual_network" "rancher" {
  name                = "${var.prefix}-rancher-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rancher.location
  resource_group_name = azurerm_resource_group.rancher.name
}

# Azure subnet for rancher server
resource "azurerm_subnet" "rancher-subnet" {
  name                 = "rancher-subnet"
  resource_group_name  = azurerm_resource_group.rancher.name
  virtual_network_name = azurerm_virtual_network.rancher.name
  address_prefixes     = ["10.0.0.0/24"]
}

# Public IP of Rancher server
resource "azurerm_public_ip" "rancher-server-pip" {
  name                = "rancher-server-pip"
  location            = azurerm_resource_group.rancher.location
  resource_group_name = azurerm_resource_group.rancher.name
  allocation_method   = var.rancher_server_use_static_public_ip ? "Static" : "Dynamic"
}

# Azure network interface for rancher server
resource "azurerm_network_interface" "rancher-server-nic" {
  name                = "rancher-server-nic"
  location            = azurerm_resource_group.rancher.location
  resource_group_name = azurerm_resource_group.rancher.name

  ip_configuration {
    name                          = "rancher_server_ip_config"
    subnet_id                     = azurerm_subnet.rancher-subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.rancher-server-pip.id
  }

}

# Azure linux virtual machine for creating a single node RKE cluster and installing the Rancher Server
resource "azurerm_linux_virtual_machine" "rancher_server" {
  name                  = "${var.prefix}-rancher-server"
  computer_name         = "rancher-server" // ensure computer_name meets 15 character limit
  location              = azurerm_resource_group.rancher.location
  resource_group_name   = azurerm_resource_group.rancher.name
  network_interface_ids = [azurerm_network_interface.rancher-server-nic.id]
  size                  = var.rancher_server_vm_size
  admin_username        = local.node_username

  license_type = "SLES_BYOS"
  source_image_reference {
    publisher = "SUSE"
    offer     = "sles-15-sp3"
    sku       = "gen1"
    version   = "latest"
  }

  admin_ssh_key {
    username   = local.node_username
    public_key = tls_private_key.global_key.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for cloud-init to complete...'",
      "cloud-init status --wait > /dev/null",
      "echo 'Completed cloud-init!'",
    ]

    connection {
      type        = "ssh"
      host        = self.public_ip_address
      user        = local.node_username
      private_key = tls_private_key.global_key.private_key_pem
    }
  }
}

# ssh command file for Rancher Server VM
resource "local_file" "ssh_to_rancher_server" {
  filename        = "${path.module}/ssh_rancher_server.sh"
  content         = join(" ", ["ssh", "-i id_rsa", "-o StrictHostKeyChecking=no", "${local.node_username}@${azurerm_linux_virtual_machine.rancher_server.public_ip_address}"])
  file_permission = "0755"
}

# Rancher bootstrap password
resource "random_password" "rancher_server_password" {
  length           = 16
  special          = true
  override_special = "_%@"
}

# Rancher resources
module "rancher_server" {
  source = "../../../terraform-modules/rancher"

  node_public_ip      = azurerm_linux_virtual_machine.rancher_server.public_ip_address
  node_internal_ip    = azurerm_linux_virtual_machine.rancher_server.private_ip_address
  node_username       = local.node_username
  ssh_private_key_pem = tls_private_key.global_key.private_key_pem

  rancher_server_dns                = join(".", ["rancher", azurerm_linux_virtual_machine.rancher_server.public_ip_address, "sslip.io"])
  rancher_server_bootstrap_password = random_password.rancher_server_password.result

  windows_prefered_cluster = var.add_windows_node
}


# ----------------------------------------------------------------
# Create RKE2 downstream cluster
# ----------------------------------------------------------------


# Azure subnet for RKE2 clusters
resource "azurerm_subnet" "rke2-subnet" {
  name                 = "rke2-subnet"
  resource_group_name  = azurerm_resource_group.rancher.name
  virtual_network_name = azurerm_virtual_network.rancher.name
  address_prefixes     = ["10.0.1.0/24"]
}

# ----------------------------------------------------------------
# Create downstream RKE2 cluster in Rancher UI
# ----------------------------------------------------------------

# Public IP of rke2 server
resource "azurerm_public_ip" "rke2-nodes-pip" {
  count               = var.no_of_downstream_clusters
  name                = format("rke2-node%d-pip", count.index + 1)
  location            = azurerm_resource_group.rancher.location
  resource_group_name = azurerm_resource_group.rancher.name
  allocation_method   = var.rancher_server_use_static_public_ip ? "Static" : "Dynamic"

}

# Azure network interface for rke2 server
resource "azurerm_network_interface" "rke2-nodes-nic" {
  count               = var.no_of_downstream_clusters
  name                = format("rke2-node%d-nic", count.index + 1)
  location            = azurerm_resource_group.rancher.location
  resource_group_name = azurerm_resource_group.rancher.name

  ip_configuration {
    name                          = format("rke2-node%d_ip_config", count.index + 1)
    subnet_id                     = azurerm_subnet.rke2-subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.rke2-nodes-pip[count.index].id
  }
}

# Azure linux virtual machine for RKE2 node
resource "azurerm_linux_virtual_machine" "rke2_node" {
  count                 = var.no_of_downstream_clusters
  name                  = format("${var.prefix}-rke2-node%d", count.index + 1)
  computer_name         = format("rke2-node%d", count.index + 1) // ensure computer_name meets 15 character limit
  location              = azurerm_resource_group.rancher.location
  resource_group_name   = azurerm_resource_group.rancher.name
  network_interface_ids = [azurerm_network_interface.rke2-nodes-nic[count.index].id]
  size                  = var.rke2_node_vm_size
  admin_username        = local.node_username

  # custom_data = base64encode(
  #   templatefile(
  #     join("/", [path.module, "files/rke2_node.template"]),
  #     {
  #       register_command = rancher2_cluster_v2.rke2_clusters[count.index].cluster_registration_token.0.insecure_node_command
  #     }
  #   )
  # )

  license_type = "SLES_BYOS"
  source_image_reference {
    publisher = "SUSE"
    offer     = "sles-15-sp3"
    sku       = "gen1"
    version   = "latest"
  }

  admin_ssh_key {
    username   = local.node_username
    public_key = tls_private_key.global_key.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 60
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for cloud-init to complete...'",
      "cloud-init status --wait > /dev/null",
      "echo 'Completed cloud-init!'",
      format("%s --etcd --controlplane --worker --address %s", rancher2_cluster_v2.rke2_clusters[count.index].cluster_registration_token.0.insecure_node_command, self.public_ip_address)
    ]

    connection {
      type        = "ssh"
      host        = self.public_ip_address
      user        = local.node_username
      private_key = tls_private_key.global_key.private_key_pem
    }
  }
}

# ssh command file for RKE2 nodes VM
resource "local_file" "ssh_to_rke2_clusters" {
  count           = var.no_of_downstream_clusters
  filename        = format("${path.module}/ssh_rke2-cluster%d.sh", count.index + 1)
  content         = join(" ", ["ssh", "-i id_rsa", "-o StrictHostKeyChecking=no", "${local.node_username}@${azurerm_linux_virtual_machine.rke2_node[count.index].public_ip_address}"])
  file_permission = "0755"
}


resource "rancher2_cluster_v2" "rke2_clusters" {
  count    = var.no_of_downstream_clusters
  provider = rancher2.admin
  name                                     = format("cluster%d", count.index + 1)
  kubernetes_version                       = "v1.24.4+rke2r1" # use the tags in here: https://hub.docker.com/r/rancher/system-agent-installer-rke2/tags
  enable_network_policy                    = false
  default_cluster_role_for_project_members = "user"
}

resource "rancher2_cluster_sync" "cluster_sync" {
  provider      = rancher2.admin
  count         = var.no_of_downstream_clusters
  cluster_id    = rancher2_cluster_v2.rke2_clusters[count.index].cluster_v1_id
  wait_catalogs = true
  state_confirm = 24 # try to confirm the active state for 12 times x 5s-interval (2 min)
}

# kubeconfig file for RKE2 clusters
resource "local_file" "rke2_clusters_kubeconfig" {
  count           = var.no_of_downstream_clusters
  filename        = format("${path.module}/kubeconfig-cluster%d.yaml", count.index + 1)
  content         = rancher2_cluster_sync.cluster_sync[count.index].kube_config
  file_permission = "0600"
}

# Enable longhorn on the RKE2 clusters
resource "rancher2_app_v2" "longhorn" {
  provider      = rancher2.admin
  count         = var.no_of_downstream_clusters
  cluster_id    = rancher2_cluster_v2.rke2_clusters[count.index].cluster_v1_id # See https://github.com/rancher/terraform-provider-rancher2/issues/848
  name          = "longhorn"
  namespace     = "longhorn-system"
  repo_name     = "rancher-charts"
  chart_name    = "longhorn"
  chart_version = "100.2.3+up1.3.2"
  values        = file(join("/", [path.module, "files/longhorn-values.yaml"]))
  timeouts {
    create = "30m"
    delete = "30m"
  }
}

