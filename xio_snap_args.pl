#!/usr/bin/perl

# Author  : Pradeep, Prabhakaran
# Version : 2.1 
# This perl script is takes call from existing shell script for creating snapshots in XIO. This 
# will also map the created snapshots into $BACKUP host, where the backup are taken from these 
# volumes. 
# The argument this script takes is DB-DATA or DB-LOGS. Default is DB in case no argument is provided. 
# Requirements. 
# Create two consistency groups based on database data luns and database archive logs.
# Consistency group for database dataluns group as 'DB-DATA'
# Consistency group for database archive logs group as 'DB-LOGS'
# Version History. 
# Date
# 07082015 1.0 Created the script with generic requirement. Just create snapshots and map the luns. 
# 10082015 1.1 Unit testing done. All tests passed. 
# 13082015 2.0 New requirement - Initiating the scripts in sequence for different set of Snap-hosts.
# 13082015 2.1 Get argument and based on the value, take the snapshots accordingly. 
# 14082015 2.1 Unit testing done. All tests passed.  
# 

#Of course all perl programs start like this !
use strict;
use warnings;

# To get local time to use for some stuff. 

#my @now = localtime();
#my $timestamp = sprintf("%04d%02d%02d%02d%02d%02d", 
#                        $now[5]+1900, $now[4]+1, $now[3],
#                        $now[2],      $now[1],   $now[0]);
                        
my $_WORKGRP = shift || 'DB-DATA';
$_WORKGRP =~ tr/a-z/A-Z/;
my $FROMCONSID = $_WORKGRP;
my $TOCONSID = "SnapshotSet." . $_WORKGRP;
my $SNAPSUFFIX = ".snapshot." . $_WORKGRP;
my $BACKUPIG = "Host1";

my $verbose=0;

my $username="admin";
my $password="Xtrem10";
my $xms="sgrdcxio";

# To make Perl find the modules without the package being installed. 
use lib '../../lib', '.';

# These are your friends. 
use REST::Client;
use MIME::Base64;
use JSON;
use Data::Dumper;
#use Try::Tiny;

##split and join
#    @mydata = ( "Simpson:Homer:1-800-000-0000:40:M",
#                "Simpson:Marge:1-800-111-1111:38:F",
#                "Simpson:Bart:1-800-222-2222:11:M",
#                "Simpson:Lisa:1-800-333-3333:9:F",
#                "Simpson:Maggie:1-800-444-4444:2:F" );
#    foreach ( @mydata ) {
#        ( $last, $first, $phone, $age ) = split ( /:/ ); 
#        print "You may call $age year old $first $last at $phone.\n";
#    }


#
# Check the response from all API calls, and exit if they fail
#
sub checkerr($) {
	# Bring it on - I'm the one who takes the error - sigh !
	my ($cl) = @_;

	my $respcode=$cl->responseCode();
	return 0 if ($respcode>=200 && $respcode <300);

	my $msg = from_json($cl->responseContent())->{message};
	print STDERR "Error - $msg (response code $respcode)\n";
	exit(2);
}

my $client = REST::Client->new();
my $headers = {Authorization => "Basic ".encode_base64($username.":".$password), "Content-Type" => 'application/json'};

# Get a list of all snapshots that we can use for reference later

sub getsnapmap {
	$client->GET("https://$xms/api/json/types/lun-maps?full=1", $headers);
	checkerr($client);
	##lun-maps {vol-name, ig-name, mapping-id,lun}
	my $snapmap;
	my $response = decode_json($client->responseContent());
	my @lunmaps = @{ $response->{'lun-maps'} };
	for my $record (@lunmaps) {
		my $_volname = $record->{"vol-name"};
		my $_voligname = $record->{"ig-name"};
		my $_vollun = $record->{"lun"};
		my $_volmapname = $record->{"name"};
		##myvol1-snapshot
		# Get those luns that are only mapped to Backup host and volume name has SNAP-SUFFIX in it. 
		if ($_voligname eq $BACKUPIG && $_volname =~ /\Q$SNAPSUFFIX\E/) {$snapmap->{ $_volname } = join(':',$_voligname,$_vollun,$_volmapname);}
	}
	# Now take this boy !!
	return $snapmap
}    

my $snmapping = getsnapmap();
## Run through the old snap-shot mappings and delete the lun-mappings. 
if (keys (%$snmapping) > 0 ) {
	for my $ki ( keys %$snmapping ){
		my $ig; 
		my $ll;
		my $mapname;
		my @val = $snmapping->{$ki};
		foreach ( @val ) { 
			($ig, $ll, $mapname) = split ( /:/ ); 
			# Unmap the given snapshot volume
			$client->DELETE("https://$xms/api/json/v2/types/lun-maps?name=$mapname", $headers);
			checkerr($client);
			}
		# Delete the given volume - Change in NAA - Please note that. 
		$client->DELETE("https://$xms/api/json/v2/types/volumes/?name=$ki", $headers);
		checkerr($client);
	}
} else {
	# Gives me 0 - I couldn't find no earlier mappings. 
	print "We don't have any snapshots to remove the mappings \n";
}

## Create new snapshots now.
#my %body= ('from-consistency-group-id' => $FROMCONSID,
#           'to-snapshot-set-id' => $TOCONSID,
#	   'backup-snap-suffix' => $SNAPSUFFIX,
#	);
	
# Other way is to consistency-group-id=1,snapshot-set-name, tag-list.
# There are lot of ways in fact - this one i thinks the best.

my %body= ('consistency-group-id' => $FROMCONSID,
           'snapshot-set-name' => $TOCONSID,
           'snap-suffix' => $SNAPSUFFIX,
	);
$client->POST("https://$xms/api/json/v2/types/snapshots", encode_json(\%body), $headers);
checkerr($client);
# Process the response - Beware there should be some hard words !
my $resp = from_json($client->responseContent());
my @links = @{ $resp->{'links'} };
	for my $record (@links) {
		$client -> GET($record->{href}, $headers);
		checkerr($client);
		$resp = from_json($client->responseContent());
		#print Dumper \$resp;
		my $_vollun = $resp->{content}{"vol-id"}[1];
#		print "$_vollun\n";
#		my $_hrefstr = $record->{"href"};
#		#print "$_hrefstr\n";
#		my $_vollun = substr($_hrefstr, rindex($_hrefstr, '/') + 1);;
#		#$_hrefstr =~ m{(.*/)([^?]*)};
#		#($_hrefstr, $_luns) = split ("/",$_hrefstr,3);
#		#print "$_vollun\n";
		print STDERR "Map snapshot $_vollun to $BACKUPIG\n" if ($verbose);
		%body= ('vol-id' => $_vollun,
			'ig-id' => $BACKUPIG);
		$client->POST("https://$xms/api/json/v2/types/lun-maps", encode_json(\%body), $headers);
		checkerr($client);
		$resp = from_json($client->responseContent());
	}
# Finally, I'm done. Happy !
exit (0);
