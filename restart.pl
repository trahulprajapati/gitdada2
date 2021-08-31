use strict;

sub check_pr {
my @cmdout = `netstat -tulp`;
if ($? >> 8 != 0) {
	die "Command failed - $!";
}
my $pid = undef;
my $fl = 1;
for my $pl (@cmdout) {
	if ($pl =~ /gitprep/) {
		my @tmp = split /\s+/, $pl;
		for my $t1 (@tmp) {
			if ($t1 =~ /gitprep/) {
				my @ida = split /\//, $t1;
				$pid = $ida[0];
				$pid =~ s/^\s+//;
			}
		}
	}
}
	return ($fl, $pid);
}

print "###################### Restarting Gitdada server  ################################\n";
print "Checking process... \n";
my ($fl, $pid) = check_pr();
#if ($fl == 1) { 
if ($pid =~ /\d/) {
	print "Gitdada process found. PID: $pid\n";
	print "################## Stoping Server ################################\n";
	system ("kill $pid");
	if ($? >>8 != 0) {
		die "System command failed for kill process - $! "
	}
	sleep 5;
	print "Verifying process \n";
	my ($fl, $pid1) = check_pr();
	#print " --$fl ,,-- $pid1 \n";
	if ($pid1 == undef) {
		print "Gidada Process killed \n";
	}else {
		die "Gitdada process still running  after kill. Please stop manually ";
	}

	print "################### Starting Server ################################\n";
	system ("sh /home/pronoor/gitprep/gitprep");

	print "Server started. \nVerifying the service \n";
	($fl, $pid) = check_pr();
	#print " --$fl ,,-- $pid \n";
	if (!$pid ) {
		print "Something went wrong, Gitdata process is not running, Please restart maually \n";
		exit;
	} else {
		print "Gitdada serveer restarted successfully. PID : $pid \n";
		exit;
	}
	#}

}else {
	print "Unable to get Gitdada process. Exiting.. \n";
	exit;
}
	#print "-- $_ \n" for (@cmdout);
