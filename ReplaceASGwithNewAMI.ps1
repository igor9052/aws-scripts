 <#
 .SYNOPSIS
This script is for replacing AMI in all existing servers of the specified auto scaling group with the new one.

.DESCRIPTION
 Only one server can be unavailable (unhealthy) during any given moment of upgrade.

 Script accepts:
 - Auto scaling group id
 - New AMI id

.EXAMPLE

ReplaceASGwithNewAMI.ps1 -ASGName "ASG-Test" -AMIId "ami-0a313d6098716f372"

.NOTES
AMI Id for test: ami-0a313d6098716f372 or ami-0de53d8956e8dcf80 ; ASG for test: ASG-Test or use yours

.LINK
https://github.com/igor9052/aws-scripts
 
 #>
 
 param(
    [Parameter(Mandatory=$true)]
    [string]$ASGName="ASG-Test",
    [Parameter(Mandatory=$true)]
    [string]$AMIId="ami-0a313d6098716f372" 
 )

 # Polling interval
 $PollingInterval = 15
 
 # Get ASG object
 $ASGroup = Get-ASAutoScalingGroup -AutoScalingGroupName $ASGName

 # Check if AS Group is found. Exit script if there is no such ASG.
 if ($null -eq $ASGroup) {
    Write-Output "ASG Name <<$ASGName>> hasn't been found!"
    exit
 }

 # Check if specified AMI is found
 $AMI = Get-EC2Image -ImageId $AMIId
 if ($null -eq $AMI) {
    Write-Output "AMI <<$AMIId>> hasn't been found!"
    exit
 }

# Get Launch Configuration assigned to Auto Scaling Group
$LaunchConfig = Get-ASLaunchConfiguration $ASGroup.LaunchConfigurationName

# Generate a new name with a random hexadecimal suffix
# TODO replace a suffix if it is already appended?
$NewLaunchConfigName = $LaunchConfig.LaunchConfigurationName+"-{0:x}" -f (Get-Random -Minimum 1048576 -Maximum 16777215)

# Create a new Launch Configuration
# New-ASLaunchConfiguration -LaunchConfigurationName $NewLaunchConfigName -ImageId $AMIId -InstanceType $LaunchConfig.InstanceType
New-ASLaunchConfiguration -LaunchConfigurationName $NewLaunchConfigName `
-ImageId $AMIId `
-KeyName $LaunchConfig.KeyName `
-SecurityGroup $LaunchConfig.SecurityGroups `
-AssociatePublicIpAddress $LaunchConfig.AssociatePublicIpAddress `
-BlockDeviceMapping $LaunchConfig.BlockDeviceMappings `
-ClassicLinkVPCId $LaunchConfig.ClassicLinkVPCId `
-ClassicLinkVPCSecurityGroup $LaunchConfig.ClassicLinkVPCSecurityGroups `
-EbsOptimized $LaunchConfig.EbsOptimized `
-InstanceMonitoring_Enabled $LaunchConfig.InstanceMonitoring.Enabled `
-IamInstanceProfile $LaunchConfig.IamInstanceProfile `
-InstanceType $LaunchConfig.InstanceType `
-KernelId $LaunchConfig.KernelId `
-PlacementTenancy $LaunchConfig.PlacementTenancy `
-RamdiskId $LaunchConfig.RamdiskId `
-SpotPrice $LaunchConfig.SpotPrice `
-UserData $LaunchConfig.UserData `
-Force

# Update ASG with a new LaunchConfiguration
Update-ASAutoScalingGroup -AutoScalingGroupName $ASGName -LaunchConfigurationName $NewLaunchConfigName

# Check that new Launch configuration is assigned to ASG
Write-Output "New Launch configuration <<$((Get-ASAutoScalingGroup -AutoScalingGroupName $ASGName).LaunchConfigurationName)>> is set."

# Check MaxSize and adjust it to be more than Desired Capacity.
if ($ASGroup.DesiredCapacity -eq $ASGroup.MaxSize) {
    Update-ASAutoScalingGroup -AutoScalingGroupName $ASGName -MaxSize ($ASGroup.DesiredCapacity+1)
}

$InstanceCount = (Get-ASAutoScalingGroup -AutoScalingGroupName $ASGName).Instances.Count
Write-Output "Number of instances: $InstanceCount"
Write-Output "Starting to replace instances..."


# Main loop. Increase desired capacity, Wait while new instance become available. Decrease desired capacity, wait while instance is terminated. Repeat.
while ($InstanceCount -gt 0) {
    # Increase Desired Capacity by 1. In this case a new instance is started (with new launch config)
    Update-ASAutoScalingGroup -AutoScalingGroupName $ASGName -DesiredCapacity ($ASGroup.DesiredCapacity+1)
    
    # Wait till new instance is started
    while ((Get-ASAutoScalingGroup -AutoScalingGroupName $ASGName).Instances.Count -ne ($ASGroup.DesiredCapacity+1)) {
        Write-Output "Waiting for reaching desired capacity (adding instance)..."
        Start-Sleep -Seconds $pollinginterval
    }

    # Get instances ids (new one is included)
    $InstanceIds = ((Get-ASAutoScalingGroup -AutoScalingGroupName $ASGName).Instances).InstanceId
    Write-Output "Instances ids: $InstanceIds"

    # Set Desired Capacity to the original value. In this case one if instance (with old launch config) is terminated automatically
    Update-ASAutoScalingGroup -AutoScalingGroupName $ASGName -DesiredCapacity $ASGroup.DesiredCapacity

    # Wait while status of new instance becomes ok
    # TODO investigate another options to be sure that instance is up and running
    foreach ($id in $InstanceIds) {        
        while ((Get-EC2InstanceStatus -InstanceId $id).Status.Status -ne "ok") {
            Write-Output "Waiting for status of instance $id to be Ok"
            Start-Sleep -Seconds $PollingInterval
        }
    }
    
    # if instantcount = 1 (last iteration) no needs to wait until image is terminated.
    if ($InstanceCount -gt 1) {
        # wait until terminated instance is not removed
        while ((Get-ASAutoScalingGroup -AutoScalingGroupName $ASGName).Instances.Count -ne $ASGroup.DesiredCapacity) {
            Write-Output "Waiting for reaching desired capacity (terminating instance)..."
            Start-Sleep -Seconds $pollinginterval
        }    
    }
    $InstanceCount--
}

# Check that all new instances have new AMI image
$NewInstanceIds = ((Get-ASAutoScalingGroup -AutoScalingGroupName $ASGName).Instances).InstanceId
foreach ($id in $NewInstanceIds) {
    $ImageId = (Get-EC2Instance -InstanceId $id).Instances[0].ImageId
    if ($ImageId -eq $AMIId) {
        $Status = (Get-ASAutoScalingInstance -InstanceId $id).LifecycleState
        Write-Output "Instance $id has been updated with AMI Image: $AMIId. Status: $Status"
    }
    else {
        $Status = (Get-ASAutoScalingInstance -InstanceId $id).LifecycleState
        Write-Output "Instance $id has a wrong AMI Image: $ImageId, but it is: $Status"
    }        
}


Write-Output "Done!"
