#! /usr/bin/perl -w

#################################################################################
# No part of this program may be reproduced or transmitted in any form or by any
# means, electronic or mechanical, including photocopying, recording, or
# information storage and retrieval systems, for any purpose other than the
# purchaser's personal use, without the express written permission of F5
# Networks, Inc.
# 
# F5 Networks and BIG-IP (c) Copyright 2008, 2012-2016. All rights reserved.
#################################################################################

# set the version of this script
my $program = $0;
$program = `basename $program`;
chomp $program;
my $version = "v2.00.00";

## CHANGE QUEUE
# rewritten for BigIQ 5.x

## DESCRIPTION
# This script reads a CSV file containing a list of BIG-IPs and then:
# - Discovers the device for each specified module
# - Imports the configuration for each specified module
# If a failure is encountered the script logs the error and continues.
# If conflicts are detected, the BigIQ version is selected.
# A summary of activity, errors, and device counts is given at the end of the script.
#
# CSV file format:
# - with creds:                        big_ip_adr,admin_user,admin_pw
# - creds from command line:           big_ip_adr
# - cluster with creds:                big_ip_adr,admin_user,admin_pw,ha-name
# - cluster, creds from command line:  big_ip_adr,,,ha-name
# Framework 
# - skip check (viprion):              big_ip_adr,admin_user,admin_pw,ha-name, skip
# - update:                            big_ip_adr,admin_user,admin_pw,ha-name, upate, root_user, root_pw

use JSON;     # a Perl library for parsing JSON - supports encode_json, decode_json, to_json, from_json
use Time::HiRes qw(gettimeofday);
use Data::Dumper qw(Dumper);    # for debug
use File::Temp qw(tempfile);

#use strict;
#use warnings;

my $section_head = "###########################################################################################";
my $table_head = "#------------------------------------------------------------------------------------------";
my $overallStartTime = gettimeofday();

# some globals
#$col1Fmt = "%-18s"; 
#$colFmt = "%-15s"; 

# log file
my $log = "bulkReImport.$$.log";
open (LOG, ">$log") || die "Unable to write the log file, '$log'\n";
&printAndLog(STDOUT, 1, "#\n# Program: $program  Version: $version\n");

# get input from the caller
use Getopt::Std;

my %usage = (
    "h" =>  "Help",
    "c" =>  "Path to CSV file with all BIG-IP devices - REQUIRED",
    "q" =>  "BIG-IQ admin credentials in form admin:password - REQUIRED if not using default",
    "k" =>  "Keep the CSV file after this finishes (not recommended if it contains creds)",
    "a" =>  "Admin credentials for every BIG-IP (such as admin:admin) - overrides any creds in CSV",
    "r" =>  "Root credentials for every BIG-IP (such as root:default) - overrides root creds in CSV",
    "u" =>  "Update framework if needed",
    "g" =>  "access group name if needed",
    "l" =>  "Discover LTM",
    "p" =>  "Discover APM",
    "s" =>  "Discover ASM",
    "f" =>  "Discover AFM",
    "v" =>  "Verbose screen output",
);

our($opt_h,$opt_c,$opt_q,$opt_k,$opt_a,$opt_r,$opt_u,$opt_g); 
our($opt_l,$opt_p,$opt_s,$opt_f,$opt_v,); 
getopts('hc:q:ka:r:g:lpsfvu');
if (defined $opt_h && $opt_h) {
    print "Discover multiple BIG-IP devices.\n";
    foreach my $opt (keys %usage) {
        print ("\t-$opt\t$usage{$opt}\n");
    }
    print "\ncsv format: ip, user, pw, cluster-name, framework-action, root-user, root-pw\n";
    print "  ip: ip address of the BigIP to discover.\n";
    print "  user, pw: username & password of the BigIP.  Will be overridden if -a is specified on the command line.\n";
    print "  cluster-name\n";
    print "  framework-action: update - update framework if needed, skip - skip framwwork update check, blank - do not attempt to update te\n";
    print "  root-user, root-password: only needed for framework update of 11.5.1 through 11.6.0 devices\n";

#    print "csv format: ip, user, pw, ha-name\n";
    print "\nexample lines:\n";
    print "  1.2.3.4\n";
    print "  1.2.3.4, admin, pw\n";
    print "  1.2.3.4, admin, pw, ha-name\n";
    print "  1.2.3.4,,, ha-name\n";
    print "  1.2.3.4, admin, pw,, skip\n";
    print "  1.2.3.4, admin, pw,, update, root, root-pw\n";
    exit;
}

# See if we got the input we needed, bail with an error if we didn't
my $bailOut = 0;
if (!defined $opt_c) {
    &printAndLog(STDERR, 1, "Please use -c to provide the path to the .csv file.\n");
    $bailOut = 1;
} elsif (!(-e $opt_c)) {
    &printAndLog(STDERR, 1, "Could not find the .csv file, '$opt_c'.\n");
    &printAndLog(STDERR, 1, "  Please use the -c option to provide a path to a valid .csv file.\n");
    $bailOut = 1;
}

if ($bailOut) {
    &gracefulExit(1);
}

# useful stuff for JSON
my $contType = "Content-Type: application/json";
my $bigiqCreds = "admin:admin";
if (defined $opt_q) {
    $bigiqCreds = $opt_q;
}

