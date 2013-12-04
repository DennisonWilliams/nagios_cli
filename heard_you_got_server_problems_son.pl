#!/usr/bin/perl
# I run this in a loop with:
# watch -n 10 ./heard_you_got_server_problems_son.pl

#TODO: have this use the CWD module, untill then you need to update this
our $NAG_CLI = '/home/evoltech/src/contract/radicaldesigns/nagios_cli/nagios_cli.pl';
run_puppet();
while ($pid = waitpid(-1, WNOHANG) > 0) { }

sub run_puppet {
	# You could set up allarms with something like the following
	# --alarm \"/home/evoltech/src/contract/radicaldesigns/nagios_cli/alarm.sh ~/Music/SoundEffects/21382\^Sound-Effect---Crickets-01.mp3\" --alarmfilter host:huang
	my $check_puppet = "$NAG_CLI --host puppet.radicaldesigns.org --ssh";
	my ($cmd) = @_;
	my $check = "/bin/ps -e -o pid,command|grep \"nagios_cli.pl --host puppet\"|grep -v grep|wc -l";
	my $ct = `$check`;
	chomp $ct;
	return if ($ct);

	die "could not fork\n" unless defined(my $pid = fork);
	#return if $pid; #parent waits for child
	if ($pid) {
		return;
	}
	exec $check_puppet; #replace child with new process
	exit;
}
