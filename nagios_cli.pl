#!/usr/bin/perl
use WWW::Mechanize;
use Getopt::Long;
use Data::Dumper;
use JSON qw( decode_json );
use Net::SSH qw(ssh_cmd sshopen2);
#use Curses::UI;

our ($HOST, $PORT, $CURL, $VERBOSE, $SSH, $DURATION, $ALARM);
$PORT = 8080;
$CURL = '/usr/bin/curl';
$VERBOSE = 0;
$DURATION = 0;
my ($MESSAGE, $ACK, $help);

my $result = GetOptions (
	"host:s" => \$HOST,
	"port:i" => \$PORT,
	"curl:s" => \$CURL,
	"message:s" => \$MESSAGE,
	"ack:s" =>	\$ACK,
	"verbose+" => \$VERBOSE,
	"duration:i" => \$DURATION,
	"alarm:s" => \$ALARM,
	"alarmfilter:s" => \$ALARMFILTER,
	"ssh" => \$SSH,
	"help" => \$help
);

if ($help) {
	usage();
	exit;
}

# Get the current jim jam
my $json;
$json = curl('state');
#open (STATE, '<', 'state.json') or die;
#while (<STATE>) { $json .= $_; }
#close STATE;

print "$json\n" if ($VERBOSE>3);
# parse the json for issues
my $djson = decode_json($json);


# Acknowledge an issue by number(s) with optional message
# Default get a list of all problems
if ($ACK) {
	ack($ACK, $MESSAGE, $djson);
} else {
	issues($djson);
}

sub ack {
	my ($ack, $message, $json) = @_;
	print "ack($ack, $message, \$json)\n"
		if ($VERBOSE>1);

	# parse the $ack
	if ($ack =~ /^(?:host):(\d+(?:,\d+)?)$/) {
		$shostids = $1;
		foreach my $hostid (split(/,/, $shostids)) {
			ack_host_by_id($hostid, $message, $json);
		}
	} elsif ($ack =~ /^(?:service):(\d+(?:,\d+)?)$/) {
		# We have a list of service ids to be ack'd
		$sservids = $1;
		foreach my $servid (split(/,/, $sservids)) {
			ack_service_by_id($servid, $message, $json);
		}
	} else {
		ack_by_plugin_output($ack, $message, $json);
	}
}

sub ack_service_by_id {
	my ($servid, $message, $djson) = @_;
	print "ack_service_by_id($servid, $message, \$djson)\n" if ($VERBOSE>1);

	my $sct = 0;
	foreach my $host (keys %{$djson->{'content'}}) {
		foreach my $service (keys %{$djson->{'content'}{$host}{'services'}}) {
			$sct++;
			if (
				$djson->{'content'}{$host}{'services'}{$service}{'current_state'} != 0 &&
				$sct == $servid
			) {

				my $jack = '{ "host": "'. $host .'", "service": "'. $service 
					.'", "comment": "'. $message .'" }';

				my $json = curl('acknowledge_problem', $jack);

				print "$json\n" if $VERBOSE;
			}
		}
	}
}

sub ack_host_by_id {
	my ($hostid, $message, $djson) = @_;
	print "ack_host_by_id($hostid, $message, \$djson)\n" if ($VERBOSE>1);

	my $hct = 0;
	foreach my $host (keys %{$djson->{'content'}}) {
		$hct++;
		if (
			$djson->{'content'}{$host}{'current_state'} != 0 &&
			$hct == $hostid
		) {

			my $jack = '{ "host": "'. $host .'", "comment": "'. $message .'" }';

			my $json = curl('acknowledge_problem', $jack);

			print "$json\n" if $VERBOSE;
		}
	}
}

sub ack_by_plugin_output {
	my ($ack, $message, $djson) = @_;
	print "ack_by_plugin_output($ack, $message, \$djson)\n"
		if ($VERBOSE>2);

	foreach my $host (keys %{$djson->{'content'}}) {
		if (
			$djson->{'content'}{$host}{'current_state'} != 0 &&
			$djson->{'content'}{$host}{'plugin_output'} =~ /$ack/
		) {

			my $jack = '{ "host": "'. $host .'", "comment": "'. $message .'" }';

			my $json = curl('acknowledge_problem', $jack);

			print "$json\n" if $VERBOSE;

		}

		foreach my $service (keys %{$djson->{'content'}{$host}{'services'}}) {
			if (
				$djson->{'content'}{$host}{'services'}{$service}{'current_state'} != 0 &&
				$djson->{'content'}{$host}{'services'}{$service}{'plugin_output'} =~ /$ack/
			) {

				my $jack = '{ "host": "'. $host .'", "service": "'. $service 
					.'", "comment": "'. $message .'" }';

				my $json = curl('acknowledge_problem', $jack);

				print "$json\n" if $VERBOSE;
			}
		}
	}
}