# ======================================================
# Import the .csv file, validate it, and (if optional 
# credentials were supplied) rewrite it for Device.
# ======================================================
# parse the user-supplied creds
#my ($bigIPadmin, $bigIPadminPW, $bigIProot, $bigIProotPW) = ("", "", "", "");
my ($bigIPadmin, $bigIPadminPW) = ("", "");
if (defined $opt_a) {
    if ($opt_a =~ /^([^:]+):(\S+)$/) {
        ($bigIPadmin, $bigIPadminPW) = ($1, $2);
        if (defined $opt_r) {
            if ($opt_r =~ /^([^:]+):(\S+)$/) {
                ($bigIProot, $bigIProotPW) = ($1, $2);
            } else {
                &printAndLog(STDERR, 1, "## ERROR - '-r $opt_r' is invalid.  Please use the format, <username>:<password>.\n");
                &gracefulExit(1);
            }
        }
    } else {
        &printAndLog(STDERR, 1, "## ERROR - '-a $opt_a' is invalid.  Please use the format, <username>:<password>.\n");
        &gracefulExit(1);
    }
}

# read the CSV file, and replace creds with the user-supplied creds as needed
open (CSV, "$opt_c") || die "## ERROR: Unable to read the .csv file, '$opt_c'\n";
my @csvLns = <CSV>;
close CSV;
my @bigips;

my $index = 0;
foreach my $ln (@csvLns) {
    chomp $ln;
    $ln =~ s/[\cM\cJ]+//g;  # some editors tack multiple such chars at the end of each line
    $ln =~ s/^\s+//;        # trim leading whitespace
    $ln =~ s/\s+$//;        # trim trailing whitespace

    # skip blank lines
    if ($ln eq '') {
        next;
    }

    # skip comments
    if ($ln =~ /^\s*#/) {
        next;
    }

    # parse line
    my ($mip, $aname, $apw, $haname, $fwUpg, $ruser, $rpwd) = split(/\s*,\s*/, $ln);

    if ($opt_a) {
        $aname = $bigIPadmin;
        $apw = $bigIPadminPW;
    }

    if ((not defined $aname) or (not defined $apw)) {
        print "$ln\n";
        print "missing credentials. Must specify in \n";
        &gracefulExit(1);
    }

    if (defined $fwUpg) {
        if (($fwUpg ne "upgrade") and ($fwUpg ne "skip")) {
            print "$ln\n";
            print "invalid framwwork option: $fwUpg. Must be upgrade, skip, or blank\n";
            &gracefulExit(1);
        }
        if ($fwUpg eq "upgrade") {
            if ($opt_r) {
                $ruser = $bigIProot;
                $rpwd = $bigIProotPW;
            }
            if ((not defined $ruser) or (not defined $rpwd)) {
                print "$ln\n";
                print "missing root credentials for framwwork update\n";
                &gracefulExit(1);
            }
        }
    }

    # remember parameters for each device (in file order)
    $bigips[$index]{"mip"} = $mip;
    $bigips[$index]{"aname"} = $aname;
    $bigips[$index]{"apw"} = $apw;
    $bigips[$index]{"haname"} = $haname;
    $bigips[$index]{"fwUpg"} = $fwUpg;
    $bigips[$index]{"ruser"} = $ruser;
    $bigips[$index]{"rpwd"} = $rpwd;

    $index++;
}

#======================================================
# Make sure the BIG-IQ API is available
# Check for available over timeout period (120 sec)
# Exit if not available during this period
#======================================================
my $timeout = 120;
my $perform_check4life = 1;
my $check4lifeStart = gettimeofday();

while($perform_check4life) {
    my $timestamp = getTimeStamp();
    my $check4life = "curl --connect-timeout 5 -s -u $bigiqCreds --insecure https://localhost/info/system";
    my $isAlive = &callCurl ($check4life, "verifying that the BIG-IQ is able to respond", $opt_v);
    
    # Check for API availability
    if ((defined $isAlive->{"available"}) && ($isAlive->{"available"} eq "true")) {
        &printAndLog(STDOUT, 1, "#\n# BIG-IQ UI is available:         $timestamp\n");
        $perform_check4life = 0;
    } else {
        &printAndLog(STDOUT, 1, "# BIG-IQ UI is not yet available: $timestamp\n");    
    }
    
    # Exit on timeout
    if ((gettimeofday() - $check4lifeStart) > $timeout) {
        &printAndLog(STDERR, 1, "## ERROR: The BIG-IQ UI is still not available.  Try again later...\n");
        &gracefulExit(1);
    }
    sleep 10;
}

#======================================================
# Check the BIG-IQ version
#======================================================
my $checkVer = "curl -sku $bigiqCreds -X GET http://localhost:8100/mgmt/shared/resolver/device-groups/cm-shared-all-big-iqs/devices?\\\$select=version";
my $versionCheck = &callCurl ($checkVer, "checking BIG-IQ version", $opt_v);
my $bqVersion = $versionCheck->{"items"}[0]->{"version"};
if ($bqVersion lt "5.0.0") {
        &printAndLog(STDERR, 1, "## ERROR: not supported in version '$bqVersion'.\n");
        &gracefulExit(1);
}

#======================================================
# Log start time  
#======================================================

