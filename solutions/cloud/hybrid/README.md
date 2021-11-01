# Executive Summary

The Nutanix Hybrid Cloud Validated Design details all the key decisions necessary to deploy a robust, resilient, and secure private cloud solution with two datacenters for high availability (HA) and disaster recovery (DR).

We based this Nutanix Validated Design (NVD) on our Hybrid Cloud Reference Architecture and can deliver it as a bundled solution for general server virtualization that includes hardware, software, and services to accelerate and simplify the deployment and implementation process.

# Audience

This guide is part of the [Nutanix Solutions Library](https://portal.nutanix.com/page/documents/solutions/list). We developed it for architects and engineers responsible for scoping, designing, installing, and testing server virtualization solutions. Readers of this document should already be familiar with the Nutanix Hybrid Cloud Reference Architecture.

# Helpers

## Calm

Relink Calm Apps in DR site using Calm DR tracking script, see that README for details.

## Flow

Synchronize Nutanix Flow Policies and categories between 2 Prism Central Instances, using Invoke-FlowRuleSync.ps1. See [KB 12253](https://portal.nutanix.com/kb/12253) for details.