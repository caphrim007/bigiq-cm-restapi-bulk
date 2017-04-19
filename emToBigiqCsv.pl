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

## DESCRIPTION
# This script reads a source CSV file containing a list of BIG-IPs and then
# converts to a format that is used by bulk discovery.
#
# CSV file format:
# - with creds:                        big_ip_adr,admin_user,admin_pw
# - creds from command line:           big_ip_adr
# - cluster with creds:                big_ip_adr,admin_user,admin_pw,ha-name
# - cluster, creds from command line:  big_ip_adr,,,ha-name
# Framework 
# - skip check (viprion):              big_ip_adr,admin_user,admin_pw,ha-name, skip
# - update:                            big_ip_adr,admin_user,admin_pw,ha-name, upate, root_user, root_pw

use Time::HiRes qw(gettimeofday);
use Data::Dumper qw(Dumper);    # for debug
use Data::Table;
use Text::CSV;

my $overallStartTime = gettimeofday();

# get input from the caller
use Getopt::Std;

my %usage = (
    "h" =>  "Help",
    "s" =>  "Path to source CSV export from Enterprise Manager with all BIG-IP devices. - REQUIRED",
    "t" =>  "Path to target CSV file with all BIG-IP devices for discovery and import into BIG-IQ - REQUIRED" 
);

our($opt_h,$opt_s, $opt_t); 
getopts('hs:t:');

if (defined $opt_h && $opt_h) {
    print "Discover multiple BIG-IP devices.\n";
    foreach my $opt (keys %usage) {
        print ("\t-$opt\t$usage{$opt}\n");
    }
    print "\ncsv format: ip, user, pw, cluster-name, framework-action, root-user, root-pw\n";
    print "csv format: ip, user, pw, ha-name\n";
    print "\nexample lines:\n";
    print "  1.2.3.4\n";
    print "  1.2.3.4, admin, pw\n";
    print "  1.2.3.4, admin, pw, ha-name\n";
    print "  1.2.3.4,,, ha-name\n";
    print "  1.2.3.4, admin, pw,, skip\n";
    print "  1.2.3.4, admin, pw,, update, root, root-pw\n";
    exit;
}

print "================================================================================\n";
print "Enterprise Manager device inventory export conversion to BIG-IQ device inventory.\n";
print "================================================================================\n";

# Managment address column extract from csv
my %ln;
my $t = Data::Table::fromCSV("$opt_s");
my $a = $t->subTable(undef, ['ManagementAddress']);
my $u = $t->subTable(undef, ['Username']);
my $p = $t->subTable(undef, ['Password']);

my @column_mgmt_addr = $a->data;
my @column_username = $u->data;
my @column_password = $p->data;

# of lines
open(my $fh, '<', $opt_s) or die "Can't open $opt_s: $!";
$lines++ while <$fh>;
close $fh;

foreach my $addr (@column_mgmt_addr) {
    for (my $i=0; $i <= $lines-2; $i++) {
	$ln{"addr$i"} .= $addr->[$i]->[0];
    }
}

foreach my $user (@column_username) {
    for (my $i=0; $i <= $lines-2; $i++) {
	$ln{"addr$i"} .= ",$user->[$i]->[0]";
    }
}

foreach my $pass (@column_password) {
    for (my $i=0; $i <= $lines-2; $i++) {
	$ln{"addr$i"} .=",$pass->[$i]->[0]";
    }
}

#DEBUG#############
#print Dumper(\%ln);
###################

# Open target CSV
open( CSV, ">$opt_t") || die "Failed for: $!\n";
foreach my $line (keys %ln) {
    print CSV $ln{$line}. "\n";
}