my $overallStart = gettimeofday();
&printAndLog(STDOUT, 1, "#\n# $section_head\n");
my $timestamp = getTimeStamp();
&printAndLog(STDOUT, 1, "#\n# Start overall discovery: $timestamp\n");


# Initialize Device status table
my %DeviceStatus;
$DeviceStatus{"all"}{"success"} = 0;
$DeviceStatus{"all"}{"already"} = 0;
$DeviceStatus{"all"}{"failure"} = 0;
$DeviceStatus{"all"}{"conflict"} = 0;

#======================================================
# Main loop
# Process Re Discovery, and Imports
#======================================================
my $i = 0;
for $bigip (@bigips) {
    my $mip = $bigip->{"mip"};
    my $user = $bigip->{"aname"};
    my $pw = $bigip->{"apw"};

    my $deviceStart = gettimeofday();
    $timestamp = getTimeStamp();
    my $deviceCmd = "curl -s -k -u $bigiqCreds -H \"$contType\" -X GET https://localhost/mgmt/shared/resolver/device-groups/cm-bigip-allBigIpDevices/devices";

    my $devices = &callCurl ($deviceCmd, "Get all devices discovered for BIGIQ $mip", $opt_v);
    my $done = 0;
    my $successStatus = 0;  

    while (not $done) {
        if ($mip eq $devices->{"items"}[$i]->{"address"}) {
	    &printAndLog(STDOUT, 1, "Found device BIG-IP - $mip: $timestamp\n");
	    if ($devices->{"items"}[$i]->{"product"} eq "BIG-IP") {
		my $machineId = $devices->{"items"}[$i]->{machineId};

		if (discoverModules($mip, $machineId)) {
		    if (importModules($mip, $machineId)) {
			$successStatus = 1;
		    }
		}
	    } else {
		print "Ignore BIG-IQ if in device list.\n"
	    };
	    $done = 1;
	    $i++;		
	} else {
	    &printAndLog(STDOUT, 1, "Continue to look for device BIG-IP - $mip: $timestamp\n");
	    $i++;
	    sleep 2;
	}
    }

    # We need discovery, and all imports to be successful before we increment the success count
    if ($successStatus eq 1)
    {
        $DeviceStatus{"all"}{"success"}++;
    }
    else
    {
        $DeviceStatus{"all"}{"failure"}++;
    }

    my $deviceEnd = gettimeofday();
    $et = sprintf("%d", $deviceEnd - $deviceStart);
    $timestamp = getTimeStamp();
    &printAndLog(STDOUT, 1, "$mip Finished:  $timestamp\n");
    &printAndLog(STDOUT, 1, "$mip Elapsed time:  $et seconds\n");

} # end for devices

$timestamp = getTimeStamp();
&printAndLog(STDOUT, 1, "\n# End overall discovery:  $timestamp\n");

my $overallEnd = gettimeofday();
my $et = $overallEnd - $overallStart;
my $hours = ($et / 3600) % 24;
my $minutes = ($et / 60) % 60;
my $seconds = $et % 60;
my $et_fmt = sprintf ("%d hours, %d minutes, %d seconds\n", $hours, $minutes, $seconds);
&printAndLog(STDOUT, 1, "# Overall elapsed time:  $et_fmt\n");

#======================================================
# Show results.
#======================================================

showTotals();

#======================================================
# Finish up
#======================================================
&gracefulExit(0);

#======================================================
# A subroutine to get the machine id.
#======================================================
sub getMachineId {
    my ($mip) = @_;

    # get the machine id for the already trusted device using the finished trust task
    my $trustCmd = "curl -s -k -u $bigiqCreds -H \"$contType\" -X GET \"https://localhost/mgmt/cm/global/tasks/device-trust?\\\$filter=address+eq+\'$mip\'+and+status+eq+\'FINISHED\'\"";
    my $trustTask = &callCurl ($trustCmd, "Get machinedId for $mip", $opt_v);

    my $machineId;
    if (defined $trustTask->{"items"}[0])
    {
        $machineId = $trustTask->{"items"}[0]->{"machineId"};
    }
    return $machineId;
}

#======================================================
# Get list of desired modules for discovery.
#======================================================
sub getModuleList {

    my @moduleList = ();

    if (defined $opt_l) {
        push @moduleList, {"module" => "adc_core"};
    }
    if (defined $opt_p) {
        push @moduleList, {"module" => "access"};
    }
    my $haveShared = 0;
    if (defined $opt_s) {
        push @moduleList, {"module" => "asm"};
        push @moduleList, {"module" => "security_shared"};
        $haveShared = 1;
    }
    if (defined $opt_f) {
        push @moduleList, {"module" => "firewall"};
        if ($haveShared == 0)
        { 
            push @moduleList, {"module" => "security_shared"};
        }
    }
    return @moduleList;  
}

