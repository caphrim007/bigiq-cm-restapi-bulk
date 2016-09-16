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
# rewritten for BigIQ 5.0

## DESCRIPTION
# This script reads a CSV file containing a list of BIG-IPs and then:
# - Licenses each BIGIP device
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
my $log = "bulkLicense.$$.log";
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
    "v" =>  "Verbose screen output",
);

our($opt_h,$opt_c,$opt_q,$opt_k,$opt_a,$opt_r,$opt_u,$opt_g); 
our($opt_l,$opt_p,$opt_s,$opt_f,$opt_v,); 
getopts('hc:q:ka:r:g:lpsfvu');
if (defined $opt_h && $opt_h) {
    print "License multiple BIG-IP devices.\n";
    foreach my $opt (keys %usage) {
        print ("\t-$opt\t$usage{$opt}\n");
    }
    print "\ncsv format: ip, user, pw, cluster-name, framework-action, root-user, root-pw\n";
    print "  ip: ip address of the BigIP to license.\n";
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
    my ($mip, $aname, $apw, $base_reg_key) = split(/\s*,\s*/, $ln);

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
    $bigips[$index]{"base_reg_key"} = $base_reg_key;

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
&printAndLog(STDOUT, 1, "#\n# Start overall licensing process: $timestamp\n");


# Initialize Device status table
my %DeviceStatus;
$DeviceStatus{"all"}{"success"} = 0;
$DeviceStatus{"all"}{"already"} = 0;
$DeviceStatus{"all"}{"failure"} = 0;
$DeviceStatus{"all"}{"conflict"} = 0;

#======================================================
# Main loop
# Process License BIGIP devices 
#======================================================
my $i = 0;
for $bigip (@bigips) {
    my $mip = $bigip->{"mip"};
    my $user = $bigip->{"aname"};
    my $pw = $bigip->{"apw"};
    my $base_reg_key = $bigip->{"base_reg_key"};	

    my $deviceStart = gettimeofday();
    $timestamp = getTimeStamp();
    &printAndLog(STDOUT, 1, "\n$mip Started:  $timestamp\n");

    my $done = 0;
    my $successStatus = 0;   
    while (not $done) {
       if (licenseDevice($mip, $user, $pw, $base_reg_key)) {
              $successStatus = 1;
          }
       $done = 1;
       $i++;		
    }
    
    # We need licensing to be successful before we increment the success count
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
&printAndLog(STDOUT, 1, "\n# End overall licensing process:  $timestamp\n");

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
&showTotals();

#======================================================
# Finish up
#======================================================
&gracefulExit(0);

#======================================================
# Subroutine to license BIGIP.
#======================================================
sub licenseDevice {
    my ($mip, $user, $pass, $baseRegKey) = @_;
    my $licenseStart = gettimeofday();
    my $success = 0;

    #my %postBodyHash = ("moduleList" => \@moduleList, "status" => "STARTED");

    # get all license pools based on the machineId
    my $findLicensePools = "curl -s -k -u $bigiqCreds -H \"$contType\" -X GET \"https://localhost/mgmt/cm/shared/licensing/pools\"";
    my $licensePools = &callCurl ($findLicensePools, "Find BIGIQ license pool and filter on base reg key: $baseRegKey");
    my $member_uuid;   
    
    my $bcnt=0;
    while(1) {
    	if (defined $licensePools->{"items"}[$bcnt]) {
            if ($licensePools->{"items"}[$bcnt]->{"baseRegKey"} eq  $baseRegKey) {
               $member_uuid = $licensePools->{"items"}[$bcnt]->{"uuid"};
               last;
    	    } else {
 	        print "\nFinding base reg key to use as defined in config. Key is: ".$baseRegKey. "\n";
		$bcnt++;
                sleep 1;
     	    }
        }
    }		

    my %postBodyHash = ("deviceAddress" => $mip, "username" => $user, "password" => $pass);
   $postBodyJson = encode_json(\%postBodyHash);
    my $licenseCmd = "curl -s -k -u $bigiqCreds -H \"$contType\" -X POST  -d \'$postBodyJson\' \"https://localhost/mgmt/cm/shared/licensing/pools/$member_uuid/members\""; 

    $licenseTask = &callCurl ($licenseCmd, "POST license for device $mip");
    sleep 5;
 
    if (defined $licenseTask->{"code"} and $licenseTask->{"code"} == '400') {
	print "\nREST API POST FAILED: ERROR: ".$licenseTask->{"message"} . "\n";
        exit;
    } else {
    	&printAndLog(STDOUT, 1, "$mip   License task " . $licenseTask->{"state"} . "\n");
    	$licenseTask = &pollTask($bigiqCreds, $licenseTask->{"selfLink"}, $opt_v);

    	# process overall results
    	my $licenseStatus = $licenseTask->{"state"};
    	$LicenseStatus{$mip}{"license_status"} = $licenseStatus;
    	my $licenseEnd = gettimeofday();
    	my $et = sprintf("%d", $licenseEnd - $licenseStart);
    	&printAndLog(STDOUT, 1, "$mip   License task $licenseStatus, $et seconds\n");

    	if ($licenseStatus eq "FAILED") {
           $LicenseStatus{$mip}{"license_error"} = $licenseTask->{"errorMessage"};
           &printAndLog(STDOUT, 1, "$mip     " . $licenseTask->{"errorMessage"} . "\n");
           $success = 0;
    	} else {
           $success = 1;
    	}
    	return $success;
    }
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
        sleep 1;
        ($taskanswer) = &callCurl("curl -s -k -u $creds -X GET $taskLink", "Attempt $ct", $printToo);
        if ($taskanswer->{"state"} =~ /^(LICENSED|FAILED(_WITH_ERRORS)?)/) {
            $result = $taskanswer->{"state"};
        } else {
            my $state = $taskanswer->{"state"};	    
	    print "License status is $state: $ct\n"; 
            $ct++;
        }	
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
    &printAndLog(STDOUT, 1, "# License log file: $log\n");    
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