sub issues {
	my ($djson) = @_;
	
	my $hct = 0;
	my $sct = 0;
	foreach my $host (keys %{$djson->{'content'}}) {
		$hct++;
		# We also want to report on doown'd hosts
		if (
			# Don't care if the hoost is fine
			$djson->{'content'}{$host}{'current_state'} != 0 &&

			# Don't care if the host has already been acknowledged
			$djson->{'content'}{$host}{'problem_has_been_acknowledged'} == 0  &&

			# Don't care is the host is in scheduled downtime
			keys $djson->{'content'}{$host}{'downtimes'} == 0 &&

			# Don't care if the issue has not existed for longer then $DURATION minutes
			((time()-$djson->{'content'}{$host}{'last_state_change'})/60) >= $DURATION
		) {
			# While we will print the issue in a soft state we only alarm in a hard state
			if ($djson->{'content'}{$host}{'current_state'} == $djson->{'content'}{$host}{'last_hard_state'}) {
				alert($host, $service);
			}
			print $hct ." : ". $host ." : ". $service ." : ". $djson->{'content'}{$host}{'plugin_output'} ."\n";
		}

		foreach my $service (keys %{$djson->{'content'}{$host}{'services'}}) {
			#print Dumper($service) ."\n";
			$sct++;
			if (
				# Don't care if the service is fine
				$djson->{'content'}{$host}{'services'}{$service}{'current_state'} != 0 &&

				# Don't care if the service has already been acknowledged
				$djson->{'content'}{$host}{'services'}{$service}{'problem_has_been_acknowledged'} == 0  &&

				# Don't care is the service is in scheduled downtime
				keys $djson->{'content'}{$host}{'services'}{$service}{'downtimes'} == 0 &&

				# Don't care if the issue has not existed for longer then $DURATION minutes
				((time()-$djson->{'content'}{$host}{'services'}{$service}{'last_state_change'})/60) >= $DURATION
			) {
				# While we will print the issue in a soft state we only alarm in a hard state
				if ($djson->{'content'}{$host}{'services'}{$service}{'current_state'} == $djson->{'content'}{$host}{'services'}{$service}{'last_hard_state'}) {
					alert($host, $service, $djson);
				}
				print $sct ." : ". $host ." : ". $service ." : ". $djson->{'content'}{$host}{'services'}{$service}{'plugin_output'} ."\n";
			}
		}
	}
}

# we abstract this out so that we can tunnel it over ssh if we need to
sub curl {
	my ($path, $json) = @_;
	my $cmd = "$CURL -s ";
	$cmd .= "-H \"Content-Type:application/json\" -d '$json' " if $json;
	my $response;

	if ($SSH) {
		$cmd .= "http://localhost:$PORT/$path";
		print "ssh_cmd($HOST, $cmd)\n" if $VERBOSE;
		$response = ssh_cmd($HOST, $cmd)
			or die "could not run $cmd: $!";
	} else {

		die "$CURL not good"
			if (! -x $CURL);
		$cmd .= "http://$HOST:$PORT/$path";

		print "$cmd\n" if $VERBOSE;
		$cmd .= "http://$HOST:$PORT/$path";
		$response = `$cmd`;
	}

	return $response;
}

sub alert {
	return if (!defined($ALARM));
	my ($host, $service, $djson) = @_;

	# If the $ALARM command is already running do not try to run again
	$ALARM =~ /^([^ ]+)/;
	my $fcmd = $1;
	if ($fcmd =~ /.*\/([^\/]+)/) { $fcmd = $1; }

	# There is a race condition here ... we'll check for it below
	return if (! `pgrep $fcmd|wc -l`);

	# If there was an alarmfilter passed in lets use that
	if ($ALARMFILTER =~ /^(?:host):([^\s]+)/) {
		return if ($host ne $1);
	} 

	open (DL, ">>", "/tmp/nagios_cli.log");
	print DL "ALARMFILTER: $ALARMFILTER, host: $host, 1: $1\n";
	print DL Dumper($djson) ."\n";
	close(DL);

	# Else background the alarm command
	# system will fork and wait for the child to end :(
	#system("$ALARM &");
	die "could not fork\n" unless defined(my $pid = fork);
	#return if $pid; #parent waits for child
	if ($pid) {
		# This sleep is protection against the race condition above
		sleep 1;
		return;
	}
	exec $ALARM; #replace child with new process
}

sub usage {
print <<END;
$0 --host <hostname> [<options>]
Interact with the nagios api (https://github.com/xb95/nagios-api) from the
command line.  With no other options this script will print the list of
issues known by nagios prefixed with a issue #.

--port <port>       : The port that the nagios api is listening on
--curl <curl_path>  : The system path to the curl binary
--ssh               : Connect to <hostname> over ssh then run the query via 
                      curl.  This requires ssh key auth to be set up.
--ack <#|SD>        : Send an acknowledgement to the server using either the
                      service #, or a regular expression matching the service
                      description.
--message <message> : The message to use in the issue acknowledgement
--alarm <cmd>				: Run <cmd> whenever there is an issue
--alarmfilter <filter>
                    : Filter all alarms by service or host.  
                      <filter> := s:<service_name>|h:<host_name>
--duration <min>		: Do not raise an issue unless it has existed for <min>
--verbose           : Increase verbosity of output.  This can be repeated.
--help              : Print this help message

END
}