#======================================================
# handle framework
#======================================================
sub handleFrameworkUpdade {
    my ($trustTask, $bigip) = @_;

    my $mip =  $bigip->{"mip"};
    my $needUpdate = 0;
    my $continue = 0;

    my $trustLink = $trustTask->{"selfLink"};

    my %patchBodyHash = ("status"=>"STARTED");
    my $patchBody;
    my $trustPatchCmd;

    if (defined $bigip->{"fwUpg"})
    {
        # if the csv file defines the action
        $fwUpg = $bigip->{"fwUpg"};

        if (lc($fwUpg) eq "skip")
        {
            &printAndLog(STDOUT, 1, "$mip   Skip framework upgrade\n");
            $patchBodyHash{"ignoreFrameworkUpgrade"} = "true";
            $patchBody = encode_json(\%patchBodyHash);

            $trustPatchCmd = "curl -s -k -u $bigiqCreds -H \"$contType\" -X PATCH -d \'$patchBody\' $trustLink";
            $trustTask = &callCurl ($trustPatchCmd, "framework action $fwUpg", $opt_v);
            $trustLink = $trustTask->{"selfLink"};
            $continue = 1;
        }
        else
        {
            # action is upgrade
            $needUpdate = 1;
        }
    }
    else
    {
        # if no action in the csv file, use the default based on the -u flag 
        if (defined opt_u and opt_u)
        {   
            $needUpdate = 1;
        }
        else
        {
            &printAndLog(STDOUT, 1, "$mip   Framework needs updating.  Must specity skip or upgrade in csv file, or use -u on command line\n");
            $continue = 0;
        }
    }

    if ($needUpdate)
    {
        &printAndLog(STDOUT, 1, "$mip   Upgrade the framework\n");
        $patchBodyHash{"confirmFrameworkUpgrade"} = "true";
        if ($trustTask->{"requireRootCredential"})
        {
            $patchBodyHash{"rootUser"} = $bigip->{"ruser"};
            $patchBodyHash{"rootPassword"} = $bigip->{"rpwd"};
        }
        $patchBody = encode_json(\%patchBodyHash);
        $trustPatchCmd = "curl -s -k -u $bigiqCreds -H \"$contType\" -X PATCH -d \'$patchBody\' $trustLink";
        $trustTask = &callCurl ($trustPatchCmd, "update framework", $opt_v);
        $continue = 1;
    }

    return $continue;
}

#======================================================
# Discover specified modules.
#======================================================
sub discoverModules {

    my ($mip, $machineId) = @_;
    my $discoverStart = gettimeofday();
    my $success = 0;

    # get the list of modules to discover
    my @moduleList = getModuleList();
    if (scalar @moduleList eq 0)
    {
        return 0;
    }

    my %postBodyHash = ("moduleList" => \@moduleList, "status" => "STARTED");

    # get the discovery task based on the machineId
    my $findDiscoverTaskCmd = "curl -s -k -u $bigiqCreds -H \"$contType\" -X GET \"https://localhost/mgmt/cm/global/tasks/device-discovery?\\\$filter=deviceReference/link+eq+\'*$machineId*\'+and+status+eq+\'FINISHED\'\"";
    my $discoveryTask = &callCurl ($findDiscoverTaskCmd, "Find discovery task for $mip $machineId", $opt_v);

    my @discoveryTaskItems = $discoveryTask->{"items"};
    my $discoverTask;
    my $postBodyJson;
    if (defined $discoveryTask->{"items"}[0])
    {
        # PATCH the existing discovery task
        my $discoveryTaskSelfLink = $discoveryTask->{"items"}[0]->{"selfLink"};
        $postBodyJson = encode_json(\%postBodyHash);
        my $discoverCmd = "curl -s -k -u $bigiqCreds -H \"$contType\" -X PATCH -d \'$postBodyJson\' $discoveryTaskSelfLink";
        $discoverTask = &callCurl ($discoverCmd, "Patch discovery task for $mip", $opt_v);
        &printAndLog(STDOUT, 1, "$mip   Discover task " . $discoverTask->{"status"} . "\n");
        $discoverTask = &pollTask($bigiqCreds, $discoveryTaskSelfLink, $opt_v);
    }
    else
    {
        # POST a new discovery task
        $postBodyHash{"deviceReference"}{"link"} = "cm/system/machineid-resolver/$machineId";
        $postBodyJson = encode_json(\%postBodyHash);

        my $newDiscoverTaskCmd = "curl -s -k -u $bigiqCreds -H \"$contType\" -X POST  -d \'$postBodyJson\' \"https://localhost/mgmt/cm/global/tasks/device-discovery\"";
        $discoverTask = &callCurl ($newDiscoverTaskCmd, "Create discovery task for $mip", $opt_v);
        &printAndLog(STDOUT, 1, "$mip   Discover task " . $discoverTask->{"status"} . "\n");

        my $newDiscoverTaskSelfLink = $discoverTask->{"selfLink"};
        $discoverTask = &pollTask($bigiqCreds, $newDiscoverTaskSelfLink, $opt_v);
    }

    # process overall results
    my $discoverStatus = $discoverTask->{"status"};
    $DeviceStatus{$mip}{"discover_status"} = $discoverStatus;
    my $discoverEnd = gettimeofday();
    my $et = sprintf("%d", $discoverEnd - $discoverStart);
    &printAndLog(STDOUT, 1, "$mip   Discover task $discoverStatus, $et seconds\n");

    if ($discoverStatus eq "FAILED")
    {
        $DeviceStatus{$mip}{"discover_error"} = $discoverTask->{"errorMessage"};
        &printAndLog(STDOUT, 1, "$mip     " . $discoverTask->{"errorMessage"} . "\n");
        $success = 0;
    }
    else
    {
        $success = 1;
    }

    # process module results
    my @discoveredModuleList = @{$discoverTask->{"moduleList"}};
    foreach my $module (@discoveredModuleList)
    {
        my $moduleName = $module->{"module"};
        my $moduleStatus = $module->{"status"};
        $DeviceStatus{$mip}{"discover_$moduleName"} = $moduleStatus;

        if ($moduleStatus eq "FAILED")
        {
            &printAndLog(STDOUT, 1,  "$mip     " . $moduleName . ": " . $module->{"errorMsg"} . "\n");
        }
    }
    return $success;
}

sub getImportParms {
    my %postBodyHash = ("skipDiscovery"=>"true", "snapshotWorkingConfig"=>"false", "useBigiqSync"=>"false" );
    if (defined $bigip->{"haname"})
    {
        $postBodyHash{"clusterName"} = $bigip->{"haname"};
        $postBodyHash{"useBigiqSync"} = "true";
    }
    return %postBodyHash;
}

#======================================================
# Import Modules for specified device
#======================================================
sub importModules {

    my ($mip, $machineId) = @_;
    if ((defined $opt_l) and (defined $DeviceStatus{$mip}{"discover_adc_core"}))
    {
        my $ltmSuccess = 0;
        if ($DeviceStatus{$mip}{"discover_adc_core"} eq "FINISHED")
        {
            %postBodyHash = getImportParms();
            $postBodyHash{"name"} = "import-adc_core_$mip";
            $postBodyHash{"createChildTasks"} = "false";
            $ltmSuccess = importModule($mip, $machineId, "ltm", "https://localhost/mgmt/cm/adc-core/tasks/declare-mgmt-authority", %postBodyHash);
        }
    }

    if ((defined $opt_p) and (defined $DeviceStatus{$mip}{"discover_access"}))
    {
        my $apmSuccess = 0;
        if ($DeviceStatus{$mip}{"discover_access"} eq "FINISHED")
        {
            # APM import is special case due to access groups
            $apmSuccess = importApm($mip);
        }
    }

    if ((defined $opt_s) and (defined $DeviceStatus{$mip}{"discover_asm"}))
    {
        my $asmSuccess = 0;
        if ($DeviceStatus{$mip}{"discover_asm"} eq "FINISHED")
        {
            %postBodyHash = getImportParms();
            $postBodyHash{"name"}="import-asm_$mip";
            $postBodyHash{"createChildTasks"} = "true";
            $asmSuccess = importModule($mip, machineId, "asm", "https://localhost/mgmt/cm/asm/tasks/declare-mgmt-authority", %postBodyHash);
        }
    }

    if ((defined $opt_f) and (defined$DeviceStatus{$mip}{"discover_firewall"}))
    {
        my $afmSuccess = 0;
        if ($DeviceStatus{$mip}{"discover_firewall"} eq "FINISHED")
        {
            %postBodyHash = getImportParms();
            $postBodyHash{"name"}="import-afm_$mip";
            $postBodyHash{"createChildTasks"} = "true";
            $afmSuccess = importModule($mip, $machineId,"afm" , "https://localhost/mgmt/cm/firewall/tasks/declare-mgmt-authority", %postBodyHash);
        }
    }

    # only report success if all requested modules were successful
    if ((defined $ltmSuccess) and ($ltmSuccess eq 0))
    {
        return 0;
    }
    if ((defined $apmSuccess) and ($apmSuccess eq 0))
    {
        return 0;
    }
    if ((defined $asmSuccess) and ($asmSuccess eq 0))
    {
        return 0;
    }
    if ((defined $afmSuccess) and ($afmSuccess eq 0))
    {
        return 0;
    }
    return 1;
}

#======================================================
# A subroutine for importing individual module.
#======================================================
sub importModule {
    my ($mip, $machineId, $module, $dmaUrl, %postBodyHash) = @_;
    my $importStart = gettimeofday();

    my $findImportTaskCmd = "curl -s -k -u $bigiqCreds -H \"$contType\" -X GET \"$dmaUrl?\\\$filter=deviceReference/link+eq+\'*$machineId*\'\"";
    my $findImportTask = &callCurl ($findImportTaskCmd, "Find $module import task for $mip $machineId ", $opt_v);
    my @findImportTaskItems = $findImportTask->{"items"};
    my $importTask;
    my $success = 0;
    my $postBodyJson;
    my $importTaskLink;

    if (defined $findImportTask->{"items"}[0])
    {
        # PATCH the existing import task
        $importTaskLink = $findImportTask->{"items"}[0]->{"selfLink"};
        $postBodyJson = encode_json(\%postBodyHash);

        my $importCmd = "curl -s -k -u $bigiqCreds -H \"$contType\" -X PATCH -d \'$postBodyJson\' $importTaskLink";
        $importTask = &callCurl ($importCmd, "Patch $module import task for $mip", $opt_v);
        &printAndLog(STDOUT, 1, "$mip   $module import task " . $importTask->{"status"} . "\n");
    }
    else
    {
        # POST a new import task
        $postBodyHash{"deviceReference"}{"link"} = "cm/system/machineid-resolver/$machineId";
        $postBodyJson = encode_json(\%postBodyHash);

        my $newImportTaskCmd = "curl -s -k -u $bigiqCreds -H \"$contType\" -X POST  -d \'$postBodyJson\' \"$dmaUrl\"";
        $importTask = &callCurl ($newImportTaskCmd, "Create $module import task for $mip", $opt_v);
        &printAndLog(STDOUT, 1, "$mip   $module import task " . $importTask->{"status"} . "\n");
        $importTaskLink = $importTask->{"selfLink"};
    }

    # The task may finish but be pending conflicts (asm/afm) or child task conflicts (shared-security)
    # if we get conflicts, we mark then to use BigIQ, patch the task back to started, and poll again
    #my $done = 0;
    my $loopCount = 0;
    my $importStatus = "";
    while (not $done)
    {
        $importTask = &pollTask($bigiqCreds, $importTaskLink, $opt_v);

        if ($loopCount++ > 5)
        {
            &printAndLog(STDOUT, 1, "$mip     Exiting import with max tries\n");
            last;
        }

        $importStatus = $importTask->{"status"};
        $DeviceStatus{$mip}{"import_${module}_status"} = $importStatus;

        my $currentStep = $importTask->{"currentStep"};
        my $importSelfLink = $importTask->{"selfLink"};

        if ($importStatus eq "FINISHED")
        {
            if (($currentStep eq "PENDING_CONFLICTS") or ($currentStep eq "PENDING_CHILD_CONFLICTS"))
            {
                &printAndLog(STDOUT, 1, "$mip     $currentStep\n");

                my @conflicts = @{$importTask->{"conflicts"}};
                if (resolveConflicts($mip, $module, $currentStep, $importSelfLink, @conflicts))
                {
                    $done = 0;
                }
                else
                {
                    # error resolving conflicts, give up
                    print "$mip     Import had error resolving conflicts, we are done\n";    # debug
                    $done = 1;
                    $success = 0;
                }
            }
            elsif (($currentStep eq "DONE") or ($currentStep eq "COMPLETE"))
            {
                # normal compleation
                $done = 1;
                $success = 1;
            }
            else
            {
                # finished at unknown step 
                &printAndLog(STDOUT, 1, "$mip     Import finished with currentStep: $currentStep \n");
                $done = 1;
                $success = 0;
            }
        }
        elsif ($importStatus eq "FAILED")
        {
            $done = 1;
            $DeviceStatus{$mip}{"import_${module}_currentStep"} = $currentStep;
            $DeviceStatus{$mip}{"import_${module}_error"} = $importTask->{"errorMessage"};
            &printAndLog(STDOUT, 1, "$mip     Import ${module} failed, $currentStep $importTask->{'errorMessage'} \n");
            $success = 0;
        }
        else
        {
            $done = 1;
            &printAndLog(STDOUT, 1, "$mip     Import done with status: $importStatus \n");
            $success = 0;
        }
    } #end task loop

    my $importEnd = gettimeofday();
    my $et = sprintf("%d", $importEnd - $importStart);
    &printAndLog(STDOUT, 1, "$mip   $module import task $importStatus, $et seconds\n");

    return $success;
}

#======================================================
# A subroutine for importing APM.
#======================================================
# APM needs an access group.
# If none exist, one will be created.
# The name should be specified with the -g option, otherwise it will default to "access_group"
sub importApm {
    my ($mip) = @_;
    my $importStart = gettimeofday();

    # find access group name
    my $machineId = $DeviceStatus{$mip}{"machineId"};
    my $accessGroupName;

    my $statusCmd = "curl -s -k -u $bigiqCreds -H \"$contType\" -X GET \"https://localhost/mgmt/cm/access/utility/view/mgmt-authority-status\"";
    my $statusTask = &callCurl ($statusCmd, "Find APM access group name for $mip ", $opt_v);
    my $importTask;
    my $postBodyJson;
    my %postBodyHash = ();
    my $success = 0;
    my $importCmd;

    # get access group name from command line.  Default to "access_group" if not specified 	
    if (defined $opt_g && $opt_g) {
        $accessGroupName = $opt_g;
    }
    else
    {
        $accessGroupName = "access_group";
    }

    # check if access group already exists
    my @items = @{$statusTask->{"items"}};
    my $actionType = "CREATE_ACCESS_GROUP";
    foreach my $item (@items)
    {
        my $groupName = $item->{"groupName"};
        if ($accessGroupName eq $groupName) {
            $actionType = "EDIT_ACCESS_GROUP";
            last;
        }
    }

    # start import 
    $postBodyHash{"actionType"} = $actionType;
    $postBodyHash{"groupName"} = "$accessGroupName";

    if ($actionType eq "CREATE_ACCESS_GROUP") {
        $postBodyHash{"sourceDevice"}{"deviceReference"}{"link"} = "http://localhost/mgmt/cm/system/machineid-resolver/cm/system/machineid-resolver/$machineId";
        $postBodyHash{"sourceDevice"}{"skipConfigDiscovery"} = "true";
        if (defined $bigip->{"haname"})
        {
            $postBodyHash{"sourceDevice"}{"clusterName"} = $bigip->{"haname"};
        }
    }
    else
    {
        $postBodyHash{"nonSourceDevices"}[0]{"deviceReference"}{"link"} = "http://localhost/mgmt/cm/system/machineid-resolver/cm/system/machineid-resolver/$machineId";
        $postBodyHash{"nonSourceDevices"}[0]{"skipConfigDiscovery"} = "true";
	    if (defined $bigip->{"haname"})
        {
            $postBodyHash{"nonSourceDevices"}[0]{"clusterName"} = $bigip->{"haname"};
        }
    }
    $postBodyJson = encode_json(\%postBodyHash);

    $importCmd = "curl -s -k -u $bigiqCreds -H \"$contType\" -X POST  -d \'$postBodyJson\' \"https://localhost/mgmt/cm/access/tasks/mgmt-authority\"";
    $importTask = &callCurl ($importCmd, "Import apm $mip", $opt_v);
    &printAndLog(STDOUT, 1, "$mip   apm import task " . $importTask->{"status"} . " ($actionType $accessGroupName)\n");

    # finish import
    $importTask = &pollTask($bigiqCreds, $importTask->{"selfLink"}, $opt_v);
    my $importStatus = $importTask->{"status"};
    $DeviceStatus{$mip}{"import_apm_status"} = $importStatus;

    my $importEnd = gettimeofday();
    my $et = sprintf("%d", $importEnd - $importStart);
    &printAndLog(STDOUT, 1, "$mip   apm import task $importStatus, $et seconds\n");

    my $currentStep = $importTask->{"currentStep"};
    my $importSelfLink = $importTask->{"selfLink"};

    if ($importStatus eq "FINISHED")
    {
        if (($currentStep ne "DONE") and ($currentStep ne "COMPLETE"))
        {
            &printAndLog(STDOUT, 1, "$mip   apm import task finished with currentStep: $currentStep \n");
            $success = 0;
        }
        else
        {
            $success = 1;
        }
    }
    elsif ($importStatus eq "FAILED")
    {
        $DeviceStatus{$mip}{"import_apm_currentStep"} = $currentStep;
        $DeviceStatus{$mip}{"import_apm_error"} = $importTask->{"errorMessage"};
        &printAndLog(STDOUT, 1, "$mip     apm import failed, $currentStep $importTask->{'errorMessage'} \n");
        $success = 0;
    }
    else
    {
        &printAndLog(STDOUT, 1, "$mip     apm import done with status: $importStatus \n");
        $success = 0;
    }
    return $success;
}

#======================================================
# A subroutine for resolving conflicts.
#======================================================

sub resolveConflicts {
    my ($mip, $module, $currentStep, $taskLink, @conflicts) = @_;
    my $conflictResolutionStart = gettimeofday();

    my $numConflicts = 0;
    $DeviceStatus{"all"}{"conflict"} ++;    #devices with conflicts;
    $success = 1;

    # open temp file for resolving conflicts
    (my $conflicts_file, my$conflicts_filename) = tempfile("conflicts_XXXXXXXX", SUFFIX => ".json", UNLINK => 1);

    # find the different configs and put the diffs in the log
    my @conflictStrs = ();
    foreach my $conflict (@conflicts)
    {
        if (ref($conflict) eq "HASH")
        {
            if ($conflict->{"fromReference"}{"link"})
            {
                my $fromRef = $conflict->{"fromReference"}{"link"};
                my $from = &callCurl("curl -s -k -u $bigiqCreds -X GET $fromRef", "show the 'from' (BIG-IQ working config)", $opt_v);
            }

            if ($conflict->{"toReference"}{"link"})
            {
                my $toRef = $conflict->{"toReference"}{"link"};
                my $to = &callCurl("curl -s -k -u $bigiqCreds -X GET $toRef", "show the 'to' (BIG-IP discovered config)", $opt_v);
            }

            $conflict->{"resolution"} = "USE_BIGIQ";

            # add this conflict to an array of them
            push(@conflictStrs, to_json($conflict));
            $numConflicts++;
        }
    }

    &printAndLog(STDOUT, 1, "$mip     Number of conflicts: $numConflicts \n");
    $DeviceStatus{$mip}{"conflicts"}{$module}{$currentStep} = $numConflicts;

    my $conflicts = join(",", @conflictStrs);

    # use a temp file for the conflict patch data since it micht be too big for the command line
    my $conflict_patch_data = "{\"status\":\"STARTED\",\"conflicts\":[$conflicts]}";
    print $conflicts_file $conflict_patch_data;
    print LOG "patch data for conflicts: $conflict_patch_data\n";
    my $resolveCmd = "curl -s -k -u $bigiqCreds -H \"$contType\" -X PATCH -d \@$conflicts_filename $taskLink";

    my $resolveTask = &callCurl ($resolveCmd, "$module conflict resolution for $mip", $opt_v);
    my $resolveLink = $resolveTask->{"selfLink"};
    $resolveTask = &pollTask($bigiqCreds, $resolveLink, $opt_v);

    # check, log error status
    my $conflictStatus = $resolveTask->{"status"};
    $DeviceStatus{$mip}{"resolve_${module}_status"} = $conflictStatus;

    my $conflictResolutionEnd = gettimeofday();
    my $et = sprintf("%d", $conflictResolutionEnd - $conflictResolutionStart);
    &printAndLog(STDOUT, 1, "$mip     Conflict resolution: $conflictStatus, $et seconds\n");
    if (defined $resolveTask->{"errorMessage"})
    {
        &printAndLog(STDOUT, 1, "$mip     $module Conflict resolution error: $resolveTask->errorMessage\n");
        $success = 0;
    }

    close $conflicts_file;
    return $success;
}

#======================================================
# A subroutine for total counts.
#======================================================

sub showTotals {

    my $string = sprintf "#\n# %-10s %-10s %-10s",
        "Success", "Failed", "Conflict";

    &printAndLog(STDOUT, 1, "$string\n");        
    &printAndLog(STDOUT, 1, "$table_head\n");  

    $string = sprintf "# %-10s %-10s %-10s",
        $DeviceStatus{"all"}{"success"},
        $DeviceStatus{"all"}{"failure"},
        $DeviceStatus{"all"}{"conflict"};
    &printAndLog(STDOUT, 1, "$string\n");
}

#======================================================
# A subroutine for making curl calls, pretty-printing the return for the caller, 
# and returning a pointer to the JSON.
#======================================================
sub callCurl {
    my ($call, $message, $printToo) = @_;

    # introduce the command, show it, then launch it
    &printAndLog(STDOUT, $printToo, "\n\n$message\n");
    my $callMask = &maskPasswords($call);    # mask all passwords in the curl command
    &printAndLog(STDOUT, $printToo, "$callMask\n");
    my @json = `$call 2>&1`;

    # check for catastrophic errors
    my $check4catastrophe = join("", @json);
    if ($check4catastrophe =~ /<h1>401 Authorization Required<\/h1>/) {
        # authentication error - bad credentials for BIG-IQ
        &printAndLog(STDOUT, $printToo, "$check4catastrophe\n");
        &printAndLog(STDERR, 1, "#\n## ERROR - BIG-IQ admin credentials, '$opt_q', do not have access.\n");
        &printAndLog(STDERR, 1, "#   Please retry, providing correct credentials with the -q option.\n#\n");
        &gracefulExit(1);
    }

    # no known catastrophes - format the JSON nicely and show it
    my $jsonWorker = JSON->new->allow_nonref; # create a new JSON object which converts non-references into their values for encoding
    my $jsonHash = $jsonWorker->decode($check4catastrophe); # converts JSON string into Perl hash(es)
    my $showRet = $jsonWorker->pretty->encode($jsonHash);   # re-encode the hash just so we can then pretty print it (hack-tacular!)
    my $maskln = &maskPasswords($showRet);            # mask all passwords in the JSON return
    &printAndLog(STDOUT, $printToo, "$maskln\n");

    # return the portable hash of JSON data
    return $jsonHash;
}

#======================================================
# A subroutine to take a string and return a copy with all
# the passwords masked out.
#======================================================
sub maskPasswords {
    my ($pwStr) = @_;

    $pwStr =~ s/("devicePassword"\s*:\s*)"[^"]+"/$1"XXXXXX"/g;
    $pwStr =~ s/("rootPassword"\s*:\s*)"[^"]+"/$1"XXXXXX"/g;
    $pwStr =~ s/-u\s+(\S[^:]+):\S+\s/-u $1:XXXXXX /g;

    return $pwStr;
}

#======================================================
# A subroutine for polling a task until it reaches a conclusion.
# $creds are the admin credentials for the curl call
# $taskLink is the URI to the POSTed task
#======================================================
sub pollTask {
    my ($creds, $taskLink, $printToo) = @_;

    # keep asking for status and checking the answer until the answer is conclusive
    &printAndLog(STDOUT, $printToo, "Polling for completion of '$taskLink'\n");
    my ($taskjpath, $taskdpath, $result, $ct, $taskanswer) = ("", "", "", 1, "");
    my $ctCurly = 0;
    do {
        sleep 5;
        ($taskanswer) = &callCurl("curl -s -k -u $creds -X GET $taskLink", "Attempt $ct", $printToo);
        if ($taskanswer->{"status"} =~ /^(FINISHED|CANCELED|FAILED|COMPLETED(_WITH_ERRORS)?)/) {
            $result = $taskanswer->{"status"};
        }
        $ct++;
    } while ($result eq "");
    &printAndLog(STDOUT, $printToo, "Finished - '$taskLink' got a result of '$result'.\n");

    # return the JSON pointer
    return $taskanswer;
}

#======================================================
# A subroutine for both printing to whatever file is given
# and printing the same thing to a log file.
# This script does a lot, so it may be useful to keep a log.
#======================================================
sub printAndLog {
    my ($FILE, $printToo, @message) = @_;

    my $message = join("", @message);
    print $FILE $message if ($printToo);
    print LOG $message;
}

#======================================================
# Print the log file and then exit, so the user knows which log
# file to examine.
#======================================================
sub gracefulExit {
    my ($status) = @_;
    &printAndLog(STDOUT, 1, "# Discovery log file: $log\n");    
    close LOG;
    exit($status);
}

#======================================================
# Pretty-print the time.
#======================================================
sub getTimeStamp {
    my ($Second, $Minute, $Hour, $Day, $Month, $Year, $WeekDay, $DayOfYear, $IsDST) = localtime(time); 
    my $time_string = sprintf ("%02d/%02d/%02d %02d:%02d:%02d",$Month+1,$Day,$Year+1900,$Hour,$Minute,$Second);
    return ($time_string);
}
